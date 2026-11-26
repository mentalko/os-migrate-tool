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
             archives/<дата>_<os>.tar.gz (+ .meta/)
```

## Компоненты

| Файл | Роль |
|---|---|
| `pack.sh` | Упаковка: выбор SSD → чеклист (группы+подпункты) → подтверждение → единый бандл |
| `pack-kitty.sh` | Лаунчер: pack.sh в окне kitty с логом сессии для агента |
| `unpack.sh` | Восстановление: тип системы → выбор бандла → TUI-дерево → распаковка |
| `src/lib.sh` | Общий код: сообщения, dry-run, root-чек, ERR-trap, выбор TUI-движка, fallback-меню/чеклист |
| `src/tui.py` | TUI на curses (stdlib python): режимы TREE / MENU / CHECK |
| `src/conf.py` | Мост конфига в bash: `eval "$(conf.py inv sel)"`; мини-YAML на stdlib |
| `src/progress-line` | Прогресс-бар `▓▓░░` для `--checkpoint` tar: байты → строка статуса |
| `configs/inventory.yaml` | Полный инвентарь: группы `group_*` с секциями + `desc:` |
| `configs/selection.yaml` | Галочки по умолчанию: `group_<имя>.on` + вложенные пути |
| `configs/exclude_dirs.yaml` | Исключения: `tar:` шаблоны (все сегменты) + `appimages.skip_zero_size` |
| `configs/mapping.toml` | Пакеты и программы: команды по типу системы (arch/debian), url для ручной установки |
| `configs/README.md` | Краткое описание каждого конфига |

## Конфигурация: inventory.yaml + selection.yaml

Три YAML-файла в `configs/`; парсит `src/conf.py` и печатает bash-код для `eval` в pack.sh
(exclude_dirs → `EXCL_PATTERNS_ARR` + `APPIMG_SKIP_ZERO`; mapping.toml →
`MAPPING_STATUS`/`PKG_CMD`/`MAPPING_URL`/`APPIMG_URL`/`PROG_CMD`/`PROG_URL`):
массивы путей (`AGENT_DIRS_ARR`, `DOT_ARR`, `AGENT_SESSIONS_ARR`, …), assoc
`DESC` (описания), `TUI_GRP_STATE` (ON/OFF по группам), `TUI_SEL`
(`группа|путь` → ON/OFF), `COMPRESS_ESTIMATE`. Значения квотируются
`shlex.quote`; assoc-элементы эмитятся строго как `[ключ]=значение` (голый
`ключ=значение` внутри `declare -A=(…)` bash не парсит как subscript).

**configs/inventory.yaml** содержит `group_programs` — секции-менеджеры
(npm/uv/pipx/bin) со списками тулзов; conf.py эмитит `PROG_SECS_ARR` +
`PROG_<SEC>_ARR`, а из mapping.toml `[programs.<сек>.<тул]` — `PROG_CMD`
(дефолт по секции: `npm i -g X` / `uv tool install X` / `pipx install X`)
и `PROG_URL`. TUI рисует их третьим уровнем (SEC/T-строки протокола).

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
подпункты) и дерево распаковки unpack (сегмент → путь → подпуть),
`MENU` — одиночный выбор, `CHECK` — плоский чеклист.

**Протокол stdin** (разделитель `;`, hint: `|` = перенос строки):

```
TREE:  G;<group>;<desc>;<sizeMB>;<ON|OFF>[;<state>]
       SEC;<group>;<section>;<desc>;<sizeMB>;<ON|OFF>[;<path>[;<state>]]  — 3-й уровень
       T;<group>;<section>;<tag>;<desc>;<sizeMB>;<ON|OFF>;<hint>;<path>[;<state>]
       S;<group>;<tag>;<desc>;<sizeMB>;<ON|OFF>;<hint>;<path>[;<state>]
