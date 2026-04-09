---
name: sync-vault
description: Verify the MAST vault is accessible on all unit machines (vault is a Samba share, no file copying needed)
user-invocable: true
---

The MAST vault is a shared network location — no file copying is needed. All machines mount it directly.

## Vault location

| Machine | Path |
|---------|------|
| mast-wis-control (local, authoritative) | `/Storage/mast-share/MAST/.mast-vault` |
| unit machines (Windows, via Samba) | `Z:\MAST.mast-share\.mast-vault` |

The Samba share is exported from mast-wis-control and mounted on all unit machines as `Z:\MAST.mast-share`.

## Step 1 — verify vault exists and is non-empty on local machine

```bash
ls /Storage/mast-share/MAST/.mast-vault
```

If missing or empty, stop and tell the user.

## Step 2 — verify vault is accessible on each unit machine (run in parallel)

```bash
# mastw
ssh mastw "dir Z:\\MAST.mast-share\\.mast-vault"
```

If a host is unreachable, report it as skipped.

## Step 3 — report

For each machine report: accessible / not accessible / skipped (unreachable), and list the files visible in the vault.
