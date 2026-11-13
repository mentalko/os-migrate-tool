# os-migrate-tool :: lib.sh
# Общий код pack.sh/unpack.sh: окружение, сообщения, собственный TUI.
# Не запускать напрямую — источникируется скриптами:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HOME="${HOME:-$(getent passwd "$(id -u)" | cut -d: -f6)}"

die()  { echo "ОШИБКА: $*" >&2; exit 1; }
info() { echo -e "\e[36m→\e[0m $*"; }
ok()   { echo -e "\e[32m✓\e[0m $*"; }
warn() { echo -e "\e[33m!\e[0m $*"; }
human(){ du -sh --apparent-size "$1" 2>/dev/null | cut -f1; }

# любой неожиданный вылет — с причиной и строкой; вернуть курсор/экран, если TUI рисовал
trap 'printf "\e[?1049l\e[?25h" >&2; printf "\e[31mОШИБКА\e[0m: сбой на строке %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

require_not_root() { [[ $EUID -eq 0 ]] && die "не запускай от root — права на файлы поедут от root"; return 0; }

# ---------- TUI-движок: python/curses первичен (корректная перерисовка, скролл,
# resize, alt-screen), bash-рисовалка — fallback. tui.py — stdlib, ставить нечего. ----------
OMT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OMT_TUI=0
if command -v python3 >/dev/null 2>&1 && python3 -c 'import curses' >/dev/null 2>&1; then
    OMT_TUI=1
fi

omt_dryrun() { # --dry-run/-n в аргументах -> DRY=1
    DRY=0
    local a
    for a in "$@"; do [[ "$a" == "--dry-run" || "$a" == "-n" ]] && DRY=1; done
    return 0
}

dry() { echo -e "\e[35m[dry-run]\e[0m $*"; }

# ---------- UI: собственный TUI на голом bash ----------
# Рисуем в stderr (stdout захватывается $()), результат функции — только stdout.
# Курсор — инверсией, пункты — цианом, hint — dim. '|' в hint = перевод строки
# (каждый путь своей строкой). Требует терминала (stdin — tty).

_hint() { # $1 — текст hint, '|' = новая строка
    local hl
    while IFS= read -r hl; do [[ -n "$hl" ]] && printf '\e[2m        %s\e[0m\n' "$hl" >&2; done \
        < <(printf '%s' "$1" | tr '|' '\n')
    return 0
}

_tty_required() { [[ -t 0 ]] || die "TUI требует интерактивного терминала (stdin не tty)"; }

ui_menu() { # одиночный выбор: tag;desc[;hint]  -> tag
    _tty_required
    local title="$1"; shift
    if (( OMT_TUI )); then
        local _rc=0
        printf 'M;%s\n' "$@" | OMT_TUI_TITLE="$title" python3 "$OMT_LIB_DIR/tui.py" MENU || _rc=$?
        (( _rc <= 1 )) || die "tui: меню завершилось с ошибкой ($_rc)"   # 1 = отмена (пусто)
        return 0
    fi
    local -a tags=() descs=() hints=()
    local it t d h cur=0 i
    for it in "$@"; do
        IFS=';' read -r t d h <<<"$it"
        tags+=("$t"); descs+=("$d"); hints+=("${h:-$d}")
    done
    printf '\e[?25l' >&2                  # спрятать курсор
    _draw_menu() {
        printf '\e[H\e[J' >&2
        echo "== $title" >&2
        echo -e "  \e[2m↑/↓ или j/k — выбор · Enter — подтвердить\e[0m" >&2
        echo >&2
        for i in "${!tags[@]}"; do
            if (( i == cur )); then
                printf '\e[7m  ▶ %-14s %s \e[0m\n' "${tags[i]}" "${descs[i]}" >&2
            else
                printf '\e[36m  ▶ %-14s %s\e[0m\n' "${tags[i]}" "${descs[i]}" >&2
            fi
        done
        echo >&2
        printf '\e[2m  ↪ [%s]\e[0m\n' "${tags[cur]}" >&2
        _hint "${hints[cur]}"
    }
    _draw_menu
    while true; do
        IFS= read -rsn1 key || break
        case "$key" in
            $'\x1b') read -rsn2 -t 0.2 seq || true
                case "$seq" in
                    '[A') if (( cur > 0 )); then cur=$((cur-1)); fi;;
                    '[B') if (( cur < ${#tags[@]}-1 )); then cur=$((cur+1)); fi;;
                esac;;
            'j'|'J'|'о'|'О') if (( cur < ${#tags[@]}-1 )); then cur=$((cur+1)); fi;;
            'k'|'K'|'л'|'Л') if (( cur > 0 )); then cur=$((cur-1)); fi;;
            'q'|'Q'|'й'|'Й') printf '\e[H\e[J\e[?25h' >&2; return 0;;   # отмена — пустой результат
            ''|$'\n'|$'\r') break;;
            *) continue;;
        esac
        _draw_menu
    done
    printf '\e[H\e[J\e[?25h' >&2          # стереть меню, вернуть курсор
    echo "${tags[cur]}"
    return 0
}

