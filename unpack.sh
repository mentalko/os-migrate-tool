#!/usr/bin/env bash
# os-migrate-tool :: unpack.sh
# Восстановление на CachyOS (Arch) из прогона на SSD.
# Запускается прямо с SSD:  ./unpack.sh [--packages|--appimages|--dotfiles|--data|--agents|--browsers|all]
set -euo pipefail

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOME="${HOME:-$(getent passwd "$(id -u)" | cut -d: -f6)}"

die()  { echo "ОШИБКА: $*" >&2; exit 1; }
info() { echo -e "\e[36m→\e[0m $*"; }
ok()   { echo -e "\e[32m✓\e[0m $*"; }
warn() { echo -e "\e[33m!\e[0m $*"; }
human(){ du -sh --apparent-size "$1" 2>/dev/null | cut -f1; }

if command -v whiptail >/dev/null 2>&1; then
    ui_menu() {
        local t="$1"; shift; local -a args=()
        for it in "$@"; do args+=("${it%%;*}" "${it#*;}"); done
        whiptail --menu "$t" 22 78 14 "${args[@]}" 3>&1 1>&2 2>&3 || true
    }
    ui_checklist() { # $1=title, $2..: tag;desc;onoff
        local t="$1"; shift; local -a args=()
        for it in "$@"; do IFS=';' read -r a b c <<<"$it"; args+=("$a" "$b" "$c"); done
        whiptail --separate-output --checklist "$t" 24 78 12 "${args[@]}" 3>&1 1>&2 2>&3 || true
    }
    ui_msg()  { whiptail --msgbox "$1" 20 78 || true; }
