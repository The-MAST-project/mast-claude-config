---
name: mount-is-moving-is-a-slew-detector
description: "PWI4 rms-based `Mount.is_moving` is a tracking-QUALITY signal, not a motion one — in wind it reads True while parked on target, so any `while mount.is_moving` loop stalls"
metadata:
  node_type: memory
  type: project
  originSessionId: 1592230a-f3a1-428c-9520-a1d1fc2f4a13
---

Applies to `MAST_unit` (`src/mount.py`). Moved here from local project memory
2026-07-21 at Arie's request; the repo's own `CLAUDE.md` carries the short
version under "Mount offsetting: settle on the channel you commanded".

## What it is

`Mount.is_moving` is `axis0.rms_error_arcsec > 3.0 or axis1.rms_error_arcsec > 1.0`
— a servo following-error test, recomputed asynchronously on the mount's timer
thread and cached.

**The thresholds are deliberate — do not "fix" them away.** Arie added them
because he did not fully trust the PWI4 status, and to **emulate PWI4's GUI**,
which shows an axis green only when its RMS falls below ~1.0" (yellow/red
above). So the rms test is a legitimate **tracking-quality** signal that merely
happens to be named `is_moving`.

`mount.geometry == 1` (equatorial), verified 2026-07-21 — so axis0≈RA,
axis1≈Dec, and the intended mapping is correctly implemented. axis1/Dec at the
1.0" threshold is the binding constraint in practice.

## The bug is the conflation, not the thresholds

One name answers two orthogonal questions:

| Question | Right source | Character |
|---|---|---|
| Is a commanded move underway? | PWI4 `is_slewing` | deterministic, weather-independent |
| Is tracking good enough to expose? | axis rms vs thresholds | weather-driven; correctly says "no" for minutes in wind |

Code that asks the first question and reads the second answer stalls.

## MEASURED 2026-07-21 on mast02 (windy): gust-dependent, True most of the time

Sampled live over 20s, mount tracking **on target**, `is_slewing=False`:
axis0 rms swung **1.36–3.81"**, axis1 rms **1.00–6.40"** → `is_moving` read True
in **6 of 7 samples**, clearing only in a lull. `dist_to_target` over the same
window swung **0.06–5.89"** per axis.

This **overturns** the "PWI4 tracks with rms ≈ 0.0008\"" figure from the
2026-06-18 review email (that number was not from this hardware). Consequence:
`while mount.is_moving:` is **weather-dependent** — instant on a calm night,
stalling for minutes or indefinitely in wind. Not theoretical: it held
`/calibrate/focuser` right after "started activity Slewing" on 2026-07-21, then
released when the wind dropped. (A single earlier sample of 3.24"/1.55" prompted
a "permanently stuck" claim — that was wrong: it is gusty, not stuck.)

Corollary: because following distance itself gusts to ~5.9",
`wait_until_settled`'s 0.5" default tolerance is unusable here — calibration
slews pass **10.0"** (`src/calibration/phases/slewing.py`).

## Where it stands in the code

Settle gates after offsets were all migrated to `wait_until_settled` on
2026-06-19 (solving.py, unit.py discrete + spiral, acquirer.py). The extra race
that made the old idiom doubly unsafe: recomputed on a timer, a `while
is_moving:` entered right after a move can read the stale pre-move False and
fall straight through.

Two `while mount.is_moving` loops were then re-introduced by the calibration
work and **fixed 2026-07-21** — both now call `slew_and_settle()` in
`src/calibration/phases/slewing.py`:
- `calibration/phases/focuser.py` `_goto`
- `calibration/phases/stage.py` (pre-sweep slew)

**Still open — the operational path:** `autofocusing.py:230-231` is
`while stage.is_moving or mount.is_moving or focuser moving`. By this
measurement it stalls the ps3cli autofocus in wind. Reported 2026-07-21, left
unfixed pending Arie's decision (observing path, not calibration).

**Unverified suspicion:** the ontimer transitions ending Slewing / FindingHome /
Parking on `not is_moving` inherit the same weather dependence, so those
activities may linger after the move finished — and the Parking branch calls
`power_off()` / sets `_was_shut_down`, so a windy shutdown could stall. Never
confirmed: rms behaviour while parked with tracking OFF was not measured.

## DEFERRED, agreed 2026-07-21

Split `is_moving` into `is_slewing` (motion) plus `tracking_quality` /
`tracking_rms_ok` (green/yellow/red + raw per-axis values, matching the GUI).
Keep the rms signal — never in a `while` loop: use it as a *bounded*
pre-exposure gate and/or stamp it into the FITS header, so windy frames are
rejected in **analysis** rather than stalling acquisition. Deferred so the
calibration run could proceed; it touches `mount.py` and the operational
`autofocusing.py`.

Related (local project memory, not in this repo): `wait-until-settled-settle-gate-fix`.

Source: review email "solve_and_correct" from Arie Blumenzweig, 2026-06-18;
verified against code 2026-06-19; corrected by live measurement 2026-07-21.
