# On-sky autofocus test harness (incl. Phase 2 donuts)

> Status: **plan only — not implemented.** Companion to
> [`self-contained-hfd-autofocus.md`](self-contained-hfd-autofocus.md).
>
> **Scope note (2026-07-19):** the whole calibration flow (focus + optical_center
> + stage) is now planned in
> [`on-sky-calibration-test-harness.md`](on-sky-calibration-test-harness.md),
> which supersedes this doc at the flow level. What remains uniquely here is the
> **focus-phase deep dive**: donut-physics characterisation (diameter-vs-defocus
> slope, inside/outside sign, CFZ) — the part that has clean sky ground truth.

## Context

The self-contained HFD autofocus is being built in phases, in **parallel** to the
existing ps3cli path (it does not replace it):

- **Phase 0** — assess/triage one frame (`near` / `far` / `empty`).
- **Phase 1** — HFD V-curve. *Analysis core built and validated offline*
  (`src/imaging/hfd.py` + `src/focus_analysis_hfd.py`): synthetic vertex recovery
  to ~2.5 ticks; A/B vs ps3cli on 10 real sessions matches within ps3cli's own
  tolerance on every *bracketed* sweep (RMS 26 ticks). Live plumbing
  (`start_hfd_autofocus`) still pending.
- **Phase 2** — donut acquisition from far out of focus. *Designed, not built.*
- **Phase 3** — thermal (mirror-temperature) focus seed. *Designed, not built.*

Two things force an **on-sky** harness rather than more offline replay:

1. **Phase 2 needs physics we do not yet have measured.** The donut acquisition
   relies on the (near-)linear **donut-outer-diameter vs defocus-magnitude** slope
   and the **inside-vs-outside sign** behaviour. The research flagged these as
   *empirically open for our optics* — they can only be characterised by
   deliberately defocusing the real telescope and measuring. There are no donut
   frames in the existing fixtures (all captured sessions are near-focus 5-point
   sweeps).
2. **End-to-end convergence** (Phase 0 → 2 → 1, from arbitrary starting offsets)
   exercises real focuser backlash, settle, tracking drift, sky/seeing, and star
   fields that synthetic data cannot reproduce.

On-sky time is scarce, so the harness's prime directive is: **capture richly
enough that almost all iteration continues offline** — every run produces a
drop-in replay bundle (same shape as the `Autofocus/<NNNN>/FOCUS*.fits` +
`status.json` sessions we already mine).

## Goals

1. **Characterise Phase-2 physics** on each unit's optics: donut-diameter-vs-defocus
   slope + its linear range, the inside/outside asymmetry (a sign cue), the
   near-focus HFD floor, and the Critical Focus Zone at f/3.
2. **Validate end-to-end convergence** from each regime (near / far-donut /
   cold-start) against a ground-truth focus, with success/repeatability metrics.
3. **A/B the analyzers** — HFD vs ps3cli vs PWI4-native — on *identical* frames.
4. **Produce replayable artifacts** that feed the offline replay harness and grow
   the fixture library.
5. **Feed the Phase-3 thermal model** — every run logs mirror + ambient temperature
   so (T, best_focus) pairs accumulate for free.

## Two jobs, one harness

| Job | Question it answers | Needs |
|---|---|---|
| **Characterisation** | What are our optics' donut slope / sign / CFZ / HFD floor / thermal slope? | wide focuser sweeps + raw capture (only Phase-1 analysis + focuser moves) |
| **Validation / regression** | Does the autofocus *converge* from each starting regime, and agree with ground truth & ps3cli? | scripted scenarios that drive the real routine |

Characterisation can start **now** (it needs only focuser moves + exposures +
the validated HFD metric); validation of Phase 2 comes online once Phase-2
acquisition exists.

## Modes

- **A. Characterisation sweep (wide).** Coarse focuser sweep far-inside → focus →
  far-outside (e.g. ±N·1000 ticks in ~200–300 tick steps), one or more exposures
  per step. Captures the full progression donut → star → donut. Post-run, fit:
  donut diameter vs offset (slope, linear range, inside/outside asymmetry), the
  HFD V near focus (floor + CFZ), and a dense fine sweep at the bottom for the
  **ground-truth vertex**. This is the key Phase-2 data collector.
- **B. Scenario / regression runner.** Each scenario defines a *starting offset*
  from known-good and the *expected path*; the harness commands that offset, runs
  the autofocus end-to-end, and scores the converged focus against ground truth +
  ps3cli. (Phase-2 scenarios gated on Phase-2 existing.)
