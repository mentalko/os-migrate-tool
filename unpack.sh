#!/usr/bin/env bash
# os-migrate-tool :: unpack.sh
# Восстановление на CachyOS (Arch) из прогона на SSD.
# Запускается прямо с SSD:  ./unpack.sh [--packages|--appimages|--dotfiles|--data|--agents|--browsers|all] [--dry-run]
# Флаги можно комбинировать; all = все компоненты прогона.
set -euo pipefail

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$TOOL_DIR/lib.sh"

# ---------- 0. --dry-run ----------
omt_dryrun "$@"
CLEAN_ARGS=()
for arg in "$@"; do [[ "$arg" == "--dry-run" || "$arg" == "-n" ]] || CLEAN_ARGS+=("$arg"); done
set -- "${CLEAN_ARGS[@]}"
(( DRY )) && warn "РЕЖИМ DRY-RUN: ничего не будет установлено и распаковано, только отчёт."

require_not_root

# ---------- 1. ОС ----------
. /etc/os-release
if [[ "${ID:-}" != cachyos && "${ID_LIKE:-}" != *arch* ]]; then
    warn "Текущая ОС: ${PRETTY_NAME:-?} — unpack.sh рассчитан на CachyOS/Arch."
    read -rp "Продолжить всё равно? [y/N] " a || a=""; [[ ${a:-n} =~ ^[Yy]$ ]] || exit 1
fi

