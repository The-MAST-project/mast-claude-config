# Focuser Calibration — Feature Summary

*Companion to `self-contained-hfd-autofocus.md` (design) and
`calibration_orchestration.md` (how the three phases are sequenced).  This
document is the **commissioning summary**: what the focus phase is for, how it
works, and what it was measured to do on sky on the nights of 2026-07-20/21/22
at Neot Smadar (unit mast02).*

---

## 1. Motivation

MAST already had an autofocus: the **ps3cli / PWI4** path (`autofocusing.py`),
which drives PlaneWave's PlateSolve3 over a small acquisition ROI.  The focuser
*calibration* phase exists for a different job:

- **A self-contained focus measurement** that owns its own sweep and analysis,
  depending on no external solver process — so it can be reasoned about,
  replayed offline, and validated frame-by-frame.
- **A calibration *product*** (`calibration.products.focuser`: best position,
  empirical CFZ, achieved star diameter, temperature) with provenance, that the
  other calibration phases build on: **optical-centre coma is only clean at best
  focus**, so focus must be established first, and the stage-geometry phase
  inherits that focus.
- **Full-frame, low-coma-restricted** measurement rather than a small ROI: the
  metric is computed over the whole detector but limited to the low-coma disk,
  which is the region the science cares about.

It deliberately does **not** touch `focuser.known_as_good_position` — that is the
ps3cli path's operational value.  The two focus systems share no state; each
seeds only from its own.

## 2. Algorithms

The phase runs **triage → (acquisition if far) → V-curve → fit → persist**.

### Phase 0 — regime triage (`hfd.assess_focus_regime`)
One frame at the seed is classified **near** / **far** / **empty**:
- **near** — a usable point-source HFD below `near_hfd_max_px` → go straight to
  the V-curve.
- **far** — structure present but no point-source HFD (large defocus donuts) →
  donut acquisition.
- **empty** — nothing extracted → cold-start coarse stepping.

### Acquisition when far from focus
- **Donut path** (`donut.plan_donut_jump`): a differential probe move
  (`donut_probe_ticks`) measures the donut diameter-vs-defocus slope and its
  sign, then makes one **informed jump** toward focus.  Because it extrapolates
  a trend, a single jump covers a lot of ground.
- **Cold-start** (`_cold_start`): when nothing extracts at all, step outward and
  inward in growing multiples of `coarse_step_ticks` (±1000, ±2000, …) up to
  `coarse_max_steps`, i.e. **±4000 ticks** from the seed, until structure
  appears.

### Phase 1 — the HFD V-curve (`vcurve.analyze_focus_samples`)
`images` frames (odd, so one sits at the centre) spaced `spacing` ticks apart,
approached from below by `backlash_ticks` to take up backlash.  The key idea:

- Stars are **cross-matched into a consistent set across all frames of the
  sweep** (`hfd.measure_sweep_hfd`), and HFD is measured at those fixed
  positions in every frame.  Detecting each frame independently and taking a
  median lets the star set wobble frame-to-frame, which buries the (often
  shallow) curve — cross-matching is what produces a clean, fittable V.
- The measurement is restricted to the **low-coma disk** — the optical-centre
  disk when the unit is calibrated, else a geometric `fallback_disk_frac` disk.
- The fit is a **parabola in squared diameter**, `D² = a·x² + b·x + c`, with the
  vertex at `-b/2a` the best focus.  `tolerance` (the empirical **Critical Focus
  Zone**) comes from the `tolerance_frac` rise of the fitted diameter.

### Re-centring and plausibility
If a sweep does not **bracket** focus (straddle the vertex), the swept arm is
extrapolated to its floor and the sweep re-centred, undershooting by
`recentre_undershoot_frac` (landing short still brackets next time; overshooting
does not), capped at `max_recentre_ticks` per jump, over `max_tries` sweeps.
A fitted vertex whose achieved diameter exceeds `max_best_hfd_px` is **rejected
as implausible** (a sweep over donuts can produce a spurious interior minimum),
and the run keeps acquiring rather than persist a confident-but-wrong answer.

### Cross-validation with PWI4
On 2026-07-22, PWI4's own autofocus and this phase were run independently against
the same optics.  **PWI4: 11977.  This phase: 12013.  Agreement: 36 ticks —
well inside the measured 49-tick CFZ.**  Two unrelated methods, one focus.

