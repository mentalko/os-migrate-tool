#!/usr/bin/env bash
# os-migrate-tool :: pack-kitty.sh
# Открывает pack.sh в отдельном окне kitty с теми же аргументами и пишет
# полный лог сессии — агент может прочитать его при падении.
#
#   ./pack-kitty.sh              # = pack.sh
#   ./pack-kitty.sh --dry-run    # = pack.sh --dry-run
#
# Лог (ввод/вывод/TUI): /tmp/omt-pack-<метка>.ts
# Код выхода:           /tmp/omt-pack-<метка>.rc
set -euo pipefail

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "ОШИБКА: $*" >&2; exit 1; }
command -v kitty >/dev/null 2>&1 || die "kitty не найден в PATH"

STAMP="$(date +%Y%m%d_%H%M%S)"
LOG="/tmp/omt-pack-$STAMP.ts"
RCF="/tmp/omt-pack-$STAMP.rc"

# аргументы pack.sh пробрасываем как есть; %q — безопасное квотирование для sh
inner="bash $(printf '%q ' "$TOOL_DIR/pack.sh")$([[ $# -gt 0 ]] && printf '%q ' "$@")"

# env-передача вместо кавычечных упражнений: kitty наследует окружение
OMT_INNER="$inner" OMT_LOG="$LOG" OMT_RCF="$RCF" kitty \
    --title "os-migrate-tool :: pack" bash -c '
    script -qec "$OMT_INNER" "$OMT_LOG"
    rc=$?
    echo "$rc" > "$OMT_RCF"
    echo
    echo "──── сессия завершена, exit=$rc ────"
    echo "Лог: $OMT_LOG"
    read -rp "Enter — закрыть окно " x
' >/dev/null 2>&1 &

disown
echo "Окно kitty открыто: pack.sh $*"
echo "Лог сессии: $LOG"
echo "Код выхода: $RCF"