# ---------- 2. Выбор прогона ----------
[[ -d "$TOOL_DIR/archives" ]] || die "рядом со скриптом нет archives/ — запусти с SSD"
mapfile -t RUNS < <(ls -1d "$TOOL_DIR/archives"/*/ 2>/dev/null | sed 's:/*$::')
((${#RUNS[@]})) || die "в archives/ нет прогонов"

RUN_DESC=(); for r in "${RUNS[@]}"; do
    RUN_DESC+=("$(basename "$r");$(human "$r"), файлов: $(find "$r" -type f | wc -l)"); done
pick=$(ui_menu "Какой прогон восстанавливаем?" "${RUN_DESC[@]}")
[[ -n "$pick" ]] || die "прогон не выбран"
RUN="$TOOL_DIR/archives/$pick"
ok "Прогон: $RUN ($(human "$RUN"))"

# ---------- 3. Компоненты ----------
COMPONENTS=(
  "packages;манифесты + установка по mapping.tsv"
  "appimages;копирование в ~/Applications"
  "dotfiles.tar.gz;конфиги, ssh, шрифты"
  "data.tar.gz;~/Documents, Downloads"
  "agents.tar.gz;AI-агенты: home + .config + скиллы"
  "browsers.tar.gz;профили браузеров целиком"
  "flatpak-data.tar.gz;данные flatpak-приложений (.var)"
  "toolchain.tar.gz;тулчейны rustup/nvm/bun/npm/vscode"
  "tmp.tar.gz;tmp-каталоги"
  "extra.tar.gz;дополнительные пути"
)

# выбор: аргументы CLI (`all` = всё, что есть), иначе интерактивный чеклист
if [[ $# -gt 0 && "$1" == all ]]; then
    SEL=()
    for c in "${COMPONENTS[@]}"; do
        IFS=';' read -r tag desc <<<"$c"
        if [[ "$tag" == *.tar.gz ]]; then [[ -f "$RUN/$tag" ]] && SEL+=("$tag")
        else [[ -d "$RUN/$tag" ]] && SEL+=("$tag"); fi
    done
elif [[ $# -gt 0 ]]; then
    SEL=()
    for a in "$@"; do
        found=0
        for c in "${COMPONENTS[@]}"; do IFS=';' read -r tag _ <<<"$c"; [[ "$tag" == "$a" ]] && found=1; done
        if (( ! found )); then die "неизвестный компонент: $a (есть: ${COMPONENTS[*]%%;*} | all)"; fi
        [[ "$a" == *.tar.gz && ! -f "$RUN/$a" ]] && die "в прогоне нет $a"
        [[ "$a" != *.tar.gz && ! -d "$RUN/$a" ]] && die "в прогоне нет $a/"
        SEL+=("$a")
    done
else
    CHECKS=(); for c in "${COMPONENTS[@]}"; do
        IFS=';' read -r tag desc <<<"$c"
        if [[ "$tag" == *.tar.gz ]]; then [[ -f "$RUN/$tag" ]] && CHECKS+=("$tag;$(human "$RUN/$tag") — $desc;OFF")
        else [[ -d "$RUN/$tag" ]] && CHECKS+=("$tag;каталог — $desc;OFF"); fi
    done
    ((${#CHECKS[@]})) || die "в прогоне нет ни одного компонента"
    SEL_STR=$(ui_checklist "Что восстанавливаем?" "${CHECKS[@]}")
    mapfile -t SEL <<<"$SEL_STR"
fi
[[ ${#SEL[@]} -gt 0 && -n "${SEL[0]:-}" ]] || die "ничего не выбрано"

# ---------- вспомогательное ----------
extract_tar() { # $1=archive file
    local arch="$1" name; name=$(basename "$arch")
    # конфликт = верхнеуровневые пути архива, уже существующие в $HOME
    local tops
    tops=$(tar -tzf "$arch" | sed 's:/.*::' | sort -u | while IFS= read -r t; do
        [[ -n "$t" && -e "$HOME/$t" ]] && echo "$t"
    done || true)
    if [[ -n "$tops" ]]; then
        if (( DRY )); then dry "«$name»: уже существуют: $(echo "$tops" | tr '\n' ' ') — skip/backup/overwrite (выбор)"; return 0; fi
        local ch
        ch=$(ui_menu "«$name» — уже существуют: $(echo "$tops" | tr '\n' ' '). Что делать?" \
            "skip;не трогать существующее" \
            "backup;переместить существующее в *.bak-premigrate" \
            "overwrite;перезаписать")
        case "$ch" in
            backup) while IFS= read -r t; do mv "$HOME/$t" "$HOME/$t.bak-premigrate"; done <<<"$tops";;
            overwrite) :;;
            *) warn "$name — пропущен"; return 0;;
        esac
    fi
    if (( DRY )); then ok "$name — распакован ($(human "$arch")) [dry-run]"; return 0; fi
    tar -xzf "$arch" -C "$HOME" && ok "$name — распакован ($(human "$arch"))"
}

if (( DRY )); then MISSING="/tmp/missing-mapping.dryrun.txt"; else MISSING="$RUN/missing-mapping.txt"; fi
: > "$MISSING"

# ---------- 4. Выполнение ----------
for s in "${SEL[@]}"; do
    case "$s" in
        packages)
            info "Сверка apt-list с mapping.tsv..."
            installed=0; while IFS=$'\t' read -r pkg status _rest; do
                [[ "$pkg" =~ ^# || -z "$pkg" ]] && continue
                # точное совпадение первого поля (grep -E ломался на '+' в именах: g++, libstdc++6)
                if ! awk -v p="$pkg" '$1==p{f=1} END{exit !f}' "$RUN/packages/apt-list.txt"; then continue; fi
                case "$status" in
                    skip) ok "  $pkg — skip (не переносится)";;
                    native|aur)
                        cmd=$(awk -F'\t' -v p="$pkg" '$1==p{print $3}' "$TOOL_DIR/mapping.tsv")
                        [[ -n "$cmd" && "$cmd" != "-" ]] && { echo "  \$ $cmd"; (( DRY )) && { dry "$cmd — выполнено"; installed=$((installed+1)); } || { eval "$cmd" && installed=$((installed+1)) || warn "  $pkg — установка не удалась"; }; }
                        ;;
                esac
            done < "$TOOL_DIR/mapping.tsv"
            # что в apt-list, но нет в mapping
            grep -vE "^#|^$" "$RUN/packages/apt-list.txt" | awk '{print $1}' | while read -r p; do
                awk -F'\t' -v p="$p" '$1==p{f=1} END{exit !f}' "$TOOL_DIR/mapping.tsv" || echo "$p" >> "$MISSING.tmp"
            done
            [[ -f "$MISSING.tmp" ]] && { cat "$MISSING.tmp" >> "$MISSING"; rm "$MISSING.tmp"; }
            # flatpak
            if [[ -s "$RUN/packages/flatpak-list.txt" ]]; then
                if (( ! DRY )); then
                    flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo 2>/dev/null || true
                fi
                info "Flatpak-приложения:"
                while read -r app; do [[ -n "$app" ]] || continue; if (( DRY )); then dry "flatpak install -y flathub $app"; else flatpak install -y flathub "$app" || warn "  flatpak $app — не установился"; fi; done < "$RUN/packages/flatpak-list.txt"
            fi
            # vscode extensions
            if [[ -s "$RUN/packages/code-extensions.txt" ]] && command -v code >/dev/null; then
                info "VS Code расширения:"
                while read -r ext; do [[ -n "$ext" ]] || continue; if (( DRY )); then dry "code --install-extension $ext"; else code --install-extension "$ext" || true; fi; done < "$RUN/packages/code-extensions.txt"
            fi
            # dconf
            if [[ -s "$RUN/packages/dconf.dump" ]]; then
                if (( DRY )); then dry "dconf load / ($(wc -l < "$RUN/packages/dconf.dump") строк)"; else dconf load / < "$RUN/packages/dconf.dump" && ok "dconf загружен"; fi
            fi
            # crontab
            if [[ -s "$RUN/packages/crontab.txt" ]]; then
                if (( DRY )); then dry "crontab $(wc -l < "$RUN/packages/crontab.txt") записей — загружен"; else crontab "$RUN/packages/crontab.txt" && ok "crontab восстановлен"; fi
            fi
            ok "packages: ${DRY:+(dry-run) }установлено/план $installed; нет в мапинге: $(wc -l < "$MISSING") строк -> $MISSING"
            ;;
        appimages)
            if (( DRY )); then
                while IFS= read -r f; do [[ -f "$f" ]] && dry "cp $f -> ~/Applications/ && chmod +x"; done < <(find "$RUN/appimages" -name '*.AppImage')
                ok "appimages (dry-run): $(find "$RUN/appimages" -name '*.AppImage' | wc -l) шт. -> ~/Applications"
            else
                mkdir -p "$HOME/Applications"
                n=0; while IFS= read -r f; do
                    [[ -f "$f" ]] && cp "$f" "$HOME/Applications/" && chmod +x "$HOME/Applications/$(basename "$f")" && n=$((n+1))
                done < <(find "$RUN/appimages" -name '*.AppImage')
                ok "appimages: $n шт. -> ~/Applications"
            fi
            ;;
        dotfiles.tar.gz) extract_tar "$RUN/dotfiles.tar.gz";;
        data.tar.gz)     extract_tar "$RUN/data.tar.gz";;
        agents.tar.gz)   extract_tar "$RUN/agents.tar.gz";;
        flatpak-data.tar.gz) extract_tar "$RUN/flatpak-data.tar.gz";;
        toolchain.tar.gz) extract_tar "$RUN/toolchain.tar.gz";;
        tmp.tar.gz)      extract_tar "$RUN/tmp.tar.gz";;
        extra.tar.gz)    extract_tar "$RUN/extra.tar.gz";;
        browsers.tar.gz)
            if (( DRY )); then ok "browsers.tar.gz — распакован [dry-run, после проверки keyring]"; continue; fi
            warn "Перед распаковкой браузеров: пароли профиля привязаны к старому keyring."
            read -rp "Помнишь пароль старого keyring? [y/N] " a
            [[ ${a:-n} =~ ^[Yy]$ ]] || { warn "browsers пропущен — введи пароль keyring и повтори"; continue; }
            extract_tar "$RUN/browsers.tar.gz";;
    esac
done

# ---------- 5. Отчёт ----------
echo; ok "===== ИТОГ $([[ $DRY == 1 ]] && echo '(DRY-RUN — ничего не выполнено)' || echo '') ====="
for s in "${SEL[@]}"; do echo "  • $s"; done
if [[ -s "$RUN/paths.tsv" ]]; then
    ok "Мапинг источник->приёмник: $RUN/paths.tsv ($(($(wc -l < "$RUN/paths.tsv")-1)) путей)"
    info "Пути восстановления (из paths.tsv):"
    tail -n +2 "$RUN/paths.tsv" | awk -F'\t' '{printf "    %s -> %s\n", $4, $6}' | sort -u | head -40
fi
[[ -s "$MISSING" ]] && warn "Нет в mapping.tsv ($(wc -l < "$MISSING")):  $MISSING — установи вручную (pacman -Si / yay -Ss / AppImage)"
(( DRY )) && ok "Реальное восстановление: bash unpack.sh (без --dry-run)"
ok "Готово."
