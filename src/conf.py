#!/usr/bin/env python3
"""os-migrate-tool :: conf.py — мост конфига в bash.

inventory.yaml — полный инвентарь (группы group_* с секциями dirs/files/
paths/home/config/sessions + desc: описания), selection.yaml — галочки
по умолчанию: group_<имя>.on и вложенные пути (точечные on/off).

Печатает bash-код (pack.sh делает eval): массивы путей, DESC, TUI_GRP_STATE,
TUI_SEL — значения нормализованы в ON/OFF.

Парсер — ОГРАНИЧЕННОЕ YAML-подмножество (stdlib, без PyYAML):
  - вложенные отображения с отступами (2 пробела);
  - блочные списки "- элемент";
  - скаляры: true/false/on/off, целые, "кавычки", голые строки;
  - комментарии — только целыми строками;
  - нет anchors/flow/multi-line. Формат наш — сложное YAML не нужно.
"""

import os
import re
import shlex
import sys


# ---------- мини-YAML ----------

def _scalar(s: str):
    s = s.strip()
    if len(s) >= 2 and s[0] == s[-1] and s[0] in "\"'":
        return s[1:-1]
    if s in ("true", "yes", "on"):
        return True
    if s in ("false", "no", "off"):
        return False
    if s == "[]":
        return []
    if re.fullmatch(r"-?\d+", s):
        return int(s)
    if s in ("null", "~", ""):
        return None
    return s


def _indent(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def _strip_comment(line: str) -> str:
    """Инлайн-комментарий ' #...' срезается (в значениях конфига '#' не встречается)."""
    idx = line.find(" #")
    return line[:idx].rstrip() if idx != -1 else line


def _parse_map(lines, i, indent):
    result = {}
    while i < len(lines):
        line = _strip_comment(lines[i])
        if not line.strip() or line.lstrip().startswith("#"):
            i += 1
            continue
        ind = _indent(line)
        if ind < indent:
            break
        if ind > indent:
            raise ValueError(f"неожиданный отступ: {line.strip()!r}")
        content = line.strip()
        if content.startswith("- "):
            raise ValueError(f"элемент списка вне ключа: {content!r}")
        key, sep, rest = content.partition(":")
        if not sep:
            raise ValueError(f"нет ':' в строке: {content!r}")
        key = key.strip().strip('"').strip("'")
        rest = rest.strip()
        i += 1
        if rest:
            result[key] = _scalar(rest)
            continue
        # значение на следующих строках: список или вложенный маппинг
        j = i
        while j < len(lines) and (not lines[j].strip() or lines[j].lstrip().startswith("#")):
            j += 1
        if j >= len(lines):
            result[key] = None
            break
        nind, ncont = _indent(lines[j]), lines[j].strip()
        if nind > ind and ncont.startswith("- "):
            items = []
            while j < len(lines):
                lj = _strip_comment(lines[j])
                if not lj.strip() or lj.lstrip().startswith("#"):
                    j += 1
                    continue
                if _indent(lines[j]) <= ind or not lj.strip().startswith("- "):
                    break
                items.append(_scalar(lj.strip()[2:]))
                j += 1
            result[key] = items
            i = j
        elif nind > ind:
            result[key], i = _parse_map(lines, j, nind)
        else:
            result[key] = None
    return result, i


def parse_yaml(text: str):
    result, _ = _parse_map([l.rstrip() for l in text.splitlines()], 0, 0)
    return result


# ---------- мост в bash ----------

def expand(p: str) -> str:
    """Разворот ведущих '~/'; '$HOME/' в абсолютный путь."""
    if p.startswith("~/"):
        return os.path.expanduser("~") + p[1:]
    if p.startswith("$HOME/"):
        return os.path.expanduser("~") + p[len("$HOME"):]
    return p


def main() -> int:
    if len(sys.argv) < 3:
        sys.stderr.write("usage: conf.py inventory.yaml selection.yaml [exclude_dirs.yaml]\n")
        return 2
    try:
        with open(sys.argv[1], encoding="utf-8") as f:
            inv = parse_yaml(f.read())
        with open(sys.argv[2], encoding="utf-8") as f:
            sel = parse_yaml(f.read())
        excl = {}
        if len(sys.argv) > 3 and os.path.exists(sys.argv[3]):
            with open(sys.argv[3], encoding="utf-8") as f:
                excl = parse_yaml(f.read())
    except (OSError, ValueError) as e:
        sys.stderr.write(f"conf.py: {e}\n")
        return 2

    out = []

    def arr(name: str, items) -> None:
        out.append(f"{name}=({' '.join(shlex.quote(str(i)) for i in items)})")

    def assoc(name: str, d: dict) -> None:
        body = " ".join(f"[{shlex.quote(str(k))}]={shlex.quote(str(v))}"
                        for k, v in d.items())
        out.append(f"declare -A {name}=({body})")

    # группы: ключи group_* из инвентаря, порядок = порядок файла
    groups = [k[len("group_"):] for k in inv if k.startswith("group_")]
    arr("MG_GROUPS", groups)

    appimg = [expand(p) for p in inv.get("group_appimages", {}).get("dirs", [])]
    arr("APPIMG_ARR", appimg)

    dotfiles = inv.get("group_dotfiles", {})
    arr("DOT_ARR", list(dotfiles.get("dirs", [])) + list(dotfiles.get("files", [])))

    agents = inv.get("group_agents", {})
    a_home = list(agents.get("home", []))
    a_conf = list(agents.get("config", []))
    a_sess = list(agents.get("sessions", []))
    # сессии, уже покрытые родительскими путями агентов, не дублируем
    parents = a_home + a_conf
    a_sess = [s for s in a_sess
              if not any(s == p or s.startswith(p.rstrip("/") + "/")
                         for p in parents)]
    arr("AGENT_DIRS_ARR", a_home)
    arr("AGENT_CONF_ARR", a_conf)
    arr("AGENT_SESSIONS_ARR", a_sess)

    for g in groups:
        if g in ("appimages", "dotfiles", "agents"):
            continue
        arr(f"{g.upper()}_ARR", inv.get(f"group_{g}", {}).get("paths", []))

    assoc("DESC", inv.get("desc", {}) or {})

    # selection: group_<имя>.on — группа; остальные ключи — точечные on/off
    def sel_group(g):
        return sel.get(f"group_{g}", {}) or {}

    assoc("TUI_GRP_STATE",
          {g: ("ON" if sel_group(g).get("on", True) else "OFF") for g in groups})
    sel_flat = {}
    for g in groups:
        for key, v in sel_group(g).items():
            if key == "on":
                continue
            sel_flat[f"{g}|{key}"] = "ON" if v else "OFF"
    assoc("TUI_SEL", sel_flat)

    out.append(f"COMPRESS_ESTIMATE={int(inv.get('meta', {}).get('compress_estimate', 55))}")

    # исключения (configs/exclude_dirs.yaml)
    arr("EXCL_PATTERNS_ARR", excl.get("tar", []) or [])
    out.append(f"APPIMG_SKIP_ZERO={1 if excl.get('appimages', {}).get('skip_zero_size', False) else 0}")

    print("\n".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
