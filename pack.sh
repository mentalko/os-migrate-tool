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

# ---------- 0. --dry-run ----------
DRY=0
for arg in "$@"; do [[ "$arg" == "--dry-run" || "$arg" == "-n" ]] && DRY=1; done
dry() { echo -e "\e[35m[dry-run]\e[0m $*"; }
(( DRY )) && warn "РЕЖИМ DRY-RUN: ничего не будет записано, только отчёт о действиях."

# ---------- 1. ОС ----------
. /etc/os-release
OS_ID="${ID:-linux}"
if [[ "$OS_ID" != ubuntu && "${ID_LIKE:-}" != *debian* ]]; then
    read -rp "Текущая ОС: ${PRETTY_NAME:-$OS_ID}. pack.sh рассчитан на Ubuntu. Продолжить? [y/N] " a
    [[ ${a:-n} =~ ^[Yy]$ ]] || exit 1
fi
info "ОС: ${PRETTY_NAME:-$OS_ID}"

# ---------- UI: собственный TUI со строкой-подсказкой под курсором ----------
# формат пунктов: tag;desc;size;onoff[;hint]  (hint — то, что показывается внизу)
ui_checklist() {
    local title="$1"; shift
    local -a tags=() descs=() sizes=() offs=() hints=()
    local it t d s o h i m
    for it in "$@"; do
        IFS=';' read -r t d s o h <<<"$it"
        tags+=("$t"); descs+=("$d"); sizes+=("$s"); offs+=("$o"); hints+=("${h:-$d}")
    done
    local cur=0
    printf '\e[?25l'                      # спрятать курсор
    _draw() {
        printf '\e[H\e[J'
        echo "== $title"
        echo -e "  \e[2m↑/↓ или j/k — выбор · пробел — галочка · a — все · n — ничего · Enter — ок\e[0m"
        echo
        for i in "${!tags[@]}"; do
            m=" "; [[ ${offs[i]} == ON ]] && m="x"
            if (( i == cur )); then
                printf '\e[7m  [%s] %-11s %-33s %9s \e[0m\n' "$m" "${tags[i]}" "${descs[i]}" "${sizes[i]}"
            else
                printf '  [%s] %-11s %-33s %9s\n' "$m" "${tags[i]}" "${descs[i]}" "${sizes[i]}"
            fi
        done
        echo
        printf '\e[2m  ↪ %s\e[0m\n' "${hints[cur]}"
    }
    _draw
    while true; do
        IFS= read -rsn1 key
        case "$key" in
            $'\x1b') read -rsn2 seq
                case "$seq" in
                    '[A') (( cur > 0 )) && (( cur-- ));;
                    '[B') (( cur < ${#tags[@]}-1 )) && (( cur++ ));;
                esac;;
            ' '|' ') [[ ${offs[cur]} == ON ]] && offs[cur]=OFF || offs[cur]=ON;;
            'a'|'A'|'ф'|'Ф') for i in "${!tags[@]}"; do offs[i]=ON; done;;
            'n'|'N'|'т'|'Т') for i in "${!tags[@]}"; do offs[i]=OFF; done;;
            'j'|'J'|'о'|'О') (( cur < ${#tags[@]}-1 )) && (( cur++ ));;
            'k'|'K'|'л'|'Л') (( cur > 0 )) && (( cur-- ));;
            ''|$'\n'|$'\r') break;;
            *) continue;;
        esac
        _draw
    done
    printf '\e[?25h'
    for i in "${!tags[@]}"; do [[ ${offs[i]} == ON ]] && echo "${tags[i]}"; done
}

