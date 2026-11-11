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
import sys

import curses


def parse_stdin():
    # режим — argv[1] (передаётся вызовом), в stdin — только пункты
    mode = (sys.argv[1] if len(sys.argv) > 1 else '').strip().upper()
    groups, subs, items = [], {}, []
    for line in sys.stdin:
        line = line.rstrip('\n')
        if not line:
            continue
        p = line.split(';')
        try:
            if mode == 'TREE' and p[0] == 'G':
                groups.append({'g': p[1], 'desc': p[2], 'size': int(p[3] or 0),
                               'on': p[4] == 'ON', 'expanded': False})
            elif mode == 'TREE' and p[0] == 'S':
                subs.setdefault(p[1], []).append(
                    {'tag': p[2], 'desc': p[3], 'size': int(p[4] or 0),
                     'on': p[5] == 'ON', 'hint': p[6] if len(p) > 6 else ''})
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
    return mode, groups, subs, items


def fmt_m(m):
    return f"{m / 1024:.1f}G" if m >= 1024 else f"{m}M"


# ---------- модель TREE ----------

def tree_rows(groups, subs):
    rows = []  # ('G', g, None) | ('S', g, sub)
    for g in groups:
        rows.append(('G', g, None))
        if g['expanded']:
            for s in subs.get(g['g'], []):
                rows.append(('S', g, s))
    return rows


def tree_total(groups, subs):
    t = 0
    for g in groups:
        ss = subs.get(g['g'])
        if ss:
            t += sum(s['size'] for s in ss if s['on'])
        elif g['on']:
            t += g['size']
    return t


def toggle(g, s, subs):
    if s is not None:
        s['on'] = not s['on']
        return
    ss = subs.get(g['g'], [])
    g['on'] = not g['on']
    for x in ss:
        x['on'] = g['on']


# ---------- отрисовка ----------

class Ctx:
    def __init__(self, scr, mode, groups, subs, items):
        self.scr = scr
        self.mode = mode
        self.groups = groups
        self.subs = subs
        self.items = items
        self.cur = 0
        self.top = 0

    def rows(self):
        if self.mode == 'TREE':
            return tree_rows(self.groups, self.subs)
        return [(None, None, it) for it in self.items]

    def hint_lines(self, row, w):
        kind, g, it = row
        src = []
        if self.mode == 'MENU':
            src = [it['hint'] or it['desc'], 'q — отмена']
        elif self.mode == 'CHECK':
            src = [it['hint'] or it['desc'], 'q — отмена']
        elif kind == 'G':
            has = bool(self.subs.get(g['g']))
            src = [g['desc']]
            if has and g['expanded']:
                src += ['пробел — отметить/снять группу целиком',
                        '← — свернуть подпункты', 'q — отмена']
            elif has:
                src += ['→ — раскрыть подпункты', 'q — отмена']
            else:
                src += ['q — отмена']
        else:
            src = [it['hint'] or it['desc'],
                   '← — вернуться к родительской группе', 'q — отмена']
        out = []
        for line in src:
            for chunk in (line.split('|') if line else ['']):
                if len(chunk) > w - 9:
                    chunk = chunk[:w - 10] + '…'
                out.append(chunk)
        return out[:4]

    def draw(self):
        scr = self.scr
        scr.erase()
        h, w = scr.getmaxyx()
        if h < 6 or w < 20:
            return
        title = os.environ.get('OMT_TUI_TITLE', '')
        scr.addnstr(0, 0, f"== {title}", w - 1, curses.A_BOLD)
        scr.addnstr(1, 0,
                    "↑/↓ j/k — курсор · пробел — галочка · a/n — все/ничего · q — отмена · Enter — ок"
                    + (" · →/← — раскрыть/свернуть" if self.mode == 'TREE' else ""),
                    w - 1, curses.A_DIM)
        rows = self.rows()
        if self.mode == 'TREE':
            scr.addnstr(2, 0,
                        f"Выбрано сырого объёма: ~{fmt_m(tree_total(self.groups, self.subs))}",
                        w - 1, curses.A_DIM)
        hints = self.hint_lines(rows[self.cur], w)
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
                text = f"    └ [{'x' if it['on'] else ' '}] {it['tag']}  {it['desc']}"
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
    kind, g, _ = ctx.rows()[ctx.cur]
    if kind == 'G' and g is not None and ctx.subs.get(g['g']) and not g['expanded']:
        g['expanded'] = True
        if ctx.cur + 1 < len(ctx.rows()):
            ctx.cur += 1  # нырок в первый подпункт


def tree_collapse(ctx):
    kind, g, _ = ctx.rows()[ctx.cur]
    if kind == 'S':
        r = ctx.rows()
        for i in range(ctx.cur - 1, -1, -1):
            if r[i][0] == 'G' and r[i][1] is g:
                ctx.cur = i
                return
    elif g is not None and g['expanded']:
        g['expanded'] = False


def get_key(scr):
    """getch + ручной разбор CSI/SS3 стрелок: terminfo описывает application-режим
    (\\EOA), а некоторые терминалы/pty шлют обычный CSI (\\E[A) — keypad его не
    матчит и отдаёт голый ESC."""
    k = scr.getch()
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


def loop(scr, mode, groups, subs, items):
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
    ctx = Ctx(scr, mode, groups, subs, items)
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
        if key in (32, ord(',')) and mode in ('TREE', 'CHECK'):
            toggle(g, it, subs)
        elif key in (ord('a'), ord('A'), ord('ф'), ord('Ф')):
            if mode == 'TREE':
                for gg in groups:
                    gg['on'] = True
                    for s in subs.get(gg['g'], []):
                        s['on'] = True
            else:
                for x in items:
                    x['on'] = True
        elif key in (ord('n'), ord('N'), ord('т'), ord('Т')):
            if mode == 'TREE':
                for gg in groups:
                    gg['on'] = False
                    for s in subs.get(gg['g'], []):
                        s['on'] = False
            else:
                for x in items:
                    x['on'] = False
        ctx.draw()
    return None


def main():
    mode, groups, subs, items = parse_stdin()
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
        picked = curses.wrapper(lambda scr: loop(scr, mode, groups, subs, items))
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
    if mode == 'MENU':
        print(items[picked]['tag'])
    elif mode == 'CHECK':
        for it in items:
            if it['on']:
                print(it['tag'])
    else:  # TREE — финальное состояние всех пунктов
        for g in groups:
            print(f"G;{g['g']};{'ON' if g['on'] else 'OFF'}")
            for s in subs.get(g['g'], []):
                print(f"S;{g['g']};{s['tag']};{'ON' if s['on'] else 'OFF'}")
    sys.exit(0)


if __name__ == '__main__':
    main()
