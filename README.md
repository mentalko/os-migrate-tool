# os-migrate-tool

**English** (this file) · [Русская версия](README.ru.md)

Universal Linux environment packer (**arch ↔ debian**, e.g. Ubuntu → CachyOS)
via an external SSD: packages (per `mapping.toml` with commands per system
type), AppImages, dotfiles, user CLIs (npm/uv/pipx/bin — reinstalled), data
and AI-agent sessions, browsers.

Project internals — [docs/architecture.md](docs/architecture.md).
Instructions for the AI agent — [skills/os-migrate-tool/SKILL.md](skills/os-migrate-tool/SKILL.md).

## AI agent setup (`/init`)

On a **new system**, point your AI agent at this repo and paste the prompt:

```text
/init os-migrate-tool

0. If this repo is not on this machine yet, clone it first:
   git clone https://github.com/mentalko/os-migrate-tool.git
Read skills/os-migrate-tool/SKILL.md first — it is the operator manual
(agent workflow, commands, reports, rules). Then prepare the configuration
for me, this user:
1. Verify configs/inventory.yaml against this system: paths may differ
   (agent versions, session dirs — special attention to group_agents.sessions).
   Non-existent paths are skipped automatically; add a desc: entry for every
   new path.
2. Tune configs/selection.yaml for me: what travels by default, what stays
   off (heavy/optional). An ON sub-item travels even inside an OFF group.
3. Review configs/exclude_dirs.yaml (what never gets packed) and
   configs/mapping.toml (install commands per system type) if targets changed.
4. Never hardcode paths in pack.sh/unpack.sh — configs only. System code
   lives in src/, user configuration in configs/.
5. Show the resulting checklist defaults for my approval when done.
```

Details: [skills/os-migrate-tool/SKILL.md](skills/os-migrate-tool/SKILL.md) ·
internals: [docs/architecture.md](docs/architecture.md).

## What it packs

| Segment | Source (Ubuntu/debian) | Target (Cachy/arch) |
|---|---|---|
| `packages` | apt/flatpak/VS Code/dconf/cron/systemd-user lists | reinstall via pacman/yay per `mapping.toml` |
| `appimages` | `*.AppImage` from ~/Applications, ~/bin, ~/Desktop | → `~/Applications` |
| `dotfiles` | ~/.config, ~/.ssh, ~/.gnupg, shell rc, fonts, history | → $HOME |
| `data` | non-hidden home dirs: ~/Documents, Downloads, Desktop, Pictures, ~/bin | → $HOME |
| `agents` | AI-agent data — inventory in `inventory.yaml`; by default only zcode + opencode are selected (sessions, configs) | → $HOME |
| `programs` | user CLIs (npm/uv/pipx/bin): no files in the bundle — unpack runs commands from `mapping.toml` (`npm i -g cline`, `uv tool install …`) and prints links; `bin` binaries travel with dotfiles | reinstall |
| `browsers` | Chrome/Firefox profiles whole (on by default) | → $HOME |
| `flatpak` | flatpak app profiles (~/.var) | → $HOME |
| `toolchain` | rustup/nvm/bun/npm/vscode (off by default — reinstall) | → $HOME |
| `extra` | paperless-ngx, Sync, v2rayN (group off; v2rayN, paperless-ngx, Sync selected point-wise) | → $HOME |

Full list of paths and descriptions — `configs/inventory.yaml`; what is selected —
`configs/selection.yaml`.

## Usage

**On the source system (Ubuntu/debian):**
```bash
bash pack.sh                 # interactive: pick SSD → checklist → confirm → pack
bash pack.sh --dry-run       # full run without writing to the SSD
bash pack.sh --no-compress   # .tar bundle without compression: faster, instant
                             # seek-based selective unpack; ~raw size on SSD
bash pack-kitty.sh --dry-run # same in a separate kitty window + session log in /tmp (for the agent)
```

**On the target system (CachyOS/arch), straight from the SSD:**
```bash
bash /mnt/<ssd>/os-migrate-tool/unpack.sh              # interactive
bash unpack.sh all                                     # all bundle segments
bash unpack.sh dotfiles extra                          # by segment names
bash unpack.sh --packages --appimages                  # same with --
bash unpack.sh --dry-run agents                        # report without changes
```

