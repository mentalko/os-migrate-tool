# os-migrate-tool

Интерактивный перенос системы **Ubuntu → CachyOS (Arch)** через внешний SSD.

## Что переносит

| Компонент | Источник (Ubuntu) | Приёмник (Cachy) |
|---|---|---|
| `packages` | списки apt/flatpak/VS Code/dconf/cron/systemd-user | переустановка через pacman/yay по `mapping.tsv` |
| `appimages` | `*.AppImage` из ~/Applications, ~/bin, ~/Desktop | → `~/Applications` |
| `dotfiles` | ~/.config, ~/.ssh, ~/.gnupg, shell rc, шрифты, история | → $HOME |
| `data` | ~/Documents | → ~/Documents |
| `agents` | ~/.qoder, ~/.codex, ~/.claude, ~/.agents, ~/.jcode, [10] SKILLS | → $HOME |
| `browsers` | профили Chrome/Firefox/Brave/Chromium целиком | → $HOME |

## Использование

**На Ubuntu:**
```bash
./pack.sh          # интерактивно: выбор SSD → выбор компонентов (галочки, пути, размеры) → упаковка
```

**На CachyOS (прямо с SSD):**
```bash
/mnt/<ssd>/os-migrate-tool/unpack.sh            # или
./unpack.sh --packages --appimages --dotfiles   # выбор компонентов флагами
```

## Структура SSD после pack.sh

```
os-migrate-tool/
├── pack.sh unpack.sh mapping.tsv exclude.txt README.md SKILL.md   # самообновляются при каждом прогоне
└── archives/
    ├── 2026-11-09_ubuntu/      # прогон = дата_исходная-ОС
    │   ├── manifest.txt        # дерево + sha256
    │   ├── packages/  appimages/
    │   └── *.tar.gz
    └── latest -> 2026-11-09_ubuntu
```

## mapping.tsv

`ubuntu_pkg<TAB>status<TAB>install_cmd<TAB>notes`

- `status = native` → есть в pacman-репо
- `status = aur` → ставится через yay
- `status = skip` → не переносится (snapd, ubuntu-*, ...)
- Нет строки в мапинге → пакет **не ставится молча**, попадает в отчёт `missing-mapping.txt`

## Требования

- `whiptail` (есть в Ubuntu по умолчанию); без него — текстовый fallback
- bash ≥ 4.4 (на Cachy 5.2, на Ubuntu 5.x — ок)
