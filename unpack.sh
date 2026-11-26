#!/usr/bin/env bash
# os-migrate-tool :: unpack.sh
# Восстановление на CachyOS (Arch) из бандла прогона на SSD.
# Запускается прямо с SSD:  ./unpack.sh [сегмент…|all] [--dry-run]
# Сегменты: programs packages appimages dotfiles data agents browsers flatpak
# toolchain tmp extra; --префикс тоже принимается (--dotfiles == dotfiles).
# Флаги можно комбинировать; all = все сегменты бандла. Без аргументов —
# TUI-дерево: сегмент → верхнеуровневые пути → подпути 2-го уровня; у каждого
# пункта маркер ● (уже есть в $HOME — будет перезаписан) / ○ (будет создан).
# Распаковка: список содержимого бандла с размерами читается 1 раз (tar -tv),
# выбранные домашние пути извлекаются ОДНИМ проходом tar (--files-from).
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

# ---------- 1. Тип системы (первый шаг) ----------
# Определяем тип по /etc/os-release; не удалось — выбор из списка.
# Тип выбирает, какие команды установки брать из configs/mapping.toml (arch/debian).
detect_type() {
    local id="" like=""
    [[ -r /etc/os-release ]] && { . /etc/os-release; id="${ID:-}"; like="${ID_LIKE:-}"; }
    case "$id" in
        arch|cachyos|manjaro|endeavouros|garuda|artix) echo arch;;
        debian|ubuntu|linuxmint|pop|elementary|kali|zorin) echo debian;;
        *)
            case "$like" in
                *arch*) echo arch;;
                *debian*) echo debian;;
            esac;;
    esac
}
SYS_TYPE="${OMT_SYS_TYPE:-$(detect_type || true)}"
if [[ -z "$SYS_TYPE" ]]; then
    SYS_TYPE=$(ui_menu "Тип системы определить не удалось — выбери вручную:" \
        "arch;Arch-подобная (pacman/yay)" "debian;Debian-подобная (apt)")
    [[ -n "$SYS_TYPE" ]] || die "тип системы не выбран"
fi
ok "Тип системы: $SYS_TYPE${OMT_SYS_TYPE:+ (задан OMT_SYS_TYPE)}"

