#!/usr/bin/env python3
"""os-migrate-tool :: tui.py — TUI на curses (stdlib python), без установки зависимостей.

Зачем: bash-рисовалка не переживает resize, списки длиннее экрана и мусорит
скроллбек (\\e[H\\e[J каждый кадр). curses рисует в альтернативном экране,
обновляет только изменившиеся ячейки и скроллит вьюпорт — перерисовка всегда
корректна, сколько бы пунктов ни было раскрыто.

Режимы (argv[1]):
  TREE    двухуровневый чеклист (группы ▸/▾ + подпункты, hint под курсором)
  MENU    одиночный выбор
  CHECK   плоский чеклист

Протокол stdin (построчно, разделитель ';', hint: '|' = перенос строки):
  TREE:  G;<group>;<desc>;<sizeMB>;<ON|OFF>
         S;<group>;<tag>;<desc>;<sizeMB>;<ON|OFF>;<hint>
  MENU:  M;<tag>;<desc>;<hint>
  CHECK: C;<tag>;<desc>;<ON|OFF>;<hint>
Заголовок окна — переменная окружения OMT_TUI_TITLE.

Выход (stdout): выбранные теги построчно.
  TREE дополнительно отдаёт финальное состояние всех пунктов:
  G;<group>;<ON|OFF> и S;<group>;<tag>;<ON|OFF> (bash обновляет свои словари).
Коды возврата: 0 — выбор (Enter), 1 — отмена (q/Esc), 2 — некорректный вход.
"""

import os
import re
import subprocess
import sys

import curses

# кэш автосводки «что внутри каталога» — по одному вычислению на путь
_summary_cache = {}


def dir_summary(path: str) -> str:
    """Внутри: крупнейшие подпапки/файлы каталога (du, лениво, с кэшем)."""
    if not path or path in _summary_cache:
        return _summary_cache.get(path, '')
    res = ''
    try:
        if os.path.isdir(path):
            kids = [e.path for e in os.scandir(path)]
            hidden = [k for k in kids if os.path.basename(k).startswith('.')]
            if len(hidden) == len(kids) and kids:
                kids = hidden          # каталог целиком из скрытых (.gnupg и т.п.)
            else:
                kids = [k for k in kids if not os.path.basename(k).startswith('.')]
            if kids:
                r = subprocess.run(["du", "-sm", "--apparent-size", *kids],
                                   capture_output=True, text=True, timeout=20)
                rows = []
                for ln in r.stdout.splitlines():
                    sz, _, name = ln.partition('\t')
                    rows.append((int(sz or 0), os.path.basename(name.rstrip('/'))))
                rows.sort(reverse=True)
                big = [f"{n} {fmt_m(s)}" for s, n in rows[:5] if s >= 1]
                if big:
                    more = f" · +{len(rows) - len(big)}" if len(rows) > 5 else ''
                    res = "Внутри: " + " · ".join(big) + more
    except Exception:
        res = ''
    _summary_cache[path] = res
    return res


