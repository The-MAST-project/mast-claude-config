---
name: wip-status
description: Show git status, diff summary, and recent commits for all MAST projects
user-invocable: true
---

Run `git -C <project> status` in parallel for all four projects:
- `/home/mast/PycharmProjects/MAST_gui`
- `/home/mast/PycharmProjects/MAST_control`
- `/home/mast/PycharmProjects/MAST_spec`
- `/home/mast/PycharmProjects/MAST_unit.2024-12-12`

For any project that has uncommitted changes, also run `git diff --stat` and `git log --oneline -5` for that project.

Present the results with a heading per project. Skip projects with no changes.
</content>
</invoke>