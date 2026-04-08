# mast-claude-config

Shared Claude Code skills and project memories for the MAST development team.

## Contents

- `skills/` — reusable Claude Code skills (`/wip-commit`, `/wip-status`, `/sync-units`)
- `memory/` — shared project memories (feedback preferences, project context, conventions)

## Setup

```bash
git clone git@github.com:The-MAST-project/mast-claude-config.git ~/mast-claude-config
cd ~/mast-claude-config
bash setup.sh
```

This symlinks skills and memories into `~/.claude/` so they're available to Claude Code. Restart Claude Code after running.

## Keeping up to date

```bash
cd ~/mast-claude-config
git pull
```

Symlinks pick up changes immediately — no need to re-run `setup.sh`.

## Notes

- **Skills** are installed into `~/.claude/skills/`
- **Memories** are installed into `~/.claude/projects/-home-mast-PycharmProjects/memory/`
- Local-only memory files (not symlinks) are never overwritten by `setup.sh`
- The memory path assumes projects live under `~/PycharmProjects/` — adjust `setup.sh` if your layout differs
