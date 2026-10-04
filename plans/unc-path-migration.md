# Migrating the shared area from a mapped drive to UNC paths

> **Status: PLAN (2026-08-11), not implemented.** Replace the `Z:` drive letter with a
> UNC path derived from `controller_host`, and run the Windows services under an account
> that has rights on the share. Tracked as `MAST_common#26`. The two halves must land
> together: the path change alone fails under a service identity that cannot reach the
> share, and the identity change alone still depends on a drive letter that does not
> exist in session zero.

## The problem, in two halves

### 1. A mapped drive is not available to a service

A UNC path (`\\server\share\file`) is **not a mount**. Windows resolves it on demand
through the network redirector (MUP → SMB), using the calling process's credentials.
There is no mounting step and nothing to prepare.

A mapped drive letter *is* the closest thing to a mount: persistent, but **per-user and
per-logon-session**, implemented as a symlink in that session's DosDevices namespace. It
therefore does not exist in session zero, where services run — not even for the same
account with the same password.

So a mapped letter is useless to a service. The code must use the full UNC path.

### 2. The identity behind the path

This is the trap: **the same code works by hand and fails as a service.** Launched from a
desktop, UNC paths just work, because the redirector resolves them with the logged-on
user's credentials, which already have share rights. As a service the string is identical
and only the identity changes — and a service running as Local System reaches the network
as the *machine* account, which typically has no rights on the share.

The fix is the service **account**, not the path — but only once the path is UNC, since a
letter would not be there either way.

## Where the code stands today

`common/filer.py`:

```python
self.shared = (
    Location("Z:/", f"MAST/{socket.gethostname()}/")
    if is_windows_drive_mapped("Z:")
    else Location("C:/", "MAST/")          # <-- silent fallback to the local disk
)
```

Two consequences worth being explicit about:

- `is_windows_drive_mapped("Z:")` asks whether **this session** has the letter, which is a
  different question from "is the shared area reachable". A service can be perfectly able
  to reach `\\mast-ns-control\mast-share` while that returns `False`.
- The fallback is **quiet**. Products then go to the local disk and nothing reports it.

### Evidence worth checking before anything else

On `mast00`, `C:\MAST` holds a long run of dated folders (2025-09-26 onward, observed
2026-08-11). That is consistent with the fallback having been taken — products written
locally rather than to the share — but it is **not proof**: `C:/MAST/` is also
`Filer.local`, and the `ram` root falls back there too when `D:` is unmapped.

Determine, on a unit, with the service running:

1. what identity the service runs as (Local System, or a named account);
2. whether `Z:` is visible **to the service**, not to an interactive shell;
3. whether `Filer().shared.root` resolves to `Z:/…` or `C:/MAST/` in the service process.

If (3) is `C:`, this migration is not an improvement but a **repair**, and the products
already on `C:\MAST` across the fleet need relocating.

## Target state

Derive the share from configuration rather than a letter. `controller_host` is already the
single source of truth (and already correct: `mast-ns-control`):

```
\\<controller_host>\<share>\MAST\<hostname>\
```

The controller serves the tree the Linux side sees as `/Storage/mast-share/MAST/`, so the
share name is expected to be `mast-share` — **confirm this**, it has not been verified.

Note the `<hostname>` component stays: the controller addresses per-machine subdirectories
(`DataServer.storage_root / <unit_name>`), and `Filer.shared.root` already ends with it.

## Steps

1. **Confirm the identity question above.** It determines whether this is an improvement
   or a repair, and whether stranded products need collecting.
2. **One service account** with rights on the share. Grant it *Log on as a service*.
3. **Point each NSSM service at it.** The setting is `ObjectName`:
   - GUI: `nssm edit <service>` → *Log on* tab
   - CLI: `nssm set <service> ObjectName <DOMAIN\user> <password>`

   `ObjectName` requires **both** username and password — NSSM rejects a username alone.
   Use the domain-qualified form. NSSM/LSA usually grants the logon right itself; if the
   service will not start, check that first. Mind special characters in the password
   (leading `$`, spaces): quote carefully or NSSM's argument concatenation mangles it.
4. **Change `Filer` to build the shared root as a UNC path** from `controller_host` and
   `domain`, with no drive letter anywhere.
5. **Make the fallback loud.** If the share is unreachable, say so. A silent demotion to
   the local disk is how this could have gone unnoticed for a year.
6. **Retire `is_windows_drive_mapped`** for the shared area. `is_accessible()` already
   answers the real question and is already wrapped in a timeout against a hung redirector.
   (The `D:` check for the ram area is a separate question — that is a local disk, and the
   letter is genuine there.)

## Open questions

- **Are the machines domain-joined?** The plan above assumes a domain account. `domain =
  "weizmann.ac.il"` in the bootstrap config is a *DNS* domain and does not settle it. In a
  workgroup the equivalent is matching local accounts (same username and password) on both
  ends, or credentials stored per-machine — which is materially more fiddly to maintain
  across twenty units.
- **Share name**, as above.
- **What to do with products already on `C:\MAST`** if the fallback has been active. The
  `product_relocation_sweeper` (`MAST_common#52`) relocates from the *ram* root, not from
  `local`, so it will not collect these on its own.
- **Reconnect behaviour.** A UNC path keeps no persistent handle, so after an idle period
  or a server restart the first access pays reconnect cost and may fail once before
  succeeding. `Filer`'s deferral and sweeper already handle that shape of transient, but it
  is worth confirming the timeout in `is_accessible()` (2 s) is generous enough.

## Related

- `MAST_common#26` — the issue this plan serves
- `MAST_common#52`, `#56` — the ram→shared lifecycle and cross-process claims that sit on
  top of whatever the shared root turns out to be
- `MAST_spec#2` — remote connection to the `Z:` folder, the same problem from the spec side