- **C. Repeatability.** Repeat one scenario K times back-to-back → scatter of the
  converged focus = the unit's per-run focus noise floor (and a regression guard).
- **D. Replay (offline).** Every A/B/C run writes a bundle the offline harness
  re-analyses with no telescope; this is where metric/fit tuning lives.

## Ground truth

Best focus "truth" = the vertex of a **dense fine V-curve** (many points, small
spacing, possibly stacked/averaged) taken around focus in the same run, at the
same pointing/temperature. Scenarios and method A/B are scored against it. Record
its fit residual / Dmin as a confidence tag; discard a scenario's score if the
truth sweep itself is poor (clouds, drift).

## Captured artifacts (per run)

One dated folder per run (mirroring today's `Autofocus/<NNNN>/`), containing:

- **All FITS** — `FOCUS<pos>.fits`, position in the name **and** a `FOCUSPOS`
  header (so bundles replay even if renamed).
- **`manifest.json`** — run id, unit/host, mode, scenario, UTC start/end; per
  exposure: focuser position, timestamps, mount alt/az + RA/Dec, **mirror &
  ambient temperature** (PWI4 `/temperatures/pw1000`: `temperature.primary` /
  `.ambient`, `-999` → null), exposure/gain/binning/ROI, FWHM-ish seeing proxy.
- **The decision trace goes to the ordinary debug log**, not a per-run file: the
  routine `logger.debug`s the Phase-0 verdict, regime transitions, every focuser
  command + reason (e.g. "donut jump −1400 from slope", "V-curve not bracketed →
  shift +150") and retries as it goes. Logs already rotate daily under
  `%LOCALAPPDATA%/mast/<date>/` (`common.mast_logging`), so no bespoke writer is
  needed.
- **`analysis.json`** — per-frame outputs of **all** analyzers on the same frames
  (HFD, ps3cli, PWI4-native) + each method's final best-focus/tolerance.
- **`report.png/html`** — V-curve, donut-diameter-vs-offset, convergence trace,
  star-position stability across frames.

## Phase-2 (donut) specifics the harness must exercise

- **Create real donuts** by commanding large defocus from known-good (±range), at
  several magnitudes — this *is* how we obtain donut frames.
- **Diameter-vs-defocus characterisation.** Measure donut **outer** diameter
  (blob/annulus detector — note HFD/point-source extraction degrades on annuli;
  the detector choice is itself a deliverable) at each offset → fit the slope,
  establish its **linear range**, and quantify the **inside-vs-outside asymmetry**
  (central-obstruction shadow / coma-driven) that disambiguates sign. Output: a
  per-unit `donut_slope` (ticks per pixel of diameter) + valid range + sign rule.
- **Sign disambiguation test.** From a donut, make a small *known* focuser move and
  confirm the diameter change resolves inside vs outside focus (the differential-move
  method) — measure how small a move is reliably detectable.
- **Slope-jump test.** From far out, one calibrated jump using `donut_slope` should
  land inside the V-curve's bracketing range → hand off to Phase-1. Measure landing
  error vs starting offset.
- **Cold-start.** From extreme defocus where nothing extracts at all → coarse
  stepping must find the donut regime; measure steps/time to first extraction.

## Scenario library (representative)

- `near` — start at known-good → Phase-0 `near` → V-curve → converge; A/B vs ps3cli.
- `bracket_fail` — offset so the first 5-point sweep does **not** bracket → assert
  "shift the sweep" → re-centre → converge (directly tests the Phase-1 gate we built).
- `far_inside` / `far_outside` — start ±~1500 ticks → Phase-2 donut jump (correct
  sign) → V-curve. Two scenarios to catch sign errors.
- `cold_start` — start ±~4000 ticks → coarse step → donut → focus.
- `thermal` — run the `near` scenario at several times/temperatures across a night →
  accumulate (T, best_focus); never resets known-good, just logs.
- `star_field` — run `near` at a sparse and a dense pointing → min-star handling,
  success rate vs star count (the fixtures show sessions from 2 to 27 stars).

## Metrics & report

Per scenario / per night: convergence **success rate**; **final achieved HFD** (and
vs the truth Dmin); **# exposures + wall-time** (mind the ~3 s/frame detection
cost — see budget note); **repeatability scatter**; **method agreement** (HFD vs
ps3cli vs PWI4, signed deltas vs tolerance); **donut slope fit** + linear range +
sign-rule confidence; **thermal points**. Auto-generate a per-night report; trend
the headline numbers across nights.

## Safety / operational gating

- Run only when **`is_safe` AND dark enough**; abort + **stow** on weather/unsafe
  mid-run (reuse the unit's existing shutdown/activity guards — the routine already
  checks `is_active(UnitActivities.Autofocusing)` between exposures; mirror that).
- **Bounded focuser travel** — never command beyond configured min/max; clamp the
  sweep range and refuse scenarios that would exceed limits.
- **Backlash discipline** — always approach a target focuser position from a
  consistent direction (the production routine starts below and steps up; the
  harness must do the same so characterisation and runs are comparable).
- **Per-scenario time budget** and a hard exposure cap; a single run must not eat
  the night.
- **Restore state** — on finish/abort, return the focuser to the pre-run known-good
  and end any exposure series; the harness must never silently overwrite
  `known_as_good_position` (characterisation/validation are read-only w.r.t. config
  unless a scenario explicitly opts in).
- **Replay self-test** — before spending telescope time, drive the harness against
  the offline replay of **previously captured real** bundles to exercise scenario
  logic, scoring, and reports. (A no-sky synthetic self-test is deferred with the
  rest of the synthetic tier — see the calibration harness's *Deferred* section.)

## Where it lives / reuse

- A harness module driving the unit's **existing** primitives (same ones
  `Autofocuser.do_start_autofocus` uses):
  `stage.move_to_preset(StagePresetPosition.Sky)`, `mount.goto_ra_dec_j2000`,
  `focuser.position` setter + `focuser.is_active(FocuserActivities.Moving)`,
  `imager.start_exposure(ImagerSettings(...))` + `wait_for_image_saved()`,
  `PathMaker().make_autofocus_folder()`, PWI4 temperatures endpoint.
- Reuse analyzers as-is: `focus_analysis_hfd.analyze_focus_files_hfd` (HFD),
  `focus_analysis.analyze_focus_files` (ps3cli), PWI4-native — all share the
  `PS3AutofocusStatus` schema, so the A/B is a loop over analyzers on one file set.
- Extend the offline replay harness (`tests/autofocus/validate_autofocus_solve.py`)
  to consume harness bundles for mode D.
- Scenarios as TOML/config (a `scenarios/` set), results to the per-unit dated
  share path like Autofocus sessions, so they're mineable later.

## Harness phasing

1. **Capture + replay core + characterisation sweep (mode A & D).** Needs only
   focuser moves + exposures + the validated HFD metric — *collect donut & thermal
   data on the next clear night, before Phase-2 acquisition is even built.* The
   slope/sign it produces is the **input** Phase-2 needs.
2. **Scenario runner (mode B/C)** once Phase-2 acquisition exists — first `near` /
   `bracket_fail` (need no Phase 2), then the donut scenarios.
3. **Automation** — nightly characterisation + report; trend tracking; optional tie
   into the unit's calibration scheduling.

## Open questions / risks

- **Donut detector choice** — blob/threshold on the annulus vs morphological
  diameter vs radial-profile fit; the harness's mode-A data is what we'll use to
  pick it. (Deliverable, not assumed.)
- **Field stationarity** — consistent-star matching (and donut tracking) assumes the
  field doesn't move during a sweep; over a *wide/slow* characterisation sweep,
  tracking drift may be non-trivial. The harness must **measure star-position drift
  across frames** and flag/register if it exceeds a pixel budget.
- **Detection cost** — ~3 s/frame (photutils Background2D dominates); a wide sweep is
  many frames. Budget accordingly, and treat detection optimisation as a parallel
  follow-up (cheaper background, smaller box, or detect-once strategies).
- **Sky dependence** — seeing/transparency vary within a night; the per-run truth
  sweep + conditions logging let us normalise, but some scenarios may need re-runs.
- **Per-unit variation** — slope/CFZ/thermal differ across mastw/mast00/mast02;
  characterisation is **per unit**, results keyed by host.

## Verification (of the harness itself)

1. **Replay** against previously captured real bundles — scenario logic, scoring,
   reports, and safety aborts exercised without new telescope time.
2. **One supervised on-sky night** — a single characterisation sweep + the `near`
   and `bracket_fail` scenarios; confirm bundles replay offline byte-for-metric and
   the report renders.
3. Only then enable the donut scenarios (after Phase-2 acquisition lands) and
   nightly automation.