# ---------- 2. Выбор бандла ----------
[[ -d "$TOOL_DIR/archives" ]] || die "рядом со скриптом нет archives/ — запусти с SSD"
mapfile -t RUNS < <(ls -1 "$TOOL_DIR/archives"/*.tar.gz "$TOOL_DIR/archives"/*.tar 2>/dev/null | sed "s|.*/||; s|\.tar\.gz$||; s|\.tar$||" | sort -u)
((${#RUNS[@]})) || die "в archives/ нет бандлов (*.tar.gz / *.tar)"

RUN_DESC=(); for r in "${RUNS[@]}"; do
    for ext in tar.gz tar; do
        b="$TOOL_DIR/archives/$r.$ext"
        [[ -f "$b" ]] && { RUN_DESC+=("$r;$ext, $(human "$b")"); break; }
    done
done
pick=$(ui_menu "Какой бандл восстанавливаем?" "${RUN_DESC[@]}")
[[ -n "$pick" ]] || die "бандл не выбран"
for ext in tar.gz tar; do
    b="$TOOL_DIR/archives/$pick.$ext"
    [[ -f "$b" ]] && { BUNDLE="$b"; break; }
done
META="$TOOL_DIR/archives/$pick.meta"
case "$BUNDLE" in
    *.tar.gz) ZF="-z";;
    *)        ZF="";;
esac
ok "Бандл: $BUNDLE ($(human "$BUNDLE"))"

command -v python3 >/dev/null 2>&1 || die "нужен python3 (конфиг и TUI)"
eval "$(python3 "$TOOL_DIR/src/conf.py" \
    "$TOOL_DIR/configs/inventory.yaml" "$TOOL_DIR/configs/selection.yaml" \
    "$TOOL_DIR/configs/exclude_dirs.yaml")"

# ---------- 3. Содержимое бандла: имена + размеры (1 проход tar -tv) ----------
# BUNDLE_LIST — пути членов; BUNDLE_IDX — агрегаты awk (один проход по выводу):
#   G <сегмент> <Mб>                        — суммарный размер сегмента
#   E <сегмент> <путь> <dir|file> <Mб>      — верхнеуровневые пути сегмента
#   C <сегмент> <путь> <подпуть> <dir|file> <Mб> — подпути 2-го уровня
BUNDLE_LIST="$(mktemp /tmp/omt-bundle-list.XXXXXX)"
BUNDLE_IDX="$(mktemp /tmp/omt-bundle-idx.XXXXXX)"
trap 'rm -f "$BUNDLE_LIST" "$BUNDLE_IDX"' EXIT
info "Читаю содержимое бандла (один проход, с размерами)..."
LC_ALL=C tar --ignore-zeros $ZF -tvf "$BUNDLE" | awk -v out="$BUNDLE_LIST" -v idx="$BUNDLE_IDX" '
function MB(x) { return int((x + 1048575) / 1048576) }  # байты -> Mб, с избытком
{
    sz = $3 + 0
    p = $0
    sub(/^[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+ +/, "", p)  # perms owner/group size date time
    sub(/ -> .*$/, "", p)                               # хвост симлинка — не имя
    print p > out
    n = split(p, c, "/")
    seg = c[1]
    G[seg] += sz
    if (n >= 2 && c[2] != "") {
        E[seg SUBSEP c[2]] = 1
        S[seg "/" c[2]] += sz
        if (p ~ /\/$/) ED[seg SUBSEP c[2]] = 1          # есть член с хвостовым / — каталог
        if (n >= 3 && c[3] != "") {
            C[seg SUBSEP c[2] SUBSEP c[3]] = 1
            T[seg "/" c[2] "/" c[3]] += sz
            if (p ~ /\/$/) CD[seg SUBSEP c[2] SUBSEP c[3]] = 1
        }
    }
}
END {
    for (k in G) printf "G\t%s\t%d\n", k, MB(G[k]) > idx
    for (k in E) { split(k, a, SUBSEP)
        printf "E\t%s\t%s\t%s\t%d\n", a[1], a[2], (ED[k] ? "dir" : "file"), MB(S[a[1] "/" a[2]]) > idx }
    for (k in C) { split(k, a, SUBSEP)
        printf "C\t%s\t%s\t%s\t%s\t%d\n", a[1], a[2], a[3], (CD[k] ? "dir" : "file"), MB(T[a[1] "/" a[2] "/" a[3]]) > idx }
}'
sort -o "$BUNDLE_IDX" "$BUNDLE_IDX"
ok "сегментов: $(awk -F'\t' '$1=="G"' "$BUNDLE_IDX" | wc -l), членов: $(wc -l < "$BUNDLE_LIST")"

declare -A SEG_SZ ENTRY_SZ ENTRY_TYPE CHILD_SZ CHILD_TYPE CHILD_OF
ENTRY_KEYS=(); CHILD_KEYS=()
while IFS=$'\t' read -r kind f2 f3 f4 f5 f6; do
    case "$kind" in
        G) SEG_SZ["$f2"]="$f3";;
        E) ENTRY_SZ["$f2/$f3"]="$f5"; ENTRY_TYPE["$f2/$f3"]="$f4"; ENTRY_KEYS+=("$f2/$f3");;
        C) CHILD_SZ["$f2/$f3/$f4"]="$f6"; CHILD_TYPE["$f2/$f3/$f4"]="$f5"; CHILD_KEYS+=("$f2/$f3/$f4");;
    esac
done < "$BUNDLE_IDX"
for ck in ${CHILD_KEYS[@]+"${CHILD_KEYS[@]}"}; do   # подпути по родителю: seg/entry -> seg/entry/child
    k="${ck%/*}"
    CHILD_OF["$k"]+="$ck"$'\n'
done

seg_in_bundle() { [[ -n "${SEG_SZ[$1]:-}" ]]; }

