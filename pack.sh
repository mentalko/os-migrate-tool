#!/usr/bin/env bash
# os-migrate-tool :: pack.sh
# Интерактивная упаковка Ubuntu -> внешний SSD для переезда на CachyOS.
set -euo pipefail

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$TOOL_DIR/src/lib.sh"

# ---------- 0. --dry-run / --no-compress / --compress ----------
NOCOMPRESS=0; COMPRESS_FORCED=0
for arg in "$@"; do
    if [[ "$arg" == "--no-compress" ]]; then NOCOMPRESS=1; COMPRESS_FORCED=1; fi
    if [[ "$arg" == "--compress" ]];     then NOCOMPRESS=0; COMPRESS_FORCED=1; fi
done
omt_dryrun "$@"
(( DRY )) && warn "РЕЖИМ DRY-RUN: ничего не будет записано, только отчёт о действиях."
(( NOCOMPRESS )) && warn "Формат задан флагом: бандл .tar без сжатия."
require_not_root

# ---------- 1. ОС ----------
. /etc/os-release
OS_ID="${ID:-linux}"
if [[ "$OS_ID" != ubuntu && "${ID_LIKE:-}" != *debian* ]]; then
    read -rp "Текущая ОС: ${PRETTY_NAME:-$OS_ID}. pack.sh рассчитан на Ubuntu. Продолжить? [y/N] " a || a=""
    [[ ${a:-n} =~ ^[Yy]$ ]] || exit 1
fi
info "ОС: ${PRETTY_NAME:-$OS_ID}"

# ---------- 2. Выбор SSD ----------
info "Поиск смонтированных дисков..."
mapfile -t ALL < <(lsblk -rno NAME,RM,SIZE,MOUNTPOINT 2>/dev/null | awk '$4 != "" && $4 !~ /^\/(boot|snap)/')
CAND=(); CAND_DESC=()
for line in "${ALL[@]}"; do
    read -r name rm size mnt <<<"$line"
    [[ "$mnt" == "/" ]] && continue
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

# ---------- 3. Конфиг: inventory.yaml (инвентарь) + selection.yaml (галочки) ----------
# Парсинг на python (мини-YAML в conf.py, stdlib): печатает bash-код, eval применяет.
command -v python3 >/dev/null 2>&1 || die "нужен python3 — на нём парсинг конфига и TUI"
[[ -f "$TOOL_DIR/configs/inventory.yaml" && -f "$TOOL_DIR/configs/selection.yaml" ]] \
    || die "нет конфига: configs/inventory.yaml / configs/selection.yaml"
CONF_OUT="$(python3 "$OMT_LIB_DIR/conf.py" "$TOOL_DIR/configs/inventory.yaml" "$TOOL_DIR/configs/selection.yaml" "$TOOL_DIR/configs/exclude_dirs.yaml")" \
    || die "ошибка конфига: см. сообщение выше"
eval "$CONF_OUT"
: "${COMPRESS_ESTIMATE:=55}"

arr_nonempty() { local e; for e in "$@"; do [[ -n "$e" ]] && return 0; done; return 1; }

# AppImage: поиск по абсолютным путям из инвентаря (без eval);
# skip_zero_size из configs/exclude_dirs.yaml — битые/пустые отсекаются условием
APPS_FIND=""
for d in "${APPIMG_ARR[@]}"; do
    [[ -n "$d" && -d "$d" ]] || continue
    while IFS= read -r f; do
        if (( APPIMG_SKIP_ZERO )) && [[ ! -s "$f" ]]; then
            continue
        fi
        APPS_FIND+="$f"$'\n'
    done < <(find "$d" -maxdepth 1 -name '*.AppImage' 2>/dev/null)
done

