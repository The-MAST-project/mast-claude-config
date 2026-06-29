# Self-contained HFD autofocus — a parallel path alongside ps3cli

> **Status: PLANNED (2026-06-29), not yet implemented.** Approved plan, archived for reference.
> **Guideline (Arie):** the HFD implementation lives **in parallel** to the current
> ps3cli code (does not replace it); add a new endpoint `start_hfd_autofocus`.

## Context

The MAST unit already has a working V-curve autofocus (`src/autofocusing.py`): it
steps the focuser over N exposures (`FOCUSnnnnn.fits`, position encoded in the
name), hands the files to **PlaneWave's external `ps3cli --server`** which returns
a best-focus position + tolerance from a quadratic V-curve over each image's
**star RMS diameter**, then persists `known_as_good_position`. A second path
delegates to PWI4's native autofocus.

Per our self-calibration design (`unit-self-calibration-design` §1) we want a
**self-contained, coma-robust HFD (half-flux diameter)** focus metric: no external
ps3cli server / star catalog, and a scalar that stays well-behaved far from focus
and tolerates the asymmetric PSFs an f/3 parabola produces (coma).

**Goal:** add an HFD autofocus path that runs **in parallel** to the existing
ps3cli path — same focuser sweep, different (in-process) analysis — exposed via a
new `start_hfd_autofocus` endpoint. **ps3cli is left fully intact** as the default,
enabling a direct A/B comparison before any switch of default.

## Design — parallel, analysis-pluggable

**Why parallel + key benefit:** because analysis is decoupled from capture (focuser
position is in each filename), **both analyzers can run on the SAME captured sweep**
— identical star field, no extra telescope time — for an apples-to-apples
HFD-vs-ps3cli comparison.

### Shared sweep, pluggable analyzer (recommended; avoids duplicating the loop)
Factor the focuser-sweep + exposure-capture loop in `do_start_autofocus` into a
shared helper that takes an **analyzer callable** returning `PS3AutofocusStatus`:
- `start_autofocus` (existing) → analyzer = ps3cli `analyze_focus_files` (default; behavior unchanged).
- `start_hfd_autofocus` (new) → analyzer = the new HFD `analyze_focus_files_hfd`.
Both share capture, plotting, persistence (`known_as_good_position`), `latest_result`,
and retry logic. (Fallback if zero edits to the existing method are required: a
sibling `do_start_hfd_autofocus` duplicating the loop — avoid if possible.)

### New: `src/imaging/hfd.py` — the metric
Reuse the photutils detection pattern from `src/imaging/optical_center.py`.
- `half_flux_diameter(stamp, cx, cy, r_out)` — per star, on the background-subtracted,
  negative-clamped stamp: $\text{HFD} = 2\,\dfrac{\sum_i v_i\, r_i}{\sum_i v_i}$
  within `r_out` ($r_i$ = distance from centroid). Robust, asymmetry-tolerant.
- `frame_hfd(image, ...) -> (hfd_median, n_stars)` — detect sources; **restrict to
  near-axis stars** (coma inflates off-axis HFD) via a central radius fraction
  (`near_axis_frac`; geometric center, since the optical center is unknown during
  focus); robust median HFD over kept stars; reject saturated/blended/too-small.

### New: `src/focus_analysis_hfd.py` — the HFD analyzer (parallel to `focus_analysis.py`)
- `analyze_focus_files_hfd(files, ...) -> PS3AutofocusStatus` — **reuses the existing
  Pydantic models** from `focus_analysis.py` (`PS3FocusSample` / `PS3FocusAnalysisResult`
  / `PS3AutofocusStatus`) so it is a drop-in for the orchestrator. `focus_analysis.py`
  itself is **untouched**.
  1. Per file: parse focus position from the `FOCUSnnnnn` name (fallback `FOCUSPOS`
     header) → `frame_hfd` → `PS3FocusSample` (HFD in `star_rms_diameter_pixels`).
  2. V-curve: fit $D^2 = a x^2 + b x + c$ via `np.polyfit(x, D**2, 2)` (linear LSQ;
     matches `vcurve_a/b/c`). Require $a>0$; best $x^\*=-b/2a$; $D_{\min}=\sqrt{c-b^2/4a}$.
  3. Tolerance: offset where fitted diameter rises by $f$ (e.g. 2.5 %):
     $\Delta x=\sqrt{D_{\min}^2((1+f)^2-1)/a}$.
  4. Return `PS3AutofocusStatus(is_running=False, analysis_result=…, errors=…)`;
     reuse `FocusAnalysisError` semantics so retry logic still applies.

### Plumbing (all additive)
- **Endpoint**: `POST /mast/api/v1/unit/start_hfd_autofocus` (+ have `stop_autofocus`
  cover it, or add `stop_hfd_autofocus`) in `src/unit.py` / `Autofocuser`.
- **Activity flag**: `UnitActivities.HfdAutofocusing` (parallel to `Autofocusing`) in
  `src/common/activities.py`, so telemetry/Grafana distinguishes the two.
- **Config**: a parallel HFD block (or sub-section) in `AutofocusConfig`
  (`src/common/config/unit.py`): `nsigma`, `min_stars`, `near_axis_frac`, `hfd_r_out`,
  tolerance fraction — independently tunable during the bake-off. (`src/common/` is the
  `MAST_common` submodule → sync to other checkouts.)
- **`src/app.py` / ps3cli**: **unchanged** — the ps3cli server keeps launching; both
  paths coexist.

## Files

- **New**: `src/imaging/hfd.py` (metric), `src/focus_analysis_hfd.py` (HFD analyzer; reuses focus_analysis.py models).
- **Modify (additive)**: `src/autofocusing.py` (shared-sweep helper + `start_hfd_autofocus` / `do_start_hfd_autofocus`), `src/unit.py` (new endpoint), `src/common/activities.py` (`HfdAutofocusing`), `src/common/config/unit.py` (HFD config; submodule-synced).
- **Untouched**: `src/focus_analysis.py`, `src/app.py` (ps3cli launch), the existing `start_autofocus` behavior, PWI4-native path.
- **Reuse**: photutils detection from `src/imaging/optical_center.py`; replay harness `tests/autofocus/validate_autofocus_solve.py`.

## Verification

1. **A/B on the SAME files (headline)**: extend the replay harness to run **both**
   `analyze_focus_files` (ps3cli) and `analyze_focus_files_hfd` over the same captured
   `Autofocus/{NNNN}/FOCUS*.fits` bundles; compare best-focus + tolerance — expect
   agreement within the tolerance band.
2. **Synthetic sequence**: Gaussian PSFs whose width varies with a known defocus
   offset, across focuser positions; assert the HFD analyzer recovers the injected
   vertex and HFD rises monotonically away from it.
3. **HFD sanity**: HFD increases off-axis at fixed focus (coma) — confirms the
   near-axis restriction; median stable vs star count.
4. **End-to-end (manual, on a unit)**: call `start_hfd_autofocus`; confirm it sweeps,
   converges, and persists `known_as_good_position` — with ps3cli still available for
   the existing endpoint.

## Out of scope (future, per design §1/§4)
Two-phase acquisition / cold-start / donut handling for far-from-focus, and the
thermal (mirror-temperature) focus-seed model — separate plans.
