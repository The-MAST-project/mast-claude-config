# HFD autofocus — phased plan (self-contained, parallel to ps3cli)

> **Status: PLANNED (2026-06-29).** Phase 1 is the immediate, implementable scope;
> Phases 2–3 are the roadmap (design intent + key algorithms), to be detailed/built
> later. Archived approved plan.
> **Guideline (Arie):** the HFD implementation lives **in parallel** to the current
> ps3cli code (does not replace it); add a new endpoint `start_hfd_autofocus`.

## Context

The MAST unit already has a working V-curve autofocus (`src/autofocusing.py`): step
the focuser over N exposures (`FOCUSnnnnn.fits`, position in the name), hand the
files to PlaneWave's external **`ps3cli --server`** (best-focus + tolerance from a
quadratic V-curve over each image's **star RMS diameter**), persist
`known_as_good_position`. A second path delegates to PWI4's native autofocus.

Per our self-calibration design (`unit-self-calibration-design` §1/§4) we want a
**self-contained, coma-robust HFD (half-flux diameter)** autofocus: no external
ps3cli/catalog; a metric that tolerates the asymmetric PSFs an f/3 parabola
produces; robust from far out of focus; and temperature-seeded so most runs are a
short confirm. Built as a **parallel path** to ps3cli so the two can be A/B'd.

Architectural spine for all phases: **shared focuser sweep + pluggable analyzer**.
Factor the sweep/capture loop out of `do_start_autofocus`; `start_autofocus` keeps
the ps3cli analyzer, `start_hfd_autofocus` uses the HFD analyzer; both return the
same `PS3AutofocusStatus`. ps3cli (and its `app.py` launch) stay untouched.

---

## Phase 1 — Self-contained HFD V-curve (near-focus), parallel path  ← BUILD NOW

**Key benefit of parallel:** analysis is decoupled from capture (position is in the
filename), so **both analyzers run on the SAME captured sweep** — identical star
field, no extra telescope time — for an apples-to-apples HFD-vs-ps3cli comparison.

### New `src/imaging/hfd.py` — the metric
Reuse the photutils detection pattern from `src/imaging/optical_center.py`.
- `half_flux_diameter(stamp, cx, cy, r_out)` — per star, background-subtracted,
  negative-clamped: $\text{HFD}=2\,\dfrac{\sum_i v_i r_i}{\sum_i v_i}$ within `r_out`.
- `frame_hfd(image, ...) -> (hfd_median, n_stars)` — detect sources; **restrict to
  near-axis stars** (coma inflates off-axis HFD) via `near_axis_frac` about the
  geometric center (optical center unknown during focus); robust median; reject
  saturated/blended/too-small.

### New `src/focus_analysis_hfd.py` — the analyzer (parallel to `focus_analysis.py`)
`analyze_focus_files_hfd(files, ...) -> PS3AutofocusStatus`, **reusing the existing
Pydantic models** so it drops into the orchestrator (`focus_analysis.py` untouched):
parse position from `FOCUSnnnnn` (fallback `FOCUSPOS` header) → `frame_hfd` per file
→ fit $D^2=ax^2+bx+c$ via `np.polyfit(x, D**2, 2)` (linear LSQ; matches `vcurve_a/b/c`),
require $a>0$, best $x^\*=-b/2a$, $D_{\min}=\sqrt{c-b^2/4a}$, tolerance
$\Delta x=\sqrt{D_{\min}^2((1+f)^2-1)/a}$.

### Plumbing (additive)
`start_hfd_autofocus` endpoint (`src/unit.py`), `UnitActivities.HfdAutofocusing`
(`src/common/activities.py`), HFD config block in `AutofocusConfig`
(`src/common/config/unit.py`; MAST_common submodule → sync). `src/app.py`/ps3cli
unchanged.

**Files:** new `src/imaging/hfd.py`, `src/focus_analysis_hfd.py`; additive edits to
`src/autofocusing.py` (shared-sweep helper + `do_start_hfd_autofocus`), `src/unit.py`,
`src/common/activities.py`, `src/common/config/unit.py`.

**Verification:** (1) **A/B on the same files** — extend `tests/autofocus/validate_autofocus_solve.py`
to run both analyzers over real `FOCUS*.fits`, compare best-focus/tolerance;
(2) synthetic Gaussian-defocus sequence recovers the injected vertex; (3) HFD rises
off-axis (coma) confirming the near-axis cut; (4) manual end-to-end `start_hfd_autofocus`
with ps3cli still available.