# ---------- 4. Чеклист: группы + подпункты ----------
hM() { awk -v m="$1" 'BEGIN{ if (m>=1024) printf "%.1fG", m/1024; else printf "%dM", m }'; }
m_of() { local p="$1"; [[ "$p" == /* ]] || p="$HOME/$p"; du -sm --apparent-size "$p" 2>/dev/null | cut -f1; }

# В сегментах dotfiles/data часть путей вырезается из tar (dedup агентов,
# браузеров, flatpak, тулчейна + общие исключения). Оценка размера должна
# вычитать то же самое, иначе прогресс-бар считает 4 ГБ вместо ~400 МБ.
DOT_EXCL=()
for p in "${AGENT_DIRS_ARR[@]}" "${AGENT_CONF_ARR[@]}" "${AGENT_SESSIONS_ARR[@]}" \
         "${BROWSERS_ARR[@]}" "${FLATPAK_ARR[@]}" "${TOOLCHAIN_ARR[@]}"; do
    [[ -n "$p" ]] && DOT_EXCL+=(--exclude="$HOME/${p%/}")
done
for pat in "${EXCL_PATTERNS_ARR[@]}"; do
    [[ -n "$pat" ]] && DOT_EXCL+=(--exclude="$pat")
done
m_of_clean() {
    local p="$1"; [[ "$p" == /* ]] || p="$HOME/$p"
    local -a ex=("${DOT_EXCL[@]}") pp=()
    local key pat prel="${p#$HOME/}"
    for key in "${!EXCL_PER_PATH[@]}"; do
        # ключ может быть и самим путём, и вложенным в него, и его родителем
        if [[ "$prel" == "$key" || "$key" == "$prel/"* ]]; then
            IFS=';' read -r -a pp <<<"${EXCL_PER_PATH[$key]}"
            for pat in "${pp[@]}"; do
                [[ -n "$pat" ]] && ex+=(--exclude="$HOME/$key/$pat")
            done
        fi
    done
    du -sm --apparent-size "${ex[@]}" "$p" 2>/dev/null | cut -f1
}

# оценка для остальных сегментов: глобальные исключения + per_path, но без
# dedup (иначе агентский/браузерный путь вычелся бы сам из себя)
m_of_seg() {
    local p="$1"; [[ "$p" == /* ]] || p="$HOME/$p"
    local -a ex=() pp=()
    local pat key prel="${p#$HOME/}"
    for pat in "${EXCL_PATTERNS_ARR[@]}"; do
        [[ -n "$pat" ]] && ex+=(--exclude="$pat")
    done
    for key in "${!EXCL_PER_PATH[@]}"; do
        if [[ "$prel" == "$key" || "$key" == "$prel/"* ]]; then
            IFS=';' read -r -a pp <<<"${EXCL_PER_PATH[$key]}"
            for pat in "${pp[@]}"; do
                [[ -n "$pat" ]] && ex+=(--exclude="$HOME/$key/$pat")
            done
        fi
    done
    du -sm --apparent-size "${ex[@]}" "$p" 2>/dev/null | cut -f1
}

# путь годится, только если он существует и в нём (включая вложенные каталоги)
# есть хотя бы один файл. Пустые/отсутствующие каталоги в чеклист и бандл не едут.
path_usable() {
    local p="$1"
    [[ -n "$p" ]] || return 1
    [[ "$p" == /* ]] || p="$HOME/$p"
    [[ -e "$p" ]] || return 1
    if [[ -d "$p" ]] && [[ -z "$(find "$p" -mindepth 1 ! -type d -print -quit 2>/dev/null)" ]]; then
        return 1
    fi
    return 0
}

desc_of() { # описание из configs/inventory.yaml (desc:); $1=ключ (путь/имя AppImage), $2=fallback
    local d="${DESC[$1]:-}"
    [[ -n "$d" ]] && { echo "$d"; return 0; }
    echo "$2"
}

declare -A SUBS SUB_ORDER GRP_DESC GRP_HAS_SUB GRP_STATE GRP_EXPANDED GRP_SIZE PATH_OF
add_sub() { # grp tag desc sizeMB hint path   (SUBS = "desc;size;hint;path")
    SUBS["$1|$2"]="$3;$4;$5;$6"
    SUB_ORDER["$1"]+="$2"$'\n'
}
SUB_KEYS() { # теги подпунктов группы в порядке добавления
    local k
    while IFS= read -r k; do [[ -n "$k" ]] && echo "$k"; done <<<"${SUB_ORDER[$1]:-}"
    return 0
}

MG_GROUPS=(packages appimages dotfiles data agents programs appdata browsers)
if arr_nonempty "${FLATPAK_ARR[@]}";   then MG_GROUPS+=(flatpak);   fi
if arr_nonempty "${TOOLCHAIN_ARR[@]}"; then MG_GROUPS+=(toolchain); fi
if arr_nonempty "${TMP_ARR[@]}";       then MG_GROUPS+=(tmp);       fi
if arr_nonempty "${EXTRA_ARR[@]}";     then MG_GROUPS+=(extra);     fi

# подпункты групп (из migrate.conf)
if [[ -n "$APPS_FIND" ]]; then
    GRP_HAS_SUB[appimages]=1
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        b=$(basename "$f"); tag="appimg:$b"
        [[ -n "${SUBS[appimages|$tag]:-}" ]] && tag="appimg:$f"   # дубли имён — тег по полному пути
        add_sub appimages "$tag" "$(desc_of "$b" "AppImage: $b")" "$(m_of "$f")" "$f" "$f"
    done <<<"$APPS_FIND"
fi
GRP_HAS_SUB[dotfiles]=1
for p in "${DOT_ARR[@]}"; do
    path_usable "$p" && add_sub dotfiles "dot:$p" "$(desc_of "$p" "$p")" "$(m_of_clean "$HOME/$p")" "~/$p" "$p"
done
GRP_HAS_SUB[agents]=1
for p in "${AGENT_DIRS_ARR[@]}"; do
    path_usable "$p" && add_sub agents "agent:$p" "$(desc_of "$p" "агент: $p")" "$(m_of_seg "$HOME/$p")" "~/$p" "$p"
done
for p in "${AGENT_CONF_ARR[@]}"; do
    path_usable "$p" && add_sub agents "agent:$p" "$(desc_of "$p" "агент-конфиг: $p")" "$(m_of_seg "$HOME/$p")" "~/$p" "$p"
done
for p in "${AGENT_SESSIONS_ARR[@]}"; do
    path_usable "$p" && add_sub agents "agent:$p" "$(desc_of "$p" "сессии: $p")" "$(m_of_seg "$HOME/$p")" "~/$p — сессии (agents.sessions)" "$p"
done
GRP_HAS_SUB[browsers]=1
for p in "${BROWSERS_ARR[@]}"; do
    path_usable "$p" && add_sub browsers "browser:$p" "$(desc_of "$p" "браузер: $p")" "$(m_of_seg "$HOME/$p")" "~/$p|на Cachy понадобится пароль старого keyring" "$p"
done
if arr_nonempty "${APPDATA_ARR[@]}"; then
    GRP_HAS_SUB[appdata]=1
    for p in "${APPDATA_ARR[@]}"; do
        path_usable "$p" && add_sub appdata "appdata:$p" "$(desc_of "$p" "данные приложения: $p")" "$(m_of_seg "$HOME/$p")" "~/$p" "$p"
    done
fi
GRP_HAS_SUB[data]=1
for p in "${DATA_ARR[@]}"; do
    path_usable "$p" && add_sub data "data:$p" "$(desc_of "$p" "данные: $p")" "$(m_of_clean "$HOME/$p")" "~/$p" "$p"
done
if arr_nonempty "${TMP_ARR[@]}"; then
    GRP_HAS_SUB[tmp]=1
    for p in "${TMP_ARR[@]}"; do
        path_usable "$p" && add_sub tmp "tmp:$p" "$(desc_of "$p" "tmp: $p")" "$(m_of_seg "$HOME/$p")" "~/$p — пересоздаваемые данные" "$p"
    done
fi
if arr_nonempty "${EXTRA_ARR[@]}"; then
    GRP_HAS_SUB[extra]=1
    for p in "${EXTRA_ARR[@]}"; do
        path_usable "$p" && add_sub extra "extra:$p" "$(desc_of "$p" "extra: $p")" "$(m_of_seg "$HOME/$p")" "~/$p" "$p"
    done
fi
if arr_nonempty "${FLATPAK_ARR[@]}"; then
    GRP_HAS_SUB[flatpak]=1
    for p in "${FLATPAK_ARR[@]}"; do
        path_usable "$p" && add_sub flatpak "flatpak:$p" "$(desc_of "$p" "flatpak-данные: $p")" "$(m_of_seg "$HOME/$p")" "~/$p — профили flatpak-приложений" "$p"
    done
fi
if arr_nonempty "${TOOLCHAIN_ARR[@]}"; then
    GRP_HAS_SUB[toolchain]=1
    for p in "${TOOLCHAIN_ARR[@]}"; do
        path_usable "$p" && add_sub toolchain "toolchain:$p" "$(desc_of "$p" "тулчейн: $p")" "$(m_of_seg "$HOME/$p")" "~/$p — тяжёлое, обычно переустанавливают" "$p"
    done
fi

# группы без подпунктов
GRP_DESC[packages]="манифесты apt/flatpak/vscode/dconf/cron"; GRP_SIZE[packages]=15
GRP_DESC[appimages]="AppImage-программы";                     GRP_SIZE[appimages]=0
GRP_DESC[dotfiles]="конфиги, ssh, шрифты, история (без агент-конфигов .config)"; GRP_SIZE[dotfiles]=0
GRP_DESC[agents]="AI-агенты: сессии, задачи, скиллы + их данные в .config";       GRP_SIZE[agents]=0
GRP_DESC[browsers]="профили браузеров (пароли, куки, расширения)";                GRP_SIZE[browsers]=0
GRP_DESC[data]="данные: ~/Documents и т.п.";                 GRP_SIZE[data]=0
GRP_DESC[appdata]="Telegram (tdata), Throne, обои";          GRP_SIZE[appdata]=0
GRP_DESC[programs]="CLI-инструменты: npm/uv/pipx (переустановка), bin"; GRP_SIZE[programs]=0
GRP_DESC[flatpak]="данные flatpak-приложений (.var)";        GRP_SIZE[flatpak]=0
GRP_DESC[toolchain]="тулчейны: rustup/nvm/bun/npm/vscode";   GRP_SIZE[toolchain]=0
GRP_DESC[tmp]="пересоздаваемые данные (/tmp и т.п.)";        GRP_SIZE[tmp]=0
GRP_DESC[extra]="дополнительные пути из inventory.yaml";       GRP_SIZE[extra]=0

# ---------- дефолты чекбоксов: selection.yaml (раскладка conf.py) ----------
# Группа -> её подпункты; точечные [группа]"путь" переопределяют (ON/OFF).
declare -A SUB_STATE PROG_SEC_STATE PROG_TOOL_STATE
for g in "${MG_GROUPS[@]}"; do GRP_STATE[$g]="${TUI_GRP_STATE[$g]:-ON}"; done
for k in "${!SUBS[@]}"; do
    g="${k%%|*}"
    SUB_STATE[$k]="${TUI_GRP_STATE[$g]:-ON}"
done
for k in "${!SUBS[@]}"; do
    g="${k%%|*}"
    IFS=';' read -r _ _ _ p <<<"${SUBS[$k]}"
    st="${TUI_SEL[${g}|${p}]:-${TUI_SEL[${g}|$(basename "$p")]:-}}"
    [[ -n "$st" ]] && SUB_STATE[$k]="$st"
done
# программы (3-й уровень): секции наследуют группу, тулы — секцию + точечный selection
for sec in "${PROG_SECS_ARR[@]}"; do
    PROG_SEC_STATE["programs|$sec"]="${TUI_GRP_STATE[programs]:-ON}"
    for tool in "PROG_${sec^^}_ARR[@]"; do
        for t in "${!tool}"; do
            PROG_TOOL_STATE["programs|$sec|$t"]="${TUI_SEL[programs|$t]:-${TUI_GRP_STATE[programs]:-ON}}"
        done
    done
done

# ---------- 5. TUI: группы с разворотом подпунктов на месте ----------
# Хоткеи: ↑/↓ или j/k — курсор · пробел — галочка · → раскрыть (нырок в первый
# подпункт) · ← свернуть/вернуться к группе · a/n — все/ничего · q — отмена · Enter — ок.
# Движок: tui.py на curses (lib.sh ставит OMT_TUI=1, если python3+доступен) —
# альтернативный экран, скролл вьюпорта, переживает resize. Fallback — bash-рисовалка.
ui_tree() {
    if (( OMT_TUI )); then
        _ui_tree_python
    else
        _ui_tree_bash
    fi
    return 0
}

_tree_feed() { # TREE-протокол для tui.py: группы + подпункты в исходном порядке
    local g k d s h tot
    for g in "${MG_GROUPS[@]}"; do
        if [[ ${GRP_HAS_SUB[$g]:-} ]]; then
            tot=0
            while IFS= read -r k; do
                [[ -n "$k" ]] || continue
                IFS=';' read -r d s h <<<"${SUBS[$g|$k]}"
                tot=$(( tot + ${s:-0} ))
            done < <(SUB_KEYS "$g")
            printf 'G;%s;%s;%s;%s\n' "$g" "${GRP_DESC[$g]}" "$tot" "${GRP_STATE[$g]}"
        else
            printf 'G;%s;%s;%s;%s\n' "$g" "${GRP_DESC[$g]}" "${GRP_SIZE[$g]:-0}" "${GRP_STATE[$g]}"
        fi
        while IFS= read -r k; do
            [[ -n "$k" ]] || continue
            IFS=';' read -r d s h p <<<"${SUBS[$g|$k]}"
            printf 'S;%s;%s;%s;%s;%s;%s;%s\n' "$g" "$k" "$d" "${s:-0}" "${SUB_STATE[$g|$k]}" "$h" "$p"
        done < <(SUB_KEYS "$g")
        # 3-й уровень: секции и тулы (group_programs)
        if [[ "$g" == programs ]]; then
            for sec in "${PROG_SECS_ARR[@]}"; do
                printf 'SEC;%s;%s;%s;%s;%s\n' "$g" "$sec" "менеджер: $sec" "0" "${PROG_SEC_STATE[programs|$sec]}"
                for t in "PROG_${sec^^}_ARR[@]"; do
                    for tool in "${!t}"; do
                        d=$(desc_of "$tool" "$tool")
                        printf 'T;%s;%s;%s;%s;%s;%s;%s;%s\n' "$g" "$sec" "$tool" "$d" "0" "${PROG_TOOL_STATE[programs|$sec|$tool]}" "переустановка на Cachy" ""
                    done
                done
            done
        fi
    done
    return 0
}

_ui_tree_python() { # tui.py пишет финальные состояния в файл — раскладываем в словари
    local line key _rc=0
    local state_file
    state_file="$(mktemp /tmp/omt-tui-state.XXXXXX)"
    OMT_STATE="$state_file" OMT_TUI_TITLE="Что пакуем?" \
        python3 "$OMT_LIB_DIR/tui.py" TREE < <(_tree_feed) || _rc=$?
    if (( _rc == 1 )); then              # q/Esc — отмена
        warn "Отменено пользователем — ничего не записано."
        exit 0
    fi
    (( _rc == 0 )) || die "tui: дерево завершилось с ошибкой ($_rc)"
    while IFS= read -r line; do
        IFS=';' read -r typ f1 f2 f3 f4 <<<"$line"
        case "$typ" in
            G)   GRP_STATE["$f1"]="$f2";;
            SEC) PROG_SEC_STATE["$f1|$f2"]="$f3";;
            T)   PROG_TOOL_STATE["$f1|$f2|$f3"]="$f4";;
            S)   SUB_STATE["$f1|$f2"]="$f3";;
        esac
    done < "$state_file"
    rm -f "$state_file"
    return 0
}

# --- fallback: TUI на голом bash (если нет python3/curses) ---
# Все перемещения — через присваивание: (( )) под set -e возвращает 1 при
# нулевом результате (упало при переходе стрелкой на строку 0).
_ui_tree_bash() {
    printf '\e[?1049h' >&2              # альтернативный экран: не мусорим скроллбек
    local cur=0 TUI_SEL=0
    local -a rows=() kinds=() tags=() descs=() sizes=() hints=()  # kinds: grp|sub; rows: "g" или "g|tag"
    local i g k n cnt sz d h p m tw

    build() { # один проход по подпунктам: размер группы, счётчики и живой итог
        rows=(); kinds=(); tags=(); descs=(); sizes=(); hints=()
        tw=0; TUI_SEL=0
        for g in "${MG_GROUPS[@]}"; do
            n=0; cnt=0
            local gt=0 st=0 v
            while IFS= read -r k; do
                [[ -n "$k" ]] || continue
                IFS=';' read -r _ v _ _ <<<"${SUBS[$g|$k]}"
                gt=$(( gt + ${v:-0} ))
                cnt=$((cnt+1))
                if [[ ${SUB_STATE[$g|$k]:-} == ON ]]; then n=$((n+1)); st=$(( st + ${v:-0} )); fi
            done < <(SUB_KEYS "$g")
            sz="$gt"
            if [[ -z ${GRP_HAS_SUB[$g]:-} ]]; then
                sz="${GRP_SIZE[$g]:-0}"
                [[ ${GRP_STATE[$g]} == ON ]] && st="$sz"
            fi
            TUI_SEL=$(( TUI_SEL + st ))
            # строка группы: ▾ раскрыта, ▸ свёрнута, ' ' — без подпунктов
            local glyph=" "
            if [[ ${GRP_HAS_SUB[$g]:-} ]]; then
                if [[ ${GRP_EXPANDED[$g]:-} ]]; then glyph="▾"; else glyph="▸"; fi
            fi
            local mark=""
            [[ ${GRP_HAS_SUB[$g]:-} ]] && mark=" [${n}/${cnt}]"
            rows+=("$g"); kinds+=(grp); tags+=("$g"); descs+=("$glyph ${GRP_DESC[$g]}$mark"); sizes+=("$(hM "$sz")")
            if [[ ${GRP_EXPANDED[$g]:-} ]]; then
                hints+=("${GRP_DESC[$g]}|пробел — отметить/снять группу целиком|← — свернуть подпункты|q — отмена")
            else
                hints+=("${GRP_DESC[$g]}|→ — раскрыть подпункты|q — отмена")
            fi
            (( ${#g} > tw )) && tw=${#g}
            # подпункты раскрытой группы — прямо в списке
            if [[ ${GRP_EXPANDED[$g]:-} ]]; then
                while IFS= read -r k; do
                    [[ -n "$k" ]] || continue
                    IFS=';' read -r d sz h p <<<"${SUBS[$g|$k]}"
                    rows+=("$g|$k"); kinds+=(sub); tags+=("$k"); descs+=("$d")
                    sizes+=("$(hM "${sz:-0}")"); hints+=("$h|q — отмена")
                    (( ${#k} > tw )) && tw=${#k}
                done < <(SUB_KEYS "$g")
            fi
        done
        (( tw > 30 )) && tw=30
        return 0
    }

    draw() {
        printf '\e[H\e[J' >&2
        echo "== Что пакуем?" >&2
        echo -e "  \e[2m↑/↓ — курсор · пробел — галочка · →/← — раскрыть/свернуть · a/n — все/ничего · q — отмена · Enter — ок\e[0m" >&2
        echo -e "  \e[2mВыбрано сырого объёма: ~$(hM "$TUI_SEL")\e[0m" >&2
        echo >&2
        for i in "${!rows[@]}"; do
            if [[ ${kinds[i]} == grp ]]; then
                m=" "; [[ ${GRP_STATE[${rows[i]}]} == ON ]] && m="x"
                if (( i == cur )); then
                    printf '\e[7m  [%s] %-*s %-40s %8s \e[0m\n' "$m" "$tw" "${tags[i]}" "${descs[i]}" "${sizes[i]}" >&2
                else
                    printf '\e[36m  [%s] %-*s %-40s %8s\e[0m\n' "$m" "$tw" "${tags[i]}" "${descs[i]}" "${sizes[i]}" >&2
                fi
            else
                m=" "; [[ ${SUB_STATE[${rows[i]}]:-} == ON ]] && m="x"
                if (( i == cur )); then
                    printf '\e[7m    └ [%s] %-*s %-40s %8s \e[0m\n' "$m" "$tw" "${tags[i]}" "${descs[i]}" "${sizes[i]}" >&2
                else
                    printf '\e[2m    └ [%s] %-*s %-40s %8s\e[0m\n' "$m" "$tw" "${tags[i]}" "${descs[i]}" "${sizes[i]}" >&2
                fi
            fi
        done
        echo >&2
        printf '\e[2m  ↪ [%s]\e[0m\n' "${tags[cur]}" >&2
        _hint "${hints[cur]}"
        return 0
    }

    move_up()   { if (( cur > 0 )); then cur=$((cur-1)); fi; return 0; }
    move_down() { if (( cur < ${#rows[@]}-1 )); then cur=$((cur+1)); fi; return 0; }

    toggle() {
        local r="${rows[cur]}" kk
        if [[ ${kinds[cur]} == grp ]]; then
            local ns=ON; [[ ${GRP_STATE[$r]} == ON ]] && ns=OFF   # флип: ON→OFF, иначе ON
            GRP_STATE[$r]="$ns"
            while IFS= read -r kk; do [[ -n "$kk" ]] && SUB_STATE["$r|$kk"]="$ns"; done < <(SUB_KEYS "$r")
        else
            [[ ${SUB_STATE[$r]:-} == ON ]] && SUB_STATE[$r]=OFF || SUB_STATE[$r]=ON
        fi
        return 0
    }
    expand() { # → / l: раскрыть свёрнутую группу, курсор — на первый подпункт
        local r="${rows[cur]}"
        [[ ${kinds[cur]} == grp && ${GRP_HAS_SUB[$r]:-} ]] || return 0
        if [[ ! ${GRP_EXPANDED[$r]:-} ]]; then
            GRP_EXPANDED[$r]=1
            if (( cur < ${#rows[@]}-1 )); then cur=$((cur+1)); fi   # первый подпункт (rows пересоберутся)
        fi
        return 0
    }
    collapse() { # ← / h: с подпункта — к родительской группе; на раскрытой группе — свернуть
        local r="${rows[cur]}" i
        if [[ ${kinds[cur]} == sub ]]; then
            for (( i=cur-1; i>=0; i-- )); do
                if [[ ${kinds[i]} == grp && ${rows[i]} == "${r%%|*}" ]]; then cur=$i; return 0; fi
            done
        elif [[ ${GRP_EXPANDED[$r]:-} ]]; then
            unset "GRP_EXPANDED[$r]"
        fi
        return 0
    }
    cancel() {
        printf '\e[?1049l\e[?25h' >&2
        warn "Отменено пользователем — ничего не записано."
        exit 0
    }

    build; draw
    while true; do
        IFS= read -rsn1 key || break
        case "$key" in
            $'\x1b') read -rsn2 -t 0.2 seq || true
                case "$seq" in
                    '[A') move_up;;
                    '[B') move_down;;
                    '[C') expand;;
                    '[D') collapse;;
                esac;;
            'j'|'J'|'о'|'О') move_down;;
            'k'|'K'|'л'|'Л') move_up;;
            ' '|',') toggle;;
            '>'|'l'|'L'|'д'|'Д') expand;;
            '<'|'h'|'H'|'b'|'B') collapse;;
            'a'|'A'|'ф'|'Ф') for g in "${MG_GROUPS[@]}"; do
                    GRP_STATE[$g]=ON
                    while IFS= read -r k; do [[ -n "$k" ]] && SUB_STATE["$g|$k"]=ON; done < <(SUB_KEYS "$g")
                done;;
            'n'|'N'|'т'|'Т') for g in "${MG_GROUPS[@]}"; do
                    GRP_STATE[$g]=OFF
                    while IFS= read -r k; do [[ -n "$k" ]] && SUB_STATE["$g|$k"]=OFF; done < <(SUB_KEYS "$g")
                done;;
            'q'|'Q'|'й'|'Й') cancel;;
            ''|$'\n'|$'\r') break;;
            *) continue;;
        esac
        build; draw
    done
    printf '\e[?1049l\e[?25h' >&2        # выйти из alt-экрана, вернуть курсор
    return 0
}

ui_tree

# ---------- 6. Разворачиваем выбор в план ----------
chosen=0
for g in "${MG_GROUPS[@]}"; do [[ ${GRP_STATE[$g]} == ON ]] && chosen=$((chosen+1)); done
(( chosen )) || die "ничего не выбрано"

declare -A SIZE_M GRP_SIZE_PLAN GRP_SEL   # GRP_SEL[группа] = пути через \n
SEL=()
for g in "${MG_GROUPS[@]}"; do
    if [[ "$g" == programs ]]; then
        # программы: файлов нет — выбранные тулы уезжают в meta/programs.txt
        for sec in "${PROG_SECS_ARR[@]}"; do
            for arr_ref in "PROG_${sec^^}_ARR[@]"; do
                for tool in "${!arr_ref}"; do
                    [[ ${PROG_TOOL_STATE[programs|$sec|$tool]:-} == ON ]] || continue
                    PROGS_SEL+="$sec|$tool"$'\n'
                done
            done
        done
        [[ -n "${PROGS_SEL:-}" ]] && GRP_SIZE_PLAN[programs]=0
    elif [[ ${GRP_HAS_SUB[$g]:-} ]]; then
        # галочка группы — массовый переключатель; решают состояния подпунктов:
        # ON-подпункт едет даже внутри выключенной группы (см. selection [extra])
        while IFS= read -r k; do
            [[ -n "$k" && ${SUB_STATE[$g|$k]:-} == ON ]] || continue
            IFS=';' read -r _ sz _ p <<<"${SUBS[$g|$k]}"
            SIZE_M[$k]="${sz:-0}"; PATH_OF[$k]="$p"
            SEL+=("$k")
            GRP_SIZE_PLAN[$g]=$(( ${GRP_SIZE_PLAN[$g]:-0} + ${sz:-0} ))
        done < <(SUB_KEYS "$g")
    elif [[ ${GRP_STATE[$g]} == ON ]]; then
        SIZE_M[$g]="${GRP_SIZE[$g]:-0}"; SEL+=("$g")
        GRP_SIZE_PLAN[$g]=$(( ${GRP_SIZE_PLAN[$g]:-0} + ${GRP_SIZE[$g]:-0} ))
    fi
done
((${#SEL[@]})) || die "внутри выбранных групп ничего не отмечено"

# ---------- 7. Итоговая оценка + подтверждение ----------
total=0
echo; info "Выбрано:"
for s in "${SEL[@]}"; do
    sz=${SIZE_M[$s]:-0}; total=$(( total + sz ))
    if [[ "$s" == *:* ]]; then
        grp="${s%%:*}"
        GRP_SEL[$grp]+="${PATH_OF[$s]}"$'\n'
        echo "   + ${PATH_OF[$s]}  [$(hM "$sz")]"
    else
        echo "   + $s  [$(hM "$sz")]"
    fi
done
est=$(( total * COMPRESS_ESTIMATE / 100 ))   # оценка сжатия из configs/inventory.yaml
(( NOCOMPRESS )) && est=$total               # без сжатия: бандл = сырой объём
free_h=$(df -h --output=avail "$SSD" | tail -1 | tr -d ' ')
free_mb=$(df -m --output=avail "$SSD" | tail -1)
echo "--------------------------------------------------"
CMP_NOTE="оценка после tar.gz: ~$(hM "$est")"
(( NOCOMPRESS )) && CMP_NOTE="без сжатия (.tar)"
warn "Сырой объём: $(hM "$total")   $CMP_NOTE   на SSD свободно: $free_h"
(( free_mb > est )) || die "на $SSD свободно $(hM "$free_mb") — мало для оценки ~$(hM "$est")"

info "Планируемые архивы:"
declare -A PLAN_ROWS=( [packages]="packages/" [appimages]="appimages/" [dotfiles]="dotfiles/" [data]="data/" \
            [agents]="agents/" [programs]="programs/" [appdata]="appdata/" [browsers]="browsers/" [flatpak]="flatpak/" \
            [toolchain]="toolchain/" [tmp]="tmp/" [extra]="extra/" )
plan_total=0
for grp in packages appimages dotfiles data agents programs appdata browsers flatpak toolchain tmp extra; do
    [[ -n "${GRP_SIZE_PLAN[$grp]:-}" ]] || continue
    plan_total=$(( plan_total + ${GRP_SIZE_PLAN[$grp]} ))
    echo "    ${PLAN_ROWS[$grp]}  —  $(hM "${GRP_SIZE_PLAN[$grp]}")"
done
echo "    --------------------------------------------"
if (( ! COMPRESS_FORCED )); then
    # формат бандла не задан флагом — спрашиваем здесь, оценки обоих вариантов известны
    fmt=$(ui_menu "Формат бандла — как упаковываем?" \
        "gz;С сжатием (gzip) — ~$(hM $(( plan_total * COMPRESS_ESTIMATE / 100 ))), медленнее" \
        "tar;Без сжатия (.tar) — ~$(hM $plan_total), быстрее, выборочная распаковка мгновенно")
    case "$fmt" in tar) NOCOMPRESS=1;; *) NOCOMPRESS=0;; esac
fi
plan_est=$(( plan_total * COMPRESS_ESTIMATE / 100 )); (( NOCOMPRESS )) && plan_est=$plan_total
warn "Итого к записи: ~$(hM $plan_est)$([[ $NOCOMPRESS == 0 ]] && echo ' (оценка tar.gz)'), на диске свободно: $free_h"
read -rp "Начать упаковку? (y = да, Enter/N = отмена) " a || a=""   # EOF = отмена
if [[ ! ${a:-n} =~ ^[Yy]$ ]]; then
    warn "Отменено пользователем — ничего не записано."
    exit 0
fi

# ---------- 8. Прогон: один бандл .tar.gz на дату ----------
# Сегменты компонентов дописываются в бандл как конкатенация gzip-членов,
# каждый — под своим каталогом (dotfiles/, data/, …) через --transform.
BUNDLE_EXT="tar.gz"; (( NOCOMPRESS )) && BUNDLE_EXT="tar"
COMPRESS_OPT="z"; (( NOCOMPRESS )) && COMPRESS_OPT=""
RUN_NAME="$(date +%F)_${OS_ID}"
META="$TOOL_ROOT/archives/$RUN_NAME.meta"
BUNDLE="$TOOL_ROOT/archives/$RUN_NAME.$BUNDLE_EXT"
if [[ -e "$BUNDLE" || -e "$META" ]]; then
    RUN_NAME="$(date +%F_%H%M)_${OS_ID}"
    META="$TOOL_ROOT/archives/$RUN_NAME.meta"
    BUNDLE="$TOOL_ROOT/archives/$RUN_NAME.$BUNDLE_EXT"
fi
if (( DRY )); then
    dry "mkdir -p $META"
else
    mkdir -p "$META/packages" "$META/appimages"
    : > "$BUNDLE"
fi
info "Прогон: ${RUN_NAME}.${BUNDLE_EXT}"

# исключения: паттерны из configs/exclude_dirs.yaml — на ВСЕ сегменты;
# dedup (агентские/браузерные/тулчейн/flatpak пути + сам tool) — только
# dotfiles/data (они едут в своих сегментах).
EXCL_PATTERNS=""; EXCL_DEDUP=""; EXCL_DOTDATA=""
if (( ! DRY )); then
    EXCL_PATTERNS="$META/exclude-patterns"
    printf '%s\n' "${EXCL_PATTERNS_ARR[@]}" > "$EXCL_PATTERNS"
    EXCL_DEDUP="$META/.exclude-dedup"
    : > "$EXCL_DEDUP"
    for p in "${AGENT_DIRS_ARR[@]}" "${AGENT_CONF_ARR[@]}" "${BROWSERS_ARR[@]}" "${FLATPAK_ARR[@]}" "${TOOLCHAIN_ARR[@]}"; do
        # без хвостового '/': tar exclude 'dir/' матчит только сам каталог,
        # но НЕ其内容 — дубли должны резаться вместе со всем поддеревом
        [[ -n "$p" ]] && printf '%s\n' "$p" >> "$EXCL_DEDUP"
    done
    printf 'Documents/os-migrate-tool\n' >> "$EXCL_DEDUP"
    cat "$EXCL_PATTERNS" "$EXCL_DEDUP" > "$META/exclude-dotfiles-data"
    EXCL_DOTDATA="$META/exclude-dotfiles-data"
fi

seg_tar() { # $1=каталог сегмента в бандле, $2=exclude-файл (пусто = без), $3=пути через \n (от $HOME)
    local seg="$1" excl="$2" list="$3"
    local -a paths=()
    local p raw=0
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        if path_usable "$p"; then
            paths+=("$p")
        else
            warn "$seg/: пропущен (нет или пусто): $p"
        fi
    done <<<"$list"
    ((${#paths[@]})) || { warn "$seg/: нечего паковать, сегмент пропущен"; return 0; }
    for p in "${paths[@]}"; do
        if [[ "$seg" == dotfiles || "$seg" == data ]]; then
            raw=$(( raw + $(m_of_clean "$p") ))
        else
            raw=$(( raw + $(m_of_seg "$p") ))
        fi
    done
    local total_bytes=$(( raw * 1048576 ))
    if (( DRY )); then
        dry "tar -c${COMPRESS_OPT}f - --transform 's,^,$seg/,' … (${paths[*]})"
        seg_est=$(( raw*COMPRESS_ESTIMATE/100 )); (( NOCOMPRESS )) && seg_est=$raw
        ok "$seg/ — ~$(hM "$raw") (оценка: ~$(hM $seg_est)) [dry-run]"
    else
        # procsub инлайном: fd /dev/fd/N живёт только внутри команды tar
        local -a pre=() pp=()
        [[ -n "$excl" ]] && pre=( --exclude-from="$excl" )
        # пер-путевые исключения (per_path: в exclude_dirs.yaml) — только для
        # выбранных путей этого сегмента, чтобы не резать данные других групп
        local per_file="" key pat p2
        per_file="$META/.excl-$seg"
        : > "$per_file"
        for p2 in "${paths[@]}"; do
            for key in "${!EXCL_PER_PATH[@]}"; do
                if [[ "$p2" == "$key" || "$key" == "$p2/"* ]]; then
                    IFS=';' read -r -a pp <<<"${EXCL_PER_PATH[$key]}"
                    for pat in "${pp[@]}"; do
                        [[ -n "$pat" ]] && printf '%s/%s\n' "$key" "$pat" >> "$per_file"
                    done
                fi
            done
        done
        [[ -s "$per_file" ]] && pre+=( --exclude-from="$per_file" ) || per_file=""
        tar_rc=0
        ( cd "$HOME" && tar -c${COMPRESS_OPT}f - --transform "s,^,$seg/," "${pre[@]}" \
            --checkpoint=200 --checkpoint-action="exec=$OMT_LIB_DIR/progress-line \"$seg\" $total_bytes" \
            --files-from <(printf '%s\n' "${paths[@]}") ) >> "$BUNDLE" || tar_rc=$?
        # progress-line перезаписывал одну строку — убираем её перед итоговой
        [[ -t 2 ]] && printf '\r\033[2K' >&2
        local w=24 fill=24 empty=0 i bar=""
        for ((i = 0; i < fill; i++)); do bar+="▓"; done
        for ((i = 0; i < empty; i++)); do bar+="░"; done
        if (( tar_rc == 0 )); then
            ok "$seg/ [$bar] 100% — дописан в бандл (${#paths[@]} путей)"
        else
            # rc 1/2 = часть файлов пропущена (нет доступа / изменились при чтении) —
            # полный список tar написал в лог выше; прогон продолжается
            warn "$seg/ [$bar] — дописан с пропусками (tar rc=$tar_rc, список выше в логе)"
        fi
    fi
    return 0
}

# ---------- 8a. Манифесты пакетов (в meta, затем сегментом в бандл) ----------
if [[ -n "${GRP_SIZE_PLAN[packages]:-}" ]]; then
    if (( DRY )); then
        if command -v dpkg >/dev/null 2>&1; then
            dry "dpkg --get-selections > packages/apt-list.txt"
        elif command -v pacman >/dev/null 2>&1; then
            dry "pacman -Qqe > packages/pacman-explicit.txt"
            dry "pacman -Qqm > packages/pacman-foreign.txt"
        fi
        dry "flatpak list --app > packages/flatpak-list.txt"
        dry "code --list-extensions > packages/code-extensions.txt"
        dry "dconf dump / > packages/dconf.dump"
        dry "crontab -l > packages/crontab.txt"
        dry "systemctl --user list-unit-files > packages/systemd-user-units.txt"
        dry "npm ls -g --depth=0 > packages/npm-global.txt"
        dry "pip3 list --user > packages/pip-user.txt"
    else
        # источник может быть не debian-подобным (например, текущая CachyOS):
        # dpkg может отсутствовать — тогда собираем pacman-списки, а apt-list
        # оставляем пустым, чтобы unpack не падал на отсутствующем файле.
        : > "$META/packages/apt-list.txt"
        if command -v dpkg >/dev/null 2>&1; then
            dpkg --get-selections > "$META/packages/apt-list.txt"
        elif command -v pacman >/dev/null 2>&1; then
            pacman -Qqe > "$META/packages/pacman-explicit.txt"
            pacman -Qqm > "$META/packages/pacman-foreign.txt"
            warn "dpkg не найден — собраны pacman-списки; имена пакетов не совпадают с apt-маппингом"
        else
            warn "нет ни dpkg, ни pacman — список пакетов пуст"
        fi
        command -v flatpak >/dev/null && flatpak list --app --columns=application > "$META/packages/flatpak-list.txt" || true
        command -v code >/dev/null && code --list-extensions > "$META/packages/code-extensions.txt" || true
        command -v dconf >/dev/null && dconf dump / > "$META/packages/dconf.dump" || true
        crontab -l > "$META/packages/crontab.txt" 2>/dev/null || true
        systemctl --user list-unit-files --state=enabled --no-legend --plain > "$META/packages/systemd-user-units.txt" || true
        command -v npm >/dev/null && npm ls -g --depth=0 > "$META/packages/npm-global.txt" 2>/dev/null || true
        command -v pip3 >/dev/null && pip3 list --user > "$META/packages/pip-user.txt" 2>/dev/null || true
        ( cd "$META" && tar -c${COMPRESS_OPT}f - packages ) >> "$BUNDLE"
        ok "packages/ — дописан в бандл"
    fi
fi

# ---------- 8b. AppImage (в meta, затем сегментом в бандл) ----------
if [[ -n "${GRP_SEL[appimg]:-}" ]]; then
    if (( DRY )); then
        while IFS= read -r f; do [[ -n "$f" ]] && dry "cp \"$f\" -> appimages/"; done <<<"${GRP_SEL[appimg]}"
    else
        : > "$META/appimages/list.txt"
        n=0
        while IFS= read -r f; do
            [[ -n "$f" ]] || continue
            printf '%s\n' "$f" >> "$META/appimages/list.txt"
            cp "$f" "$META/appimages/" && n=$((n+1))
        done <<<"${GRP_SEL[appimg]}"
        ( cd "$META" && tar -c${COMPRESS_OPT}f - appimages ) >> "$BUNDLE"
        ok "appimages/ — дописан в бандл ($n шт.)"
    fi
fi

# ---------- 8c. Сегменты по группам ----------
[[ -n "${GRP_SEL[dot]:-}" ]]       && seg_tar dotfiles   "$EXCL_DOTDATA" "${GRP_SEL[dot]}"
[[ -n "${GRP_SEL[data]:-}" ]]      && seg_tar data       "$EXCL_DOTDATA" "${GRP_SEL[data]}"
[[ -n "${GRP_SEL[agent]:-}" ]]     && seg_tar agents     "$EXCL_PATTERNS" "${GRP_SEL[agent]}"
[[ -n "${GRP_SEL[appdata]:-}" ]]   && seg_tar appdata    "$EXCL_PATTERNS" "${GRP_SEL[appdata]}"
[[ -n "${GRP_SEL[browser]:-}" ]]   && seg_tar browsers   "$EXCL_PATTERNS" "${GRP_SEL[browser]}"
[[ -n "${GRP_SEL[flatpak]:-}" ]]   && seg_tar flatpak    "$EXCL_PATTERNS" "${GRP_SEL[flatpak]}"
[[ -n "${GRP_SEL[toolchain]:-}" ]] && seg_tar toolchain  "$EXCL_PATTERNS" "${GRP_SEL[toolchain]}"
[[ -n "${GRP_SEL[tmp]:-}" ]]       && seg_tar tmp        "$EXCL_PATTERNS" "${GRP_SEL[tmp]}"
[[ -n "${GRP_SEL[extra]:-}" ]]     && seg_tar extra      "$EXCL_PATTERNS" "${GRP_SEL[extra]}"

# staging больше не нужен — содержимое внутри бандла
if (( ! DRY )); then rm -rf "$META/packages" "$META/appimages"; fi

# ---------- 9. paths.tsv: происхождение каждого пути ----------
write_paths() {
    echo -e "group\ttag\tsize\tsource\tarchive\tdest"
    if [[ -n "${GRP_SIZE_PLAN[packages]:-}" ]]; then
        echo -e "packages\tpackages\t15M\t(manifests: dpkg|pacman/flatpak/code/dconf/cron/systemd)\t${RUN_NAME}.tar.gz:packages/\t\$HOME"
    fi
    if [[ -n "${PROGS_SEL:-}" ]]; then
        while IFS= read -r pt; do
            [[ -n "$pt" ]] || continue
            echo -e "programs\t${pt%%|*}\t-\t(menеджер: ${pt%%|*})\t${RUN_NAME}.tar.gz:meta/programs.txt\tпереустановка на Cachy"
        done <<<"$PROGS_SEL"
    fi
    if [[ -n "${GRP_SEL[appimg]:-}" ]]; then
        while IFS= read -r f; do
            [[ -n "$f" ]] || continue
            path_usable "$f" || continue
            echo -e "appimages\tappimg\t$(m_of "$f")M\t$f\t${RUN_NAME}.tar.gz:appimages/$(basename "$f")\t\$HOME/Applications/$(basename "$f")"
        done <<<"${GRP_SEL[appimg]}"
    fi
    local spec grp seg
    for spec in "dot dotfiles" "data data" "agent agents" "appdata appdata" "browser browsers" \
                "flatpak flatpak" "toolchain toolchain" "tmp tmp" "extra extra"; do
        read -r grp seg <<<"$spec"
        [[ -n "${GRP_SEL[$grp]:-}" ]] || continue
        while IFS= read -r f; do
            [[ -n "$f" ]] || continue
            path_usable "$f" || continue
            echo -e "$grp\t$grp\t-\t\$HOME/$f\t${RUN_NAME}.tar.gz:$seg/$f\t\$HOME/$f"
        done <<<"${GRP_SEL[$grp]}"
    done
    return 0
}
if (( ! DRY )); then
    write_paths > "$META/paths.tsv"
    ok "paths.tsv записан ($(($(wc -l < "$META/paths.tsv")-1)) путей) — что, откуда и куда"
    if [[ -n "${PROGS_SEL:-}" ]]; then
        printf '%s' "$PROGS_SEL" > "$META/programs.txt"
        ok "programs.txt записан ($(wc -l < "$META/programs.txt") программ) — переустановка на Cachy"
    fi
    # резерв meta внутри бандла: если .meta/ на диске потеряется — paths.tsv
    # восстанавливается распаковкой сегмента meta/ (manifest с sha внутрь не
    # положить — рекурсия, он только снаружи)
    ( cd "$META" && tar -c${COMPRESS_OPT}f - --transform "s,^,meta/," paths.tsv programs.txt .exclude-dedup exclude-patterns ) >> "$BUNDLE" 2>/dev/null || \
( cd "$META" && tar -c${COMPRESS_OPT}f - --transform "s,^,meta/," paths.tsv .exclude-dedup exclude-patterns ) >> "$BUNDLE"
    ok "meta/ — paths.tsv дублирован в бандл"
fi

# ---------- 10. Самообновление инструмента на SSD ----------
info "Синхронизация инструмента на SSD..."
TOOL_FILES=(src/lib.sh src/tui.py src/conf.py src/progress-line configs/mapping.toml configs/exclude_dirs.yaml configs/inventory.yaml configs/selection.yaml skills/os-migrate-tool/SKILL.md pack.sh pack-kitty.sh unpack.sh README.md README.ru.md)
if (( DRY )); then
    dry "cp ${TOOL_FILES[*]} -> $TOOL_ROOT/"
else
    mkdir -p "$TOOL_ROOT/src" "$TOOL_ROOT/configs" "$TOOL_ROOT/skills/os-migrate-tool"
    for f in "${TOOL_FILES[@]}"; do cp "$TOOL_DIR/$f" "$TOOL_ROOT/$f"; done
    ok "скопировано: ${TOOL_FILES[*]}"
fi

# ---------- 11. Манифест: sha256 бандла + дерево содержимого ----------
if (( DRY )); then
    dry "manifest.txt записан (sha256 бандла + tar -tzf); latest -> ${RUN_NAME}.tar.gz"
else
    {
        sha256sum "$BUNDLE"
        echo "--- содержимое бандла ---"
        tar --ignore-zeros -t${COMPRESS_OPT}f "$BUNDLE"
    } > "$META/manifest.txt"
    if ln -sfn "$RUN_NAME.tar.gz" "$TOOL_ROOT/archives/latest" 2>/dev/null; then
        ok "manifest.txt записан; latest -> ${RUN_NAME}.tar.gz"
    else
        echo "$RUN_NAME.tar.gz" > "$TOOL_ROOT/archives/latest.txt"
        warn "manifest.txt записан; ФС SSD не поддерживает симлинки — прогон записан в latest.txt"
    fi
fi

echo
if (( DRY )); then
    ok "DRY-RUN завершён: ничего не записано. Планируемый бандл: $BUNDLE (~$(hM "$est"))"
    ok "Реальный прогон: bash pack.sh (без --dry-run)"
else
    ok "Готово! Бандл: $BUNDLE  ($(human "$BUNDLE"))"
    ok "На CachyOS запусти: $TOOL_ROOT/unpack.sh"
fi