ui_menu() { # одиночный выбор: tag;desc[;hint]
    local title="$1"; shift
    local -a tags=() descs=() hints=()
    local it t d h i cur=0
    for it in "$@"; do
        IFS=';' read -r t d h <<<"$it"
        tags+=("$t"); descs+=("$d"); hints+=("${h:-$d}")
    done
    printf '\e[?25l'
    _drawm() {
        printf '\e[H\e[J'
        echo "== $title"
        echo -e "  \e[2m↑/↓ — выбор · Enter — подтвердить\e[0m"
        echo
        for i in "${!tags[@]}"; do
            if (( i == cur )); then
                printf '\e[7m  ▶ %-11s %s \e[0m\n' "${tags[i]}" "${descs[i]}"
            else
                printf '    %-11s %s\n' "${tags[i]}" "${descs[i]}"
            fi
        done
        echo
        printf '\e[2m  ↪ %s\e[0m\n' "${hints[cur]}"
    }
    _drawm
    while true; do
        IFS= read -rsn1 key
        case "$key" in
            $'\x1b') read -rsn2 seq
                case "$seq" in
                    '[A') (( cur > 0 )) && (( cur-- ));;
                    '[B') (( cur < ${#tags[@]}-1 )) && (( cur++ ));;
                esac;;
            'j'|'J'|'о'|'О') (( cur < ${#tags[@]}-1 )) && (( cur++ ));;
            'k'|'K'|'л'|'Л') (( cur > 0 )) && (( cur-- ));;
            ''|$'\n'|$'\r') break;;
            *) continue;;
        esac
        _drawm
    done
    printf '\e[?25h'
    echo "${tags[cur]}"
}

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
    rem=''; [[ "$rm" == 1 ]] && rem=', съёмный'
    desc="${label:-без метки};/dev/$name ($fstype), $size, свободно ${free}, $mnt${rem}"
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
  "packages;манифесты apt/flatpak/vscode/dconf/cron;10-20M;ON;dpkg --get-selections, flatpak list, code --list-extensions, dconf dump, crontab -l, systemd-user units"
  "appimages;AppImage: $(echo "$APPS_FIND" | grep -c . || true) шт.;${appimg_size}M;$([[ $appimg_size -gt 0 ]] && echo ON || echo OFF);$(echo "$APPS_FIND" | sed "s|$HOME|~|g" | tr '\n' ' ')"
  "dotfiles;конфиги, ssh, шрифты, история;$(size_of "${DOT_DIRS[@]}" "${DOT_FILES[@]}")M;ON;~/${DOT_DIRS[*]} ~/${DOT_FILES[*]}"
  "data;~/Documents;$(size_of Documents)M;ON;~/Documents целиком, исключая os-migrate-tool и [10] SKILLS"
  "agents;AI-агенты + скиллы;$(size_of .qoder .codex .claude .agents .jcode)M;ON;~/.qoder ~/.codex ~/.claude ~/.agents ~/.jcode ~/Documents/[10] SKILLS — сессии, задачи, скиллы"
  "browsers;профили браузеров целиком;$(size_of "${BROWSER_DIRS[@]}")M;OFF;~/${BROWSER_DIRS[*]} — пароли, куки, расширения; на Cachy нужен пароль старого keyring"
)

# Полные пути — в терминал, чтобы не распирало диалог
echo; info "Что входит в каждый компонент:"
echo "  packages   : манифесты (apt, flatpak, vscode, dconf, cron, systemd-user)"
[[ -n "$APPS_FIND" ]] && echo "  appimages  : $(echo "$APPS_FIND" | sed "s|$HOME|~|g" | tr '\n' ' ')"
echo "  dotfiles   : ${DOT_DIRS[*]} ${DOT_FILES[*]}" | sed "s| |, |g; s/^/               /"
echo "  data       : ~/Documents (без os-migrate-tool, [10] SKILLS)"
echo "  agents     : ~/.qoder, ~/.codex, ~/.claude, ~/.agents, ~/.jcode, ~/Documents/[10] SKILLS"
echo "  browsers   : ${BROWSER_DIRS[*]}" | sed "s| |, |g; s/^/               /"

SEL=$(ui_checklist "Что пакуем?" "${ITEMS[@]}")
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
if (( DRY )); then
    dry "создал бы $RUN_DIR/{packages,appimages}/"
else
    mkdir -p "$RUN_DIR/packages" "$RUN_DIR/appimages"
fi
info "Прогон: $RUN_DIR"

