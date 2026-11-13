# os-migrate-tool — архитектура

Техническое описание устройства проекта. Пользовательский уровень — README.md,
инструкция для агента — skills/os-migrate-tool/SKILL.md.

## Обзор

Интерактивный перенос окружения **Ubuntu → CachyOS (Arch)** через внешний SSD.
Два скрипта: `pack.sh` (упаковка выбранных компонентов на SSD) и `unpack.sh`
(восстановление на новой системе). Все пути, дефолты галочек и описания — в
конфиге; код путей не содержит.

```
Ubuntu                                 CachyOS
pack.sh ──► SSD/os-migrate-tool/ ──► unpack.sh
             archives/<дата>_<os>/
```

## Компоненты

| Файл | Роль |
|---|---|
| `pack.sh` | Упаковка: выбор SSD → чеклист (группы+подпункты) → подтверждение → архивы |
| `unpack.sh` | Восстановление: выбор прогона и компонентов, установка пакетов, распаковка |
| `lib.sh` | Общий код: сообщения, dry-run, root-чек, ERR-trap, выбор движка TUI, bash-fallback TUI |
| `tui.py` | TUI на curses (stdlib python): режимы TREE / MENU / CHECK |
| `src/lib.sh` | Общий код: сообщения, dry-run, root-чек, ERR-trap, выбор TUI-движка |
| `src/tui.py` | TUI на curses: TREE / MENU / CHECK |
| `src/conf.py` | Мост конфига в bash: `eval "$(conf.py inv sel)"`; мини-YAML на stdlib |
| `src/mapping.tsv` | Маппинг apt-пакетов → pacman/yay |
| `src/exclude.txt` | Исключения tar (кэши, node_modules, Steam…) |
| `configs/inventory.yaml` | Полный инвентарь: группы `group_*` с секциями + `desc:` |
| `configs/selection.yaml` | Галочки по умолчанию: `group_<имя>.on` + вложенные пути |
| `pack-kitty.sh` | Лаунчер: pack.sh в окне kitty с логом сессии для агента |

## Конфигурация: inventory.yaml + selection.yaml

Два YAML-файла в `configs/`; парсит `src/conf.py` и печатает bash-код для `eval` в pack.sh:
массивы путей (`AGENT_DIRS_ARR`, `DOT_ARR`, `AGENT_SESSIONS_ARR`, …), assoc
`DESC` (описания), `TUI_GRP_STATE` (ON/OFF по группам), `TUI_SEL`
(`группа|путь` → ON/OFF), `COMPRESS_ESTIMATE`. Значения квотируются
`shlex.quote`; assoc-элементы эмитятся строго как `[ключ]=значение` (голый
`ключ=значение` внутри `declare -A=(…)` bash не парсит как subscript).

Парсер — **YAML-подмножество на stdlib** (PyYAML не нужен): вложенные
отображения (отступы 2 пробела), блочные списки `- `, скаляры
true/false/числа/строки, комментарии только целыми строками + инлайн ` #`
срезается; anchors/flow/multi-line не поддерживаются. Формат наш — сложный
YAML не нужен. Группы — ключи `group_<имя>` в порядке файла.

**configs/inventory.yaml** — полный инвентарь (несуществующие пути авто-скип):
`group_appimages.dirs` — где искать AppImage; `group_dotfiles` — `dirs`+`files`;
`group_agents` — `home`/`config`/`sessions` (сессии, покрытые родителями из
home/config, conf.py отбрасывает — covered-check, двойной упаковки нет);
`group_browsers/data/toolchain/flatpak/tmp/extra` — `paths`; `desc:` —
описания пунктов; `meta.compress_estimate`.

**configs/selection.yaml** — галочки по умолчанию, дерево повторяет чеклист:
```yaml
group_agents:
  on: true
  .zcode: true
  .config/Cursor: false

group_extra:
  on: false
  v2rayN: true      # ON внутри выключенной группы — легально
```
Порядок применения в pack.sh: группа → её подпункты → точечные TUI_SEL.
Ручные галочки чеклиста перекрывают всё. Разворот SEL считает подпункты:
ON-подпункт едет даже внутри выключенной группы (галочка группы — массовый
переключатель, не фильтр).

## TUI (tui.py)