> On FAT/exFAT/NTFS SSDs run via `bash pack.sh` — there is no executable bit
> on such filesystems.

## SSD layout after pack.sh

```
os-migrate-tool/
├── pack.sh  pack-kitty.sh  unpack.sh   # scripts
├── src/                                # lib.sh, tui.py, conf.py, progress-line
├── configs/                            # inventory.yaml, selection.yaml, exclude_dirs.yaml, mapping.toml
├── README.md  README.ru.md             # self-updates
├── skills/os-migrate-tool/SKILL.md     # AI-agent skill (self-updates)
└── archives/
    ├── 2026-11-14_ubuntu.tar.gz    # SINGLE bundle per run (.tar when
    │   │                           # --no-compress; inside — segments
    │   │                           # packages/, appimages/, dotfiles/, data/,
    │   │                           # agents/, browsers/, flatpak/, … + meta/
    │   │                           # with a backup copy of paths.tsv)
    ├── 2026-11-14_ubuntu.meta/     # manifest.txt (bundle sha256 + tree),
    │   │                           # paths.tsv, missing-mapping.txt
    │   │                           # (if lost — paths.tsv is restored
    │   │                           #  from the bundle automatically)
    └── latest -> 2026-11-14_ubuntu.tar.gz   # or latest.txt on FAT/exFAT
```

Multi-member gzip: segments are appended to the bundle, reads always use
`tar --ignore-zeros`. Selective unpack scrolls the bundle (slow), so home
segments are extracted in **one tar pass**.

## src/ — shared code and the TUI engine

Helpers (messages, dry-run, root check) — `src/lib.sh`; TUI — `src/tui.py`
on **curses (stdlib python, nothing to install)**: alternate screen (no
scrollback litter), viewport scroll for lists longer than the terminal,
correct redraw after resize. `src/conf.py` bridges configs into bash.
The bash TUI in `src/lib.sh` is a fallback when curses is unavailable.

## Configuration: inventory.yaml + selection.yaml (YAML subset, no hardcode)

Two files in `configs/`, parsed by `src/conf.py` (mini-YAML on stdlib —
2-space indents, `- ` lists, whole-line comments):

**`configs/inventory.yaml`** — full inventory; a group is `group_<name>`, with
sections inside (`home`/`config`/`sessions` for agents, `dirs`+`files` for
dotfiles, `paths` for the rest), `desc:` — item descriptions (what lives in a
directory). The config is the **full inventory**: everything is visible in the
checklist, non-existent paths are skipped automatically.

**`selection.yaml`** — default checkboxes, the tree mirrors the checklist:
```yaml
group_agents:
  on: true
  .zcode: true
  .config/Cursor: false

group_extra:
  on: false          # group is off…
  v2rayN: true       # …but the item is on — an ON item inside an OFF group travels
```
Sub-items not mentioned inherit the group's `on:`; manual checkboxes in the
checklist override everything. An ON sub-item travels even inside a disabled group.

## mapping.toml

`[packages.<ubuntu-name>]` with a status and install command for the target
system:
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
# url = "https://…"   # unpack prints the link at the end
```
- `native` → repo packages, `aur` → via yay, `manual` → by hand (url in the
  report), `skip` → not migrated
- No entry → the package is **silently not installed**, goes to `missing-mapping.txt`
- flatpak apps and appimages are not installed by the script: at the end a
  “name — link” list is printed (flathub / url from mapping.toml)

## Requirements

- bash ≥ 4.4, tar, lsblk, df — base system
- **python3** (mini-YAML parser conf.py + curses; present on Ubuntu and Cachy) —
  config parsing and TUI run on it; the bash TUI remains a terminal fallback
- Target systems: arch-like and debian-like (auto-detected)
- SSD format: FAT/exFAT/NTFS — fine (run via `bash pack.sh`; permissions/owners
  are stored inside tar.gz; the `latest` symlink falls back to `latest.txt`)
