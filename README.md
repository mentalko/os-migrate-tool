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
├── lib.sh tui.py conf.py inventory.toml selection.toml pack.sh unpack.sh mapping.tsv exclude.txt README.md SKILL.md  # самообновляются
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

## Конфигурация: inventory.toml + selection.toml (TOML, без хардкода в скриптах)

Два файла, парсит `conf.py` (stdlib `tomllib`, python ≥ 3.11):

**`inventory.toml`** — полный инвентарь: пути по группам (`[agents]` home/config/sessions,
`[dotfiles]`, `[browsers]`, `[data]`, `[toolchain]`, `[flatpak]`, `[extra]`…),
`[appimages] dirs` — где искать AppImage, `[desc]` — описания пунктов
(что в каталоге / что за программы), `[meta] compress_estimate`.
Конфиг — **полный инвентарь**: всё видно в чеклисте, несуществующие пути
автоматически пропускаются.

**`selection.toml`** — галочки по умолчанию, деревом:
```toml
[groups]
agents    = true
browsers  = true
toolchain = false
extra     = false

[agents]                  # точечно внутри группы
".zcode" = true
".config/Cursor" = false

[extra]                   # ON внутри выключенной группы — тоже можно
"v2rayN" = true
```
Не упомянутые подпункты наследуют группу; ручные галочки в чеклисте
перекрывают всё. Подпункт с ON едет даже внутри выключенной группы.

## mapping.tsv

`ubuntu_pkg<TAB>status<TAB>install_cmd<TAB>notes`

- `status = native` → есть в pacman-репо
- `status = aur` → ставится через yay
- `status = skip` → не переносится (snapd, ubuntu-*, ...)
- Нет строки в мапинге → пакет **не ставится молча**, попадает в отчёт `missing-mapping.txt`

## Требования

- bash ≥ 4.4, tar, lsblk, df — базовая система
- **python3 ≥ 3.11** (stdlib `tomllib` + curses; есть на Ubuntu и Cachy) —
  конфиг и TUI на нём; bash-TUI остаётся fallback'ом терминала
- Формат SSD: FAT/exFAT/NTFS — ок (запуск через `bash pack.sh`; права/владельцы
  хранятся внутри tar.gz; симлинк `latest` заменяется на `latest.txt`)