Почему curses: bash-рисовалка `\e[H\e[J` мусорила скроллбек, ломалась на
списках длиннее терминала и не знала о resize. Curses даёт альтернативный
экран, дельта-обновления, скролл вьюпорта и KEY_RESIZE.

**Режимы** (`argv[1]`): `TREE` — двухуровневый чеклист pack (группы `▸/▾` +
подпункты), `MENU` — одиночный выбор, `CHECK` — плоский чеклист.

**Протокол stdin** (разделитель `;`, hint: `|` = перенос строки):

```
TREE:  G;<group>;<desc>;<sizeMB>;<ON|OFF>
       S;<group>;<tag>;<desc>;<sizeMB>;<ON|OFF>;<hint>;<path>
MENU:  M;<tag>;<desc>;<hint>
CHECK: C;<tag>;<desc>;<ON|OFF>;<hint>
```

Режим передаётся через **argv**, не через stdin (иначе первый пункт съедался
как строка режима).

**Разводка fd** — ключевой трюк: stdin занят данными пунктов, stdout захвачен
`$( )` под результат. Поэтому после чтения данных fd 0 и fd 1 переключаются
`dup2` на `/dev/tty` (рисование + клавиатура), а исходный stdout сохраняется
в отдельный fd — результат печатается в него после `endwin`.

**Стрелки**: ncurses матчит последовательности по terminfo (application-режим,
`\EOB`); терминалы шлют и CSI (`\E[B`) — после голого ESC (27) дочитываем до 3
байтов в nodelay и разбираем CSI/SS3 вручную (`get_key`).

**Хоткеи** (все режимы): `↑/↓`/`j k` — курсор, `пробел` — галочка (на группе —
вся группа), `a/n` — все/ничего, `q`/Esc — отмена (exit 1), `Enter` — выбор.
TREE дополнительно: `→` — раскрыть группу и нырнуть в первый подпункт, `←` —
свернуть / с подпункта — к родительской группе, **Tab** — раскрыть/свернуть
все группы разом (при сворачивании курсор клампится к списку).

**Нижняя панель** (под курсором): полное описание пункта из `desc`, путь в
виде `~/…`, для каталогов автосводка «Внутри:» — до 5 крупнейших подпапок
с размерами (`du -sm` по детям, лениво, кэш `_summary_cache`, timeout 20 c).
Панель сжимается на маленьких терминалах (2–6 строк).

**Коды возврата**: 0 — выбор (stdout: теги; для TREE — финальное состояние
всех пунктов `G;…;ON/OFF` и `S;…;ON/OFF`), 1 — отмена, 2 — ошибка входа.

**Интеграция**: `lib.sh` ставит `OMT_TUI=1`, если есть `python3` + `curses`;
иначе скрипты используют bash-fallback (ui_menu/ui_checklist/ui_tree в
lib.sh/pack.sh, голый bash, alt-screen `\e[?1049h`). ERR-trap возвращает
`\e[?1049l\e[?25h`, чтобы терминал не остался сломанным после падения.

## pack.sh — поток

1. `omt_dryrun` (арг `--dry-run`/`-n`) → `require_not_root` → проверка debian-подобной ОС.
2. Выбор SSD: `lsblk` → не-`/` маунтпойнты → `ui_menu` (устройство, метка, ФС,
   размер, свободно); write-test `touch`.
3. `eval "$(src/conf.py configs/inventory.yaml configs/selection.yaml)"` → массивы, DESC, дефолты галочек; поиск AppImage.
4. Построение групп/подпунктов (`SUBS` = `desc;size;hint;path`, `SUB_ORDER`
   хранит порядок), дефолты из `CHECKBOX_*`, размеры `du -sm --apparent-size`.
5. `ui_tree` (tui.py или fallback) → раскладка состояний обратно в
   `GRP_STATE`/`SUB_STATE` → разворот в `SEL` + `GRP_SIZE_PLAN` + `GRP_SEL`
   (пути через `\n` — безопасно к пробелам).
6. Подтверждение: построчный список с размерами, сырой объём, оценка tar.gz,
   свободное место (die при нехватке), таблица планируемых архивов, `y/n`.
7. Прогон: `archives/<%F>_<os_id>/` (коллизия → суффикс времени).
   `.exclude-dedup` генерируется один раз: агентские/браузерные/тулчейн/flatpak
   пути + сам tool — вырезаются из dotfiles/data (они едут в своих архивах).
   `targz()` принимает пути через `\n`, фильтрует несуществующие, `--files-from`
   из `<(printf)`, exclude-файл по группе.