else
    ui_menu() { local t="$1"; shift; echo "== $t" >&2
        local -a tags=() descs=()
        for it in "$@"; do IFS=';' read -r a b <<<"$it"; tags+=("$a"); descs+=("$b"); done
        for i in "${!tags[@]}"; do echo "  $((i+1))) ${tags[i]}  —  ${descs[i]}" >&2; done
        read -rp "Выбор: " n >&2; (( n>=1 && n<=${#tags[@]} )) && echo "${tags[n-1]}"; return 0; }
    ui_checklist() { # $1=title, $2..: tag;desc;onoff
        local t="$1"; shift
        local -a tags=() descs=() offs=()
        local it a b c i m
        for it in "$@"; do IFS=';' read -r a b c <<<"$it"; tags+=("$a"); descs+=("$b"); offs+=("$c"); done
        echo "== $t" >&2
        for i in "${!tags[@]}"; do
            m=" "; [[ ${offs[i]} == ON ]] && m="x"
            echo "  [$m] $((i+1))) ${tags[i]} — ${descs[i]}" >&2; done
        read -rp "Номера через пробел (Enter — оставить как есть): " ns >&2
        for n in $ns; do (( n>=1 && n<=${#tags[@]} )) || continue
            [[ ${offs[n-1]} == ON ]] && offs[n-1]=OFF || offs[n-1]=ON; done
        for i in "${!tags[@]}"; do [[ ${offs[i]} == ON ]] && echo "${tags[i]}"; done; return 0; }
    ui_msg()  { echo; echo "== $1"; }
fi

[[ $EUID -eq 0 ]] && die "не запускай от root — права на файлы поедут от root"

# ---------- 1. ОС ----------
. /etc/os-release
if [[ "${ID:-}" != cachyos && "${ID_LIKE:-}" != *arch* ]]; then
    warn "Текущая ОС: ${PRETTY_NAME:-?} — unpack.sh рассчитан на CachyOS/Arch."
    read -rp "Продолжить всё равно? [y/N] " a; [[ ${a:-n} =~ ^[Yy]$ ]] || exit 1
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
component_exists() { [[ -s "$RUN/$1" ]]; }
COMPONENTS=(
  "packages;манифесты + установка по mapping.tsv"
  "appimages;копирование в ~/Applications"
  "dotfiles.tar.gz;конфиги, ssh, шрифты"
  "data.tar.gz;~/Documents"
  "agents.tar.gz;.qoder/.codex/.claude/.agents/.jcode + скиллы"
  "browsers.tar.gz;профили браузеров целиком"
)
if [[ $# -gt 0 && "$1" != all ]]; then SEL=("$@")
else
    CHECKS=(); for c in "${COMPONENTS[@]}"; do
        IFS=';' read -r tag desc <<<"$c"
        if [[ "$tag" == *.tar.gz ]]; then [[ -f "$RUN/$tag" ]] && CHECKS+=("$tag;$(human "$RUN/$tag") — $desc;OFF")
        else [[ -d "$RUN/$tag" ]] && CHECKS+=("$tag;каталог — $desc;OFF"); fi
    done
    ((${#CHECKS[@]})) || die "в прогоне нет ни одного компонента"
    if command -v whiptail >/dev/null 2>&1; then
        SEL=$(ui_checklist "Что восстанавливаем?" "${CHECKS[@]}")
    else
        echo; echo "== Что восстанавливаем?"; for i in "${!CHECKS[@]}"; do
            IFS=';' read -r t d s <<<"${CHECKS[i]}"; echo "  $((i+1))) $t — $d ($s)"; done
        read -rp "Номера через пробел: " ns; SEL=""
        for n in $ns; do IFS=';' read -r t _ _ <<<"${CHECKS[n-1]}"; SEL+="$t"$'\n'; done
    fi
fi
mapfile -t SEL <<<"$SEL"; SEL=("${SEL[@]:-}")
((${#SEL[@]})) && [[ -n "${SEL[0]}" ]] || die "ничего не выбрано"

# ---------- вспомогательное ----------
ask_conflict() { # $1=цель; возвращает код: 0=распаковывать, 1=skip, 2=backup
    local target="$1"
    local -a opts=("skip;не трогать существующее" "backup;переместить существующее в *.bak-premigrate" "overwrite;перезаписать")
    ch=$(ui_menu "«$(basename "$target")» уже существует. Что делать?" "${opts[@]}")
    case "$ch" in
        skip) return 1;;
        backup) mv "$target" "$target.bak-premigrate"; return 0;;
        overwrite) return 0;;
        *) return 1;;
    esac
}

extract_tar() { # $1=archive file
    local arch="$1" name; name=$(basename "$arch")
    # конфликт = если первый путь архива уже существует в $HOME
    local first; first=$(tar -tzf "$arch" | head -1)
    if [[ -e "$HOME/$first" ]]; then
        ask_conflict "$HOME/$first" || { warn "$name — пропущен"; return 0; }
    fi
    tar -xzf "$arch" -C "$HOME" && ok "$name — распакован ($(human "$arch"))"
}

MISSING="$RUN/missing-mapping.txt"; : > "$MISSING"

# ---------- 4. Выполнение ----------
for s in "${SEL[@]}"; do
    case "$s" in
        packages)
            info "Сверка apt-list с mapping.tsv..."
            installed=0; while IFS=$'\t' read -r pkg status _rest; do
                [[ "$pkg" =~ ^# || -z "$pkg" ]] && continue
                # найдём строку в apt-list
                if ! grep -qE "^${pkg}[[:space:]]" "$RUN/packages/apt-list.txt"; then continue; fi
                case "$status" in
                    skip) ok "  $pkg — skip (не переносится)";;
                    native|aur)
                        cmd=$(awk -F'\t' -v p="$pkg" '$1==p{print $3}' "$TOOL_DIR/mapping.tsv")
                        [[ -n "$cmd" && "$cmd" != "-" ]] && { echo "  \$ $cmd"; eval "$cmd" && installed=$((installed+1)) || warn "  $pkg — установка не удалась"; }
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
                info "Flatpak-приложения:"
                while read -r app; do [[ -n "$app" ]] && flatpak install -y flathub "$app" || warn "  flatpak $app — не установился"; done < "$RUN/packages/flatpak-list.txt"
            fi
            # vscode extensions
            if [[ -s "$RUN/packages/code-extensions.txt" ]] && command -v code >/dev/null; then
                info "VS Code расширения:"
                while read -r ext; do [[ -n "$ext" ]] && code --install-extension "$ext" || true; done < "$RUN/packages/code-extensions.txt"
            fi
            # dconf
            [[ -s "$RUN/packages/dconf.dump" ]] && dconf load / < "$RUN/packages/dconf.dump" && ok "dconf загружен"
            # crontab
            [[ -s "$RUN/packages/crontab.txt" ]] && crontab "$RUN/packages/crontab.txt" && ok "crontab восстановлен"
            ok "packages: установлено $installed; нет в мапинге: $(wc -l < "$MISSING") строк -> $MISSING"
            ;;
        appimages)
            mkdir -p "$HOME/Applications"
            n=0; while IFS= read -r f; do
                [[ -f "$f" ]] && cp "$f" "$HOME/Applications/" && chmod +x "$HOME/Applications/$(basename "$f")" && n=$((n+1))
            done < <(find "$RUN/appimages" -name '*.AppImage')
            ok "appimages: $n шт. -> ~/Applications"
            ;;
        dotfiles.tar.gz) extract_tar "$RUN/dotfiles.tar.gz";;
        data.tar.gz)     extract_tar "$RUN/data.tar.gz";;
        agents.tar.gz)   extract_tar "$RUN/agents.tar.gz";;
        browsers.tar.gz)
            warn "Перед распаковкой браузеров: пароли профиля привязаны к старому keyring."
            read -rp "Помнишь пароль старого keyring? [y/N] " a
            [[ ${a:-n} =~ ^[Yy]$ ]] || { warn "browsers пропущен — введи пароль keyring и повтори"; continue; }
            extract_tar "$RUN/browsers.tar.gz";;
    esac
done

# ---------- 5. Отчёт ----------
echo; ok "===== ИТОГ ====="
for s in "${SEL[@]}"; do echo "  • $s"; done
[[ -s "$MISSING" ]] && warn "Нет в mapping.tsv ($(wc -l < "$MISSING")):  $MISSING — установи вручную (pacman -Si / yay -Ss / AppImage)"
ok "Готово."