MENU:  M;<tag>;<desc>;<hint>
CHECK: C;<tag>;<desc>;<ON|OFF>;<hint>
```

`state` (только unpack): `exists` — цель уже есть в $HOME (жёлтый `●`),
`new` — будет создан (зелёный `○`), пусто — маркера нет (pack). У SEC с
`path` нижняя панель показывает путь и du-сводку «Внутри:» текущего $HOME.

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
с размерами (`du -sm` по детям, лениво, кэш `_summary_cache`, timeout 20 c);
при state — строка «● уже существует — будет перезаписан» / «○ будет создан»,
у группы — счётчик «уже есть N · будет создано M». Панель сжимается на
маленьких терминалах (2–6 строк).

**Коды возврата**: 0 — выбор (stdout: теги; для TREE — финальное состояние
всех пунктов `G;…;ON/OFF` и `S;…;ON/OFF`), 1 — отмена, 2 — ошибка входа.

**Интеграция**: `lib.sh` ставит `OMT_TUI=1`, если есть `python3` + `curses`;
иначе скрипты используют bash-fallback (ui_menu/ui_checklist/ui_tree в
lib.sh/pack.sh, голый bash, alt-screen `\e[?1049h`). ERR-trap возвращает
`\e[?1049l\e[?25h`, чтобы терминал не остался сломанным после падения.

## pack.sh — поток

1. `omt_dryrun` (`--dry-run`/`-n`), `--no-compress`/`--compress` → `require_not_root` → проверка debian-подобной ОС.
2. Выбор SSD: `lsblk` → не-`/` маунтпойнты → `ui_menu` (устройство, метка, ФС,
   размер, свободно); write-test `touch`.
3. `eval "$(src/conf.py configs/inventory.yaml configs/selection.yaml configs/exclude_dirs.yaml)"`
   → массивы путей, `DESC`, дефолты галочек, `EXCL_PATTERNS_ARR`, `APPIMG_SKIP_ZERO`;
   поиск AppImage (битые/пустые отсекаются `skip_zero_size`).
4. Построение групп/подпунктов (`SUBS` = `desc;size;hint;path`, `SUB_ORDER`
   хранит порядок), описания из `DESC`, размеры `du -sm --apparent-size`;
   дефолты — из `TUI_GRP_STATE`/`TUI_SEL` (selection.yaml), программы —
   3-й уровень (`PROG_SECS_ARR`/`PROG_<SEC>_ARR`).
5. `ui_tree` (tui.py TREE или bash-fallback) → финальные состояния раскладываются
   обратно в `GRP_STATE`/`SUB_STATE`/`PROG_*_STATE` → разворот в `SEL` +
   `GRP_SIZE_PLAN` + `GRP_SEL` (пути через `\n` — безопасно к пробелам).
   Галочка группы — массовый переключатель: решают состояния подпунктов,
   ON-подпункт едет даже внутри OFF-группы.
6. Подтверждение: построчный список с размерами, сырой объём, оценка tar.gz,
   свободное место (die при нехватке), таблица сегментов бандла; если формат
   не задан флагом — вопрос «с сжатием или без» (gz/tar, оценки обоих вариантов);
   `y/n`.
7. Прогон — **один бандл** `archives/<дата>_<os>.tar.gz` (или `.tar`; коллизия
   → суффикс времени) + рядом `<...>.meta/` (служебные файлы прогона).
   Исключения: `exclude-patterns` (из exclude_dirs.yaml, на все сегменты) и
   `exclude-dotfiles-data` (паттерны + dedup агентских/браузерных/тулчейн/flatpak
   путей — только dotfiles/data, они едут в своих сегментах).
   `seg_tar()` дописывает сегмент в бандл: gzip-члены (мульти-членный бандл),
   `--transform 's,^,<сег>/,'`, `--checkpoint=200` → `src/progress-line`
   (бар `▓▓░░`); tar rc 1/2 = часть файлов пропущена — warn, прогон продолжается.
8. Манифесты packages: dpkg/flatpak/code/dconf/crontab/systemd-user +
   `npm ls -g` + `pip3 list --user` — пишутся в `.meta/packages/`, оттуда
   сегментом в бандл.
9. AppImage: `list.txt` + `cp` в `.meta/appimages/` (имена с пробелами ок) →
   сегментом в бандл; staging удаляется.
10. `paths.tsv` (source → bundle:segment → dest) + `programs.txt` в `.meta/`;
    резерв `meta/` (paths.tsv, списки исключений) дописывается внутрь бандла —
    потерянный `.meta/` восстанавливается unpack'ом.
11. Самосинхронизация `TOOL_FILES` (src/, configs/, skills/, скрипты, README) на SSD.
12. `manifest.txt` = sha256 бандла + дерево (`tar --ignore-zeros -t`); симлинк
    `latest` → при ФС без симлинков (exFAT) файл `latest.txt`.

## unpack.sh — поток

1. **Тип системы** — первый шаг: автоопределение по os-release (ID/ID_LIKE →
   arch/debian); не удалось — ui_menu из списка. Переопределение: `OMT_SYS_TYPE`.
   Тип выбирает команды из mapping.toml (`PKG_CMD[тип|pkg]`, `PROG_CMD[тип|сек|тул]`).
2. Выбор бандла (`archives/*.tar.gz` / `*.tar`).
3. **Индекс содержимого** — 1 проход `tar -tvf` (формат вывода стабилен в
   C/ru локалях, ISO-даты): awk за проход строит три уровня — сегмент (сумма),
   верхнеуровневые пути сегмента (тип dir/file + размер), подпути 2-го уровня.
   Симлинки: хвост « -> цель» срезается. Хранилище: assoc-массивы SEG_SZ /
   ENTRY_* / CHILD_* + CHILD_OF (подпути по родителю).
4. **Выбор — TUI-дерево** (tui.py TREE, как в pack): сегмент → верхнеуровневый
   путь → подпуть 2-го уровня. У каждого пункта маркер существования цели:
   `●` жёлтый — уже есть в $HOME (будет перезаписан), `○` зелёный — будет
   создан; группа показывает счётчик «уже есть N · будет создано M», hint —
   состояние + путь + «Внутри:» (du-сводка того, что лежит в $HOME сейчас).
   Состояния детей решают и при OFF-группе (включённый подпуть едет);
   выбраны все верхнеуровневые пути → сегмент целиком (`SEG_WHOLE`), иначе —
   список member-путей (`SEL_PARTS`). Аргументы CLI (`all`, `dotfiles`, …)
   дерево пропускают; без curses — плоский чеклист сегментов целиком.
5. **Конфликты** — ДО распаковки, только по ВЫБРАННЫМ путям: один вопрос на
   сегмент: overwrite / backup (`*.bak-premigrate`) / keep (докатить только
   несуществующее) / skip. keep переписывает SEG_WHOLE → SEL_PARTS без
   существующих целей; если после keep ничего не осталось — сегмент отпадает
   с warn.
6. Распаковка — 2 прохода максимум: packages+appimages → `<run>.meta/`;
   домашние пути → `$HOME` одним `tar --ignore-zeros -xzf --strip-components=1
   --verbatim-files-from --files-from=<список>` (сегменты целиком — именем,
   выбранные подпути — построчно).
7. `packages`: сверка `apt-list.txt` с `mapping.toml` — **точное** сравнение
   первого поля через assoc-массив (grep -E ломался на `+` в именах: g++,
   libstdc++6). `status=native|aur` → `eval install_cmd` для текущего типа;
   пакеты вне маппинга → `missing-mapping.txt`, молча ничего не ставится.
   VS Code extensions, `dconf load`, `crontab` — по наличию файлов.
8. Браузеры: предупреждение про старый keyring до распаковки; отказ → сегмент
   вынимается из очереди извлечения.
9. Отчёт: выбранные сегменты (целиком/число путей + объём), paths.tsv
   (source → dest), missing-mapping, блок «скачать/установить вручную»
   (flathub/manual/programs urls).

## Формат mapping.toml

TOML (stdlib `tomllib`, python ≥ 3.11). `[packages.<имя-в-ubuntu>]`: `name`
(дублируется для читаемости), `status` ∈ {native, aur, manual, skip}, команды
по ТИПАМ систем `arch =` / `debian =` — выполняются только для native/aur
на соответствующей системе; `url` — страница для manual (unpack печатает в
отчёте). `[programs.<секция>.<тул]` — пользовательские CLI (npm/uv/pipx/bin):
команда по умолчанию от менеджера (`npm i -g X` / `uv tool install X` /
`pipx install X`), переопределяется `arch`/`debian`; `url` печатается в
блоке «установить вручную». `[appimages."<файл>"]` — url страницы скачивания.
Нет записи → пакет не ставится, попадает в missing-отчёт.

## Известные ограничения и грабли

- **`set -e` + арифметика**: `(( expr ))` возвращает 1 при нулевом результате —
  `(( --cur ))` на переходе к строке 0 убивал скрипт. Все перемещения курсора —
  через `if`/присваивание; у compose-функций `return 0`.
- **Пайпы в `$( )` под set -e**: последний `[[ ]] && cmd` цикла возвращает 1 →
  присваивание падает. Закрывать `|| true`.
- **FAT/exFAT/NTFS**: нет бита исполнения → запуск `bash pack.sh`; симлинки не
  поддерживаются → `latest.txt`; права/владельцы сохраняются только внутри tar.gz.
- **`.cache`** вырезается шаблонами `configs/exclude_dirs.yaml` (`.cache` + `cache`
  на любой глубине) из всех сегментов — включать его в `group_toolchain`
  бессмысленно (пункт-пустышка).
- **Креды**: сегмент `agents` содержит `~/.zcode/cli/credentials.json`, данные
  opencode (db/auth в `~/.local/share/opencode`) и `.pencil/agent-auth`; конфиг
  OpenWhispr содержит `auth-token.bin` — SSD с бэкапом держать при себе/шифровать
  (по умолчанию бэкапятся zcode + opencode + pencil, см. selection).
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
