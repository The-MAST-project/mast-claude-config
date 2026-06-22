---
name: project-proxy-mode-explicit
description: "Proxy is selected via explicit --proxy-mode {weizmann,direct} flag, no longer auto-probed"
metadata: 
  node_type: memory
  type: project
  originSessionId: 8efbf7e7-8a61-41a4-ab6b-a5da23946505
---

The proxy mode for a provisioning run is chosen by the operator at run
time via `python vm/run-prov-test.py --proxy-mode {weizmann,direct}`
(default `weizmann`). The flag flows: `run-prov-test.py` ->
`build-mast.ps1 -ProxyMode` -> baked into `commands.json` as
`-ForceMode use|direct` on the proxy provider and `-ProxyMode use|direct`
on `astrometry-dependencies`.

**Why:** The earlier "soft probe" approach (briefly lived 2026-05-25)
detected reachability at runtime and was both unnecessary (operator knows)
and incomplete (cygwin setup-x86_64.exe still picked a proxy via WinINet
+ WPAD even with all registry/env cleared). Replaced 2026-05-26.

**How to apply:**
- Running from home (or any unit that can't reach bcproxy.weizmann.ac.il
  :8080): MUST pass `--proxy-mode direct`. Without it the run will set
  every proxy surface to bcproxy and downstream installs will fail.
- Running from on-campus: omit the flag (or pass `--proxy-mode weizmann`).
- "dev vs prod" is NOT the same axis as on-/off-campus; pick based on
  the unit's network reachability only.
- Banners `*** WEIZMANN-PROXY MODE ***` / `*** NO-WEIZMANN-PROXY (DIRECT)
  MODE ***` are printed by run-prov-test.py, build-mast.ps1, and the two
  affected providers, so the mode is visible at every layer.

See [[project-mast-provisioning-upstream]] for the surrounding repo
layout and DECISIONS.md 2026-05-26 entry for full rationale.