def parse_stdin():
    # режим — argv[1] (передаётся вызовом), в stdin — только пункты
    mode = (sys.argv[1] if len(sys.argv) > 1 else '').strip().upper()
    groups, subs, items = [], {}, []
    secs, sectools = {}, {}   # 3-й уровень: secs[g]=секции, sectools[g|sec]=тулы
    for line in sys.stdin:
        line = line.rstrip('\n')
        if not line:
            continue
        p = line.split(';')
        try:
            if mode == 'TREE' and p[0] == 'G':
                groups.append({'g': p[1], 'desc': p[2], 'size': int(p[3] or 0),
                               'on': p[4] == 'ON', 'expanded': False})
            elif mode == 'TREE' and p[0] == 'SEC':
                # 3-й уровень: секция внутри группы (напр. programs → npm/uv/pipx/bin)
                secs.setdefault(p[1], []).append(
                    {'g': p[1], 'name': p[2], 'desc': p[3], 'size': int(p[4] or 0),
                     'on': p[5] == 'ON', 'expanded': False})
            elif mode == 'TREE' and p[0] == 'T':
                sectools.setdefault(f"{p[1]}|{p[2]}", []).append(
                    {'tag': p[3], 'desc': p[4], 'size': int(p[5] or 0),
                     'on': p[6] == 'ON', 'hint': p[7] if len(p) > 7 else '',
                     'path': p[8] if len(p) > 8 else ''})
            elif mode == 'TREE' and p[0] == 'S':
                subs.setdefault(p[1], []).append(
                    {'tag': p[2], 'desc': p[3], 'size': int(p[4] or 0),
                     'on': p[5] == 'ON', 'hint': p[6] if len(p) > 6 else '',
                     'path': p[7] if len(p) > 7 else ''})
            elif mode == 'MENU' and p[0] == 'M':
                items.append({'tag': p[1], 'desc': p[2],
                              'hint': p[3] if len(p) > 3 else ''})
            elif mode == 'CHECK' and p[0] == 'C':
                items.append({'tag': p[1], 'desc': p[2], 'on': p[3] == 'ON',
                              'hint': p[4] if len(p) > 4 else ''})
            else:
                sys.stderr.write(f"tui.py: неожиданная строка входа: {line[:60]}\n")
                sys.exit(2)
        except (IndexError, ValueError):
            sys.exit(2)
    if mode not in ('TREE', 'MENU', 'CHECK'):
        sys.exit(2)
    return mode, groups, subs, items, secs, sectools


def fmt_m(m):
    return f"{m / 1024:.1f}G" if m >= 1024 else f"{m}M"


# ---------- модель TREE ----------

def tree_rows(groups, subs, secs, sectools):
    """('G', g, None) | ('SEC', sec, None) | ('S', g, sub) | ('T', sec, tool)"""
    rows = []
    for g in groups:
        rows.append(('G', g, None))
        if not g['expanded']:
            continue
        g_secs = secs.get(g['g'])
        if g_secs:                     # группа с секциями (3-й уровень)
            for sec in g_secs:
                rows.append(('SEC', sec, None))
                if sec['expanded']:
                    for t in sectools.get(f"{sec['g']}|{sec['name']}", []):
                        rows.append(('T', sec, t))
        else:
            for s in subs.get(g['g'], []):
                rows.append(('S', g, s))
    return rows


def tree_total(groups, subs, secs, sectools):
    t = 0
    for g in groups:
        g_secs = secs.get(g['g'])
        if g_secs:                     # 3-й уровень: сумма по тулам секций
            for sec in g_secs:
                tools = sectools.get(f"{sec['g']}|{sec['name']}", [])
                if tools:
                    t += sum(x['size'] for x in tools if x['on'])
                elif sec['on']:
                    t += sec['size']
        else:
            ss = subs.get(g['g'])
            if ss:
                t += sum(s['size'] for s in ss if s['on'])
            elif g['on']:
                t += g['size']
    return t


def toggle(g, s, subs, sec=None, tools=None):
    if s is not None:                  # тул
        s['on'] = not s['on']
        return
    if sec is not None:                # секция — вся секция целиком
        sec['on'] = not sec['on']
        for x in (tools or []):
            x['on'] = sec['on']
        return
    ss = subs.get(g['g'], [])          # группа
    g['on'] = not g['on']
    for x in ss:
        x['on'] = g['on']
    for sec in secs.get(g['g'], []):
        sec['on'] = g['on']
        for x in sectools.get(f"{sec['g']}|{sec['name']}", []):
            x['on'] = g['on']


# ---------- отрисовка ----------

