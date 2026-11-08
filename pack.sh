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

# любой неожиданный вылет — с причиной и строкой
trap 'printf "\e[?25h" >&2; printf "\e[31mОШИБКА\e[0m: сбой на строке %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

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
    local tw=0; for i in "${!tags[@]}"; do (( ${#tags[i]} > tw )) && tw=${#tags[i]}; done
    printf '\e[?25l' >&2                  # спрятать курсор
    _draw() {                             # рисуем в stderr: stdout захватывается $()
        printf '\e[H\e[J' >&2
        echo "== $title" >&2
        echo -e "  \e[2m↑/↓ или j/k — выбор · пробел — галочка · a — все · n — ничего · Enter — ок\e[0m" >&2
        echo >&2
        for i in "${!tags[@]}"; do
            m=" "; [[ ${offs[i]} == ON ]] && m="x"
            if (( i == cur )); then
                printf '\e[7m  [%s] %-*s %-33s %9s \e[0m\n' "$m" "$tw" "${tags[i]}" "${descs[i]}" "${sizes[i]}" >&2
            else
                printf '  [%s] %-*s %-33s %9s\n' "$m" "$tw" "${tags[i]}" "${descs[i]}" "${sizes[i]}" >&2
            fi
        done
        echo >&2
        printf '\e[2m  ↪ [%s]\e[0m\n' "${tags[cur]}" >&2
        local hl   # hint: '|' = перевод строки — каждый путь своей строкой
        while IFS= read -r hl; do [[ -n "$hl" ]] && printf '\e[2m        %s\e[0m\n' "$hl" >&2; done \
            < <(printf '%s' "${hints[cur]}" | tr '|' '\n')
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
    printf '\e[H\e[J\e[?25h' >&2          # стереть меню с экрана
    for i in "${!tags[@]}"; do [[ ${offs[i]} == ON ]] && echo "${tags[i]}"; done
    return 0
}

ui_menu() { # одиночный выбор: tag;desc[;hint]
    local title="$1"; shift
    local -a tags=() descs=() hints=()
    local it t d h i cur=0
    for it in "$@"; do
        IFS=';' read -r t d h <<<"$it"
        tags+=("$t"); descs+=("$d"); hints+=("${h:-$d}")
    done
    printf '\e[?25l' >&2
    _drawm() {                            # рисуем в stderr: stdout захватывается $()
        printf '\e[H\e[J' >&2
        echo "== $title" >&2
        echo -e "  \e[2m↑/↓ или j/k — выбор · Enter — подтвердить\e[0m" >&2
        echo >&2
        for i in "${!tags[@]}"; do
            if (( i == cur )); then
                printf '\e[7m  ▶ %-11s %s \e[0m\n' "${tags[i]}" "${descs[i]}" >&2
            else
                printf '    %-11s %s\n' "${tags[i]}" "${descs[i]}" >&2
            fi
        done
        echo >&2
        printf '\e[2m  ↪ [%s]\e[0m\n' "${tags[cur]}" >&2
        local hl
        while IFS= read -r hl; do [[ -n "$hl" ]] && printf '\e[2m        %s\e[0m\n' "$hl" >&2; done \
            < <(printf '%s' "${hints[cur]}" | tr '|' '\n')
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
    printf '\e[H\e[J\e[?25h' >&2          # стереть меню с экрана
    echo "${tags[cur]}"
    return 0
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

# ---------- 3. Компоненты: группы с проваливанием ----------
hM() { awk -v m="$1" 'BEGIN{ if (m>=1024) printf "%.1fG", m/1024; else printf "%dM", m }'; }
size_of() { local s=0 p; for p in "$@"; do [[ -e "$HOME/$p" || -e "$p" ]] && s=$(( s + $(du -sm --apparent-size "$HOME/$p" 2>/dev/null | cut -f1) )); done; echo "$s"; }
m_of() { du -sm --apparent-size "$1" 2>/dev/null | cut -f1; }

DOT_DIRS=(.config .ssh .gnupg .local/share/fonts .local/bin .local/share/applications)
DOT_FILES=(.zshrc .bashrc .profile .gitconfig .gitignore_global .bash_history .zsh_history)
AGENT_DIRS=(.qoder .codex .claude .agents .jcode "Documents/[10] SKILLS")
BROWSER_DIRS=(.config/google-chrome .config/BraveSoftware .config/chromium .mozilla)

APPS_FIND=$(find "$HOME/Applications" "$HOME/bin" "$HOME/Desktop" -maxdepth 1 -name '*.AppImage' 2>/dev/null || true)

MG_GROUPS=(packages appimages dotfiles data agents browsers)
declare -A GRP_DESC GRP_HAS_SUB GRP_EXPANDED SUBS   # SUBS["grp|tag"]="desc;size;onoff;hint;path"
add_sub() { # grp tag desc sizeMB onoff hint path
    SUBS["$1|$2"]="$3;$4;$5;$6;$7"
}
grp_total() { # сумма размеров подпунктов группы
    local g="$1" t=0 k v
    for k in "${!SUBS[@]}"; do [[ "$k" == "$g|"* ]] && { IFS=';' read -r _ v _ _ _ <<<"${SUBS[$k]}"; t=$(( t + v )); }; done
    echo "$t"
}
# --- подпункты групп ---
if [[ -n "$APPS_FIND" ]]; then
    GRP_HAS_SUB[appimages]=1
    while IFS= read -r f; do
        b=$(basename "$f"); add_sub appimages "appimg:$b" "AppImage: $b" "$(m_of "$f")" ON "~/$f" "$f"
    done <<<"$APPS_FIND"
fi
GRP_HAS_SUB[dotfiles]=1
for p in "${DOT_DIRS[@]}" "${DOT_FILES[@]}"; do
    [[ -e "$HOME/$p" ]] && add_sub dotfiles "dot:$p" "$p" "$(m_of "$HOME/$p")" ON "~/$p" "~/$p"
done
GRP_HAS_SUB[agents]=1
for p in "${AGENT_DIRS[@]}"; do
    [[ -e "$HOME/$p" ]] && add_sub agents "agent:$p" "агент: $p" "$(m_of "$HOME/$p")" ON "~/$p — сессии, задачи, скиллы" "~/$p"
done
GRP_HAS_SUB[browsers]=1
for p in "${BROWSER_DIRS[@]}"; do
    [[ -e "$HOME/$p" ]] && add_sub browsers "browser:$p" "браузер: $p" "$(m_of "$HOME/$p")" OFF "~/$p|на Cachy понадобится пароль старого keyring" "$p"
done

# группы без подпунктов
declare -A GRP_SIZE PATH_OF
GRP_DESC[packages]="манифесты apt/flatpak/vscode/dconf/cron"; GRP_SIZE[packages]=15; PATH_OF[packages]=""
GRP_DESC[appimages]="AppImage-программы"; GRP_SIZE[appimages]=0
GRP_DESC[dotfiles]="конфиги, ssh, шрифты, история"; GRP_SIZE[dotfiles]=0
GRP_DESC[data]="~/Documents целиком (без os-migrate-tool, [10] SKILLS)"; GRP_SIZE[data]="$(m_of "$HOME/Documents")"; PATH_OF[data]="Documents"
GRP_DESC[agents]="AI-агенты: сессии, задачи, скиллы"; GRP_SIZE[agents]=0
GRP_DESC[browsers]="профили браузеров (пароли, куки, расширения)"; GRP_SIZE[browsers]=0

# состояние группы: ON/OFF; подпункты берут свои дефолты (browsers — OFF)
declare -A GRP_STATE SUB_STATE
for g in "${MG_GROUPS[@]}"; do GRP_STATE[$g]=ON; done
GRP_STATE[browsers]=OFF
for k in "${!SUBS[@]}"; do
    IFS=';' read -r _ _ o _ _ <<<"${SUBS[$k]}"
    SUB_STATE[$k]="$o"
done

# ---------- 3b. TUI: группы → подпункты ----------
SUB_KEYS() { local g="$1" k; for k in "${!SUBS[@]}"; do [[ "$k" == "$g|"* ]] && echo "${k#*|}"; done; }

ui_groups() { # главный чеклист групп; выход: выбранные группы через \n
    local -a tags=() descs=() sizes=() offs=() hints=()
    local g t sz sub_cnt n
    for g in "${MG_GROUPS[@]}"; do
        sz=${GRP_SIZE[$g]:-0}; [[ ${GRP_HAS_SUB[$g]:-} ]] && sz=$(grp_total "$g")
        sub_cnt=0; mapfile -t _k < <(SUB_KEYS "$g"); sub_cnt=${#_k[@]}
        n=0; local k
        for k in "${_k[@]}"; do [[ ${SUB_STATE[$g|$k]:-} == ON ]] && n=$((n+1)); done
        [[ ${GRP_STATE[$g]} == ON ]] && t=ON || t=OFF
        local selinfo=""
        [[ ${GRP_HAS_SUB[$g]:-} ]] && selinfo=" [$n/$sub_cnt выбрано] · → — детали"
        tags+=("$g"); descs+=("${GRP_DESC[$g]}$selinfo"); sizes+=("$(hM "$sz")"); offs+=("$t")
        hints+=("${GRP_DESC[$g]}")
    done
    local cur=0 m i tw=0
    for i in "${!tags[@]}"; do (( ${#tags[i]} > tw )) && tw=${#tags[i]}; done
    printf '\e[?25l' >&2
    _draw_g() {
        printf '\e[H\e[J' >&2
        echo "== Что пакуем? (группы)" >&2
        echo -e "  \e[2m↑/↓ — выбор · пробел — галочка · → — детали группы · Enter — ок\e[0m" >&2
        echo >&2
        for i in "${!tags[@]}"; do
            m=" "; [[ ${offs[i]} == ON ]] && m="x"
            if (( i == cur )); then
                printf '\e[7m  [%s] %-*s  %s\e[0m\n' "$m" "$tw" "${tags[i]}" "${descs[i]}" >&2
            else
                printf '  [%s] %-*s  %s\n' "$m" "$tw" "${tags[i]}" "${descs[i]}" >&2
            fi
        done
        echo >&2
        printf '\e[2m  ↪ [%s]\e[0m\n' "${tags[cur]}" >&2
        local hl
        while IFS= read -r hl; do [[ -n "$hl" ]] && printf '\e[2m        %s\e[0m\n' "$hl" >&2; done \
            < <(printf '%s' "${hints[cur]}" | tr '|' '\n')
    }
    _draw_g
    while true; do
        IFS= read -rsn1 key
        case "$key" in
            $'\x1b') read -rsn2 seq
                case "$seq" in
                    '[A') (( cur > 0 )) && (( cur-- ));;
                    '[B') (( cur < ${#tags[@]}-1 )) && (( cur++ ));;
                    '[C') { printf '\e[?25h' >&2; echo "${tags[cur]}:expand"; return 0; };;
                esac;;
            'j'|'J') (( cur < ${#tags[@]}-1 )) && (( cur++ ));;
            'k'|'K') (( cur > 0 )) && (( cur-- ));;
            ' '|' ') [[ ${offs[cur]} == ON ]] && offs[cur]=OFF || offs[cur]=ON; GRP_STATE[${tags[cur]}]=${offs[cur]}
                local kk; for kk in $(SUB_KEYS "${tags[cur]}"); do SUB_STATE["${tags[cur]}|$kk"]=${offs[cur]}; done;;
            'a'|'A') for i in "${!tags[@]}"; do offs[i]=ON; GRP_STATE[${tags[i]}]=ON; done;;
            'n'|'N') for i in "${!tags[@]}"; do offs[i]=OFF; GRP_STATE[${tags[i]}]=OFF; done;;
            '>'|'l'|'L'|'д'|'Д') { printf '\e[?25h' >&2; echo "${tags[cur]}:expand"; return 0; };;
            ''|$'\n'|$'\r') break;;
            *) continue;;
        esac
        _draw_g
    done
    printf '\e[H\e[J\e[?25h' >&2
    for i in "${!tags[@]}"; do [[ ${offs[i]} == ON ]] && echo "${tags[i]}"; done
    return 0
}

ui_sublist() { # $1=группа; чеклист её подпунктов; '←'/b — назад
    local g="$1"
    mapfile -t keys < <(SUB_KEYS "$g")
    ((${#keys[@]})) || { warn "у группы $g нет подпунктов"; return 0; }
    local -a descs=() sizes=() hints=()
    local i k IFSv m
    for k in "${keys[@]}"; do
        IFSv=${SUBS[$g|$k]}; IFS=';' read -r _ d s o h <<<"$IFSv"
        descs+=("$d"); sizes+=("$(hM "$s")"); hints+=("$h")
    done
    local cur=0 tw=0
    for i in "${!keys[@]}"; do (( ${#keys[i]} > tw )) && tw=${#keys[i]}; done
    printf '\e[?25l' >&2
    _draw_s() {
        printf '\e[H\e[J' >&2
        echo "== $g — подпункты" >&2
        echo -e "  \e[2m↑/↓ — выбор · пробел — галочка · ←/b — назад к группам\e[0m" >&2
        echo >&2
        for i in "${!keys[@]}"; do
            m=" "; [[ ${SUB_STATE[$g|${keys[i]}]:-} == ON ]] && m="x"
            if (( i == cur )); then
                printf '\e[7m  [%s] %-*s %-34s %9s \e[0m\n' "$m" "$tw" "${keys[i]}" "${descs[i]}" "${sizes[i]}" >&2
            else
                printf '  [%s] %-*s %-34s %9s\n' "$m" "$tw" "${keys[i]}" "${descs[i]}" "${sizes[i]}" >&2
            fi
        done
        echo >&2
        printf '\e[2m  ↪ [%s]\e[0m\n' "${keys[cur]}" >&2
        local hl
        while IFS= read -r hl; do [[ -n "$hl" ]] && printf '\e[2m        %s\e[0m\n' "$hl" >&2; done \
            < <(printf '%s' "${hints[cur]}" | tr '|' '\n')
    }
    _draw_s
    while true; do
        IFS= read -rsn1 key
        case "$key" in
            $'\x1b') read -rsn2 seq
                case "$seq" in
                    '[A') (( cur > 0 )) && (( cur-- ));;
                    '[B') (( cur < ${#keys[@]}-1 )) && (( cur++ ));;
                    '[D') break;;
                    '') break;;
                esac;;
            'j'|'J') (( cur < ${#keys[@]}-1 )) && (( cur++ ));;
            'k'|'K') (( cur > 0 )) && (( cur-- ));;
            ' '|' ') [[ ${SUB_STATE[$g|${keys[cur]}]:-} == ON ]] && SUB_STATE[$g|${keys[cur]}]=OFF || SUB_STATE[$g|${keys[cur]}]=ON;;
            'a'|'A') for i in "${!keys[@]}"; do SUB_STATE[$g|${keys[i]}]=ON; done;;
            'n'|'N') for i in "${!keys[@]}"; do SUB_STATE[$g|${keys[i]}]=OFF; done;;
            'b'|'B'|'и'|'И'|'<'|'h'|'H') break;;
            ''|$'\n'|$'\r') break;;
            *) continue;;
        esac
        _draw_s
    done
    printf '\e[H\e[J\e[?25h' >&2
    return 0
}

# цикл: группы → детали → назад → Enter подтверждает
while true; do
    echo "DEBUG: GRP_DESC keys: ${!GRP_DESC[@]}" >&2
pick=$(ui_groups "" )
    if [[ "$pick" == *:expand ]]; then
        g="${pick%%:*}"
        [[ ${GRP_HAS_SUB[$g]:-} ]] && ui_sublist "$g" || warn "у группы $g нет подпунктов"
        continue
    fi
    break
done
mapfile -t GRP_CHOSEN <<<"$pick"; GRP_CHOSEN=("${GRP_CHOSEN[@]:-}")
((${#GRP_CHOSEN[@]})) && [[ -n "${GRP_CHOSEN[0]}" ]] || die "ничего не выбрано"

# разворачиваем выбор в SEL: группы без sub — сам тег; с sub — отмеченные подпункты
declare -A SIZE_M
SEL=()
for g in "${GRP_CHOSEN[@]}"; do
    if [[ ${GRP_HAS_SUB[$g]:-} ]]; then
        while IFS= read -r k; do
            if [[ ${SUB_STATE[$g|$k]:-} == ON ]]; then
                IFS=';' read -r _ _ sz _ _ p <<<"${SUBS[$g|$k]}"
                SIZE_M[$k]="$sz"; PATH_OF[$k]="$p"
                SEL+=("$k")
            fi
        done < <(SUB_KEYS "$g")
    else
        SIZE_M[$g]="${GRP_SIZE[$g]}"
        SEL+=("$g")
    fi
done
((${#SEL[@]})) || die "внутри выбранных групп ничего не отмечено"

# ---------- 4. Итоговая оценка ----------
total=0
declare -A GRP_SEL   # group -> пути через пробел
echo; info "Выбрано:"
for s in "${SEL[@]}"; do
    sz=${SIZE_M[$s]:-0}; total=$(( total + sz ))
    if [[ "$s" == *:* ]]; then
        grp="${s%%:*}"
        GRP_SEL[$grp]+="${PATH_OF[$s]} "
        echo "   + ${PATH_OF[$s]}  [$(hM "$sz")]"
    else
        echo "   + $s  [$(hM "$sz")]"
        GRP_SEL[$s]="${PATH_OF[$s]}"
    fi
done
est=$(( total * 55 / 100 ))   # tar.gz ~55% от исходника
free_h=$(df -h --output=avail "$SSD" | tail -1 | tr -d ' ')
echo "--------------------------------------------------"
warn "Сырой объём: $(hM "$total")   оценка после tar.gz: ~$(hM "$est")   на SSD свободно: $free_h"
free_mb=$(df -m --output=avail "$SSD" | tail -1)
(( free_mb > est )) || die "на $SSD свободно $(hM "$free_mb") — мало для оценки ~$(hM "$est")"
read -rp "Начать упаковку? (y = да, Enter/N = отмена) " a
if [[ ! ${a:-n} =~ ^[Yy]$ ]]; then
    warn "Отменено пользователем — ничего не записано."
    exit 0
fi

# ---------- 5. Прогон ----------
RUN_NAME="$(date +%F)_${OS_ID}"
RUN_DIR="$TOOL_ROOT/archives/$RUN_NAME"
if [[ -e "$RUN_DIR" ]]; then RUN_NAME="$(date +%F_%H%M)_${OS_ID}"; RUN_DIR="$TOOL_ROOT/archives/$RUN_NAME"; fi
if (( DRY )); then
    dry "mkdir -p $RUN_DIR/{packages,appimages}/"
else
    mkdir -p "$RUN_DIR/packages" "$RUN_DIR/appimages"
fi
info "Прогон: $RUN_DIR"

targz() { # $1=archive name, остальное — пути от $HOME
    local out="$RUN_DIR/$1"; shift
    local -a paths=(); local p
    for p in "$@"; do [[ -e "$HOME/$p" ]] && paths+=("$p"); done
    ((${#paths[@]})) || { warn "$1: нечего паковать, пропущен"; return 0; }
    if (( DRY )); then
        local raw=0
        for p in "${paths[@]}"; do raw=$(( raw + $(m_of "$HOME/$p") )); done
        dry "tar -czf $out  (${paths[*]})"
        ok "$1 — ~$(hM "$raw") (оценка tar.gz: ~$(hM $(( raw*55/100 )))) [dry-run]"
        return 0
    fi
    ( cd "$HOME" && tar -czf "$out" --exclude-from="$TOOL_DIR/exclude.txt" --files-from <(printf '%s\n' "${paths[@]}") )
    ok "$1 — $(human "$out")"
}

if [[ -n "${GRP_SEL[packages]:-}" ]]; then
    if (( DRY )); then
        dry "dpkg --get-selections > packages/apt-list.txt"
    dry "flatpak list --app > packages/flatpak-list.txt"
    dry "code --list-extensions > packages/code-extensions.txt"
    dry "dconf dump / > packages/dconf.dump"
    dry "crontab -l > packages/crontab.txt"
    dry "systemctl --user list-unit-files > packages/systemd-user-units.txt"
    else
        dpkg --get-selections > "$RUN_DIR/packages/apt-list.txt"
        command -v flatpak >/dev/null && flatpak list --app --columns=application > "$RUN_DIR/packages/flatpak-list.txt" || true
        command -v code >/dev/null && code --list-extensions > "$RUN_DIR/packages/code-extensions.txt" || true
        command -v dconf >/dev/null && dconf dump / > "$RUN_DIR/packages/dconf.dump" || true
        crontab -l > "$RUN_DIR/packages/crontab.txt" 2>/dev/null || true
        systemctl --user list-unit-files --state=enabled --no-legend --plain > "$RUN_DIR/packages/systemd-user-units.txt" || true
    fi
    ok "манифесты ${DRY:+(dry-run) }готовы в packages/"
fi
if [[ -n "${GRP_SEL[appimg]:-}" ]]; then
    read -ra APPS_SEL <<<"${GRP_SEL[appimg]}"
    if (( DRY )); then
        printf '    [dry-run] cp %s -> $RUN_DIR/appimages/\n' "${APPS_SEL[@]}"
    else
        printf '%s\n' "${APPS_SEL[@]}" > "$RUN_DIR/appimages/list.txt"
        printf '%s\n' "${APPS_SEL[@]}" | while IFS= read -r f; do cp -v "$f" "$RUN_DIR/appimages/"; done | tail -3
        ok "appimages: $(ls "$RUN_DIR/appimages"/*.AppImage 2>/dev/null | wc -l) шт."
    fi
fi
[[ -n "${GRP_SEL[dot]:-}" ]]     && targz dotfiles.tar.gz ${GRP_SEL[dot]}
[[ -n "${GRP_SEL[data]:-}" ]]    && targz data.tar.gz "${GRP_SEL[data]}"
[[ -n "${GRP_SEL[agent]:-}" ]]   && targz agents.tar.gz ${GRP_SEL[agent]}
[[ -n "${GRP_SEL[browser]:-}" ]] && targz browsers.tar.gz ${GRP_SEL[browser]}

# ---------- 6. Самообновление инструмента на SSD ----------
info "Синхронизация инструмента на SSD..."
if (( DRY )); then
    dry "cp pack.sh unpack.sh mapping.tsv exclude.txt README.md SKILL.md -> $TOOL_ROOT/"
else
    cp -v "$TOOL_DIR"/{pack.sh,unpack.sh,mapping.tsv,exclude.txt,README.md,SKILL.md} "$TOOL_ROOT/" 2>/dev/null | tail -1
fi

# ---------- 7. Манифест ----------
if (( DRY )); then
    dry "manifest.txt записан (дерево + sha256); latest -> $RUN_NAME"
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
