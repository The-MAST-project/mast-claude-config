---
name: ps-build-mast-utf8-bom
description: build-mast.ps1 emits commands.json / build-manifest.json with a UTF-8 BOM; Python readers must use vm_lib.load_json_file (utf-8-sig) or parse_json_text
metadata: 
  node_type: memory
  type: project
  originSessionId: 904ecf42-382a-4d4c-bcfa-f752ead02c9c
---

`build/build-mast.ps1` writes the staged `commands.json` and `build-manifest.json` via PS 5.1's `Out-File -Encoding UTF8`, which prepends a UTF-8 BOM (EF BB BF). Plain `json.loads(path.read_text(encoding="utf-8"))` chokes on the leading U+FEFF.

This caused `interrupted-inject-fail` and `failure-recover-no-reset` to ERROR with `JSONDecodeError: Unexpected UTF-8 BOM` on 2026-05-16.

**Why:** the source-of-truth fix would be replacing `Out-File -Encoding UTF8` with `[IO.File]::WriteAllText($p, $json, (New-Object Text.UTF8Encoding $false))` in `build-mast.ps1`. Instead I added BOM-tolerant readers in `vm_lib.py` (`load_json_file`, `parse_json_text`, `dump_json_file`) so any future Python reader is safe regardless of how the file was written.

**How to apply:** any new Python code that reads a JSON file written by a PS script in this repo must go through `vm_lib.load_json_file` / `parse_json_text`. Do not call `json.loads(..., encoding="utf-8")` directly on PS-authored files.

Related: [[ps-winrm-exit-hang]]
