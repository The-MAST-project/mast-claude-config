---
name: solve-and-correct-gradual-offset-channel-mismatch
description: Root cause of slow/erratic mount convergence — solve_and_correct polled axis0/axis1 progress after commanding ra/dec; FIXED 2026-06-19
type: project
---

**STATUS: FIXED 2026-06-19** (repo MAST_unit.2024-12-12, branch eli/vm-provisioning). First the channel was corrected (now polls `ra_arcsec`/`dec_arcsec`), then the whole settle path was migrated to [[wait-until-settled-settle-gate-fix]] — all 4 approach_modes now use `wait_until_settled`, which also guards the start-of-ramp race, and the global `is_moving` backstop is deleted. Compile/import verified; NOT yet hardware-verified. The below describes the original bug.

---

**Root cause of the reported slow/erratic mount convergence in `solving.py:solve_and_correct`** (the mode-2 gradual-offset path).

After a mode-2 correction the code commanded the **RA/Dec** offset channels (`ra_add_gradual_offset_arcsec`) but then waited on the **Axis0/Axis1** progress channels:
```
ra_progress  = st.mount.offsets.axis0_arcsec.gradual_offset_progress   # WRONG channel
dec_progress = st.mount.offsets.axis1_arcsec.gradual_offset_progress   # WRONG channel
```
PWI4 keeps six independent accumulators (`mount.offsets.{ra,dec,axis0,axis1,path,transverse}_arcsec`), each with its own total/rate/gradual_offset_progress. Commanding the RA channel leaves the Axis0 channel untouched, so the polled progress reads "complete" (≥1) at idle and `while ra_progress < 1 or dec_progress < 1` falls straight through. The `is_moving` backstop can't cover for it (a gentle ramp is tracked sub-arcsec, so is_moving stays False — see [[mount-is-moving-is-a-slew-detector]]).

Result: code re-exposes and re-solves while RA/Dec is still ramping → solver measures residual off a still-moving mount → next correction over/undershoots; mode 2 derives its rate from that transient residual and adds a fresh gradual offset with no reset → offsets stack and the loop hunts. Slow, occasionally divergent — matches the symptom.

**Fix direction:** poll the channel you commanded (ra_arcsec/dec_arcsec); guard the start-of-offset race (progress can still read the previous 1 for a tick — wait until it first drops below 1, or `total` changes, before waiting for it to climb back to 1); stop trusting is_moving for gradual offsets. Implemented via [[wait-until-settled-settle-gate-fix]].

🔎 **Confirmation test (still unverified on hardware):** issue `mount_offset(ra_add_gradual_offset_arcsec=20, ra_gradual_offset_rate=2)`, poll /status ~10s — `mount.offsets.ra_arcsec.gradual_offset_progress` should ramp 0→1 while `axis0_arcsec.gradual_offset_progress` sits still, proving the mismatch on this PWI4 build.

Related lower-priority items from the same review (not yet addressed): cos(dec) on RA delta may be inverted (🔎 dec 0/45/70° convergence test); mode 3 (GRADUAL_BY_TIME) does reset-then-add which double-counts; guiding reuses the acquisition path with max_tries=3 + sleeps; SolvingGuider.status() is a stub and cadence-sleep is misplaced.

Source: review email "solve_and_correct" from Arie Blumenzweig, 2026-06-18.
