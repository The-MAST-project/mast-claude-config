# mast-claude-config

Shared Claude Code skills and project memories for the MAST development team.

## Contents

- `skills/` — reusable Claude Code skills (`/wip-commit`, `/wip-status`, `/sync-units`)
- `memory/` — shared project memories (feedback preferences, project context, conventions)

## Setup

```bash
git clone git@github.com:The-MAST-project/mast-claude-config.git ~/mast-claude-config
cd ~/mast-claude-config
```

**Linux / macOS / Git-Bash:**
```bash
bash setup.sh [project-working-dir]
# e.g.  bash setup.sh /home/mast/PycharmProjects
```

**Windows (PowerShell):**
```powershell
.\setup.ps1 -ProjectDir 'C:\Users\you\Desktop\MAST'
```

This symlinks skills and memories into `~/.claude/` so they're available to Claude Code. Restart Claude Code after running.

The project working-dir argument tells the installer which `~/.claude/projects/<slug>/memory` to populate — the `<slug>` is how Claude Code encodes that path (separators and the drive `:` become `-`), so it differs per machine and cannot be hardcoded. If you omit the argument and only one project exists under `~/.claude/projects`, it is detected automatically.

## Keeping up to date

```bash
cd ~/mast-claude-config
git pull
```

Symlinks pick up changes immediately — no need to re-run `setup.sh`.

## Notes

- **Skills** are installed into `~/.claude/skills/`
- **Memories** are installed into `~/.claude/projects/<slug>/memory/`, where `<slug>` is derived from the project working-dir argument
- Local-only memory files (not symlinks) are never overwritten by either installer
- On Windows, symlinks require Developer Mode or an elevated shell; `setup.ps1` falls back to copying (re-run after `git pull`) when it can't create links