## 3. Measured performance (on sky, 2026-07-22)

**Reference focus 12013, empirical CFZ ≈ 49 ticks.**

### Repeatability — the solid result
Eight independent runs of the phase (each fired with `force=true`), all seeded
near focus (see the methodology note below):

| run | best focus | error vs ref | within CFZ |
|---|---|---|---|
| 1 | 12025.5 | +12.5 | yes |
| 2 | 12004.4 | −8.6 | yes |
| 3 | 12018.8 | +5.8 | yes |
| 4 | 12031.2 | +18.2 | yes |
| 5 | 12036.2 | +23.2 | yes |
| 6 | 12038.9 | +25.9 | yes |
| 7 | 12050.3 | +37.3 | yes |

(One further run failed — a **focuser stall**, hardware; §6.)

**Seven solves span ~46 ticks — about one CFZ — and every one lands within the
CFZ of the reference.**  This is the headline: the pipeline is *precise and
repeatable*.  The individual V-curve samples are measurably scattered (the curve
bottom is noisy), but the parabola fit averages them out and the vertex is set
by the arms, so the run-to-run vertex scatter stays inside the CFZ.  PWI4's
independent autofocus (11977) sits 36 ticks from the mean — cross-validation
across two unrelated methods.

Per-run time was ~230–830 s; the spread is run-to-run luck in how quickly a
sweep brackets, **not** a function of start distance (see below).

### Methodology note — what was NOT measured, and why (important)
The convergence campaign was designed to park the focuser at large offsets
(±1200, ±3000) and confirm the phase walks back to focus.  **It did not test
that.**  `_seed_position` (`phases/focuser.py`) seeds the Phase-0 probe from
`calibration.products.focuser.best_position` **whenever a product exists**, and
ignores the current focuser position.  Once the first solve wrote the product
(12013), every subsequent run seeded at 12013 regardless of where the harness
parked the focuser — confirmed by the saved probe frames (all at 12031–12039,
never at the parked 13212/9013/15012).

