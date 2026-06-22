# MEMORY.md

Shared, cross-cutting working-style preferences for the MAST team. Project-specific
context, design plans, and machine-specific notes deliberately do NOT live here —
durable engineering knowledge belongs in each repo's `CLAUDE.md` / `docs/`, and
in-progress or machine-local notes stay in each developer's local `~/.claude` memory.

## Feedback
- [Comment out, don't delete, when disabling temporarily](feedback_comment_dont_delete.md) — preserves position for re-enablement
- [Never run git writes/pushes unprompted](feedback_no_unprompted_git_writes.md) — no commit/push/rm/reset/rebase/tag without an explicit request in the current turn; read-only git is fine
- [Throwaway tests live outside module trees](feedback_throwaway_tests_outside_modules.md) — one-off assessments get a fresh top-level dir; never nest in a source module