class Ctx:
    def __init__(self, scr, mode, groups, subs, items, secs=None, sectools=None):
        self.scr = scr
        self.mode = mode
        self.groups = groups
        self.subs = subs
        self.items = items
        self.secs = secs or {}
        self.sectools = sectools or {}
        self.cur = 0
        self.top = 0

    def rows(self):
        if self.mode == 'TREE':
            return tree_rows(self.groups, self.subs, self.secs, self.sectools)
        return [(None, None, it) for it in self.items]

    def hint_lines(self, row, w, max_lines=6):
        """Нижняя панель: подробное описание пункта + путь + «что внутри» + хоткеи."""
        kind, g, it = row
        if self.mode == 'MENU':
            src = [it['hint'] or it['desc'], 'q — отмена']
        elif self.mode == 'CHECK':
            src = [it['hint'] or it['desc'],
                   'пробел — галочка · a/n — все/ничего · q — отмена']
        elif kind == 'G':
            src = [g['desc']]
            has = bool(self.subs.get(g['g'])) or bool(self.secs.get(g['g']))
            if has and g['expanded']:
                src.append('пробел — вся группа · ← — свернуть · Tab — свернуть все · q — отмена')
            elif has:
                src.append('→ — раскрыть подпункты · Tab — раскрыть все · q — отмена')
            else:
                src.append('Enter — ок · q — отмена')
        elif kind == 'SEC':
            has = bool(self.sectools.get(f"{g['g']}|{g['name']}"))
            src = [f"{g['name']}: {g['desc']}"]
            if has:
                src.append('пробел — вся секция · → — раскрыть тулы · ← — к группе · q — отмена')
            else:
                src.append('пробел — галочка · q — отмена')
        else:
            # подпункт: полное описание, путь, автосводка содержимого, хоткеи
            src = [it['desc']]
            path = it.get('path', '')
            if path:
                home = os.path.expanduser('~')
                src.append('~' + path[len(home):] if path.startswith(home) else path)
            s = dir_summary(path)
            if s:
                src.append(s)
            src.append('← — к родительской группе · пробел — галочка · Tab — все списки · q — отмена')
        wrapn = max(10, w - 9)
        out = []
        for line in src:
            out.extend([line[i:i + wrapn] for i in range(0, len(line), wrapn)] or [''])
        return out[:max_lines]

    def draw(self):
        scr = self.scr
        scr.erase()
        h, w = scr.getmaxyx()
        if h < 6 or w < 20:
            return
        rows_all = self.rows()
        if self.cur >= len(rows_all):          # страховка: курсор за пределами списка
            self.cur = max(0, len(rows_all) - 1)
        title = os.environ.get('OMT_TUI_TITLE', '')
        scr.addnstr(0, 0, f"== {title}", w - 1, curses.A_BOLD)
        hdr = "↑/↓ j/k — курсор · пробел — галочка · a/n — все/ничего · q — отмена · Enter — ок"
        if self.mode == 'TREE':
            hdr += " · →/← — раскрыть/свернуть · Tab — все списки"
        scr.addnstr(1, 0, hdr, w - 1, curses.A_DIM)
        rows = self.rows()
        if self.mode == 'TREE':
            scr.addnstr(2, 0,
                        f"Выбрано сырого объёма: ~{fmt_m(tree_total(self.groups, self.subs, self.secs, self.sectools))}",
                        w - 1, curses.A_DIM)
        max_h = max(2, min(6, h - 9))
        hints = self.hint_lines(rows[self.cur], w, max_h)
        body_top = 3
        body_h = max(1, h - body_top - len(hints) - 2)
        # вьюпорт: держим курсор на экране
        if self.cur < self.top:
            self.top = self.cur
        if self.cur >= self.top + body_h:
            self.top = self.cur - body_h + 1
        for i in range(self.top, min(self.top + body_h, len(rows))):
            kind, g, it = rows[i]
            cur_row = (i == self.cur)
            attr = curses.A_REVERSE if cur_row else 0
            if self.mode == 'TREE' and kind == 'SEC':
                if not cur_row:
                    attr = curses.color_pair(1) | curses.A_BOLD
                n = sum(1 for x in self.sectools.get(f"{g['g']}|{g['name']}", []) if x['on'])
                cnt = len(self.sectools.get(f"{g['g']}|{g['name']}", []))
                glyph = '▾' if g['expanded'] else '▸'
                mark = f" [{n}/{cnt}]" if cnt else ''
                text = f"    └ [ {'▶' if cur_row else ' '}] {glyph} {g['name']} — {g['desc']}{mark}"
                size = g['size'] if cnt == 0 else sum(x['size'] for x in self.sectools[f"{g['g']}|{g['name']}"])
                y = body_top + i - self.top
                scr.addnstr(y, 0, text, w - 11, attr)
                if size:
                    scr.addnstr(y, max(0, w - 10), f"{fmt_m(size):>8}", 9, attr)
                continue
            if self.mode == 'TREE' and kind == 'T':
                if not cur_row:
                    attr = curses.A_DIM | attr
                text = f"        └ [{'x' if it['on'] else ' '}] {it['tag']}  {it['desc']}"
                size = it['size']
                y = body_top + i - self.top
                scr.addnstr(y, 0, text, w - 11, attr)
                if size:
                    scr.addnstr(y, max(0, w - 10), f"{fmt_m(size):>8}", 9, attr)
                continue
            if self.mode == 'TREE' and kind == 'G':
                if not cur_row:
                    attr = curses.color_pair(1)
                n = sum(1 for s in self.subs.get(g['g'], []) if s['on'])
                cnt = len(self.subs.get(g['g'], []))
                glyph = ' ' if not cnt else ('▾' if g['expanded'] else '▸')
                mark = f" [{n}/{cnt}]" if cnt else ''
                text = f"  [{'x' if g['on'] else ' '}] {glyph} {g['desc']}{mark}"
                size = g['size'] if cnt == 0 else sum(s['size'] for s in self.subs[g['g']])
            elif self.mode == 'TREE':
                tag_disp = it['tag'].split(':', 1)[1] if ':' in it['tag'] else it['tag']
                text = f"    └ [{'x' if it['on'] else ' '}] {tag_disp}  {it['desc']}"
                size = it['size']
                if not cur_row:
                    attr = curses.A_DIM | attr
            else:
                if self.mode == 'MENU':
                    mark = '▶' if cur_row else ' '
                    text = f"  {mark} {it['tag']}  {it['desc']}"
                    size = 0
                else:
                    text = f"  [{'x' if it['on'] else ' '}] {it['tag']}  {it['desc']}"
                    size = 0
                if not cur_row:
                    attr = curses.color_pair(1)
            y = body_top + i - self.top
            scr.addnstr(y, 0, text, w - 11, attr)
            if size:
                scr.addnstr(y, max(0, w - 10), f"{fmt_m(size):>8}", 9, attr)
        # ↪ + hint-зона внизу
        kind, g, it = rows[self.cur]
        cur_tag = it['tag'] if it is not None else (g['g'] if g is not None else '')
        scr.addnstr(h - len(hints) - 2, 0, f"  ↪ [{cur_tag}]", w - 1, curses.A_DIM)
        for j, hl in enumerate(hints):
            scr.addnstr(h - len(hints) - 1 + j, 0, f"        {hl}", w - 1, curses.A_DIM)
        scr.refresh()


