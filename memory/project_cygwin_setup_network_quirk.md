---
name: cygwin-setup-network-quirk
description: Cygwin setup-x86_64.exe fails with WinINet error 12007 in this Claude Code session; manual install script bypasses it.
metadata: 
  node_type: memory
  type: project
  originSessionId: 8efbf7e7-8a61-41a4-ab6b-a5da23946505
---

`C:\cygwin64\setup-x86_64.exe` consistently fails with `connection error: 12007` (ERROR_INTERNET_NAME_NOT_RESOLVED) when launched from this shell — both with and without admin elevation, across all mirrors. PowerShell `Invoke-WebRequest` to the same URLs works fine. Root cause is unclear (possibly WinINet stack inheritance through the spawned setup process), so don't waste time fighting it.

**Why:** Investigated 2026-05-25 while installing build deps for astrometry.net. Tried `--no-admin`, `--only-site`, `--no-verify`, `--disable-buggy-antivirus`, multiple mirrors, `dangerouslyDisableSandbox`. All produced the same error.

**How to apply:** When packages need to be installed into `C:\cygwin64`, use `C:\Users\labcomp2\Desktop\MAST\cygwin-pkg-install.ps1` — it downloads `setup.xz` via PowerShell, parses `setup.ini`, resolves the dependency closure, and extracts each `.tar.zst` via Cygwin's `tar --zstd --force-local --no-same-permissions --no-same-owner --no-overwrite-dir`. Don't try `setup-x86_64.exe` from a Claude shell.