So the eight runs are eight *repeatability* measurements near focus, not a
capture-range sweep.  **Capture range remains untested on sky.**  To actually
test it, the product must be absent or bypassed on each run — the phase's own
docstring notes this ("exercise on sky by parking the focuser well out of focus
on purpose", which only works before a product exists).  A `?seed=` /
`?ignore_product=` override on the endpoint would make the test possible without
deleting the product each time.

## 4. Capture range — estimated, NOT yet measured

Tonight established repeatability, not reach.  What follows is *reasoning*, to be
confirmed by a proper capture-range test (§3 methodology note).

Three boundaries apply, and which one binds depends on what the **probe frame**
sees, not on raw distance:

1. **Donut detectability (the physical wall).**  Defocus spreads each star into a
   donut whose diameter grows ~linearly with defocus, so surface brightness falls
   ~1/diameter²; eventually the donut sinks below detection and *no algorithm can
   measure what it cannot detect*.  This is set by the star field, not the code,
   and is expected to be the true outer limit.
2. **Cold-start reach — a hard ±4000 ticks from the start** (`coarse_step_ticks`
   × `coarse_max_steps`), but this only bites once the probe reads *empty*, i.e.
   once you are already past boundary 1.  While donuts are visible you are in the
   long-reach donut path; once they vanish you fall into ±4000 of blind stepping.
3. **Re-centring reach** — a *near*-classified but non-bracketing sweep
   extrapolates its arm, capped at `max_recentre_ticks` (2000) per jump over
   `max_tries` (3) sweeps.

**Detectability data available so far is insufficient to place the wall**: every
saved frame is within ~770 ticks of focus (because every run stayed near focus,
per §3), where detection is healthy — **~1800–2500 sources per frame, roughly
flat** — with no fall-off yet visible.  The wall is far beyond ±770; tonight's
frames simply do not reach it.  Measuring it needs frames taken *far* from focus,
which needs the capture-range test above.

Capture range is also partly a *config* choice — `coarse_max_steps`,
`coarse_step_ticks`, `max_recentre_ticks` set the reach and can be widened.  And
in practice the more likely killer than defocus range is the **focuser stall**
(§6), which is hardware.

## 5. Tunables (`calibration.settings.focuser`, live values 2026-07-22)

| setting | value | role |
|---|---|---|
| `exposure` | 5.0 s | per sweep frame |
| `binning` | 1 | HFD is relative, so a binned sweep still finds the vertex; low-coma disk is bin-1 |
| `images` | 7 | V-curve points; must be **odd** so a point sits at the centre |
| `spacing` | 150 | ticks between points → sweep ±450.  **Tuned up from 50** (±150 was too flat to bracket) |
| `max_tries` | 3 | re-centred sweeps before giving up |
| `tolerance_frac` | 0.025 | fitted-diameter rise that defines the CFZ |
| `fallback_disk_frac` | 0.6 | low-coma disk when no optical centre exists |
| `near_hfd_max_px` | 20.0 | Phase-0 near/far threshold (single-frame HFD scale) |
| `max_best_hfd_px` | 35.0 | plausibility ceiling (cross-matched HFD scale).  **Tuned 12→25→35** — see §6 |
| `backlash_ticks` | 200 | approach every sweep from below by this much |
| `donut_probe_ticks` | 500 | differential move that calibrates the donut slope |
| `coarse_step_ticks` | 1000 | cold-start step size |
| `coarse_max_steps` | 8 | → cold-start reach ±4000 |
| `recentre_undershoot_frac` | 0.15 | deliberately land short so the next sweep still brackets |
| `max_recentre_ticks` | 2000 | cap on a single extrapolated jump |
| `min/max_position` | 0 / 49999 | travel clamp — a bad seed cannot drive into the stops |

Default pointing is now the **zenith** (`coord.dec = None` → mount latitude;
`coord.ra = None` → LST/transit) — minimum airmass, since every product is
measured from star shapes.

## 6. Known issues and gotchas

- **Two HFD scales.**  Single-frame `frame_hfd` and the cross-matched sweep HFD
  differ by ~2–4× at the same position (the cross-match sizes the aperture for
  the *most* defocused frame in the sweep, inflating it).  `near_hfd_max_px`
  compares against the single-frame scale (~12–13 px at focus); `max_best_hfd_px`
  against the cross-matched scale (Dmin ≈ 19–24).  **Tuning one threshold by
  looking at the other's numbers will be badly wrong.**  The original
  `max_best_hfd_px=12` would have *rejected* the correct first solution
  (Dmin 20.3); it was raised to 35.
- **The focuser stall is the dominant real-world failure.**  Twice in two nights
  the focuser physically stalled mid-move (200 and ~850 ticks, both directions).
  The software now fails such a move in 120 s with a diagnostic
  (`FocuserMoveError` naming commanded-vs-actual position) instead of hanging —
  but the stall itself is **hardware** and remains to be chased.
- **`known_as_good_position` was 1763 ticks stale** (10250 vs true 12013), so
  every backend restart de-focused the telescope and the ps3cli path seeded far
  out.  Updated to 12013 on mast02.
- **Star density matters.**  Focus succeeded with thousands of sources per frame;
  the earlier "sparse field" nights were actually a *covered telescope* — all
  those measurements are void.
- **The probe seeds from the product, not the focuser.**  Once
  `calibration.products.focuser` exists, a run starts its search from the stored
  best position, *ignoring where the focuser currently is*.  This is deliberate
  (keeps the calibration flow decoupled from the ps3cli path) but it is a trap
  for testing: parking the focuser and running does **not** start the search
  there.  It also means a routine re-calibration always begins near the last
  known focus — good for speed, but it is why capture range could not be
  measured tonight (§3).
- **Run artifacts.**  Every run writes `vcurve.png` + `status.json` and moves the
  folder off the volatile RAM disk to the shared area, on every exit path
  (success, failure, abort) — a failed run's frames are the ones worth replaying.

## 7. Provenance

Design: `self-contained-hfd-autofocus.md`.  Orchestration:
`calibration_orchestration.md`.  Code: `MAST_unit` branch `calibration`,
`src/calibration/` (phase `phases/focuser.py`, analysis `analysis/hfd.py` +
`analysis/vcurve.py` + `analysis/donut.py`).  On-sky commissioning
2026-07-20/21/22, mast02, Neot Smadar.
