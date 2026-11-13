#!/usr/bin/env python3
"""os-migrate-tool :: conf.py — мост конфига в bash.

inventory.toml — полный инвентарь путей (что вообще можно паковать),
selection.toml  — галочки по умолчанию: [groups] булево по группам,
таблицы [группа] — точечные on/off по путям.

Печатает bash-код (pack.sh делает eval): массивы путей, DESC, TUI_GRP_STATE,
TUI_SEL — значения уже нормализованы в ON/OFF. tomllib — stdlib (python
3.11+), внешних зависимостей нет.
"""

import os
import shlex
import sys

try:
    import tomllib
except ModuleNotFoundError:  # python < 3.11
    sys.stderr.write("conf.py: нужен python >= 3.11 (stdlib tomllib)\n")
    sys.exit(2)

GROUP_ORDER = ["packages", "appimages", "dotfiles", "data", "agents",
               "browsers", "flatpak", "toolchain", "tmp", "extra"]


def expand(p: str) -> str:
    """Разворот ведущих '~/'; '$HOME/' в абсолютный путь."""
    if p.startswith("~/"):
        return os.path.expanduser("~") + p[1:]
    if p.startswith("$HOME/"):
        return os.path.expanduser("~") + p[len("$HOME"):]
    return p


def main() -> int:
    if len(sys.argv) != 3:
        sys.stderr.write("usage: conf.py inventory.toml selection.toml\n")
        return 2
    try:
        with open(sys.argv[1], "rb") as f:
            inv = tomllib.load(f)
        with open(sys.argv[2], "rb") as f:
            sel = tomllib.load(f)
    except (OSError, tomllib.TOMLDecodeError) as e:
        sys.stderr.write(f"conf.py: {e}\n")
        return 2

    out = []

    def arr(name: str, items) -> None:
        out.append(f"{name}=({' '.join(shlex.quote(str(i)) for i in items)})")

    def assoc(name: str, d: dict) -> None:
        body = " ".join(f"[{shlex.quote(str(k))}]={shlex.quote(str(v))}"
                        for k, v in d.items())
        out.append(f"declare -A {name}=({body})")

    arr("MG_GROUPS", GROUP_ORDER)

    appimg = [expand(p) for p in inv.get("appimages", {}).get("dirs", [])]
    arr("APPIMG_ARR", appimg)

    dotfiles = inv.get("dotfiles", {})
    arr("DOT_ARR", list(dotfiles.get("dirs", [])) + list(dotfiles.get("files", [])))

    agents = inv.get("agents", {})
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

    for key, name in (("browsers", "BROWSER_ARR"), ("data", "DATA_ARR"),
                      ("toolchain", "TOOLCHAIN_ARR"), ("flatpak", "FLATPAK_ARR"),
                      ("tmp", "TMP_ARR"), ("extra", "EXTRA_ARR")):
        arr(name, inv.get(key, {}).get("paths", []))

    assoc("DESC", inv.get("desc", {}))

    # [groups] -> состояния групп; таблицы [группа] -> точечные ON/OFF
    groups_tbl = sel.get("groups", {})
    assoc("TUI_GRP_STATE", {g: ("ON" if groups_tbl.get(g, True) else "OFF")
                            for g in GROUP_ORDER})
    sel_flat = {}
    for g, table in sel.items():
        if isinstance(table, dict):
            for path, v in table.items():
                sel_flat[f"{g}|{path}"] = "ON" if v else "OFF"
    assoc("TUI_SEL", sel_flat)

    out.append(f"COMPRESS_ESTIMATE={int(inv.get('meta', {}).get('compress_estimate', 55))}")

    print("\n".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
