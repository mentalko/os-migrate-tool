# os-migrate-tool

Интерактивный перенос системы **Ubuntu → CachyOS (Arch)** через внешний SSD.

Техническое устройство проекта — [docs/architecture.md](docs/architecture.md).

## Что переносит

| Компонент | Источник (Ubuntu) | Приёмник (Cachy) |
|---|---|---|
| `packages` | списки apt/flatpak/VS Code/dconf/cron/systemd-user | переустановка через pacman/yay по `mapping.tsv` |
| `appimages` | `*.AppImage` из ~/Applications, ~/bin, ~/Desktop | → `~/Applications` |
| `dotfiles` | ~/.config, ~/.ssh, ~/.gnupg, shell rc, шрифты, история | → $HOME |
| `data` | не-скрытые каталоги home: ~/Documents, Downloads, Desktop, Pictures, ~/bin | → $HOME |
| `agents` | данные ИИ-агентов — инвентарь в `inventory.yaml`; по умолчанию отмечены только zcode + opencode (сессии, конфиги) | → $HOME |
| `browsers` | профили Chrome/Firefox целиком (по умолчанию on) | → $HOME |
| `flatpak` | профили flatpak-приложений (~/.var) | → $HOME |
| `toolchain` | rustup/nvm/bun/npm/vscode (по умолчанию off — переустановить) | → $HOME |
| `extra` | paperless-ngx, Sync, v2rayN (группа off, v2rayN включен точечно) | → $HOME |

Полный список путей и их описания — `inventory.yaml`; что отмечено — `selection.yaml`.

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
├── lib.sh tui.py conf.py inventory.yaml selection.yaml pack.sh pack-kitty.sh unpack.sh mapping.tsv exclude.txt README.md SKILL.md  # самообновляются
└── archives/
    ├── 2026-11-09_ubuntu/      # прогон = дата_исходная-ОС
    │   ├── manifest.txt        # дерево + sha256
    │   ├── paths.tsv           # source -> archive -> dest для каждого пути
    │   ├── packages/  appimages/
    │   └── *.tar.gz
    └── latest -> 2026-11-09_ubuntu   # или latest.txt, если ФС не умеет симлинки
```

## lib.sh + tui.py + conf.py — общий код и TUI-движок

Хелперы (сообщения, dry-run, проверка root) — в `lib.sh`; TUI — в `tui.py`
на **curses (stdlib python, ничего устанавливать не нужно)**: альтернативный
экран (без мусора в скроллбеке), скролл вьюпорта при списках длиннее
терминала, корректная перерисовка после resize. Конфиг в bash переносит
`conf.py` (мини-YAML на stdlib). bash-TUI в `lib.sh` — fallback, если
curses недоступен.

## Конфигурация: inventory.yaml + selection.yaml (YAML-подмножество, без хардкода в скриптах)

Два файла, парсит `conf.py` (мини-YAML на stdlib — отступы 2 пробела, списки `- `, комментарии целыми строками):

**`inventory.yaml`** — полный инвентарь; группа = `group_<имя>`, внутри — секции
(`home`/`config`/`sessions` у агентов, `dirs`+`files` у dotfiles, `paths` у остальных),
`[desc]` → секция `desc:` — описания пунктов (что в каталоге / что за программы).
Конфиг — **полный инвентарь**: всё видно в чеклисте, несуществующие пути
автоматически пропускаются.

**`selection.yaml`** — галочки по умолчанию, дерево повторяет чеклист:
```yaml
group_agents:
  on: true
  .zcode: true
  .config/Cursor: false

group_extra:
  on: false          # группа выключена…
  v2rayN: true       # …но пункт включен — ON внутри OFF-группы едет
```
Не упомянутые подпункты наследуют `on:` группы; ручные галочки в чеклисте
перекрывают всё. Подпункт с ON едет даже внутри выключенной группы.

## mapping.tsv

`ubuntu_pkg<TAB>status<TAB>install_cmd<TAB>notes`

- `status = native` → есть в pacman-репо
- `status = aur` → ставится через yay
- `status = manual` → в репозиториях нет, ставится руками (AppImage/сайт)
- `status = skip` → не переносится (snapd, ubuntu-*, ...)
- Нет строки в мапинге → пакет **не ставится молча**, попадает в отчёт `missing-mapping.txt`

## Требования

- bash ≥ 4.4, tar, lsblk, df — базовая система
- **python3** (мини-YAML-парсер conf.py + curses; есть на Ubuntu и Cachy) —
  конфиг и TUI на нём; bash-TUI остаётся fallback'ом терминала
- Формат SSD: FAT/exFAT/NTFS — ок (запуск через `bash pack.sh`; права/владельцы
  хранятся внутри tar.gz; симлинк `latest` заменяется на `latest.txt`)