8. Манифесты packages: dpkg/flatpak/code/dconf/crontab/systemd-user.
9. AppImage: `list.txt` + `cp` (read по строкам — имена с пробелами ок).
10. `paths.tsv`: `group/tag/size/source/archive/dest` — происхождение каждого пути.
11. Самосинхронизация `TOOL_FILES` на SSD; `manifest.txt` (find + sha256 через
    `find -print0 | sort -z | xargs -0 -r` — имена с пробелами ок); симлинк
    `latest` → при ФС без симлинков (exFAT) файл `latest.txt`.

## unpack.sh — поток

1. Выбор бандла (`archives/*.tar.gz`), список содержимого — 1 проход в tmp-файл.
2. Компоненты: имена сегментов (`dotfiles`, `data`, …), аргументы валидируются
   (ведущие `--` срезаются), `all` = сегменты, присутствующие в бандле.
3. Конфликты — ДО распаковки, по кэшированному списку: верхнеуровневые пути
   сегмента, уже существующие в `$HOME`; один вопрос на сегмент: skip / backup
   (`*.bak-premigrate`) / overwrite.
4. Распаковка — 2 прохода максимум: packages+appimages → `<run>.meta/`,
   домашние сегменты → `$HOME` одним `tar --ignore-zeros -xzf --strip-components=1`.
5. `packages`: сверка `apt-list.txt` с `mapping.tsv` — **точное** сравнение
   первого поля через awk (grep -E ломался на `+` в именах: g++, libstdc++6).
   `status=native|aur` → `eval install_cmd` из третьей колонки; пакеты вне
   маппинга → `missing-mapping.txt`, молча ничего не ставится. Flatpak: remote-add
   --if-not-exists flathub + установка списка. VS Code extensions, `dconf load`,
   `crontab` — по наличию файлов.
6. Браузеры: предупреждение про старый keyring до распаковки; отказ → сегмент
   вынимается из очереди извлечения.
7. Отчёт: выбранные сегменты, paths.tsv (source → dest), missing-mapping.

## Формат mapping.tsv

`ubuntu_pkg<TAB>status<TAB>install_cmd<TAB>notes`; статус ∈ {native, aur, skip,
manual}; строки `#` и пустые пропускаются. Нет строки → пакет не ставится,
попадает в missing-отчёт.

## Известные ограничения и грабли

- **`set -e` + арифметика**: `(( expr ))` возвращает 1 при нулевом результате —
  `(( --cur ))` на переходе к строке 0 убивал скрипт. Все перемещения курсора —
  через `if`/присваивание; у compose-функций `return 0`.
- **Пайпы в `$( )` под set -e**: последний `[[ ]] && cmd` цикла возвращает 1 →
  присваивание падает. Закрывать `|| true` (см. extract_tar).
- **FAT/exFAT/NTFS**: нет бита исполнения → запуск `bash pack.sh`; симлинки не
  поддерживаются → `latest.txt`; права/владельцы сохраняются только внутри tar.gz.
- **`.cache`** исключён `exclude.txt` из всех архивов — включать его в
  `TOOLCHAIN_DIRS` бессмысленно (пункт-пустышка).
- **Креды**: `agents.tar.gz` содержит `~/.zcode/cli/credentials.json`,
  `.codex/auth.json` и т.п. — SSD с бэкапом держать при себе/шифровать.
- Ключи браузеров привязаны к старому keyring — без его пароля пароли не
  откроются.

## Отладка

- `bash pack-kitty.sh --dry-run` — открывает pack.sh в kitty, весь ввод/вывод
  пишется в `/tmp/omt-pack-<метка>.ts`, код выхода — в `.rc`. Агент читает лог
  при падении (ERR-trap печатает строку и команду).
- Тесты в песочнице: `script -qec` даёт pty; для корректного рендера
  передавать `TERM=xterm-256color` (в CI-подобных окружениях TERM=dumb и
  curses деградирует). Функционально проверяются коды выхода и stdout tui.py.
- История багов этого репозитория — в git log; два главных класса: set -e
  арифметика и потеря данных при quoting (data.tar.gz, `'...'` вокруг списков путей).
