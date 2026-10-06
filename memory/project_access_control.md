---
name: MAST access control — Django is the sole permissions authority
description: Team decision 2026-10-06 (Arie Blumenzweig): users and permissions live only in the Django GUI; normal requests go browser → GUI → backend; backends take API keys; personal keys for engineers and operators only
type: project
---

**Team decision, 2026-10-06; authority Arie Blumenzweig.** Applies in every MAST repo that touches users, permissions or
backend calls (`MAST_gui`, `MAST_control`, `MAST_unit`, `MAST_spec`, `MAST_common`).

- **Django is the only identity and permission store.** Users, groups and `accounts.can_*`
  permissions live in the GUI's database. Nothing else carries permissions: the Mongo `users` /
  `groups` config collections are being removed
  ([MAST_common#146](https://github.com/The-MAST-project/MAST_common/issues/146)) — do not read,
  extend or reintroduce them.
- **The GUI is the normal route.** Browser → Django → backend: Django authenticates the user,
  checks the permission, then makes the backend call itself. Do not add browser-to-backend calls;
  the existing ones (`MAST_gui/static/js/api.js`, port 8002) are being retired.
- **Backends authenticate by API key** and hold no user data. Engineers and operators hold
  personal keys for direct calls — an exception for running and maintaining the system, not the
  normal route. Mechanism: [MAST_unit#45](https://github.com/The-MAST-project/MAST_unit.2024-12-12/issues/45).
- **The GUI's permission layer gets rebuilt** as a clean shell over the backends. Its current
  camelCase checks (`canView`, `auth.canUseControls`, …) match no real permission and pass only
  for Admins — a known defect, not a pattern to copy.

Full statement, with its open questions: `plans/api_design_guidelines.md` §2 and §6 Q5.
