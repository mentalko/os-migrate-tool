---
name: os-migrate-tool
description: >
  Интерактивный перенос системы Ubuntu → CachyOS (Arch) через внешний SSD:
  пакеты (apt→pacman/yay по mapping.tsv), AppImages, dotfiles, ~/Documents,
  сессии AI-агентов (.qoder/.codex/.claude/.agents/.jcode + скиллы) и
  профили браузеров целиком. Использовать, когда пользователь просит
  «упаковать систему для переезда», «запаковать на SSD», «распаковать на
  Cachy», «миграция на cachy», «перенос на arch». Триггеры: os-migrate-tool,
  pack.sh, unpack.sh, mapping.tsv.
---

# os-migrate-tool

Перенос Ubuntu → CachyOS через внешний SSD. Скрипты живут на SSD
(`os-migrate-tool/`), при каждом прогоне самообновляются там же.

## Команды

### Упаковка (Ubuntu)

```bash
./pack.sh
```

Интерактивно:
1. Выбор SSD — сканируются смонтированные съёмные диски, показываются
   устройство, метка, точка монтирования, свободное место.
2. Чеклист компонентов: packages / appimages / dotfiles / data / agents /
   browsers — у каждого путь и размер, сумма и оценка итога считаются живьём,
   галочки снимаются.
3. Упаковка в `archives/<YYYY-MM-DD>_<os>/`, пишется `manifest.txt`
   (дерево + sha256) и симлинк `latest`.

### Распаковка (CachyOS)

```bash
./unpack.sh                          # полностью интерактивно
./unpack.sh --packages --appimages   # или флагами
```

Режимы:
- `--packages` — сверяет `packages/apt-list.txt` с `mapping.tsv`;
  ставит через pacman/yay только записанное; не найденное → отчёт
  `missing-mapping.txt`, молча ничего не ставится.
- `--appimages` — копирует в `~/Applications`, `chmod +x`.
- `--dotfiles` / `--agents` / `--browsers` / `--data` — распаковка tar.gz;
  при конфликте спрашивает: перезаписать / пропустить / сделать backup.

## Правила

- `mapping.tsv` — единственный источник истины для установки пакетов.
  Формат: `ubuntu_pkg<TAB>status<TAB>install_cmd<TAB>notes`;
  status ∈ {native, aur, skip}. Нет строки → только в отчёт.
- Названия прогонов: `<дата>_<исходная-ос>` (берётся из /etc/os-release),
  чтобы бэкапы до/после переезда не смешались.
- Перед распаковкой браузеров убедиться, что пользователь помнит пароль
  старого keyring — иначе пароли в профиле не откроются.
- Прямые ссылки на файлы отчёта давать после каждого шага.
