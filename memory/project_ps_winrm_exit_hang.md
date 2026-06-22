---
name: ps-winrm-exit-hang
description: "Two distinct causes for \"unit finished but run_ps keeps ticking\" symptom: (1) historical unit-side PSEventJob teardown hang, and (2) recent host-side pywinrm Receive sitting on a half-dead TCP socket. Diagnose before fixing."
metadata:
  node_type: memory
  type: project
  originSessionId: 904ecf42-382a-4d4c-bcfa-f752ead02c9c
---

Symptom: `run-prov-test.py` shows `Cycle N ERROR: HTTPConnectionPool ... Read timed out` and the streamed unit log shows the provisioning summary ("Failed: 0", "LEASE_RELEASE ...") well before the host timeout fired. Looks like a hang at the very end of the unit-side run.

There are **two different bugs** with this same surface symptom — never assume which one without checking.

### Cause A (resolved 2026-05-16): unit-side PSEventJob teardown
`Register-ObjectEvent` / `Register-EngineEvent` / `System.Timers.Timer` subscribers don't drain before `powershell.exe` returns its WinRM response. Documented in `MAST_provisioning/CLAUDE.md` DO NOT list. Original instance was the lease renewer in `execute-mast-provisioning.ps1`; that renewer has been removed (see DECISIONS.md 2026-05-16). If you see this signature *and* the unit-side `Get-Process wsmprovhost` confirms the worker is still alive after `LEASE_RELEASE` was logged, audit the script for newly-added event subscribers / timers and move them to a child `Start-Process` per CLAUDE.md guidance.

### Cause B (resolved 2026-05-17): host-side pywinrm hangs on a stale TCP socket
The recent occurrence of this symptom was actually host-side, not unit-side. `vm_lib.winrm_session()` was setting `operation_timeout_sec` to the full 1 h script ceiling, so pywinrm parked on a single mega-Receive for up to an hour. A long silent stretch during heavy install IO + a transient TCP glitch left the socket half-dead; the Receive never returned even though the unit's `wsmprovhost` had already exited cleanly. Fixed by:
- `_WSMAN_OP_TIMEOUT_S=60`, `_WSMAN_READ_TIMEOUT_S=120` in `vm_lib.py` (short WSMan polls, decoupled from the heartbeat-thread script ceiling)
- New `_resilient_get_command_output` that retries `Receive` against the same `shell_id`+`command_id` on transient HTTP failures, evicting the local `requests.Session` connection pool first
- `_resilient_run_ps` replacing `session.run_ps()` so `run_ps` survives transient WinRM hiccups

### Diagnostic flow

**Always triage before fixing.** Run on the unit while the symptom is live:

```powershell
Get-Process powershell, wsmprovhost -ErrorAction SilentlyContinue | Format-Table Id, ProcessName, StartTime, CPU -Auto
```

- `wsmprovhost` (or the PS worker with the right PID) still alive → Cause A territory (unit-side teardown hang).
- No `wsmprovhost`, only an interactive `powershell.exe` → Cause B territory (host-side pywinrm orphaned on a dead socket).

Also useful: the unit-side `TEARDOWN reached_exit_point` / `inventory event_subscribers=N ps_jobs=N` / `exit_code=N` breadcrumbs at the bottom of `execute-mast-provisioning.ps1`. If those three lines are present in `provisioning-execute.log`, the unit-side script exited cleanly — meaning the stall is host-side. Their presence in 2026-05-17 logs is what localized Cause B.

### Do not just bump the WinRM timeout
That only hides whichever cause is active. Heard once-and-for-all on 2026-05-17 — the `[Environment]::Exit($code)` workaround that was added on the unit side to "guarantee fast exit" actually masked Cause B for a while and made it look like a unit problem.

Related: [[ps-build-mast-utf8-bom]]