ui_checklist() { # множественный выбор: tag;desc;onoff[;hint] -> выбранные теги построчно
    _tty_required
    local title="$1"; shift
    if (( OMT_TUI )); then
        local _rc=0
        printf 'C;%s\n' "$@" | OMT_TUI_TITLE="$title" python3 "$OMT_LIB_DIR/tui.py" CHECK || _rc=$?
        (( _rc <= 1 )) || die "tui: чеклист завершился с ошибкой ($_rc)"   # 1 = отмена (пусто)
        return 0
    fi
    local -a tags=() descs=() offs=() hints=()
    local it t d o h cur=0 i m
    for it in "$@"; do
        IFS=';' read -r t d o h <<<"$it"
        tags+=("$t"); descs+=("$d"); offs+=("${o:-OFF}"); hints+=("${h:-$d}")
    done
    printf '\e[?25l' >&2
    _draw_chk() {
        printf '\e[H\e[J' >&2
        echo "== $title" >&2
        echo -e "  \e[2m↑/↓ — курсор · пробел — галочка · a/n — все/ничего · Enter — ок\e[0m" >&2
        echo >&2
        for i in "${!tags[@]}"; do
            m=" "; [[ ${offs[i]} == ON ]] && m="x"
            if (( i == cur )); then
                printf '\e[7m  [%s] %-20s %-44s \e[0m\n' "$m" "${tags[i]}" "${descs[i]}" >&2
            else
                printf '\e[36m  [%s] %-20s %-44s\e[0m\n' "$m" "${tags[i]}" "${descs[i]}" >&2
            fi
        done
        echo >&2
        printf '\e[2m  ↪ [%s]\e[0m\n' "${tags[cur]}" >&2
        _hint "${hints[cur]}"
    }
    _draw_chk
    while true; do
        IFS= read -rsn1 key || break
        case "$key" in
            $'\x1b') read -rsn2 -t 0.2 seq || true
                case "$seq" in
                    '[A') if (( cur > 0 )); then cur=$((cur-1)); fi;;
                    '[B') if (( cur < ${#tags[@]}-1 )); then cur=$((cur+1)); fi;;
                esac;;
            'j'|'J'|'о'|'О') if (( cur < ${#tags[@]}-1 )); then cur=$((cur+1)); fi;;
            'k'|'K'|'л'|'Л') if (( cur > 0 )); then cur=$((cur-1)); fi;;
            ' '|',') [[ ${offs[cur]} == ON ]] && offs[cur]=OFF || offs[cur]=ON;;
            'a'|'A'|'ф'|'Ф') for i in "${!tags[@]}"; do offs[i]=ON; done;;
            'n'|'N'|'т'|'Т') for i in "${!tags[@]}"; do offs[i]=OFF; done;;
            'q'|'Q'|'й'|'Й') printf '\e[H\e[J\e[?25h' >&2; return 0;;   # отмена — ничего не выбрано
            ''|$'\n'|$'\r') break;;
            *) continue;;
        esac
        _draw_chk
    done
    printf '\e[H\e[J\e[?25h' >&2
    for i in "${!tags[@]}"; do [[ ${offs[i]} == ON ]] && echo "${tags[i]}"; done
    return 0
}
