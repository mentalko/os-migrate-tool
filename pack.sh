#!/usr/bin/env bash
# os-migrate-tool :: pack.sh
# Интерактивная упаковка Ubuntu -> внешний SSD для переезда на CachyOS.
set -euo pipefail

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOME="${HOME:-$(getent passwd "$(id -u)" | cut -d: -f6)}"

die()  { echo "ОШИБКА: $*" >&2; exit 1; }
info() { echo -e "\e[36m→\e[0m $*"; }
ok()   { echo -e "\e[32m✓\e[0m $*"; }
warn() { echo -e "\e[33m!\e[0m $*"; }
human(){ du -sh --apparent-size "$1" 2>/dev/null | cut -f1; }

[[ $EUID -eq 0 ]] && die "не запускай от root — потеряются права на файлы"

# ---------- 1. ОС ----------
. /etc/os-release
OS_ID="${ID:-linux}"
if [[ "$OS_ID" != ubuntu && "${ID_LIKE:-}" != *debian* ]]; then
    read -rp "Текущая ОС: ${PRETTY_NAME:-$OS_ID}. pack.sh рассчитан на Ubuntu. Продолжить? [y/N] " a
    [[ ${a:-n} =~ ^[Yy]$ ]] || exit 1
fi
info "ОС: ${PRETTY_NAME:-$OS_ID}"

# ---------- UI: whiptail или текстовый fallback ----------
if command -v whiptail >/dev/null 2>&1; then
    ui_checklist() { # $1=title, $2..: tag;desc;size;onoff
        local title="$1"; shift
        whiptail --separate-output --checklist "$title" 24 78 12 "$@" 3>&1 1>&2 2>&3 || true
    }
    ui_menu() { # $1=title, $2..: tag;desc
        local title="$1"; shift
        whiptail --menu "$title" 22 78 14 "$@" 3>&1 1>&2 2>&3 || true
    }
