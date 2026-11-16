# os-migrate-tool

[English](README.md) · **Русская версия** (этот файл)

Универсальный пакер Linux-окружения (**arch ↔ debian**, например Ubuntu → CachyOS)
через внешний SSD: пакеты (по `mapping.toml` с командами под тип системы),
AppImages, dotfiles, пользовательские CLI (npm/uv/pipx/bin — переустановка),
данные и сессии ИИ-агентов, браузеры.

Техническое устройство проекта — [docs/architecture.md](docs/architecture.md).
Инструкция для ИИ-агента — [skills/os-migrate-tool/SKILL.md](skills/os-migrate-tool/SKILL.md).

## Инициализация ИИ-агентом (`/init`)

На **новой системе** передай агенту этот репозиторий и вставь промпт:

```text
/init os-migrate-tool

Сначала прочитай skills/os-migrate-tool/SKILL.md — это руководство оператора
(рабочий цикл агента, команды, отчёты, правила). Затем составь конфигурацию
под меня, этого пользователя:
1. Сверь configs/inventory.yaml с этой системой: пути могут отличаться
   (версии агентов, каталоги сессий — особое внимание group_agents.sessions).
   Несуществующие пути пропускаются автоматически; для каждого нового пути
   добавь запись в desc:.
2. Настрой configs/selection.yaml под меня: что едет по умолчанию, что
   остаётся выключенным (тяжёлое/опциональное). ON-подпункт едет даже внутри
   OFF-группы.
3. Пересмотри configs/exclude_dirs.yaml (что никогда не пакуется) и
   configs/mapping.toml (команды установки по типу системы), если цели
   изменились.
4. Не хардкодь пути в pack.sh/unpack.sh — только конфиги. Системный код —
   в src/, пользовательские конфиги — в configs/.
5. В конце покажи итоговые дефолты галочек на моё подтверждение.
```

Детали: [skills/os-migrate-tool/SKILL.md](skills/os-migrate-tool/SKILL.md) ·
устройство проекта: [docs/architecture.md](docs/architecture.md).

## Что переносит

| Сегмент | Источник (Ubuntu/debian) | Приёмник (Cachy/arch) |
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
| `extra` | paperless-ngx, Sync, v2rayN (группа off; v2rayN, paperless-ngx, Sync включены точечно) | → $HOME |

Полный список путей и их описания — `configs/inventory.yaml`; что отмечено —
`configs/selection.yaml`.

## Использование

**На исходной системе (Ubuntu/debian):**
```bash
bash pack.sh                 # интерактивно: выбор SSD → чеклист → подтверждение → упаковка
bash pack.sh --dry-run       # полный прогон без записи на SSD
bash pack.sh --no-compress   # бандл .tar без сжатия: быстрее, выборочная
                             # распаковка мгновенная (seek), на SSD ~raw объём
bash pack-kitty.sh --dry-run # то же в отдельном окне kitty + лог сессии в /tmp (для агента)
```

**На целевой системе (CachyOS/arch), прямо с SSD:**
```bash
bash /mnt/<ssd>/os-migrate-tool/unpack.sh              # интерактивно
bash unpack.sh all                                     # все сегменты бандла
bash unpack.sh dotfiles extra                          # по именам сегментов
bash unpack.sh --packages --appimages                  # то же с --
bash unpack.sh --dry-run agents                        # отчёт без изменений
```

> На FAT/exFAT/NTFS-SSD запускай через `bash pack.sh` — бита исполнения на
> таких ФС нет.

## Структура SSD после pack.sh

```
os-migrate-tool/
├── pack.sh  pack-kitty.sh  unpack.sh   # скрипты
├── src/                                # lib.sh, tui.py, conf.py, progress-line
├── configs/                            # inventory.yaml, selection.yaml, exclude_dirs.yaml, mapping.toml
├── README.md  README.ru.md             # самообновляется
├── skills/os-migrate-tool/SKILL.md     # скилл для ИИ-агента (самообновляется)
└── archives/
    ├── 2026-11-14_ubuntu.tar.gz    # ЕДИНЫЙ бандл прогона (.tar при
    │   │                           # --no-compress; внутри — сегменты
    │   │                           # packages/, appimages/, dotfiles/, data/,
    │   │                           # agents/, browsers/, flatpak/, … + meta/
    │   │                           # с резервом paths.tsv)
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

Хелперы (сообщения, dry-run, проверка root) — `src/lib.sh`; TUI — `src/tui.py`
на **curses (stdlib python, ничего устанавливать не нужно)**: альтернативный
экран (без мусора в скроллбеке), скролл вьюпорта при списках длиннее
терминала, корректная перерисовка после resize. Конфиг в bash переносит
`src/conf.py` (мини-YAML на stdlib). bash-TUI в `src/lib.sh` — fallback,
если curses недоступен.

## Конфигурация: inventory.yaml + selection.yaml (YAML-подмножество, без хардкода)

Два файла в `configs/`, парсит `src/conf.py` (мини-YAML на stdlib — отступы
2 пробела, списки `- `, комментарии целыми строками):

**`configs/inventory.yaml`** — полный инвентарь; группа = `group_<имя>`, внутри —
секции (`home`/`config`/`sessions` у агентов, `dirs`+`files` у dotfiles,
`paths` у остальных), `desc:` — описания пунктов (что в каталоге / что за
программы). Конфиг — **полный инвентарь**: всё видно в чеклисте, несуществующие
пути автоматически пропускаются.

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

`[packages.<ubuntu-имя>]` со статусом и командой установки на целевой системе:
```toml
[packages."zsh"]
name = "zsh"
status = "native"
debian = "sudo apt install -y zsh"
arch   = "sudo pacman -S zsh"

[programs.npm.cline]
url = "https://cline.bot"

[packages."chatgpt"]
name = "chatgpt"
status = "manual"
# url = "https://…"   # unpack напечатает ссылку в конце
```
- `native` → репозитории, `aur` → через yay, `manual` → руками (url в отчёте),
  `skip` → не переносится
- Нет записи → пакет **не ставится молча**, попадает в `missing-mapping.txt`
- flatpak-приложения и appimages не ставятся скриптом: в конце печатается
  список «название — ссылка» (flathub / url из mapping.toml)

## Требования

- bash ≥ 4.4, tar, lsblk, df — базовая система
- **python3** (мини-YAML-парсер conf.py + curses; есть на Ubuntu и Cachy) —
  конфиг и TUI на нём; bash-TUI остаётся fallback'ом терминала
- Целевые системы: arch-подобные и debian-подобные (автоопределение)
- Формат SSD: FAT/exFAT/NTFS — ок (запуск через `bash pack.sh`; права/владельцы
  хранятся внутри tar.gz; симлинк `latest` заменяется на `latest.txt`)
