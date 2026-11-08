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
                    '[A') (( cur > 0 )) && (( --cur ));;
                    '[B') (( cur < ${#tags[@]}-1 )) && (( ++cur ));;
                esac;;
            ' '|' ') [[ ${offs[cur]} == ON ]] && offs[cur]=OFF || offs[cur]=ON;;
            'a'|'A'|'ф'|'Ф') for i in "${!tags[@]}"; do offs[i]=ON; done;;
            'n'|'N'|'т'|'Т') for i in "${!tags[@]}"; do offs[i]=OFF; done;;
            'j'|'J'|'о'|'О') (( cur < ${#tags[@]}-1 )) && (( ++cur ));;
            'k'|'K'|'л'|'Л') (( cur > 0 )) && (( --cur ));;
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
                    '[A') (( cur > 0 )) && (( --cur ));;
                    '[B') (( cur < ${#tags[@]}-1 )) && (( ++cur ));;
                esac;;
            'j'|'J'|'о'|'О') (( cur < ${#tags[@]}-1 )) && (( ++cur ));;
            'k'|'K'|'л'|'Л') (( cur > 0 )) && (( --cur ));;
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

# ---------- 3. Компоненты: конфиг + группы с проваливанием ----------
hM() { awk -v m="$1" 'BEGIN{ if (m>=1024) printf "%.1fG", m/1024; else printf "%dM", m }'; }
size_of() { local s=0 p; for p in "$@"; do [[ -e "$HOME/$p" || -e "$p" ]] && s=$(( s + $(du -sm --apparent-size "$HOME/$p" 2>/dev/null | cut -f1) )); done; echo "$s"; }
m_of() { du -sm --apparent-size "$1" 2>/dev/null | cut -f1; }

CONF="$TOOL_DIR/migrate.conf"
[[ -f "$CONF" ]] || die "нет конфига путей: $CONF (см. migrate.conf в репозитории)"
# shellcheck disable=SC1090
source "$CONF"
: "${APPIMG_DIRS:=}" "${DOT_DIRS:=}" "${DOT_FILES:=}" "${AGENT_DIRS:=}" \
  "${AGENT_CONFIG_DIRS:=}" "${BROWSER_DIRS:=}" "${DATA_DIRS:=}" "${TMP_DIRS:=}" \
  "${EXTRA_DIRS:=}" "${COMPRESS_ESTIMATE:=55}"

read -ra DOT_ARR    <<<"$DOT_DIRS $DOT_FILES"
read -ra AGENT_ARR  <<<"$AGENT_DIRS $AGENT_CONFIG_DIRS"
# сессии: отдельная переменная (актуализируется агентом на новой системе);
# добавляем только пути, не покрытые родительскими каталогами из AGENT_*
AGENT_EXTRA_SESSIONS=""
for sp in ${AGENT_SESSIONS_DIRS:-}; do
    covered=0
    for ap in ${AGENT_DIRS} ${AGENT_CONFIG_DIRS}; do [[ "$sp" == "$ap"/* || "$sp" == "$ap" ]] && covered=1; done
    (( covered )) || AGENT_EXTRA_SESSIONS+=" $sp"
done
read -ra AGENT_ARR <<<"$AGENT_ARR $AGENT_EXTRA_SESSIONS"
read -ra BROWSER_ARR<<<"$BROWSER_DIRS"
read -ra DATA_ARR   <<<"$DATA_DIRS"
read -ra TMP_ARR    <<<"$TMP_DIRS"
read -ra EXTRA_ARR  <<<"$EXTRA_DIRS"
read -ra TOOLCHAIN_ARR <<<"${TOOLCHAIN_DIRS:-}"
read -ra FLATPAK_ARR   <<<"${FLATPAK_DATA_DIRS:-}"
[[ -n "$APPIMG_DIRS" ]] && APPS_FIND=$(eval find $APPIMG_DIRS -maxdepth 1 -name '*.AppImage' 2>/dev/null || true)

MG_GROUPS=(packages appimages dotfiles data agents browsers)
[[ ${#FLATPAK_ARR[@]} -gt 0 && -n "${FLATPAK_ARR[0]:-}" ]] && MG_GROUPS+=(flatpak)
[[ ${#TOOLCHAIN_ARR[@]} -gt 0 && -n "${TOOLCHAIN_ARR[0]:-}" ]] && MG_GROUPS+=(toolchain)
[[ ${#TMP_ARR[@]} -gt 0 && -n "${TMP_ARR[0]:-}" ]] && MG_GROUPS+=(tmp)
[[ ${#EXTRA_ARR[@]} -gt 0 && -n "${EXTRA_ARR[0]:-}" ]] && MG_GROUPS+=(extra)

declare -A GRP_DESC GRP_HAS_SUB GRP_STATE_OFF SUBS   # SUBS["grp|tag"]="desc;size;onoff;hint;path"
add_sub() { # grp tag desc sizeMB onoff hint path
    SUBS["$1|$2"]="$3;$4;$5;$6;$7"
}
grp_total() { # сумма размеров подпунктов группы
    local g="$1" t=0 k v
    for k in "${!SUBS[@]}"; do [[ "$k" == "$g|"* ]] && { IFS=';' read -r _ v _ _ _ <<<"${SUBS[$k]}"; t=$(( t + v )); }; done
    echo "$t"
}
# --- подпункты групп (из migrate.conf) ---
if [[ -n "$APPS_FIND" ]]; then
    GRP_HAS_SUB[appimages]=1
    while IFS= read -r f; do
        b=$(basename "$f"); add_sub appimages "appimg:$b" "AppImage: $b" "$(m_of "$f")" ON "~/$f" "$f"
    done <<<"$APPS_FIND"
fi
GRP_HAS_SUB[dotfiles]=1
for p in "${DOT_ARR[@]}"; do
    [[ -e "$HOME/$p" ]] && add_sub dotfiles "dot:$p" "$p" "$(m_of "$HOME/$p")" ON "~/$p" "~/$p"
done
GRP_HAS_SUB[agents]=1
for p in ${AGENT_DIRS}; do
    [[ -e "$HOME/$p" ]] && add_sub agents "agent:$p" "агент: $p" "$(m_of "$HOME/$p")" ON "~/$p — сессии, задачи, скиллы" "~/$p"
done
for p in ${AGENT_CONFIG_DIRS}; do
    [[ -e "$HOME/$p" ]] && add_sub agents "agent:$p" "агент-конфиг: $p" "$(m_of "$HOME/$p")" ON "~/$p" "$p"
done
for p in $AGENT_EXTRA_SESSIONS; do
    [[ -e "$HOME/$p" ]] && add_sub agents "agent:$p" "сессии: $p" "$(m_of "$HOME/$p")" ON "~/$p — сессии (AGENT_SESSIONS_DIRS)" "~/$p"
done
GRP_HAS_SUB[browsers]=1
for p in "${BROWSER_ARR[@]}"; do
    [[ -e "$HOME/$p" ]] && add_sub browsers "browser:$p" "браузер: $p" "$(m_of "$HOME/$p")" OFF "~/$p|на Cachy понадобится пароль старого keyring" "$p"
done
GRP_HAS_SUB[data]=1
for p in "${DATA_ARR[@]}"; do
    [[ -e "$HOME/$p" ]] && add_sub data "data:$p" "данные: $p" "$(m_of "$HOME/$p")" ON "~/$p" "$p"
done
if [[ ${#TMP_ARR[@]} -gt 0 && -n "${TMP_ARR[0]:-}" ]]; then
    GRP_HAS_SUB[tmp]=1
    for p in "${TMP_ARR[@]}"; do
        [[ -e "$HOME/$p" || -e "$p" ]] && add_sub tmp "tmp:$p" "tmp: $p" "$(m_of "$HOME/$p")" OFF "~/$p — пересоздаваемые данные" "$p"
    done
fi
if [[ ${#EXTRA_ARR[@]} -gt 0 && -n "${EXTRA_ARR[0]:-}" ]]; then
    GRP_HAS_SUB[extra]=1
    for p in "${EXTRA_ARR[@]}"; do
        [[ -e "$HOME/$p" ]] && add_sub extra "extra:$p" "extra: $p" "$(m_of "$HOME/$p")" OFF "~/$p" "$p"
    done
fi
if [[ ${#FLATPAK_ARR[@]} -gt 0 && -n "${FLATPAK_ARR[0]:-}" ]]; then
    GRP_HAS_SUB[flatpak]=1
    for p in "${FLATPAK_ARR[@]}"; do
        [[ -e "$HOME/$p" ]] && add_sub flatpak "flatpak:$p" "flatpak-данные: $p" "$(m_of "$HOME/$p")" ON "~/$p — профили flatpak-приложений" "$p"
    done
fi
if [[ ${#TOOLCHAIN_ARR[@]} -gt 0 && -n "${TOOLCHAIN_ARR[0]:-}" ]]; then
    GRP_HAS_SUB[toolchain]=1
    for p in "${TOOLCHAIN_ARR[@]}"; do
        [[ -e "$HOME/$p" ]] && add_sub toolchain "toolchain:$p" "тулчейн: $p" "$(m_of "$HOME/$p")" OFF "~/$p — тяжёлое, обычно переустанавливают" "$p"
    done
fi

# группы без подпунктов
declare -A GRP_SIZE PATH_OF
GRP_DESC[packages]="манифесты apt/flatpak/vscode/dconf/cron"; GRP_SIZE[packages]=15; PATH_OF[packages]=""
GRP_DESC[appimages]="AppImage-программы"; GRP_SIZE[appimages]=0
GRP_DESC[dotfiles]="конфиги, ssh, шрифты, история (без агент-конфигов .config)"; GRP_SIZE[dotfiles]=0
GRP_DESC[agents]="AI-агенты: сессии, задачи, скиллы + их данные в .config"; GRP_SIZE[agents]=0
GRP_DESC[browsers]="профили браузеров (пароли, куки, расширения)"; GRP_SIZE[browsers]=0
GRP_DESC[data]="данные: ~/Documents и т.п."; GRP_SIZE[data]=0
GRP_DESC[flatpak]="данные flatpak-приложений (.var)"; GRP_SIZE[flatpak]=0
GRP_DESC[toolchain]="тулчейны: rustup/nvm/bun/npm/vscode"; GRP_SIZE[toolchain]=0
GRP_DESC[tmp]="пересоздаваемые данные (/tmp и т.п.)"; GRP_SIZE[tmp]=0
GRP_DESC[extra]="дополнительные пути из migrate.conf"; GRP_SIZE[extra]=0

# состояние группы: ON/OFF; подпункты берут свои дефолты (browsers/toolchain/tmp/extra — OFF)
declare -A GRP_STATE SUB_STATE
for g in "${MG_GROUPS[@]}"; do GRP_STATE[$g]=ON; done
for g in browsers toolchain tmp extra; do GRP_STATE[$g]=OFF; done
for k in "${!SUBS[@]}"; do
    IFS=';' read -r _ _ o _ _ <<<"${SUBS[$k]}"
    SUB_STATE[$k]="$o"
done

# ---------- 3b. TUI: группы с разворотом подпунктов на месте ----------
SUB_KEYS() { local g="$1" k; for k in "${!SUBS[@]}"; do [[ "$k" == "$g|"* ]] && echo "${k#*|}"; done; }

declare -A GRP_EXPANDED
ui_tree() { # плоский список: группы + (развёрнутые) подпункты; Enter — подтвердить
    local -a rows=() tags=() descs=() sizes=() hints=() kinds=()   # kinds: grp|sub; rows: "g" или "g|tag"
    local cur=0 m i tw=0 g k n cnt sz d h p o

    build() {
        rows=(); descs=(); sizes=(); hints=(); kinds=(); tw=0
        for g in "${MG_GROUPS[@]}"; do
            sz=$(grp_total "$g"); [[ -z ${GRP_HAS_SUB[$g]:-} ]] && sz=${GRP_SIZE[$g]:-0}; n=0; cnt=0
            for k in $(SUB_KEYS "$g"); do
                cnt=$((cnt+1)); [[ ${SUB_STATE[$g|$k]:-} == ON ]] && n=$((n+1))
            done
            local mark=""; [[ ${GRP_HAS_SUB[$g]:-} ]] && mark=" [${n}/${cnt}]"$([[ ${GRP_EXPANDED[$g]:-} ]] && echo ' · ← свернуть' || echo ' · → — раскрыть')
            rows+=("$g"); tags+=("$g"); kinds+=(grp); descs+=("${GRP_DESC[$g]}$mark"); sizes+=("$(hM "$sz")")
            hints+=("${GRP_DESC[$g]}|$([[ ${GRP_EXPANDED[$g]:-} ]] && echo 'подпункты раскрыты ниже' || echo '→ — показать подпункты')")
            (( ${#g} > tw )) && tw=${#g} || true
            if [[ ${GRP_EXPANDED[$g]:-} ]]; then
                for k in $(SUB_KEYS "$g"); do
                    IFS=';' read -r d s o h p <<<"${SUBS[$g|$k]}"
                    rows+=("$g|$k"); tags+=("$k"); kinds+=(sub); descs+=("$d"); sizes+=("$(hM "$s")"); hints+=("$h")
                    (( ${#k} > tw )) && tw=${#k} || true
                done
            fi
        done
    }

    draw() {
        printf '\e[H\e[J' >&2
        echo "== Что пакуем?" >&2
        echo -e "  \e[2m↑/↓ — курсор · пробел — галочка · →/← — раскрыть/свернуть группу · a/n — все/ничего · Enter — ок\e[0m" >&2
        echo >&2
        for i in "${!rows[@]}"; do
            m=" "
            if [[ ${kinds[i]} == grp ]]; then [[ ${GRP_STATE[${rows[i]}]} == ON ]] && m="x"
            else [[ ${SUB_STATE[${rows[i]}]:-} == ON ]] && m="x"; fi
            local prefix="  "
            [[ ${kinds[i]} == sub ]] && prefix="    \e[2m└\e[0m "
            if (( i == cur )); then
                printf '\e[7m%s[%s] %-*s %-38s %9s \e[0m\n' "$prefix" "$m" "$tw" "${tags[i]}" "${descs[i]}" "${sizes[i]}" >&2
            else
                printf '%s[%s] %-*s %-38s %9s\n' "$prefix" "$m" "$tw" "${tags[i]}" "${descs[i]}" "${sizes[i]}" >&2
            fi
        done
        echo >&2
        printf '\e[2m  ↪ [%s]\e[0m\n' "${descs[cur]%% [*}" >&2
        local hl
        while IFS= read -r hl; do [[ -n "$hl" ]] && printf '\e[2m        %s\e[0m\n' "$hl" >&2; done \
            < <(printf '%s' "${hints[cur]}" | tr '|' '\n')
    }

    toggle() {
        local r="${rows[cur]}"
        if [[ ${kinds[cur]} == grp ]]; then
            local ns=OFF; [[ ${GRP_STATE[$r]} == ON ]] && ns=ON
            GRP_STATE[$r]="$ns"
            local kk; for kk in $(SUB_KEYS "$r"); do SUB_STATE["$r|$kk"]="$ns"; done
        else
            [[ ${SUB_STATE[$r]:-} == ON ]] && SUB_STATE[$r]=OFF || SUB_STATE[$r]=ON
        fi
    }

    build; draw
    while true; do
        IFS= read -rsn1 key
        case "$key" in
            $'\x1b') read -rsn2 seq
                case "$seq" in
                    '[A') (( cur > 0 )) && (( --cur ));;
                    '[B') (( cur < ${#rows[@]}-1 )) && (( ++cur ));;
                    '[C') [[ ${kinds[cur]} == grp && ${GRP_HAS_SUB[${rows[cur]}]:-} ]] && { if [[ ${GRP_EXPANDED[${rows[cur]}]:-} ]]; then unset 'GRP_EXPANDED[${rows[cur]}]'; else GRP_EXPANDED[${rows[cur]}]=1; fi; };;
                    '[D') [[ ${kinds[cur]} == grp ]] && unset "GRP_EXPANDED[${rows[cur]}]";;
                esac;;
            'j'|'J') (( cur < ${#rows[@]}-1 )) && (( ++cur ));;
            'k'|'K') (( cur > 0 )) && (( --cur ));;
            ' '|',') toggle;;
            '>'|'l'|'L'|'д'|'Д') [[ ${kinds[cur]} == grp && ${GRP_HAS_SUB[${rows[cur]}]:-} ]] && GRP_EXPANDED[${rows[cur]}]=1;;
            '<'|'h'|'H'|'b'|'B') [[ ${kinds[cur]} == grp ]] && unset "GRP_EXPANDED[${rows[cur]}]";;
            'a'|'A'|'ф'|'Ф') for g in "${MG_GROUPS[@]}"; do GRP_STATE[$g]=ON; local kk; for kk in $(SUB_KEYS "$g"); do SUB_STATE["$g|$kk"]=ON; done; done;;
            'n'|'N'|'т'|'Т') for g in "${MG_GROUPS[@]}"; do GRP_STATE[$g]=OFF; local kk2; for kk2 in $(SUB_KEYS "$g"); do SUB_STATE["$g|$kk2"]=OFF; done; done;;
            ''|$'\n'|$'\r') break;;
            *) continue;;
        esac
        build; draw
    done
    printf '\e[H\e[J\e[?25h' >&2
    return 0
}

ui_tree ""
GRP_CHOSEN=(); for g in "${MG_GROUPS[@]}"; do [[ ${GRP_STATE[$g]} == ON ]] && GRP_CHOSEN+=("$g"); done
((${#GRP_CHOSEN[@]})) || die "ничего не выбрано"

# разворачиваем выбор в SEL: группы без sub — сам тег; с sub — отмеченные подпункты
declare -A SIZE_M GRP_SIZE_PLAN
SEL=()
for g in "${GRP_CHOSEN[@]}"; do
    if [[ ${GRP_HAS_SUB[$g]:-} ]]; then
        while IFS= read -r k; do
            if [[ ${SUB_STATE[$g|$k]:-} == ON ]]; then
                IFS=';' read -r _ sz _ _ p <<<"${SUBS[$g|$k]}"
                SIZE_M[$k]="$sz"; PATH_OF[$k]="$p"
                SEL+=("$k")
                GRP_SIZE_PLAN[$g]=$(( ${GRP_SIZE_PLAN[$g]:-0} + sz ))
            fi
        done < <(SUB_KEYS "$g")
    else
        SIZE_M[$g]="${GRP_SIZE[$g]}"
        SEL+=("$g")
        GRP_SIZE_PLAN[$g]=$(( ${GRP_SIZE_PLAN[$g]:-0} + ${GRP_SIZE[$g]} ))
    fi
done
((${#SEL[@]})) || die "внутри выбранных групп ничего не отмечено"

# ---------- 4. Итоговая оценка ----------
total=0
declare -A GRP_SEL
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
est=$(( total * COMPRESS_ESTIMATE / 100 ))   # оценка сжатия из migrate.conf
free_h=$(df -h --output=avail "$SSD" | tail -1 | tr -d ' ')
echo "--------------------------------------------------"
warn "Сырой объём: $(hM "$total")   оценка после tar.gz: ~$(hM "$est")   на SSD свободно: $free_h"
free_mb=$(df -m --output=avail "$SSD" | tail -1)
(( free_mb > est )) || die "на $SSD свободно $(hM "$free_mb") — мало для оценки ~$(hM "$est")"
echo; info "Планируемые архивы:"
declare -A PLAN_ROWS=( [packages]="packages/" [appimages]="appimages/" [dotfiles]=dotfiles.tar.gz [data]=data.tar.gz [agents]=agents.tar.gz [browsers]=browsers.tar.gz [flatpak]=flatpak-data.tar.gz [toolchain]=toolchain.tar.gz [tmp]=tmp.tar.gz [extra]=extra.tar.gz )
plan_total=0
for grp in packages appimages dotfiles data agents browsers flatpak toolchain tmp extra; do
    [[ -n "${GRP_SIZE_PLAN[$grp]:-}" ]] || continue
    gsz=${GRP_SIZE_PLAN[$grp]}
    plan_total=$(( plan_total + gsz ))
    echo "    ${PLAN_ROWS[$grp]}  —  $(hM "$gsz")"
done
echo "    --------------------------------------------"
warn "Итого к записи: ~$(hM $(( plan_total * COMPRESS_ESTIMATE / 100 ))) (оценка tar.gz), на диске свободно: $free_h"
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

# dedup-исключения генерируются из migrate.conf: агентские пути и браузеры
# едут в своих архивах, поэтому вырезаются из dotfiles/data
EXCL_DEDUP="$RUN_DIR/.exclude-dedup"
if (( ! DRY )); then
    : > "$EXCL_DEDUP"
    for p in ${AGENT_DIRS} ${AGENT_CONFIG_DIRS} ${BROWSER_DIRS} ${FLATPAK_DATA_DIRS:-} ${TOOLCHAIN_DIRS:-}; do echo "$p/" >> "$EXCL_DEDUP"; done
    echo "Documents/os-migrate-tool/" >> "$EXCL_DEDUP"
fi
for p in ${AGENT_DIRS} ${AGENT_CONFIG_DIRS} ${BROWSER_DIRS}; do echo "$p/" >> "$EXCL_DEDUP"; done
echo "Documents/os-migrate-tool/" >> "$EXCL_DEDUP"

targz() { # $1=archive name, $2=exclude file, остальное — пути от $HOME
    local out="$RUN_DIR/$1"; local excl="$2"; shift 2
    local -a paths=(); local p
    for p in "$@"; do [[ -e "$HOME/$p" ]] && paths+=("$p"); done
    ((${#paths[@]})) || { warn "$1: нечего паковать, пропущен"; return 0; }
    if (( DRY )); then
        local raw=0
        for p in "${paths[@]}"; do raw=$(( raw + $(m_of "$HOME/$p") )); done
        dry "tar -czf $out  (${paths[*]})"
        ok "$1 — ~$(hM "$raw") (оценка tar.gz: ~$(hM $(( raw*COMPRESS_ESTIMATE/100 )))) [dry-run]"
        return 0
    fi
    ( cd "$HOME" && tar -czf "$out" --exclude-from="$TOOL_DIR/$excl" --files-from <(printf '%s\n' "${paths[@]}") )
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
[[ -n "${GRP_SEL[dot]:-}" ]]     && targz dotfiles.tar.gz "$EXCL_DEDUP" ${GRP_SEL[dot]}
[[ -n "${GRP_SEL[data]:-}" ]]    && targz data.tar.gz "$EXCL_DEDUP" "${GRP_SEL[data]}"
[[ -n "${GRP_SEL[agent]:-}" ]]   && targz agents.tar.gz exclude.txt ${GRP_SEL[agent]}
[[ -n "${GRP_SEL[browser]:-}" ]] && targz browsers.tar.gz exclude.txt ${GRP_SEL[browser]}
[[ -n "${GRP_SEL[flatpak]:-}" ]] && targz flatpak-data.tar.gz exclude.txt ${GRP_SEL[flatpak]}
[[ -n "${GRP_SEL[toolchain]:-}" ]] && targz toolchain.tar.gz exclude.txt ${GRP_SEL[toolchain]}
[[ -n "${GRP_SEL[tmp]:-}" ]]     && targz tmp.tar.gz exclude.txt ${GRP_SEL[tmp]}
[[ -n "${GRP_SEL[extra]:-}" ]]   && targz extra.tar.gz exclude.txt ${GRP_SEL[extra]}

# ---------- 5b. paths.tsv: происхождение каждого файла ----------
# формат: group<TAB>tag<TAB>size<TAB>source(в Ubuntu)<TAB>archive<TAB>dest(на Cachy)
if (( ! DRY )); then
    PATHS_TSV="$RUN_DIR/paths.tsv"
    echo -e "group\ttag\tsize\tsource\tarchive\tdest" > "$PATHS_TSV"
    for grp in "${!GRP_SEL[@]}"; do
        case "$grp" in
            packages) echo -e "packages\tpackages\t${SIZE_M[packages]:-15}\t(manifests: dpkg/flatpak/code/dconf/cron/systemd)\tpackages/\t\$HOME" >> "$PATHS_TSV";;
            appimg)   for f in ${GRP_SEL[appimg]}; do
                          echo -e "appimages\tappimg\t$(m_of "$f")M\t$f\tappimages/$(basename "$f")\t\$HOME/Applications/$(basename "$f")" >> "$PATHS_TSV"
                      done;;
            dot)      for f in ${GRP_SEL[dot]}; do   echo -e "dotfiles\tdot\t-\t\$HOME/$f\tdotfiles.tar.gz\t\$HOME/$f" >> "$PATHS_TSV"; done;;
            data)     for f in ${GRP_SEL[data]}; do  echo -e "data\tdata\t-\t\$HOME/$f\tdata.tar.gz\t\$HOME/$f" >> "$PATHS_TSV"; done;;
            agent)    for f in ${GRP_SEL[agent]}; do echo -e "agents\tagent\t-\t\$HOME/$f\tagents.tar.gz\t\$HOME/$f" >> "$PATHS_TSV"; done;;
            browser)  for f in ${GRP_SEL[browser]}; do echo -e "browsers\tbrowser\t-\t\$HOME/$f\tbrowsers.tar.gz\t\$HOME/$f" >> "$PATHS_TSV"; done;;
            flatpak)  for f in ${GRP_SEL[flatpak]}; do echo -e "flatpak\tflatpak\t-\t\$HOME/$f\tflatpak-data.tar.gz\t\$HOME/$f" >> "$PATHS_TSV"; done;;
            toolchain) for f in ${GRP_SEL[toolchain]}; do echo -e "toolchain\ttoolchain\t-\t\$HOME/$f\ttoolchain.tar.gz\t\$HOME/$f" >> "$PATHS_TSV"; done;;
            tmp)      for f in ${GRP_SEL[tmp]}; do   echo -e "tmp\ttmp\t-\t\$HOME/$f\ttmp.tar.gz\t\$HOME/$f" >> "$PATHS_TSV"; done;;
            extra)    for f in ${GRP_SEL[extra]}; do echo -e "extra\textra\t-\t\$HOME/$f\textra.tar.gz\t\$HOME/$f" >> "$PATHS_TSV"; done;;
        esac
    done
    ok "paths.tsv записан ($(wc -l < "$PATHS_TSV") строк) — что, откуда и куда"
fi

# ---------- 6. Самообновление инструмента на SSD ----------
info "Синхронизация инструмента на SSD..."
if (( DRY )); then
    dry "cp pack.sh unpack.sh mapping.tsv exclude.txt migrate.conf README.md SKILL.md -> $TOOL_ROOT/"
else
    cp -v "$TOOL_DIR"/{pack.sh,unpack.sh,mapping.tsv,exclude.txt,migrate.conf,README.md,SKILL.md} "$TOOL_ROOT/" 2>/dev/null | tail -1
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
