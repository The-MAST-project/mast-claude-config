---
name: sync-units
description: Push the latest MAST_common submodule to all unit development machines (local and remote)
user-invocable: true
---

Sync the `MAST_common` submodule from the authoritative local copy to all unit repos.

## Step 1 — ensure local common is pushed to GitHub

The authoritative branch for `MAST_common` is `master` on all machines (local and remote).

Check both local source repos for unpushed commits (run in parallel):

```bash
git -C /home/mast/PycharmProjects/MAST_control/common log --oneline origin/master..HEAD
git -C /home/mast/PycharmProjects/MAST_unit.2024-12-12/src/common log --oneline origin/master..HEAD
```

Push any that have unpushed commits:

```bash
git -C /home/mast/PycharmProjects/MAST_control/common push          # if needed
git -C /home/mast/PycharmProjects/MAST_unit.2024-12-12/src/common push  # if needed
```

If both have diverged from each other, warn the user and stop — manual merge resolution is needed.

Note: `MAST_unit.2024-12-12/src/common` may be on `main` or detached HEAD — ensure it is on `master` before checking. If the submodule is uninitialized (shown by `-` prefix in `git submodule status`), run `git -C /home/mast/PycharmProjects/MAST_unit.2024-12-12 submodule update --init src/common` first.

## Step 2 — pull on every unit repo

Repos to update (run all in parallel):

| Location | Path                                                                        |
|----------|-----------------------------------------------------------------------------|
| local    | `/home/mast/PycharmProjects/MAST_unit.2024-12-12/src/common`               |
| mastw    | `C:\Users\mast\PycharmProjects\MAST_unit.2024.12.12\src\common` (via SSH)  |

Commands:

```bash
# local
git -C /home/mast/PycharmProjects/MAST_unit.2024-12-12/src/common checkout master && git -C /home/mast/PycharmProjects/MAST_unit.2024-12-12/src/common pull

# remote (Windows — use cmd syntax)
ssh mastw "cd C:\\Users\\mast\\PycharmProjects\\MAST_unit.2024-12-12\\src\\common && git checkout master && git pull"
```

## Step 3 — report

For each target report: location, old commit SHA (before pull), new commit SHA (after pull), and whether it was already up to date.

## Notes

- If a remote host is unreachable, report it as skipped and continue with the others.
- When new unit machines are added in the future, add a row to the table above.
- The common submodule branch is `master`.
