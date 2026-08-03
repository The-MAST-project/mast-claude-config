---
name: Integration branch per MAST repo — not always `main`
description: MAST_common, MAST_control and MAST_spec integrate on `master`; the rest on `main`. Never assume `main`; check before branching or diffing.
type: reference
---

The MAST repos do **not** share one default branch name. Assuming `main` everywhere
silently produces work based on the wrong ref, or a diff against a branch that does
not exist.

| Integration branch | Repos |
| --- | --- |
| `master` | `MAST_common`, `MAST_control`, `MAST_spec` |
| `main` | `MAST_unit.2024-12-12`, `MAST_gui`, `MAST_provisioning`, `MAST_config_db`, `mast-claude-config` |

`MAST_common` and `MAST_control` used to carry a vestigial `main` alongside `master` —
a 2024 stub that was never an ancestor of `master` and was never developed on. Both
were **deleted upstream on 2026-08-02** and the GitHub default set to `master`, so
`origin/main` no longer resolves in those repos. A local `main` there is a leftover
from an older clone and can be deleted.

All of these live at `github.com/The-MAST-project/<repo>`, reached through a single
remote named `origin` — there is no `upstream` remote any more. If a checkout still
has `origin` = a personal fork plus `upstream` = The-MAST-project, it predates the
2026-08-02 fork retirement: `git remote remove origin && git remote rename upstream origin`.

When in doubt, ask git rather than guessing: `git remote show origin | grep HEAD`.