# ---------- ввод ----------

def key_move(ctx, key):
    n = len(ctx.rows())
    if key in (curses.KEY_UP, ord('k'), ord('K'), ord('л'), ord('Л')):
        ctx.cur = max(0, ctx.cur - 1)
    elif key in (curses.KEY_DOWN, ord('j'), ord('J'), ord('о'), ord('О')):
        ctx.cur = min(n - 1, ctx.cur + 1)
    elif key == curses.KEY_HOME:
        ctx.cur = 0
    elif key == curses.KEY_END:
        ctx.cur = n - 1
    elif key == curses.KEY_PPAGE:
        ctx.cur = max(0, ctx.cur - 10)
    elif key == curses.KEY_NPAGE:
        ctx.cur = min(n - 1, ctx.cur + 10)


def tree_expand(ctx):
    kind, g, extra = ctx.rows()[ctx.cur]
    if kind == 'G' and g is not None:
        has = bool(ctx.subs.get(g['g'])) or bool(ctx.secs.get(g['g']))
        if has and not g['expanded']:
            g['expanded'] = True
            if ctx.cur + 1 < len(ctx.rows()):
                ctx.cur += 1  # нырок в первую секцию/подпункт
    elif kind == 'SEC' and g is not None:
        has = bool(ctx.sectools.get(f"{g['g']}|{g['name']}"))
        if has and not g['expanded']:
            g['expanded'] = True
            if ctx.cur + 1 < len(ctx.rows()):
                ctx.cur += 1  # нырок в первый тул


