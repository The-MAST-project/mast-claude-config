# On-sky calibration test harness (whole `/calibrate` flow)

> Status: **plan only — not implemented.** Supersedes and absorbs
> `on-sky-autofocus-test-harness.md` (now just the *focus-phase* deep dive /
> donut-physics characterisation). Validates the flow in
> `calibration_orchestration.md` (this folder): `/calibrate` and the phase
> endpoints `/calibrate/{focuser,optical_center,stage}`.
>
> **Scope (this rev, 2026-07-19): real sky only.** A synthetic-injection tier
> (exact known-truth frames) and a simulated-unit CI tier are explicitly
> **deferred** — see [Deferred](#deferred-not-now). Everything below runs against
> the real telescope.

## Each phase has a real-sky accuracy reference

The earlier worry — "optical_center has no sky ground truth" — was wrong: every
phase has something real to score against on sky.

| Phase | Accuracy reference (real sky) |
|---|---|
| **focuser** | dense fine **V-curve vertex** taken in the same run/pointing/temperature |
| **optical_center** | the **lab-measured optical center** already in the DB at `guiding.rois.fcu_v2.{fiber_x, fiber_y}` — accuracy = the delta to it |
| **stage** | the **geometric invariant**: at the solved `spec_position` the shadow centerline passes through the optical center (self-consistent, measurable on real shadows) |

So the harness is a **real-sky runner + an offline replay** of what it captures.
No injected frames.

## Tiers

### Primary — on-sky runs

Drive `/calibrate` end-to-end and each phase standalone against the real unit;
every run writes a replay bundle so nearly all iteration continues offline.

### Secondary — replay of captured bundles (no telescope)

Re-analyse real captured frames with no hardware — where metric/fit tuning lives
(HFD params, coma weighting, shadow detector, aggregation). Real frames, real
references carried in the bundle; just no live telescope.

## Per-phase validation

### focuser
- **Accuracy:** converged focus vs. the run's dense V-curve vertex (tag by fit
  residual / Dmin; discard the score if the truth sweep itself is poor).
- **A/B:** HFD vs. ps3cli vs. PWI4-native on identical frames.
- Low-coma-disk check: A/B a focus restricted to `calibration.optical_center`'s
  disk vs. the 60% fallback vs. whole-frame — does the disk actually help?

### optical_center
- **Accuracy = delta to the lab reference.** Report `dx, dy, |d|` between the
  computed `(center_x, center_y)` and `guiding.rois.fcu_v2.{fiber_x, fiber_y}`.
  This is the headline number.
  - *Caveat to track, not assume away:* the fiber may not sit exactly on the
    optical axis, so a small **persistent** offset can be a real fiber-vs-axis
    displacement rather than method bias. Distinguish them by watching the delta
    **across units and nights** — method bias varies frame-to-frame and averages
    down; a true fiber offset is fixed per unit. (When the deferred synthetic tier
    lands, it separates the two cleanly by injecting a known axis.)
- **Precision:** scatter of the pooled-`number_of_frames` center across repeated
  runs of the same field (and across fields/nights) — should sit far below the
  ~10²-px single-frame scatter; this is what justifies the N-frame aggregation.
- **Independent sky cross-check (optional, high value):** **defocus-donut
  concentricity** — far out of focus the central-obstruction shadow is concentric
  within the donut *on the optical axis*, a different physics (pupil geometry, not
  coma) pointing at the same axis. It reuses the Phase-2 donut frames the focus
  sweep already produces. Agreement between the coma-null center, the
  donut-concentricity center, and the fiber reference is strong three-way
  evidence.
- **Quality gates:** `radiality`, `residual_rms`, source count, `≥ceil(N/2)`
  frames passing.

### stage
- **Accuracy:** the geometric-invariant residual — perpendicular distance from
  the optical center to the shadow centerline at the solved `spec_position`
  (should be ~0), plus `angle_rms` across the sweep and `bracketed`.
- **Precision:** repeatability of `spec_position` across runs.

## Flow-level contract (exercised on real runs)

The orchestration wiring, checked by observing real runs + controlled DB edits
(no simulated unit in this rev):

- **Order:** `/calibrate` runs `focuser → optical_center → stage` (assert from the
  decision trace).
- **Prerequisite fail:** delete `calibration.optical_center` from the DB, call
  `/calibrate/stage` standalone → expect a clean error, not a guess. Same for
  `/calibrate/optical_center` with no `calibration.focuser.best_position`.
