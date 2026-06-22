---
name: feedback-cygwin-cfg-crlf
description: "Config files read by cygwin programs (astrometry-engine, etc.) must be written with LF-only line endings — PowerShell Set-Content's default CRLF causes opendir/open to fail with a trailing \\r appended to the value"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: c25d4914-72eb-4065-9b26-32180929589b
---

When a PowerShell script writes a config file that a cygwin binary will
read line-by-line, the file MUST use LF-only line endings. CRLF leaves
a trailing `\r` on the value, and cygwin code like
`opendir("/cygdrive/d/mast-indexes\r")` returns ENOENT silently.

`Set-Content -Encoding ASCII` writes CRLF on Windows. The fix is to use
.NET directly:

```powershell
$body = "cpulimit 300`nadd_path $cygIndex`nautoindex`n"
[System.IO.File]::WriteAllText($CfgPath, $body, [System.Text.Encoding]::ASCII)
```

**Why:** Lost ~30 minutes debugging astrometry-engine reporting
`failed to open index directory: "/cygdrive/d/mast-indexes"` plus
`You must list at least one index in the config file` when the path
clearly existed and cygwin's own `ls` could see it. `xxd` on the cfg
showed `0d 0a` line endings; the engine was opening the literal path
with a trailing CR. astro-perf harness wrote the cfg with
`Set-Content` like verify-astrometry.ps1 does.

**How to apply:** Any time a PS script produces a file consumed by a
cygwin program (cfg, shell script, list of paths), write it via
`[System.IO.File]::WriteAllText` with explicit `\n` separators, not
`Set-Content` / `Out-File`. This also applies to UTF-8 BOM concerns
covered in [[project-ps-build-mast-utf8-bom]].