def tree_collapse(ctx):
    kind, g, extra = ctx.rows()[ctx.cur]
    if kind == 'T':                    # тул → к родительской секции
        r = ctx.rows()
        for i in range(ctx.cur - 1, -1, -1):
            if r[i][0] == 'SEC' and r[i][1] is g:
                ctx.cur = i
                return
    elif kind == 'SEC':
        if g['expanded']:
            g['expanded'] = False
        else:                          # секция свёрнута — к родительской группе
            r = ctx.rows()
            for i in range(ctx.cur - 1, -1, -1):
                if r[i][0] == 'G' and r[i][1]['g'] == g['g']:
                    ctx.cur = i
                    return
    elif kind == 'S':
        r = ctx.rows()
        for i in range(ctx.cur - 1, -1, -1):
            if r[i][0] == 'G' and r[i][1] is g:
                ctx.cur = i
                return
    elif g is not None and g['expanded']:
        g['expanded'] = False


_DBG = os.environ.get("OMT_KEY_DEBUG")


def get_key(scr):
    """getch + ручной разбор CSI/SS3 стрелок: terminfo описывает application-режим
    (\\EOA), а некоторые терминалы/pty шлют обычный CSI (\\E[A) — keypad его не
    матчит и отдаёт голый ESC."""
    k = scr.getch()
    if _DBG:
        sys.stderr.write(f"[key={k!r}] ")
        sys.stderr.flush()
    if k != 27:
        return k
    scr.nodelay(True)
    seq = ''
    try:
        while len(seq) < 3:
            c = scr.getch()
            if c == -1:
                break
            if 32 <= c < 127:
                seq += chr(c)
    finally:
        scr.nodelay(False)
    if seq.startswith(('[A', 'OA')):
        return curses.KEY_UP
    if seq.startswith(('[B', 'OB')):
        return curses.KEY_DOWN
    if seq.startswith(('[C', 'OC')):
        return curses.KEY_RIGHT
    if seq.startswith(('[D', 'OD')):
        return curses.KEY_LEFT
    return 27  # голый Esc = отмена


def loop(scr, mode, groups, subs, items, secs=None, sectools=None):
    scr.keypad(True)              # стрелки как KEY_* (протокол терминала)
    for fn in (lambda: curses.curs_set(0), curses.use_default_colors):
        try:
            fn()
        except curses.error:
            pass                  # косметика: терминал может не уметь
    curses.set_escdelay(30)
    if curses.has_colors():
        curses.start_color()
        curses.init_pair(1, curses.COLOR_CYAN, -1)
    ctx = Ctx(scr, mode, groups, subs, items, secs, sectools)
    ctx.draw()
    while True:
        key = get_key(scr)
        if key in (ord('q'), ord('Q'), ord('й'), ord('Й'), 27):
            return None                       # отмена
        if key in (curses.KEY_ENTER, 10, 13):
            return ctx.cur                    # выбор: позиция курсора
        if key == curses.KEY_RESIZE:
            ctx.draw()
            continue
        key_move(ctx, key)
        rows = ctx.rows()
        kind, g, it = rows[ctx.cur]
        if mode == 'TREE':
            if key in (curses.KEY_RIGHT, ord('>'), ord('l'), ord('L'), ord('д'), ord('Д')):
                tree_expand(ctx)
            elif key in (curses.KEY_LEFT, ord('<'), ord('h'), ord('H'), ord('b'), ord('B')):
                tree_collapse(ctx)
            elif key == 9:  # Tab: раскрыть/свернуть все группы и секции разом
                any_exp = any(gg['expanded'] for gg in groups) or \
                          any(sec['expanded'] for lst in secs.values() for sec in lst)
                for gg in groups:
                    gg['expanded'] = not any_exp
                for lst in secs.values():
                    for sec in lst:
                        sec['expanded'] = not any_exp
                if ctx.cur >= len(ctx.rows()):
                    ctx.cur = len(ctx.rows()) - 1   # список ужался — клампим курсор
        if key in (32, ord(',')) and mode in ('TREE', 'CHECK'):
            if mode == 'TREE' and kind == 'SEC':
                toggle(g, None, subs, sec=g,
                       tools=sectools.get(f"{g['g']}|{g['name']}", []))
            else:
                toggle(g, it, subs)
        elif key in (ord('a'), ord('A'), ord('ф'), ord('Ф')):
            if mode == 'TREE':
                for gg in groups:
                    gg['on'] = True
                    for s in subs.get(gg['g'], []):
                        s['on'] = True
                    for sec in secs.get(gg['g'], []):
                        sec['on'] = True
                        for x in sectools.get(f"{sec['g']}|{sec['name']}", []):
                            x['on'] = True
            else:
                for x in items:
                    x['on'] = True
        elif key in (ord('n'), ord('N'), ord('т'), ord('Т')):
            if mode == 'TREE':
                for gg in groups:
                    gg['on'] = False
                    for s in subs.get(gg['g'], []):
                        s['on'] = False
                    for sec in secs.get(gg['g'], []):
                        sec['on'] = False
                        for x in sectools.get(f"{sec['g']}|{sec['name']}", []):
                            x['on'] = False
            else:
                for x in items:
                    x['on'] = False
        ctx.draw()
    return None


