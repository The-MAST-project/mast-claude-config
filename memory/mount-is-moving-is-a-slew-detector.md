---
name: mount-is-moving-is-a-slew-detector
description: mount.is_moving is a slew detector (axis rms_error > 3"/1"), was wrongly used as a settle gate after offsets (now fixed)
type: project
---

`Mount.is_moving` (mount.py:295-298) is defined as `axis0.rms_error_arcsec > 3.0 or axis1.rms_error_arcsec > 1.0` — a servo following-error test, recomputed on a timer tick and cached. It means "a large/fast move is underway": True during slews/homing/parking, but **False during tracking, gradual offsets, and small discrete offsets** the servo keeps up with (PWI4 tracks with rms ≈ 0.0008"). It is a slew detector wearing the name `is_moving`.

**Suitable** uses (large moves): FindingHome/Parking/Slewing completion, MountActivities.Moving telemetry, post-`goto_ra_dec_j2000` slew guard.

**Was misused as a settle gate after offsets** — these read open and expose before settle. **ALL FIXED/REMOVED 2026-06-19** (migrated to `wait_until_settled`, see [[wait-until-settled-settle-gate-fix]]):
- ~~solving.py gradual-offset backstop~~ → all 4 approach_modes settle per-mode; global backstop deleted.
- ~~unit.py:779 — after discrete `mount_offset(ra_add_arcsec=…)`~~ → OFFSET_STEP.
- ~~unit.py:1079 / 1103 — after spiral offsets~~ → OFFSET_STEP.
- ~~acquirer.py:130 — `while stage/mount.is_moving` + blind `time.sleep(3)`~~ → SLEW (kept `stage.is_moving`, dropped the sleep(3)).

Extra race (why the heuristic was doubly unsafe): because it's recomputed asynchronously on a timer, a `while is_moving:` entered right after issuing a move can read the stale pre-move False and fall through.

**Current state:** no `is_moving` settle gates remain. Its definition (slew detector) now *fits* all remaining consumers — slew-completion checks (mount.py FindingHome/Parking/Slewing), `MountActivities.Moving` telemetry, and the autofocus guard (autofocusing.py, the mount just tracks during focus). Possible polish: route the three completion checks through PWI4-native `is_slewing` (what `wait_until_settled(SLEW)` already uses) to retire the rms heuristic; and the axis0>3.0/axis1>1.0 threshold asymmetry could be symmetrized + config-driven.

Source: review email "solve_and_correct" from Arie Blumenzweig, 2026-06-18, verified against code 2026-06-19 (repo MAST_unit.2024-12-12, branch eli/vm-provisioning). Line numbers drift between checkouts — verify before editing.