targz() { # $1=archive name, остальное — пути от $HOME
    local out="$RUN_DIR/$1"; shift
    local -a paths=(); local p
    for p in "$@"; do [[ -e "$HOME/$p" ]] && paths+=("$p"); done
    ((${#paths[@]})) || { warn "$1: нечего паковать, пропущен"; return 0; }
    if (( DRY )); then dry "tar -czf $out  [пути: ${paths[*]}]"; return 0; fi
    ( cd "$HOME" && tar -czf "$out" --exclude-from="$TOOL_DIR/exclude.txt" --files-from <(printf '%s\n' "${paths[@]}") )
    ok "$1 — $(human "$out")"
}

for s in "${SEL[@]}"; do
    case "$s" in
        packages)
            if (( DRY )); then
                dry "записал бы packages/{apt-list,flatpak-list,code-extensions,dconf.dump,crontab,systemd-user-units}.txt"
            else
                dpkg --get-selections > "$RUN_DIR/packages/apt-list.txt"
                command -v flatpak >/dev/null && flatpak list --app --columns=application > "$RUN_DIR/packages/flatpak-list.txt" || true
                command -v code >/dev/null && code --list-extensions > "$RUN_DIR/packages/code-extensions.txt" || true
                command -v dconf >/dev/null && dconf dump / > "$RUN_DIR/packages/dconf.dump" || true
                crontab -l > "$RUN_DIR/packages/crontab.txt" 2>/dev/null || true
                systemctl --user list-unit-files --state=enabled --no-legend --plain > "$RUN_DIR/packages/systemd-user-units.txt" || true
            fi
            ok "манифесты ${DRY:+(dry-run) }готовы в packages/"
            ;;
        appimages)
            if (( DRY )); then
                dry "скопировал бы $(echo "$APPS_FIND" | grep -c .) AppImage в $RUN_DIR/appimages/"
                echo "$APPS_FIND" | sed 's/^/    [dry-run] cp /'
            else
                echo "$APPS_FIND" > "$RUN_DIR/appimages/list.txt"
                echo "$APPS_FIND" | while IFS= read -r f; do cp -v "$f" "$RUN_DIR/appimages/"; done | tail -3
                ok "appimages: $(ls "$RUN_DIR/appimages"/*.AppImage 2>/dev/null | wc -l) шт."
            fi
            ;;
        dotfiles) targz dotfiles.tar.gz "${DOT_DIRS[@]}" "${DOT_FILES[@]}";;
        data)     targz data.tar.gz Documents;;
        agents)   targz agents.tar.gz .qoder .codex .claude .agents .jcode "Documents/[10] SKILLS";;
        browsers) targz browsers.tar.gz "${BROWSER_DIRS[@]}";;
    esac
done

# ---------- 6. Самообновление инструмента на SSD ----------
info "Синхронизация инструмента на SSD..."
if (( DRY )); then
    dry "скопировал бы pack.sh unpack.sh mapping.tsv exclude.txt README.md SKILL.md -> $TOOL_ROOT/"
else
    cp -v "$TOOL_DIR"/{pack.sh,unpack.sh,mapping.tsv,exclude.txt,README.md,SKILL.md} "$TOOL_ROOT/" 2>/dev/null | tail -1
fi

# ---------- 7. Манифест ----------
if (( DRY )); then
    dry "записал бы manifest.txt (дерево + sha256) и latest -> $RUN_NAME"
else
    ( cd "$TOOL_ROOT/archives/$RUN_NAME" && find . -type f | sort > manifest.txt && sha256sum $(find . -type f ! -name manifest.txt | sort) >> manifest.txt )
    ln -sfn "$RUN_NAME" "$TOOL_ROOT/archives/latest"
    ok "manifest.txt записан; latest -> $RUN_NAME"
fi

echo
if (( DRY )); then
    ok "DRY-RUN завершён: ничего не записано. Планируемый архив: $RUN_DIR (~${est}M)"
    ok "Реальный прогон: bash pack.sh (без --dry-run)"
else
    ok "Готово! Архив: $RUN_DIR  ($(human "$RUN_DIR"))"
    ok "На CachyOS запусти: $TOOL_ROOT/unpack.sh"
fi