def main():
    mode, groups, subs, items, secs, sectools = parse_stdin()
    # Данные уже прочитаны из stdin (труба). Курсор curses читает fd 0 и рисует
    # в fd 1 — переключаем оба на /dev/tty; результат пишем в исходный stdout,
    # который bash захватывает через $().
    if not os.environ.get('TERM'):
        os.environ['TERM'] = 'xterm-256color'
    try:
        tty = os.open('/dev/tty', os.O_RDWR)
    except OSError as e:
        sys.stderr.write(f"tui.py: /dev/tty недоступен: {e}\n")
        sys.exit(2)
    out_fd = os.dup(1)          # исходный stdout (труба захвата)
    saved_in = os.dup(0)        # исходный stdin (труба данных)
    os.dup2(tty, 0)
    os.dup2(tty, 1)
    picked = None
    try:
        picked = curses.wrapper(lambda scr: loop(scr, mode, groups, subs, items, secs, sectools))
    except KeyboardInterrupt:
        picked = None
    finally:
        # endwin вызывает curses.wrapper; здесь только возвращаем fd на место
        os.dup2(out_fd, 1)      # stdout обратно на захват результата
        os.dup2(saved_in, 0)
        os.close(tty)
        os.close(out_fd)
        os.close(saved_in)
    if picked is None:
        sys.exit(1)  # отмена — без вывода
    # результат: в файл OMT_STATE (надёжно), иначе — stdout
    state_path = os.environ.get("OMT_STATE", "")
    fh = open(state_path, "w", encoding="utf-8") if state_path else None
    w = (lambda t: fh.write(t + "\n")) if fh else (lambda t: print(t))
    if mode == 'MENU':
        w(items[picked]['tag'])
    elif mode == 'CHECK':
        for it in items:
            if it['on']:
                w(it['tag'])
    else:  # TREE — финальное состояние всех пунктов
        for g in groups:
            w(f"G;{g['g']};{'ON' if g['on'] else 'OFF'}")
            for sec in secs.get(g['g'], []):
                w(f"SEC;{g['g']};{sec['name']};{'ON' if sec['on'] else 'OFF'}")
                for t in sectools.get(f"{sec['g']}|{sec['name']}", []):
                    w(f"T;{g['g']};{sec['name']};{t['tag']};{'ON' if t['on'] else 'OFF'}")
            for s in subs.get(g['g'], []):
                w(f"S;{g['g']};{s['tag']};{'ON' if s['on'] else 'OFF'}")
    if fh:
        fh.close()
    sys.exit(0)


if __name__ == '__main__':
    main()
