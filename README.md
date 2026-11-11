# os-migrate-tool

Интерактивный перенос системы **Ubuntu → CachyOS (Arch)** через внешний SSD.

Техническое устройство проекта — [docs/architecture.md](docs/architecture.md).

## Что переносит

| Компонент | Источник (Ubuntu) | Приёмник (Cachy) |
|---|---|---|
| `packages` | списки apt/flatpak/VS Code/dconf/cron/systemd-user | переустановка через pacman/yay по `mapping.tsv` |
| `appimages` | `*.AppImage` из ~/Applications, ~/bin, ~/Desktop | → `~/Applications` |
| `dotfiles` | ~/.config, ~/.ssh, ~/.gnupg, shell rc, шрифты, история | → $HOME |
| `data` | ~/Documents, Downloads, Desktop, Pictures | → $HOME |
| `agents` | ~/.qoder, ~/.codex, ~/.claude, .agents/.jcode/.zcode/…, [10] SKILLS | → $HOME |
| `browsers` | профили Chrome/Firefox/Brave/Chromium целиком (по умолчанию off) | → $HOME |

## Использование

**На Ubuntu:**
```bash
bash pack.sh                 # интерактивно: выбор SSD → чеклист → подтверждение → упаковка
bash pack.sh --dry-run       # полный прогон без записи на SSD
bash pack-kitty.sh --dry-run # то же в отдельном окне kitty + лог сессии в /tmp (для агента)
```

**На CachyOS (прямо с SSD):**
```bash
bash /mnt/<ssd>/os-migrate-tool/unpack.sh              # интерактивно
bash unpack.sh all                                     # все компоненты прогона
bash unpack.sh --packages --appimages --dotfiles       # любые комбинации флагов
bash unpack.sh --dry-run dotfiles.tar.gz               # отчёт без изменений
```

> На FAT/exFAT/NTFS-SSD запускай через `bash pack.sh` — бита исполнения на таких ФС нет.

## Структура SSD после pack.sh

```
os-migrate-tool/
├── lib.sh tui.py pack.sh unpack.sh mapping.tsv exclude.txt migrate.conf README.md SKILL.md  # самообновляются
└── archives/
    ├── 2026-11-09_ubuntu/      # прогон = дата_исходная-ОС
    │   ├── manifest.txt        # дерево + sha256
    │   ├── paths.tsv           # source -> archive -> dest для каждого пути
    │   ├── packages/  appimages/
    │   └── *.tar.gz
    └── latest -> 2026-11-09_ubuntu   # или latest.txt, если ФС не умеет симлинки
```

## lib.sh + tui.py — общий код и TUI-движок

Хелперы (сообщения, dry-run, проверка root) — в `lib.sh`; TUI — в `tui.py`
на **curses (stdlib python, ничего устанавливать не нужно)**: альтернативный
экран (без мусора в скроллбеке), скролл вьюпорта при списках длиннее
терминала, корректная перерисовка после resize. Если python3 недоступен —
автоматический fallback на встроенный bash-TUI (lib.sh).

## migrate.conf — пути и дефолты чекбоксов (без хардкода в скриптах)

Списки разделены `:` — **пути могут содержать пробелы** (например
`Documents/[10] SKILLS`). Задают: `APPIMG_DIRS`, `DOT_DIRS`, `DOT_FILES`,
`AGENT_DIRS` (в home), `AGENT_CONFIG_DIRS` (данные агентов в .config),
`AGENT_SESSIONS_DIRS` (сессии отдельно — актуализирует агент на новой системе),
`BROWSER_DIRS`, `DATA_DIRS`, `TOOLCHAIN_DIRS`, `FLATPAK_DATA_DIRS`,
`TMP_DIRS` (пусто — /tmp не пакуем), `EXTRA_DIRS`, `COMPRESS_ESTIMATE`.
Каждый путь — отдельная строка в чеклисте pack.sh (группа → подпункты).

Дефолты галочек (подобраны агентом, чтобы не расставлять вручную каждый раз):
- `CHECKBOX_GROUPS_OFF="browsers:toolchain:tmp:extra"` — группы, по умолчанию выключенные;
- `CHECKBOX_SUBS_OFF=""` — отдельные подпункты поверх группового дефолта (формат `группа|тег`).

Описания пунктов: `DESC_MAP` — строки `путь|описание` (для AppImage — имя файла).
Их видит чеклист под каждым подпунктом: что в каталоге и какие там программы.
Добавил путь — добавь описание.

## mapping.tsv

`ubuntu_pkg<TAB>status<TAB>install_cmd<TAB>notes`

- `status = native` → есть в pacman-репо
- `status = aur` → ставится через yay
- `status = skip` → не переносится (snapd, ubuntu-*, ...)
- Нет строки в мапинге → пакет **не ставится молча**, попадает в отчёт `missing-mapping.txt`

## Требования

- bash ≥ 4.4, tar, lsblk, df — базовая система
- **python3 с curses** (есть на Ubuntu и Cachy по умолчанию) — для TUI;
  без него скрипты работают через bash-fallback
- Формат SSD: FAT/exFAT/NTFS — ок (запуск через `bash pack.sh`; права/владельцы
  хранятся внутри tar.gz; симлинк `latest` заменяется на `latest.txt`)
