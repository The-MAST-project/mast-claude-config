---
name: MAST_common sync rule
description: Any file changed under a common/ checkout must be synced to all other checkouts
type: feedback
---

MAST_common is checked out in multiple locations. Any change to a file under any `common/` must be synced to all other checkouts:

- `MAST_control/common/`
- `MAST_spec/common/`
- `MAST_gui/common/`
- `MAST_unit.*/src/common/`

**Why:** They are all checkouts of the same repository. Editing one without syncing the others causes divergence.

**How to apply:** After every edit to a file under any `common/` path, immediately apply the same change to the equivalent file in all other checkouts.