else
    ui_checklist() { # fallback: tag;desc;size;onoff
        local title="$1"; shift
        local -a tags descs sizes offs
        for it in "$@"; do IFS=';' read -r t d s o <<<"$it"
            tags+=("$t"); descs+=("$d"); sizes+=("$s"); offs+=("$o"); done
        local sel=(); for i in "${!tags[@]}"; do
            [[ ${offs[i]} == ON ]] && sel+=("${tags[i]}"); done
        while true; do
            echo; echo "== $title"
            for i in "${!tags[@]}"; do
                local m=" "; [[ ${sel[*]} == *" ${tags[i]} "* || ${sel[0]:-} == "${tags[i]}" ]] && m="x"
                printf "  [%s] %-12s %-45s %8s\n" "$m" "${tags[i]}" "${descs[i]}" "${sizes[i]}"; done
            read -rp "Номера через пробел — переключить, Enter — подтвердить: " nums
            [[ -z "${nums// }" ]] && break
            for n in $nums; do (( n>=1 && n<=${#tags[@]} )) || continue
                local t="${tags[n-1]}"; local found=0
                for j in "${!sel[@]}"; do [[ ${sel[j]} == "$t" ]] && { unset 'sel[j]'; found=1; break; }; done
                (( found )) || sel+=("$t")
            done; sel=("${sel[@]:-}")
        done; printf '%s\n' "${sel[@]}"
    }
    ui_menu() { # fallback: возвращает tag выбранного пункта
        local title="$1"; shift
        echo; echo "== $title"
        local -a tags=() descs=()
        for it in "$@"; do IFS=';' read -r t d <<<"$it"; tags+=("$t"); descs+=("$d"); done
        for i in "${!tags[@]}"; do echo "  $((i+1))) ${tags[i]}  —  ${descs[i]}"; done
        read -rp "Выбор (1-${#tags[@]}): " n
        (( n>=1 && n<=${#tags[@]} )) && echo "${tags[n-1]}"
    }
fi

# ---------- 2. Выбор SSD ----------
info "Поиск смонтированных дисков..."
mapfile -t ALL < <(lsblk -rno NAME,RM,SIZE,MOUNTPOINT 2>/dev/null | awk '$4 != "" && $4 !~ /^\/(boot|snap)/')
CAND=(); CAND_DESC=()
for line in "${ALL[@]}"; do
    read -r name rm size mnt <<<"$line"
    [[ "$mnt" == "/" ]] && continue
    mount | grep -q " $mnt " || continue
    mountpoint -q "$mnt" || continue
    label=$(lsblk -rno LABEL "/dev/$name" 2>/dev/null || true)
    fstype=$(lsblk -rno FSTYPE "/dev/$name" 2>/dev/null || true)
    free=$(df -h --output=avail "$mnt" | tail -1)
    desc="${label:-без метки};/dev/$name ($fstype), $size, свободно ${free}, $mnt$( [[ $rm == 1 ]] && echo ', съёмный' )"
    CAND+=("$mnt"); CAND_DESC+=("$mnt;$desc")
done
((${#CAND[@]})) || die "не найдено смонтированных дисков. Смонтируй SSD и повтори."

pick=$(ui_menu "Куда паковать? Выбери внешний SSD:" "${CAND_DESC[@]}")
[[ -n "$pick" ]] || die "диск не выбран"
SSD="$pick"; TOOL_ROOT="$SSD/os-migrate-tool"
touch "$SSD/.omt-write-test" 2>/dev/null && rm -f "$SSD/.omt-write-test" \
    || die "диск $SSD не доступен на запись (ro-маунт?)"
ok "SSD: $SSD (свободно $(df -h --output=avail "$SSD" | tail -1))"

# ---------- 3. Компоненты: путь + размер ----------
DOT_DIRS=(.config .ssh .gnupg .local/share/fonts .local/bin .local/share/applications)
DOT_FILES=(.zshrc .bashrc .profile .gitconfig .gitignore_global .bash_history .zsh_history)
BROWSER_DIRS=(.config/google-chrome .config/BraveSoftware .config/chromium .mozilla)

size_of() { local s=0 p; for p in "$@"; do [[ -e "$HOME/$p" || -e "$p" ]] && s=$(( s + $(du -sm --apparent-size "$HOME/$p" 2>/dev/null | cut -f1) )); done; echo "$s"; }

APPS_FIND=$(find "$HOME/Applications" "$HOME/bin" "$HOME/Desktop" -maxdepth 1 -name '*.AppImage' 2>/dev/null || true)
appimg_size=0; [[ -n "$APPS_FIND" ]] && appimg_size=$(echo "$APPS_FIND" | xargs -r du -sm --apparent-size 2>/dev/null | awk '{s+=$1} END{print s+0}')

ITEMS=(
  "packages;Манифесты apt/flatpak/vscode/dconf/cron/systemd;10-20M;ON"
  "appimages;AppImage-файлы: ${APPS_FIND:+$(echo "$APPS_FIND" | wc -l)} шт.;${appimg_size}M;$([[ $appimg_size -gt 0 ]] && echo ON || echo OFF)"
  "dotfiles;${DOT_DIRS[*]} ${DOT_FILES[*]};$(size_of "${DOT_DIRS[@]}" "${DOT_FILES[@]}")M;ON"
  "data;~/Documents (без os-migrate-tool и [10] SKILLS);$(size_of Documents)M;ON"
  "agents;.qoder .codex .claude .agents .jcode + [10] SKILLS;$(size_of .qoder .codex .claude .agents .jcode)M;ON"
  "browsers;Chrome/Brave/Chromium/Firefox профили целиком;$(size_of "${BROWSER_DIRS[@]}")M;OFF"
)

SEL=$(ui_checklist "Что пакуем? (пробел — галочка, Enter — ок)\nИтог и оценка сжатия — ниже." "${ITEMS[@]}")
[[ -n "$SEL" ]] || die "ничего не выбрано"
mapfile -t SEL <<<"$SEL"

# ---------- 4. Итоговая оценка ----------
total=0
echo; info "Выбрано:"
for s in "${SEL[@]}"; do
    case "$s" in
        packages)  echo "   packages   — манифесты"; total=$((total+20));;
        appimages) echo "   appimages  — $(echo "$APPS_FIND" | wc -l) шт., ${appimg_size}M"; total=$((total+appimg_size));;
        dotfiles)  echo "   dotfiles   — ${size_of "${DOT_DIRS[@]}" "${DOT_FILES[@]}"}M"; total=$((total+$(size_of "${DOT_DIRS[@]}" "${DOT_FILES[@]}")));;
        data)      echo "   data       — Documents, $(size_of Documents)M"; total=$((total+$(size_of Documents)));;
        agents)    echo "   agents     — $(size_of .qoder .codex .claude .agents .jcode)M"; total=$((total+$(size_of .qoder .codex .claude .agents .jcode)));;
        browsers)  echo "   browsers   — $(size_of "${BROWSER_DIRS[@]}")M"; total=$((total+$(size_of "${BROWSER_DIRS[@]}")));;
    esac
done
est=$(( total * 55 / 100 ))   # tar.gz ~55% от исходника
echo "--------------------------------------------------"
warn "Сырой объём: ${total}M   оценка после tar.gz: ~${est}M"
free_mb=$(df -m --output=avail "$SSD" | tail -1)
(( free_mb > est )) || die "на $SSD свободно ${free_mb}M — мало для оценки ~${est}M"
read -rp "Начать упаковку? [y/N] " a; [[ ${a:-n} =~ ^[Yy]$ ]] || exit 0

# ---------- 5. Прогон ----------
RUN_NAME="$(date +%F)_${OS_ID}"
RUN_DIR="$TOOL_ROOT/archives/$RUN_NAME"
if [[ -e "$RUN_DIR" ]]; then RUN_NAME="$(date +%F_%H%M)_${OS_ID}"; RUN_DIR="$TOOL_ROOT/archives/$RUN_NAME"; fi
mkdir -p "$RUN_DIR/packages" "$RUN_DIR/appimages"
info "Прогон: $RUN_DIR"

targz() { # $1=archive name, остальное — пути от $HOME
    local out="$RUN_DIR/$1"; shift
    local -a paths=(); local p
    for p in "$@"; do [[ -e "$HOME/$p" ]] && paths+=("$p"); done
    ((${#paths[@]})) || { warn "$1: нечего паковать, пропущен"; return 0; }
    ( cd "$HOME" && tar -czf "$out" --exclude-from="$TOOL_DIR/exclude.txt" --files-from <(printf '%s\n' "${paths[@]}") )
    ok "$1 — $(human "$out")"
}

for s in "${SEL[@]}"; do
    case "$s" in
        packages)
            dpkg --get-selections > "$RUN_DIR/packages/apt-list.txt"
            command -v flatpak >/dev/null && flatpak list --app --columns=application > "$RUN_DIR/packages/flatpak-list.txt" || true
            command -v code >/dev/null && code --list-extensions > "$RUN_DIR/packages/code-extensions.txt" || true
            command -v dconf >/dev/null && dconf dump / > "$RUN_DIR/packages/dconf.dump" || true
            crontab -l > "$RUN_DIR/packages/crontab.txt" 2>/dev/null || true
            systemctl --user list-unit-files --state=enabled --no-legend --plain > "$RUN_DIR/packages/systemd-user-units.txt" || true
            ok "манифесты записаны в packages/"
            ;;
        appimages)
            echo "$APPS_FIND" > "$RUN_DIR/appimages/list.txt"
            echo "$APPS_FIND" | while IFS= read -r f; do cp -v "$f" "$RUN_DIR/appimages/"; done | tail -3
            ok "appimages: $(ls "$RUN_DIR/appimages"/*.AppImage 2>/dev/null | wc -l) шт."
            ;;
        dotfiles) targz dotfiles.tar.gz "${DOT_DIRS[@]}" "${DOT_FILES[@]}";;
        data)     targz data.tar.gz Documents;;
        agents)   targz agents.tar.gz .qoder .codex .claude .agents .jcode "Documents/[10] SKILLS";;
        browsers) targz browsers.tar.gz "${BROWSER_DIRS[@]}";;
    esac
done

# ---------- 6. Самообновление инструмента на SSD ----------
info "Синхронизация инструмента на SSD..."
cp -v "$TOOL_DIR"/{pack.sh,unpack.sh,mapping.tsv,exclude.txt,README.md,SKILL.md} "$TOOL_ROOT/" 2>/dev/null | tail -1

# ---------- 7. Манифест ----------
( cd "$TOOL_ROOT/archives/$RUN_NAME" && find . -type f | sort > manifest.txt && sha256sum $(find . -type f ! -name manifest.txt | sort) >> manifest.txt )
ln -sfn "$RUN_NAME" "$TOOL_ROOT/archives/latest"
ok "manifest.txt записан; latest -> $RUN_NAME"

echo
ok "Готово! Архив: $RUN_DIR  ($(human "$RUN_DIR"))"
ok "На CachyOS запусти: $TOOL_ROOT/unpack.sh"
