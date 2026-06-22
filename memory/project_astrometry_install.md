---
name: astrometry-install
description: "Current astrometry.net + Cygwin layout after ansvr removal — install paths, index location, Cygwin caveats."
metadata: 
  node_type: memory
  type: project
  originSessionId: 8efbf7e7-8a61-41a4-ab6b-a5da23946505
---

ansvr was uninstalled on 2026-05-25; astrometry.net 0.97 was built from source under Cygwin and installed to `/usr/local/astrometry` inside `C:\cygwin64`.

**Layout:**
- Binaries: `C:\cygwin64\usr\local\astrometry\bin\` (`solve-field.exe`, `astrometry-engine.exe`, `wcsinfo.exe`, `build-astrometry-index.exe`, etc.)
- Config: `C:\cygwin64\usr\local\astrometry\etc\astrometry.cfg`
- Index files: `D:\mast-indexes\` (~9.8 GB, 96 files; preserved across the ansvr removal, **do not delete** — costly to redownload). Referenced from astrometry.cfg as `add_path /cygdrive/d/mast-indexes`.
- Source tree: `C:\Users\labcomp2\Desktop\MAST\astrometry-build\astrometry.net-0.97.tar.gz` + `\home\labcomp2\build\astrometry.net-0.97` inside Cygwin.

**Why:** ansvr (`C:\Users\labcomp2\AppData\Local\cygwin_ansvr`) bundled an outdated Cygwin sandbox; user wanted a clean, up-to-date astrometry.net built against the system Cygwin (C:\cygwin64) instead.

**How to apply:** Invoke solver via `C:\cygwin64\bin\bash.exe -lc '/usr/local/astrometry/bin/solve-field ...'` (or set PATH to include `C:\cygwin64\usr\local\astrometry\bin`). Use cygwin-style paths (`/cygdrive/c/...`) for arguments. See [[cygwin-setup-network-quirk]] for the package install workaround.
