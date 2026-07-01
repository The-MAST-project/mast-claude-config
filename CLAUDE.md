# mast-claude-config — overarching MAST LLM configuration

This repo holds the **project-wide** Claude/LLM configuration for the MAST team:
shared skills (`skills/`) and shared memory (`memory/`), symlinked into `~/.claude/`
by `setup.sh`. It is the home for guidance that applies across *all* MAST repos,
and every MAST repo's own `CLAUDE.md` references it as that source of truth.

## Where does a piece of information belong?

**Default: put it in the repo it's about.** Durable engineering knowledge — how a
subsystem works, gotchas, design rationale, per-repo conventions, calibration and
hardware findings — belongs in that repo's own `CLAUDE.md` / `docs/`, next to the
code it describes. It versions with the code, travels with it, and is found by
whoever works there.

**Put it here only if it is genuinely cross-cutting** — it applies in (almost)
every MAST repo regardless of which one you are in. Examples:
- team working-style preferences (how we want the assistant to behave),
- shared coding standards (e.g. a project-wide Python style guide),
- environment/access facts true everywhere (e.g. the Weizmann git proxy).

**When unsure, prefer the per-repo home.** Promoting a note here later — once it
has proved cross-cutting — is cheap. The reverse is not: per-repo specifics parked
in shared memory bloat every project's context and go stale where nobody working
the code will see them. This is exactly why the unit self-calibration / imaging
design notes moved out of `memory/` and into `MAST_unit/docs/`, while only the
truly global items (proxy, working-style) stayed.

## Layout

- `skills/` — reusable Claude Code skills (`/wip-commit`, `/wip-status`, `/sync-units`)
- `memory/` — shared, cross-cutting memories only (working-style, project-wide facts)
- `CLAUDE.md` — this file: what belongs here vs. in a per-repo `CLAUDE.md`
