#!/usr/bin/env bash
# os-migrate-tool :: unpack.sh
# Восстановление на CachyOS (Arch) из бандла прогона на SSD.
# Запускается прямо с SSD:  ./unpack.sh [--packages|--appimages|--dotfiles|--data|--agents|--browsers|all] [--dry-run]
# Флаги можно комбинировать; all = все компоненты прогона.
# Распаковка: список содержимого бандла читается 1 раз, домашние сегменты
# извлекаются ОДНИМ проходом tar (каждый проход = полная прокрутка gzip).
set -euo pipefail

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$TOOL_DIR/src/lib.sh"

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

# ---------- 2. Выбор бандла ----------
[[ -d "$TOOL_DIR/archives" ]] || die "рядом со скриптом нет archives/ — запусти с SSD"
mapfile -t RUNS < <(ls -1 "$TOOL_DIR/archives"/*.tar.gz 2>/dev/null | sed "s|.*/||; s|\.tar\.gz$||")
((${#RUNS[@]})) || die "в archives/ нет бандлов (*.tar.gz)"

RUN_DESC=(); for r in "${RUNS[@]}"; do
    b="$TOOL_DIR/archives/$r.tar.gz"
    RUN_DESC+=("$r;$(human "$b")"); done
pick=$(ui_menu "Какой бандл восстанавливаем?" "${RUN_DESC[@]}")
[[ -n "$pick" ]] || die "бандл не выбран"
BUNDLE="$TOOL_DIR/archives/$pick.tar.gz"
META="$TOOL_DIR/archives/$pick.meta"
ok "Бандл: $BUNDLE ($(human "$BUNDLE"))"

command -v python3 >/dev/null 2>&1 || die "нужен python3 (конфиг и TUI)"
eval "$(python3 "$TOOL_DIR/src/conf.py" \
    "$TOOL_DIR/configs/inventory.yaml" "$TOOL_DIR/configs/selection.yaml" \
    "$TOOL_DIR/configs/exclude_dirs.yaml")"

# ---------- 3. Список содержимого бандла (1 проход) ----------
BUNDLE_LIST="$(mktemp /tmp/omt-bundle-list.XXXXXX)"
info "Читаю содержимое бандла (один проход)..."
tar --ignore-zeros -tzf "$BUNDLE" > "$BUNDLE_LIST"
ok "сегментов: $(cut -d/ -f1 "$BUNDLE_LIST" | sort -u | wc -l), членов: $(wc -l < "$BUNDLE_LIST")"

seg_in_bundle() { grep -q "^$1/" "$BUNDLE_LIST"; }

# .meta/ потерян на диске — восстанавливаем paths.tsv из резервного сегмента
if [[ ! -s "$META/paths.tsv" ]] && grep -q "^meta/paths.tsv" "$BUNDLE_LIST"; then
    mkdir -p "$META"
    tar --ignore-zeros -xzf "$BUNDLE" -C "$META" meta
    ok "paths.tsv восстановлен из бандла (.meta/ отсутствовал на диске)"
fi
seg_conflicts() { # верхнеуровневые пути сегмента, уже существующие в $HOME
    grep "^$1/" "$BUNDLE_LIST" | sed "s|^$1/||; s|/.*||" | sort -u | \
        while IFS= read -r t; do [[ -n "$t" && -e "$HOME/$t" ]] && echo "$t"; done || true
}

# ---------- 4. Компоненты ----------
COMPONENTS=(
  "packages;манифесты + установка по mapping.toml"
  "appimages;копирование в ~/Applications"
  "dotfiles;конфиги, ssh, шрифты"
  "data;~/Documents, Downloads и пр."
  "agents;AI-агенты: home + .config + сессии"
  "browsers;профили браузеров целиком"
  "flatpak;данные flatpak-приложений (.var)"
  "toolchain;тулчейны rustup/nvm/bun/npm/vscode"
  "tmp;tmp-каталоги"
  "extra;дополнительные пути"
)

# выбор: аргументы CLI (`all` = всё, что есть в бандле), иначе чеклист
if [[ $# -gt 0 && "$1" == all ]]; then
    SEL=()
    for c in "${COMPONENTS[@]}"; do
        IFS=';' read -r tag desc <<<"$c"
        seg_in_bundle "$tag" && SEL+=("$tag")
    done
elif [[ $# -gt 0 ]]; then
    SEL=()
    for a in "$@"; do
        a="${a#--}"   # --dotfiles == dotfiles
        found=0
        for c in "${COMPONENTS[@]}"; do IFS=';' read -r tag _ <<<"$c"; [[ "$tag" == "$a" ]] && found=1; done
        if (( ! found )); then die "неизвестный компонент: $a (есть: ${COMPONENTS[*]%%;*} | all)"; fi
        seg_in_bundle "$a" || die "в бандле нет сегмента $a/"
        SEL+=("$a")
    done
else
    CHECKS=(); for c in "${COMPONENTS[@]}"; do
        IFS=';' read -r tag desc <<<"$c"
        seg_in_bundle "$tag" && CHECKS+=("$tag;$desc;OFF")
    done
    ((${#CHECKS[@]})) || die "в бандле нет ни одного сегмента"
    SEL_STR=$(ui_checklist "Что восстанавливаем?" "${CHECKS[@]}")
    mapfile -t SEL <<<"$SEL_STR"
fi
[[ ${#SEL[@]} -gt 0 && -n "${SEL[0]:-}" ]] || die "ничего не выбрано"

if (( DRY )); then MISSING="/tmp/missing-mapping.dryrun.txt"; else MISSING="$META/missing-mapping.txt"; fi
: > "$MISSING"

# ---------- 5. Конфликты (до распаковки) — один вопрос на сегмент ----------
declare -A SEG_ACTION   # сегмент -> "" | backup | (skip отсеется)
HOME_SEGS=()            # сегменты, распаковываемые в $HOME
for s in "${SEL[@]}"; do
    case "$s" in packages|appimages) continue;; esac
    if (( DRY )); then
        tops=$(seg_conflicts "$s")
        if [[ -n "$tops" ]]; then
            dry "«$s»: уже существуют: $(echo "$tops" | tr '\n' ' ') — skip/backup/overwrite (выбор)"
        else
            dry "«$s» — распакован в \$HOME [dry-run]"
        fi
        HOME_SEGS+=("$s")
        continue
    fi
    tops=$(seg_conflicts "$s")
    if [[ -n "$tops" ]]; then
        ch=$(ui_menu "«$s» — уже существуют: $(echo "$tops" | tr '\n' ' '). Что делать?" \
            "skip;не трогать существующее" \
            "backup;переместить существующее в *.bak-premigrate" \
            "overwrite;перезаписать")
        case "$ch" in
            backup)
                while IFS= read -r t; do mv "$HOME/$t" "$HOME/$t.bak-premigrate"; done <<<"$tops"
                HOME_SEGS+=("$s");;
            overwrite) HOME_SEGS+=("$s");;
            *) warn "$s — пропущен";;
        esac
    else
        HOME_SEGS+=("$s")
    fi
done

# browsers: keyring до распаковки
if (( ! DRY )) && [[ " ${SEL[*]} " == *" browsers "* && " ${HOME_SEGS[*]} " == *" browsers "* ]]; then
    warn "Перед распаковкой браузеров: пароли профиля привязаны к старому keyring."
    read -rp "Помнишь пароль старого keyring? [y/N] " a || a=""
    [[ ${a:-n} =~ ^[Yy]$ ]] || {
        warn "browsers пропущен — введи пароль keyring и повтори"
        NEW=(); for s in "${HOME_SEGS[@]}"; do [[ "$s" == browsers ]] || NEW+=("$s"); done
        HOME_SEGS=("${NEW[@]:-}")
    }
fi

# ---------- 6. Распаковка: по одному проходу на цель ----------
if (( ! DRY )); then
    if [[ " ${SEL[*]} " == *" packages "* || " ${SEL[*]} " == *" appimages "* ]]; then
        mkdir -p "$META"
        META_SEGS=(); for s in packages appimages; do
            [[ " ${SEL[*]} " == *" $s "* ]] && META_SEGS+=("$s"); done
        info "Распаковка в meta: ${META_SEGS[*]} (проход 1/2)..."
        tar --ignore-zeros -xzf "$BUNDLE" -C "$META" "${META_SEGS[@]}"
    fi
    if ((${#HOME_SEGS[@]})); then
        info "Распаковка в \$HOME: ${HOME_SEGS[*]} (проход 2/2)..."
        tar --ignore-zeros -xzf "$BUNDLE" -C "$HOME" --strip-components=1 "${HOME_SEGS[@]}"
        ok "распаковано в \$HOME: ${HOME_SEGS[*]}"
    fi
else
    [[ " ${SEL[*]} " == *" packages "* ]] && dry "packages: манифесты -> $META/packages/"
    [[ " ${SEL[*]} " == *" appimages "* ]] && dry "appimages: из бандла -> ~/Applications"
    ((${#HOME_SEGS[@]})) && dry "в \$HOME: ${HOME_SEGS[*]} (один проход tar)"
fi

# ---------- 7. Пост-обработка компонентов ----------
for s in "${SEL[@]}"; do
    case "$s" in
        packages)
            if (( DRY )); then
                dry "packages: сверка apt-list с configs/mapping.toml + flatpak/vscode/dconf/cron"
                continue
            fi
            info "Сверка apt-list с configs/mapping.toml..."
            installed=0
            # точное совпадение первого поля через assoc (grep -E ломался на '+' в именах)
            while IFS= read -r pkg; do
                [[ -z "$pkg" ]] && continue
                status="${MAPPING_STATUS[$pkg]:-}"
                case "$status" in
                    native|aur)
                        cmd="${MAPPING_CMD[$pkg]:-}"
                        [[ -n "$cmd" ]] && { echo "  \$ $cmd"; (( DRY )) && { dry "$cmd — выполнено"; installed=$((installed+1)); } || { eval "$cmd" && installed=$((installed+1)) || warn "  $pkg — установка не удалась"; }; }
                        ;;
                    skip) ok "  $pkg — skip (не переносится)";;
                    manual) ok "  $pkg — manual (ссылка в конце отчёта)";;
                esac
            done < <(cut -f1 "$META/packages/apt-list.txt")
            # что в apt-list, но нет в mapping
            cut -f1 "$META/packages/apt-list.txt" | while read -r p; do
                [[ -n "${MAPPING_STATUS[$p]:-}" ]] || echo "$p" >> "$MISSING.tmp"
            done
            [[ -f "$MISSING.tmp" ]] && { sort -u "$MISSING.tmp" >> "$MISSING"; rm "$MISSING.tmp"; }
            # flatpak: НЕ ставим автоматически — печатаем ссылки (см. отчёт)
            # vscode extensions
            if [[ -s "$META/packages/code-extensions.txt" ]] && command -v code >/dev/null; then
                info "VS Code расширения:"
                while read -r ext; do [[ -n "$ext" ]] || continue; if (( DRY )); then dry "code --install-extension $ext"; else code --install-extension "$ext" || true; fi; done < "$META/packages/code-extensions.txt"
            fi
            # dconf
            if [[ -s "$META/packages/dconf.dump" ]]; then
                if (( DRY )); then dry "dconf load / ($(wc -l < "$META/packages/dconf.dump") строк)"; else dconf load / < "$META/packages/dconf.dump" && ok "dconf загружен"; fi
            fi
            # crontab
            if [[ -s "$META/packages/crontab.txt" ]]; then
                if (( DRY )); then dry "crontab $(wc -l < "$META/packages/crontab.txt") записей — загружен"; else crontab "$META/packages/crontab.txt" && ok "crontab восстановлен"; fi
            fi
            ok "packages: ${DRY:+(dry-run) }установлено/план $installed; нет в мапинге: $(wc -l < "$MISSING") строк -> $MISSING"
            ;;
        appimages)
            if (( DRY )); then
                ok "appimages (dry-run): из бандла -> ~/Applications"
            else
                mkdir -p "$HOME/Applications"
                n=0
                while IFS= read -r f; do
                    [[ -n "$f" && -f "$META/appimages/$f" ]] || continue
                    cp "$META/appimages/$f" "$HOME/Applications/" && chmod +x "$HOME/Applications/$f" && n=$((n+1))
                done < "$META/appimages/list.txt"
                ok "appimages: $n шт. -> ~/Applications"
            fi
            ;;
    esac
done

# ---------- 8. Отчёт ----------
echo; ok "===== ИТОГ $([[ $DRY == 1 ]] && echo '(DRY-RUN — ничего не выполнено)' || echo '') ====="
for s in "${SEL[@]}"; do echo "  • $s"; done
if [[ -s "$META/paths.tsv" ]]; then
    ok "Мапинг источник->приёмник: $META/paths.tsv ($(($(wc -l < "$META/paths.tsv")-1)) путей)"
    info "Пути восстановления (из paths.tsv):"
    tail -n +2 "$META/paths.tsv" | awk -F'\t' '{printf "    %s -> %s\n", $4, $6}' | sort -u | head -40
fi
[[ -s "$MISSING" ]] && warn "Нет в mapping.toml ($(wc -l < "$MISSING")):  $MISSING — установи вручную (pacman -Si / yay -Ss / AppImage)"

# ---------- ссылки на скачивание (скрипт ниоткуда не качает сам) ----------
LINKS=""
FLATPAK_APPS=""
if [[ -s "$META/packages/flatpak-list.txt" ]]; then
    FLATPAK_APPS=$(cat "$META/packages/flatpak-list.txt")
elif (( DRY )); then
    FLATPAK_APPS=$(tar --ignore-zeros -xzOf "$BUNDLE" packages/flatpak-list.txt 2>/dev/null || true)
fi
if [[ -n "$FLATPAK_APPS" ]]; then
    while read -r app; do
        [[ -n "$app" ]] && LINKS+="flatpak: $app — https://flathub.org/apps/$app"$'\n'
    done <<<"$FLATPAK_APPS"
fi
for pkg in "${!MAPPING_URL[@]}"; do
    [[ ${MAPPING_STATUS[$pkg]:-} == manual ]] && LINKS+="пакет: $pkg — ${MAPPING_URL[$pkg]}"$'\n'
done
APPIMG_LIST=""
if [[ -s "$META/appimages/list.txt" ]]; then
    APPIMG_LIST=$(cat "$META/appimages/list.txt")
elif (( DRY )); then
    APPIMG_LIST=$(tar --ignore-zeros -xzOf "$BUNDLE" appimages/list.txt 2>/dev/null || true)
fi
if [[ -n "$APPIMG_LIST" ]]; then
    while read -r f; do
        [[ -n "$f" ]] || continue
        b=$(basename "$f")
        LINKS+="appimage: $b — ${APPIMG_URL[$b]:-ссылка не указана — добавь в configs/mapping.toml [appimages]}"$'\n'
    done <<<"$APPIMG_LIST"
fi
if [[ -n "$LINKS" ]]; then
    echo; ok "===== СКАЧАТЬ/УСТАНОВИТЬ ВРУЧНУЮ (ссылки) ====="
    echo "$LINKS" | sed 's/^/  /'
fi
(( DRY )) && ok "Реальное восстановление: bash unpack.sh (без --dry-run)"
ok "Готово."