# .meta/ потерян на диске — восстанавливаем paths.tsv из резервного сегмента
if [[ ! -s "$META/paths.tsv" ]] && grep -q "^meta/paths.tsv" "$BUNDLE_LIST"; then
    mkdir -p "$META"
    tar --ignore-zeros $ZF -xf "$BUNDLE" -C "$META" meta
    ok "paths.tsv восстановлен из бандла (.meta/ отсутствовал на диске)"
fi

# ---------- 4. Что восстанавливаем ----------
COMPONENTS=(
  "programs;CLI-программы: переустановка по mapping.toml"
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

# Особые компоненты: programs (meta/programs.txt), packages/appimages (сегменты
# в $META). Остальные едут в $HOME. Выбор: SEG_WHOLE[seg]=1 — сегмент целиком,
# либо SEL_PARTS[seg] — member-пути бандла (seg/entry или seg/entry/child).
declare -A SEG_WHOLE SEL_PARTS
is_home_seg() { case "$1" in packages|appimages|programs) return 1;; *) return 0;; esac; }

_unpack_feed() { # TREE-протокол: сегмент -> верхнеуровневые пути -> подпути
    local c tag desc k e ck ch ct cst ty
    for c in "${COMPONENTS[@]}"; do
        IFS=';' read -r tag desc <<<"$c"
        [[ "$tag" == programs ]] || seg_in_bundle "$tag" || continue
        printf 'G;%s;%s;%s;OFF\n' "$tag" "$desc" "${SEG_SZ[$tag]:-0}"
        is_home_seg "$tag" || continue
        for k in ${ENTRY_KEYS[@]+"${ENTRY_KEYS[@]}"}; do
            [[ "$k" == "$tag/"* ]] || continue
            e="${k#"$tag"/}"
            ct="$HOME/$e"
            if [[ -e "$ct" || -L "$ct" ]]; then cst="exists"; else cst="new"; fi
            if [[ "${ENTRY_TYPE[$k]:-}" == dir ]]; then ty="каталог"; else ty="файл"; fi
            printf 'SEC;%s;%s;%s;%s;OFF;%s;%s\n' "$tag" "$e" "$ty" "${ENTRY_SZ[$k]:-0}" "$ct" "$cst"
            while IFS= read -r ck; do
                [[ -n "$ck" ]] || continue
                ch="${ck##*/}"
                ct="$HOME/${ck#"$tag"/}"
                if [[ -e "$ct" || -L "$ct" ]]; then cst="exists"; else cst="new"; fi
                if [[ "${CHILD_TYPE[$ck]:-}" == dir ]]; then ty="каталог"; else ty="файл"; fi
                printf 'T;%s;%s;%s;%s;%s;OFF;;%s;%s\n' "$tag" "$e" "$ch" "$ty" "${CHILD_SZ[$ck]:-0}" "$ct" "$cst"
            done <<<"${CHILD_OF[$k]:-}"
        done
    done
    return 0
}