- **`force` / skip-when-present:** product present + `force=false` → skipped;
  `force=true` or product deleted → runs.
- **Hardware made-to-happen:** each phase slews to the resolved coord, calls
  `stage.home()` (focus/optical_center), sets `focuser.position` — assert from the
  trace, with no inter-phase carry-over assumed.
- **Activities / single-flight:** umbrella `Calibrating` on `/calibrate`, per-phase
  `Calibrating{Focus,OpticalCenter,Stage}`; a second start while any is active is
  rejected.
- **Abort/safety:** `is_safe`→false mid-run aborts and stows; **no partial DB
  write** (a failed phase looks absent and reruns).
- **DB round-trip:** phase N persists (`calibration.*` unit-delta upsert +
  TTL-cache clear); phase N+1 reads it back.

## Captured artifacts (per run)

One dated folder (mirroring `Autofocus/<NNNN>/`):

- **All FITS** — focus sweep; the N optical-center frames (full-frame, bin 1); the
  stage sweep frames (stage position in the name **and** a header).
- **`manifest.json`** — run id, unit/host, endpoint(s), `force`, UTC start/end;
  per exposure: focuser + stage position, mount alt/az + RA/Dec, mirror & ambient
  temperature, exposure/gain/binning/ROI. **Record the `guiding.rois.fcu_v2`
  reference** used for the optical-center delta.
- **`decisions.jsonl`** — order, skip-because-present, prerequisite checks, regime
  transitions, every focuser/stage/mount command + reason, gate pass/fail, DB
  writes.
- **`calibration_products.json`** — the `calibration.{focuser,optical_center,
  stage}` records written this run + their quality fields.
- **`analysis.json`** — per-frame analyzer outputs (focus: HFD/ps3cli/PWI4;
  optical_center: center + radiality + coma_slope + delta-to-fiber; stage:
  centerlines + solve + invariant residual).
- **`report.png/html`** — V-curve; coma field + fitted center + low-coma disk +
  **fiber-reference marker**; shadow-centerline-vs-stage-position with the optical
  center overlaid; convergence + star-drift traces.

## Safety / operational gating

Reuse the flow's own guards: `is_safe AND dark-enough`; abort + stow on unsafe;
single-flight; bounded focuser/stage travel (clamp sweeps, refuse out-of-limit
scenarios); backlash discipline (consistent approach direction); per-run time +
exposure caps; **read-only w.r.t. operational config** — the calibrate flow writes
only `calibration.*`, never `focuser.known_as_good_position` or the `guiding.rois`
reference it scores against.

## Open questions / risks

- **Fiber-vs-axis offset** (above) — the one interpretation subtlety in the
  optical-center delta; resolved by cross-unit/cross-night tracking now, cleanly by
  the synthetic tier later.
- **Field stationarity** over slow sweeps (optical-center N frames, stage sweep,
  focus sweep) — measure star-position drift across frames, flag if it exceeds a
  pixel budget.
- **Donut detector choice** — blob vs. morphological vs. radial-profile fit; the
  Tier-3 donut sweeps from the focus harness are the data to pick it.
- **Detection cost** ~3 s/frame (photutils Background2D) — a wide sweep is many
  frames; budget it.
- **Per-unit variation** — coma_slope, CFZ, donut slope, shadow geometry differ per
  unit; every product and every reference is per-unit, keyed by host.

## Deferred (not now)

- **Synthetic-injection tier** — render frames with a *known* optical center /
  known shadow geometry / known defocus vertex to measure absolute bias and to
  separate method bias from the fiber-vs-axis offset. Needs a faithful coma-field
  generator (PSF, blends, background); low-fidelity synthetic gives false
  confidence, so it's deferred until it's worth building well.
- **Simulated-unit CI** — run the flow-level contract headless (no sky) for
  regression. For now those checks ride along on real runs via controlled DB edits.

## Verification ladder

1. **One supervised on-sky night** — `/calibrate` end-to-end + each phase
   standalone; headline checks: optical-center **delta to `fcu_v2` fiber**,
   center repeatability, stage invariant residual, focus vs. V-curve truth;
   confirm bundles replay offline and the report renders.
2. **Replay** those bundles to tune metrics/fits.
3. **Donut-physics characterisation** sweeps (focus harness) once Phase-2 exists.
4. Later: the deferred synthetic + CI tiers.
