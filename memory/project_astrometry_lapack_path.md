---
name: project-astrometry-lapack-path
description: "When invoking C:\\cygwin64\\usr\\local\\astrometry\\bin\\solve-field.exe from Windows, PATH must include both C:\\cygwin64\\bin and the cygwin POSIX path /usr/lib/lapack — otherwise removelines fails with numpy ImportError"
metadata: 
  node_type: memory
  type: project
  originSessionId: c25d4914-72eb-4065-9b26-32180929589b
---

When running cygwin `solve-field.exe` from a Windows shell (PowerShell,
Python `subprocess.run`, etc.), the spawned `removelines` Python script
imports numpy, which loads `_umath_linalg.cpython-39-x86_64-cygwin.dll`,
which depends on `cyglapack-0.dll`. That DLL lives at
`C:\cygwin64\lib\lapack\cyglapack-0.dll`, NOT in `C:\cygwin64\bin`.

The canonical fix (from `MAST_unit.2024-12-12\src\solvers\mastrometry.py:130`):

```python
env["PATH"] = r"C:\cygwin64\bin" + os.pathsep + "/usr/lib/lapack" + os.pathsep + env.get("PATH", "")
```

The POSIX-style entry `/usr/lib/lapack` works because cygwin1.dll
re-parses Windows PATH at process startup and accepts cygwin POSIX
paths in it.

**Why:** Without `/usr/lib/lapack` on PATH, every solve fails with
`ImportError: No such file or directory` from numpy.linalg, augment-xylist
reports "Command failed: return value 1" for removelines, and no
`.solved` marker is produced. See [[project-astrometry-install]] for the
install layout. Hit during astro-perf harness development - the verify
script gets away without it (`verify-astrometry.ps1:41`) because... it
just does, apparently, but production code and any new wrapper must
include the lapack POSIX path.

**How to apply:** Any new Windows-side wrapper around `solve-field.exe`
must prepend both `C:\cygwin64\bin` and `/usr/lib/lapack` to PATH before
spawning the solver. Just adding `C:\cygwin64\bin` is not enough.