---

## Phase 2 — Far-from-focus robustness (two-phase acquisition)  ← LATER

Phase 1 assumes you start **near** focus (point sources extractable). Starting wildly
out of focus, stars are large **donuts** (central-obstruction shadow) or sky-limited
blur, and point-source HFD breaks. Add a **Phase A (acquisition)** ahead of the
Phase-1 V-curve (which becomes **Phase B, refinement**).

- **Donut regime metric (not SEP point sources):** detect **blobs** via
  connected-components/threshold (donuts are large and may blend). The donut **outer
  diameter ≈ linear in focuser offset** (slope set by f-ratio + pixel scale). One
  **differential focuser move** calibrates the slope → jump to near-focus in ~one
  shot. Donut size gives **magnitude but not sign** (inside vs outside focus look
  identical) → the differential move **disambiguates direction**. "Getting warmer"
  signal: blob count + above-threshold area both rise toward focus.
- **Cold start:** if nothing extracts at all (sky-limited blur), step the focuser in
  **coarse increments** until blobs/sources appear, then enter the donut regime.
- **Hand-off A→B:** when point sources become extractable and HFD is measurable,
  switch to the Phase-1 HFD V-curve for the precise vertex.
- **New pieces:** a donut/blob metric in `src/imaging/hfd.py` (or a `focus_metrics`
  module); an adaptive Phase-A controller in the sweep helper (direction-finding +
  coarse stepping) that precedes the fixed N-step V-curve. Phase B reuses Phase-1
  unchanged.
- **Verification:** synthetic donut sequences (annuli whose diameter ∝ |offset|) →
  the slope-calibration move lands near focus and the sign is resolved; cold-start
  test from a blank/blurred frame finds the regime.

---

## Phase 3 — Thermal focus-seed model  ← LATER

Best focus drifts with temperature (tube/focuser expansion; large WAO day-night
swing); **mirror temperature predicts better than ambient** (mirror lags ambient).
Goal: seed each run so most are a short confirming V-curve, not a full sweep.

- **Model:** `seed = offset + slope · T_mirror` (linear; resist higher-order — sparse
  points overfit). **Robust/sigma-clipped** fit over a **rolling, recency-weighted**
  training set of `(mirror_temp, best_focus, timestamp, quality)` — one point
  **appended per successful autofocus** (Phase 1/2), so it self-calibrates and tracks
  drift. **Keyed per `(unit, config-epoch)`**; also store **altitude** as an
  (initially unused) covariate for later flexure analysis.
- **Maturity gate:** trust the slope only with **≥N points spanning ≥ΔT**; below that
  use the **most-recent good focus as a flat seed**.
- **Degradation ladder:** (a) mature model + temp → predicted seed → short V-curve;
  (b) temp `None` but recent good focus → flat seed (wider V-curve); (c) neither →
  full Phase-A acquisition. **Guardrail across all:** take one image first and check
  HFD is in the expected ballpark; if wildly off, the seed is stale → fall down the
  ladder.
- **`get_mirror_temperature() -> Optional[float]`:** stub returning `None` when no
  reading (never fabricate a constant); **timestamp captured at the call site** so a
  stale reading can be rejected. PWI4 reality: the official `pwi4_client.py` parses
  **no** temperature fields; EFA mirror/ambient temps exist inside PWI4 but the exact
  `/status` keyword strings are **unconfirmed** — verify on a connected unit
  (`curl /status | grep -i temp`). Candidate sources, best first: EFA primary-mirror
  sensor; PWI4 `/status` keyword; PWI4 temperature CSV log; independent ESP32
  backplate probe.
- **Persistence:** per-unit config DB as an **accumulating/rolling point set**
  (distinct from replace-on-refresh geometric calibrations like optical center).
- **Verification:** feed a synthetic `(T, best_focus)` history → the robust fit
  recovers the slope and the maturity gate / ladder behave; with `get_mirror_temperature`
  returning `None`, the ladder falls back cleanly.

---

## Phasing rationale
Phase 1 delivers an offline, coma-robust analyzer A/B-able against ps3cli today.
Phase 2 makes it reliable from any starting defocus. Phase 3 makes routine runs cheap
and drift-aware. Each phase stands alone and slots into the same pluggable-sweep spine.
