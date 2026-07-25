---
name: MAST fleet topology — machines, IPs, mast-share, SSH access
description: MAST fleet machines, IPs, sites, SSH access, the mast-share Samba server, and the Windows per-session drive-mapping gotcha
type: reference
---

**Sites & machines (as of 2026-07-25, interim buildout):**
- **NS (Neot Smadar)** subnet `10.23.1.0/24`: units **mast00** `10.23.1.74`, **mast02** `10.23.1.102`; **mast-ns-control** `10.23.1.181` (Ubuntu, Samba). Also **mast-ns-spec** (Windows) `10.23.1.182` — `Z:` mapped to `\\10.23.1.181\mast-share` (persistent, creds mast/physics), `common` at `7a84400`. Gateway `10.23.1.254`.
- **WIS (Weizmann)** subnet `10.23.3.0/24`: unit **mastw** `10.23.3.72`. Gateway `10.23.3.254`. mast-wis-control + a WIS spec are being installed (not up yet).

**Naming caveat:** one control box has hostname `mast-wis-control` (and `/etc/hosts` maps it to 127.0.0.1) but by network identity it is `10.23.1.181` on the NS subnet and runs the active `smbd` serving `mast-share` — i.e. it is functionally **mast-ns-control**. Don't trust name resolution on it (it even resolves `mast-ns-control` to its own 10.23.1.181).

**mast-share (Samba on mast-ns-control / 10.23.1.181):** share `mast-share`, `security=user`, `guest ok = no`, `map to guest = bad user`, `valid users = mast`. Working creds: **user `mast`, password `physics`** (verified via smbclient). On Windows units it maps to drive **Z:** (`Filer.shared` = `Z:/MAST/<host>` when Z: mapped, else falls back to local `C:/MAST`). `D:` = RAM disk on units (real ramdisk), but on **mast-ns-spec `D:` is a plain local disk** (persistent), not a ramdisk.

**Interim cross-site mount (2026-07-25):** mastw `Z:` maps `\\10.23.1.181\mast-share` (NS control) across the router — route `10.23.3.254 -> 132.76.56.110 -> 10.23.1.181`, ~70 ms RTT, SMB/445 open. Command: `net use Z: \\10.23.1.181\mast-share /user:mast physics /persistent:yes`. Slower than a local share but works, until mast-wis-control is installed.

**SSH access:** `mast-ns-spec` and `mastw` accept key `~/.ssh/mast`; `mast00`/`mast02` need password `physics` (no key) — use paramiko. All fleet units/spec are **Windows** (cmd default shell, git + `py` present; pywin32 only in the unit venv, not system `py`).

**Windows per-session drive-mapping gotcha (IMPORTANT):** mapped network drives are per-logon-session. An OpenSSH session does NOT see the interactive/service session's mapped drives, so `GetLogicalDriveStrings` / `is_windows_drive_mapped("Z:")` / `os.path.isdir("Z:/...")` run over SSH do NOT reflect what the running MAST_unit/MAST_spec process sees. A `net use /persistent:yes` made over SSH only takes effect for the app after the interactive `mast` session re-logs on (or reboot). This determines whether `Filer.shared` resolves to Z: (defer-on-outage works) vs the C: fallback.

**mast02 layout differs:** repos under `C:\MAST\repos\` (MAST_unit.2024-12-12 on branch `calibration`, standalone MAST_common clone) via an automated pull-staging script `C:\mast-staging\mast-pull-staging.ps1`; not `~\PycharmProjects\`. See [[feedback_github_ssh_proxy]], [[feedback_no_proxy]], [[feedback_weizmann_proxy]].