unpack_tree() { # TUI-дерево выбора: результат -> SEG_WHOLE / SEL_PARTS
    local st rc=0 line tag c k e ck n_all n_on
    local -a mems
    declare -A T_G T_SEC T_T
    st="$(mktemp /tmp/omt-unpack-sel.XXXXXX)"
    OMT_STATE="$st" OMT_TUI_TITLE="Что восстанавливаем?" \
        python3 "$TOOL_DIR/src/tui.py" TREE < <(_unpack_feed) || rc=$?
    if (( rc == 1 )); then
        warn "Отменено — ничего не распаковано."
        exit 0
    fi
    (( rc == 0 )) || die "tui: дерево завершилось с ошибкой ($rc)"
    while IFS= read -r line; do
        IFS=';' read -r typ f1 f2 f3 f4 <<<"$line"
        case "$typ" in
            G)   T_G["$f1"]="$f2";;
            SEC) T_SEC["$f1|$f2"]="$f3";;
            T)   T_T["$f1|$f2|$f3"]="$f4";;
        esac
    done < "$st"
    rm -f "$st"
    for c in "${COMPONENTS[@]}"; do
        IFS=';' read -r tag _ <<<"$c"
        if ! is_home_seg "$tag"; then
            [[ ${T_G["$tag"]:-} == ON ]] && SEG_WHOLE["$tag"]=1
            continue
        fi
        # состояние детей решает и при OFF-группе (включённый подпункт едет);
        # группа ON без деталей = все записи ON -> сегмент целиком
        mems=(); n_all=0; n_on=0
        for k in ${ENTRY_KEYS[@]+"${ENTRY_KEYS[@]}"}; do
            [[ "$k" == "$tag/"* ]] || continue
            e="${k#"$tag"/}"; n_all=$((n_all+1))
            if [[ ${T_SEC["$tag|$e"]:-} == ON ]]; then
                n_on=$((n_on+1)); mems+=("$k")       # путь целиком
            else
                while IFS= read -r ck; do            # только выбранные подпути
                    [[ -n "$ck" && ${T_T["$tag|$e|${ck##*/}"]:-} == ON ]] && mems+=("$ck")
                done <<<"${CHILD_OF[$k]:-}"
            fi
        done
        if (( n_all > 0 && n_on == n_all )); then
            SEG_WHOLE["$tag"]=1                      # выбраны все пути — сегмент целиком
        elif (( ${#mems[@]} > 0 )); then
            SEL_PARTS["$tag"]=$(printf '%s\n' "${mems[@]}")
        fi
    done
    return 0
}

if [[ $# -gt 0 && "$1" == all ]]; then
    for c in "${COMPONENTS[@]}"; do
        IFS=';' read -r tag _ <<<"$c"
        seg_in_bundle "$tag" && SEG_WHOLE["$tag"]=1
    done
elif [[ $# -gt 0 ]]; then
    VALID=""
    for c in "${COMPONENTS[@]}"; do IFS=';' read -r tag _ <<<"$c"; VALID+="$tag "; done
    for a in "$@"; do
        a="${a#--}"   # --dotfiles == dotfiles
        [[ " $VALID " == *" $a "* ]] || die "неизвестный компонент: $a (есть: ${VALID% }| all)"
        [[ "$a" == programs ]] || seg_in_bundle "$a" || die "в бандле нет сегмента $a/"
        SEG_WHOLE["$a"]=1
    done
elif (( OMT_TUI )); then
    unpack_tree
else
    # fallback без curses: плоский чеклист сегментов целиком
    CHECKS=(); for c in "${COMPONENTS[@]}"; do
        IFS=';' read -r tag desc <<<"$c"
        { [[ "$tag" == programs ]] || seg_in_bundle "$tag"; } && CHECKS+=("$tag;$desc;OFF")
    done
    ((${#CHECKS[@]})) || die "в бандле нет ни одного сегмента"
    mapfile -t SEL < <(ui_checklist "Что восстанавливаем? (без curses — сегменты целиком)" "${CHECKS[@]}")
    for tag in "${SEL[@]}"; do [[ -n "$tag" ]] && SEG_WHOLE["$tag"]=1; done
fi

SEL=()
for c in "${COMPONENTS[@]}"; do
    IFS=';' read -r tag _ <<<"$c"
    [[ -n "${SEG_WHOLE[$tag]:-}" || -n "${SEL_PARTS[$tag]:-}" ]] && SEL+=("$tag")
done
[[ ${#SEL[@]} -gt 0 && -n "${SEL[0]:-}" ]] || die "ничего не выбрано"

if (( DRY )); then MISSING="/tmp/missing-mapping.dryrun.txt"; else MISSING="$META/missing-mapping.txt"; fi
: > "$MISSING"

# ---------- 5. Конфликты с $HOME — по выбранным путям, вопрос на сегмент ----------
hmb() { awk -v m="${1:-0}" 'BEGIN { if (m >= 1024) printf "%.1fG", m/1024; else printf "%dM", m }'; }

member_size() { # размер member-пути бандла ("seg" | "seg/entry" | "seg/e/child")
    local m="$1"
    case "$m" in
        */*/*) echo "${CHILD_SZ[$m]:-0}";;
        */*)   echo "${ENTRY_SZ[$m]:-0}";;
        *)     echo "${SEG_SZ[$m]:-0}";;
    esac
    return 0
}

seg_sel_size() { # выбранный объём сегмента, Мб
    local s="$1" m t=0
    if [[ -n "${SEG_WHOLE[$s]:-}" ]]; then echo "${SEG_SZ[$s]:-0}"; return 0; fi
    while IFS= read -r m; do
        [[ -n "$m" ]] && t=$(( t + $(member_size "$m") ))
    done <<<"${SEL_PARTS[$s]:-}"
    echo "$t"
    return 0
}

seg_targets() { # выбранные верхнеуровневые цели сегмента в $HOME (пути от $HOME)
    local s="$1"
    if [[ -n "${SEG_WHOLE[$s]:-}" ]]; then
        grep "^$s/" "$BUNDLE_LIST" | sed "s|^$s/||; s|/.*||" | grep -v '^$' | sort -u || true
    else
        sed "s|^$s/||" <<<"${SEL_PARTS[$s]}"
    fi
    return 0
}

seg_exists() { [[ -e "$HOME/$1" || -L "$HOME/$1" ]]; }

seg_conflicts() { # выбранные цели сегмента, уже существующие в $HOME
    local t
    while IFS= read -r t; do
        [[ -n "$t" ]] && seg_exists "$t" && printf '%s\n' "$t"
    done < <(seg_targets "$1")
    return 0
}

drop_seg() { # убрать сегмент из выбора
    local s="$1" x
    unset "SEG_WHOLE[$s]" "SEL_PARTS[$s]"
    nsel=()
    for x in "${SEL[@]}"; do [[ "$x" != "$s" ]] && nsel+=("$x"); done
    if (( ${#nsel[@]} )); then SEL=("${nsel[@]}"); else SEL=(); fi
    return 0
}

for s in "${SEL[@]}"; do
    case "$s" in packages|appimages|programs) continue;; esac
    if (( DRY )); then
        dry "«$s» (~$(hmb "$(seg_sel_size "$s")")):"
        while IFS= read -r t; do
            [[ -n "$t" ]] || continue
            if seg_exists "$t"; then dry "   ● $t — уже есть, будет перезаписан"; else dry "   ○ $t — будет создан"; fi
        done < <(seg_targets "$s")
        continue
    fi
    confs=$(seg_conflicts "$s")
    [[ -z "$confs" ]] && continue
    ch=$(ui_menu "«$s»: уже существуют — $(echo "$confs" | tr '\n' ' '). Что делать?" \
        "overwrite;перезаписать существующее" \
        "backup;перенести существующее в *.bak-premigrate" \
        "keep;распаковать только новое — существующее не трогать" \
        "skip;пропустить сегмент целиком")
    case "$ch" in
        overwrite) :;;
        backup)
            while IFS= read -r t; do
                [[ -n "$t" ]] || continue
                mv "$HOME/$t" "$HOME/$t.bak-premigrate"
                ok "  $t -> $t.bak-premigrate"
            done <<<"$confs";;
        keep)
            keep=()
            while IFS= read -r m; do
                [[ -n "$m" ]] || continue
                seg_exists "${m#"$s"/}" || keep+=("$m")
            done < <(if [[ -n "${SEG_WHOLE[$s]:-}" ]]; then
                        grep "^$s/" "$BUNDLE_LIST" | sed "s|^$s/||; s|/.*||" | grep -v '^$' | sort -u | sed "s|^|$s/|"
                     else
                        printf '%s\n' "${SEL_PARTS[$s]}"
                     fi)
            unset "SEG_WHOLE[$s]"
            if (( ${#keep[@]} )); then
                SEL_PARTS["$s"]=$(printf '%s\n' "${keep[@]}")
            else
                drop_seg "$s"
                warn "$s — существующее не тронуто, нового нет — сегмент пропущен"
            fi;;
        *) drop_seg "$s"; warn "$s — пропущен";;
    esac
done
((${#SEL[@]})) || die "после разбора конфликтов нечего распаковывать"

# browsers: keyring до распаковки
if (( ! DRY )) && [[ " ${SEL[*]} " == *" browsers "* ]]; then
    warn "Перед распаковкой браузеров: пароли профиля привязаны к старому keyring."
    read -rp "Помнишь пароль старого keyring? [y/N] " a || a=""
    [[ ${a:-n} =~ ^[Yy]$ ]] || {
        warn "browsers пропущен — введи пароль keyring и повтори"
        drop_seg "browsers"
    }
fi

# ---------- 6. Распаковка: META-сегменты целиком, $HOME — одним проходом tar ----------
if (( ! DRY )); then
    META_SEGS=()
    for s in packages appimages; do
        [[ -n "${SEG_WHOLE[$s]:-}" ]] && META_SEGS+=("$s")
    done
    if (( ${#META_SEGS[@]} )); then
        mkdir -p "$META"
        info "Распаковка в meta: ${META_SEGS[*]} (проход 1/2)..."
        tar --ignore-zeros $ZF -xf "$BUNDLE" -C "$META" "${META_SEGS[@]}"
    fi
    EXTRACT="$(mktemp /tmp/omt-unpack-list.XXXXXX)"
    HOME_SEGS=()
    for s in "${SEL[@]}"; do
        is_home_seg "$s" || continue
        HOME_SEGS+=("$s")
        if [[ -n "${SEG_WHOLE[$s]:-}" ]]; then
            echo "$s" >> "$EXTRACT"
        else
            grep -v '^$' <<<"${SEL_PARTS[$s]}" >> "$EXTRACT" || true
        fi
    done
    if (( ${#HOME_SEGS[@]} )); then
        info "Распаковка в \$HOME: ${HOME_SEGS[*]} — только выбранные пути (проход 2/2)..."
        tar --ignore-zeros $ZF -xf "$BUNDLE" -C "$HOME" --strip-components=1 \
            --verbatim-files-from --files-from="$EXTRACT"
        ok "распаковано в \$HOME: ${HOME_SEGS[*]}"
    fi
    rm -f "$EXTRACT"
else
    META_SEGS=()
    for s in packages appimages; do
        [[ -n "${SEG_WHOLE[$s]:-}" ]] && META_SEGS+=("$s")
    done
    ((${#META_SEGS[@]})) && dry "packages/appimages: манифесты и списки -> $META/"
    HOME_SEGS=()
    for s in "${SEL[@]}"; do is_home_seg "$s" && HOME_SEGS+=("$s"); done
    ((${#HOME_SEGS[@]})) && dry "в \$HOME: ${HOME_SEGS[*]} — один проход tar, только выбранные пути"
fi

# ---------- 7. Пост-обработка компонентов ----------
for s in "${SEL[@]}"; do
    case "$s" in
        packages)
            if (( DRY )); then
                dry "packages: сверка списков пакетов с configs/mapping.toml + flatpak/vscode/dconf/cron"
                continue
            fi
            info "Сверка списков пакетов с configs/mapping.toml (тип: $SYS_TYPE)..."
            installed=0
            # источник мог быть debian (apt-list) или arch (pacman-списки)
            PKGS_FILES=()
            [[ -f "$META/packages/apt-list.txt" ]] && PKGS_FILES+=("$META/packages/apt-list.txt")
            for pf in pacman-explicit.txt pacman-foreign.txt; do
                [[ -s "$META/packages/$pf" ]] && PKGS_FILES+=("$META/packages/$pf")
            done
            PKGS_ALL() { cat "${PKGS_FILES[@]}" 2>/dev/null | cut -f1 | sort -u; }
            # точное совпадение первого поля через assoc (grep -E ломался на '+' в именах)
            while IFS= read -r pkg; do
                [[ -z "$pkg" ]] && continue
                status="${MAPPING_STATUS[$pkg]:-}"
                case "$status" in
                    native|aur)
                        cmd="${PKG_CMD[$SYS_TYPE|$pkg]:-}"
                        [[ -n "$cmd" ]] && { echo "  \$ $cmd"; (( DRY )) && { dry "$cmd — выполнено"; installed=$((installed+1)); } || { eval "$cmd" && installed=$((installed+1)) || warn "  $pkg — установка не удалась"; }; }
                        ;;
                    skip) ok "  $pkg — skip (не переносится)";;
                    manual) ok "  $pkg — manual (ссылка в конце отчёта)";;
                esac
            done < <(PKGS_ALL)
            # что есть в списках, но нет в mapping
            PKGS_ALL | while read -r p; do
                [[ -n "$p" && -z "${MAPPING_STATUS[$p]:-}" ]] && echo "$p" >> "$MISSING.tmp"
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
        programs)
            PROGLIST=$(tar --ignore-zeros $ZF -xOf "$BUNDLE" meta/programs.txt 2>/dev/null || true)
            [[ -n "$PROGLIST" ]] || { info "programs: список пуст"; break; }
            # система: arch-подобная или debian-подобная — варианты установки разные
            SYS="debian"
            [[ "${ID:-}" == cachyos || "${ID_LIKE:-}" == *arch* ]] && SYS="arch"
            info "Программы — пошагово (тип: $SYS_TYPE)..."
            # fd 3: stdin остаётся tty для интерактивного меню
            while IFS='|' read -r sec tool <&3; do
                [[ -n "$sec" ]] || continue
                key="$sec|$tool"
                d="${DESC[$tool]:-$tool}"   # desc из configs/inventory.yaml
                install_cmd="${PROG_CMD[$SYS_TYPE|$key]:-}"
                url="${PROG_URL[$key]:-}"
                opts=()
                [[ -n "$install_cmd" ]] && opts+=("$install_cmd;выполнить команду установки")
                [[ -n "$url" ]] && opts+=("url;показать ссылку: $url")
                opts+=("skip;пропустить")
                ch=$(ui_menu "$tool — $d. Как установить?" "${opts[@]}")
                case "$ch" in
                    url) ok "  $tool — $url";;
                    skip|"") warn "  $tool — пропущен";;
                    *)
                        echo "  \$ $ch"
                        (( DRY )) && dry "$ch — выполнено" || { eval "$ch" && ok "  $tool — установлен" || warn "  $tool — установка не удалась"; }
                        ;;
                esac
            done 3<<<"$PROGLIST"
            ;;
    esac
done

# ---------- 8. Отчёт ----------
echo; ok "===== ИТОГ $([[ $DRY == 1 ]] && echo '(DRY-RUN — ничего не выполнено)' || echo '') ====="
for s in "${SEL[@]}"; do
    if [[ -n "${SEG_WHOLE[$s]:-}" ]]; then
        echo "  • $s — сегмент целиком (~$(hmb "${SEG_SZ[$s]:-0}"))"
    else
        echo "  • $s — выбранных путей: $(grep -c . <<<"${SEL_PARTS[$s]}" || true), ~$(hmb "$(seg_sel_size "$s")")"
    fi
done
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
    FLATPAK_APPS=$(tar --ignore-zeros $ZF -xOf "$BUNDLE" packages/flatpak-list.txt 2>/dev/null || true)
fi
if [[ -n "$FLATPAK_APPS" ]]; then
    while read -r app; do
        [[ -n "$app" ]] && LINKS+="flatpak: $app — https://flathub.org/apps/$app"$'\n'
    done <<<"$FLATPAK_APPS"
fi
for pkg in "${!MAPPING_URL[@]}"; do
    [[ ${MAPPING_STATUS[$pkg]:-} == manual ]] && LINKS+="пакет: $pkg — ${MAPPING_URL[$pkg]}"$'\n'
done
for key in "${!PROG_URL[@]}"; do
    LINKS+="программа: ${key#*|} — ${PROG_URL[$key]}"$'\n'
done
APPIMG_LIST=""
if [[ -s "$META/appimages/list.txt" ]]; then
    APPIMG_LIST=$(cat "$META/appimages/list.txt")
elif (( DRY )); then
    APPIMG_LIST=$(tar --ignore-zeros $ZF -xOf "$BUNDLE" appimages/list.txt 2>/dev/null || true)
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
