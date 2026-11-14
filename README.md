# os-migrate-tool

Интерактивный перенос системы **Ubuntu → CachyOS (Arch)** через внешний SSD.

Техническое устройство проекта — [docs/architecture.md](docs/architecture.md).
Инструкция для ИИ-агента — [skills/os-migrate-tool/SKILL.md](skills/os-migrate-tool/SKILL.md).

## Что переносит

| Компонент | Источник (Ubuntu) | Приёмник (Cachy) |
|---|---|---|
| `packages` | списки apt/flatpak/VS Code/dconf/cron/systemd-user | переустановка через pacman/yay по `mapping.toml` |
| `appimages` | `*.AppImage` из ~/Applications, ~/bin, ~/Desktop | → `~/Applications` |
| `dotfiles` | ~/.config, ~/.ssh, ~/.gnupg, shell rc, шрифты, история | → $HOME |
| `data` | не-скрытые каталоги home: ~/Documents, Downloads, Desktop, Pictures, ~/bin | → $HOME |
| `agents` | данные ИИ-агентов — инвентарь в `inventory.yaml`; по умолчанию отмечены только zcode + opencode (сессии, конфиги) | → $HOME |
| `programs` | пользовательские CLI (npm/uv/pipx/bin): файлов в бандле нет — unpack выполняет команды из `mapping.toml` (`npm i -g cline`, `uv tool install …`) и печатает ссылки; `bin`-бинарники едут с dotfiles | переустановка |
| `browsers` | профили Chrome/Firefox целиком (по умолчанию on) | → $HOME |
| `flatpak` | профили flatpak-приложений (~/.var) | → $HOME |
| `toolchain` | rustup/nvm/bun/npm/vscode (по умолчанию off — переустановить) | → $HOME |
| `extra` | paperless-ngx, Sync, v2rayN (группа off, v2rayN включен точечно) | → $HOME |

Полный список путей и их описания — `configs/inventory.yaml`; что отмечено — `configs/selection.yaml`.

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
bash unpack.sh all                                     # все сегменты бандла
bash unpack.sh dotfiles extra                          # по именам сегментов
bash unpack.sh --packages --appimages                  # то же с --
bash unpack.sh --dry-run agents                        # отчёт без изменений
```

> На FAT/exFAT/NTFS-SSD запускай через `bash pack.sh` — бита исполнения на таких ФС нет.

## Структура SSD после pack.sh

```
os-migrate-tool/
├── pack.sh  pack-kitty.sh  unpack.sh   # скрипты
├── src/                                # lib.sh, tui.py, conf.py, mapping.toml, exclude.txt
├── configs/                            # inventory.yaml, selection.yaml, exclude_dirs.yaml
├── README.md                           # самообновляется
├── skills/os-migrate-tool/SKILL.md     # скилл для ИИ-агента (самообновляется)
└── archives/
    ├── 2026-11-14_ubuntu.tar.gz    # ЕДИНЫЙ бандл прогона (внутри — сегменты
    │   │                           #  packages/, appimages/, dotfiles/, data/,
    │   │                           #  agents/, browsers/, flatpak/, … + meta/
    │   │                           #  с резервом paths.tsv)
    ├── 2026-11-14_ubuntu.meta/     # manifest.txt (sha256 бандла + дерево),
    │   │                           # paths.tsv, missing-mapping.txt
    │   │                           # (потеряется — paths.tsv восстановится
    │   │                           #  из бандла автоматически)
    └── latest -> 2026-11-14_ubuntu.tar.gz   # или latest.txt на FAT/exFAT
```

Мульти-членный gzip: сегменты дописываются в бандл, чтение — всегда с
`tar --ignore-zeros`. Выборочная распаковка прокручивает бандл (медленно),
поэтому домашние сегменты извлекаются **одним проходом tar**.

## src/ — общий код и TUI-движок

Хелперы (сообщения, dry-run, проверка root) — в `src/lib.sh`; TUI — в `src/tui.py`
на **curses (stdlib python, ничего устанавливать не нужно)**: альтернативный
экран (без мусора в скроллбеке), скролл вьюпорта при списках длиннее
терминала, корректная перерисовка после resize. Конфиг в bash переносит
`src/conf.py` (мини-YAML на stdlib). bash-TUI в `src/lib.sh` — fallback, если
curses недоступен.

## Конфигурация: inventory.yaml + selection.yaml (YAML-подмножество, без хардкода в скриптах)

Два файла в `configs/`, парсит `src/conf.py` (мини-YAML на stdlib — отступы 2 пробела, списки `- `, комментарии целыми строками):

**`configs/inventory.yaml`** — полный инвентарь; группа = `group_<имя>`, внутри — секции
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

## mapping.toml

`[packages.<ubuntu-имя>]` со статусом и командой установки на CachyOS:
```toml
[packages."zsh"]
name = "zsh"
status = "native"
ubuntu = "sudo apt install -y zsh"
cachyos = "sudo pacman -S zsh"

[programs.npm.cline]
url = "https://cline.bot"

[packages."chatgpt"]
name = "chatgpt"
status = "manual"
# url = "https://…"   # unpack напечатает ссылку в конце
```
- `native` → pacman-репо, `aur` → yay, `manual` → руками (url в отчёте),
  `skip` → не переносится
- Нет записи → пакет **не ставится молча**, попадает в `missing-mapping.txt`
- flatpak-приложения и appimages не ставятся скриптом: в конце печатается
  список «название — ссылка» (flathub / url из mapping.toml)

## Требования

- bash ≥ 4.4, tar, lsblk, df — базовая система
- **python3** (мини-YAML-парсер conf.py + curses; есть на Ubuntu и Cachy) —
  конфиг и TUI на нём; bash-TUI остаётся fallback'ом терминала
- Формат SSD: FAT/exFAT/NTFS — ок (запуск через `bash pack.sh`; права/владельцы
  хранятся внутри tar.gz; симлинк `latest` заменяется на `latest.txt`)
