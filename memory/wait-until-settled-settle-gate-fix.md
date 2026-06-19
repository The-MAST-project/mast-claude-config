---
name: wait-until-settled-settle-gate-fix
description: wait_until_settled(mode) Mount helper — implemented in mount.py and wired into all settle-gate sites (solving.py/unit.py/acquirer.py); not hardware-verified
type: project
---

`Mount.wait_until_settled(mode, *, channels, dist_tolerance_arcsec, stable_samples, start_grace_seconds, poll_seconds, timeout_seconds)` replaces the `while self.mount.is_moving: sleep()` settle idiom. Matches the wait signal to the move type, guards the start-of-motion race in every branch, and bounds every wait with a timeout (returns False on timeout, logged). **Implemented 2026-06-19 in mount.py** (repo MAST_unit.2024-12-12, branch eli/vm-provisioning):

- `SettleMode` enum (SLEW / OFFSET_STEP / OFFSET_GRADUAL) + module helpers `_max_dist_to_target_arcsec`, `_offset_channel` (guards PWI4 too old to report `mount.offsets`) sit just above `class Mount`.
- `Mount.wait_until_settled(...)` + private `Mount._wait_dist_settle(...)` added after the `is_tracking` property.
- **SLEW** (goto/find_home/park): confirm `mount.is_slewing` started, wait for it to clear, then `max|axisN.dist_to_target_arcsec| < tol` for N stable samples.
- **OFFSET_STEP** (discrete `ra/dec_add_arcsec`, spiral steps): wait for `dist_to_target` to spike (bounded grace so a sub-tolerance step doesn't hang), then settle below tol.
- **OFFSET_GRADUAL** (`add_gradual_offset_*`): Phase A waits for each **commanded** channel's `gradual_offset_progress` to first drop below 1 (or `total` to change) — the stale-"1" race guard — then Phase B waits for progress→1, then a brief dist settle. Reads `self.pw.status()` fresh each poll (no timer-staleness race).

**solving.py solve_and_correct: fully migrated.** The `approach_mode` if/elif chain was converted to a `match`/`case`; each case got its own settle gate; the global `while is_moving` backstop was deleted (only `end_activity(Correcting)` stays global):
- DISCRETE_STEP (1) → `OFFSET_STEP`
- GRADUAL_BY_RATE (2, the active mode) → `OFFSET_GRADUAL(channels=("ra","dec"))`
- GRADUAL_BY_TIME (3) → `OFFSET_GRADUAL(channels=("ra","dec"))`
- STEP_WITH_TRACKING_RATE (4) → `OFFSET_STEP` (discrete step waited; ongoing rate is servo-followed and persists by design, reads as settled)

The bare ints 1..4 were replaced by an `ApproachMode(IntEnum)` defined in acquisition.py (used as the match case labels and threaded through type hints in solving.py/acquirer.py); a `case _:` default logs an error and applies no offset. IntEnum keeps existing config/JSON/API int values valid. solving.py imports `from mount import SettleMode` (no import cycle — mount doesn't import solving).

**All other settle-gate sites migrated** (no `is_moving` settle gates remain anywhere): unit.py post-goto:637 → SLEW; unit.py discrete offset:779 → OFFSET_STEP; unit.py spirals:1079/1103 → OFFSET_STEP; acquirer.py:130 → SLEW (kept `stage.is_moving`, dropped the blind sleep(3)). `is_moving` now only serves slew-completion checks + telemetry — see [[mount-is-moving-is-a-slew-detector]].

**Remaining TODO:** `dist_tolerance_arcsec` (default 0.5) and `stable_samples` (default 2) are hardcoded, to be sourced from unit_conf; poll defaults to 1.0s to match existing cadence.

**NOT hardware-verified** — compile/import only. The confirmation test (does the ra/dec gradual ramp actually drive `ra_arcsec.gradual_offset_progress` 0→1 on this PWI4 build) still matters before trusting OFFSET_GRADUAL on-sky. Mode 4's continuous rate is assumed "settled once the step lands" — revisit if that rate ever needs to be waited out.

Fixes [[mount-is-moving-is-a-slew-detector]] and the [[solve-and-correct-gradual-offset-channel-mismatch]] backstop uniformly. Reference implementation origin: review email "solve_and_correct" from Arie Blumenzweig, 2026-06-18 (§5.1).
