---
name: sync-vault
description: Sync common/vault/ secrets from the authoritative MAST_control checkout to all other local and remote MAST_common checkouts
user-invocable: true
---

Sync the contents of `MAST_control/common/vault/` to every other checkout of `MAST_common`.

The `vault/` directory is listed in `.gitignore` and is never committed to git. This skill is the only mechanism for distributing its contents.

## Source (authoritative)

```
/home/mast/PycharmProjects/MAST_control/common/vault/
```

## Targets

| Location | Path |
|----------|------|
| local unit | `/home/mast/PycharmProjects/MAST_unit.2024-12-12/src/common/vault/` |
| mastw (unit, Windows) | `C:\Users\mast\PycharmProjects\MAST_unit.2024-12-12\src\common\vault\` via SSH |

When new machines (spec, additional units) become SSH-reachable, add a row to the table above.

## Step 1 — verify source exists and is non-empty

```bash
ls /home/mast/PycharmProjects/MAST_control/common/vault/
```

If the directory does not exist or is empty, stop and tell the user — there is nothing to sync.

## Step 2 — sync to all targets (run in parallel)

### Local unit

```bash
mkdir -p /home/mast/PycharmProjects/MAST_unit.2024-12-12/src/common/vault
rsync -av --delete \
  /home/mast/PycharmProjects/MAST_control/common/vault/ \
  /home/mast/PycharmProjects/MAST_unit.2024-12-12/src/common/vault/
```

### mastw (Windows via SSH)

```bash
ssh mastw "mkdir -p 'C:/Users/mast/PycharmProjects/MAST_unit.2024-12-12/src/common/vault'"
rsync -av --delete \
  /home/mast/PycharmProjects/MAST_control/common/vault/ \
  mastw:'C:/Users/mast/PycharmProjects/MAST_unit.2024-12-12/src/common/vault/'
```

If `mastw` is unreachable, report it as skipped and continue.

## Step 3 — report

For each target report:
- files transferred (from rsync output)
- whether it was already up to date
- if skipped (unreachable), say so
