# Self-contained HFD autofocus — replace the ps3cli analyzer

> **Status: PLANNED (2026-06-29), not yet implemented.** Approved plan, archived for reference.

## Context

The MAST unit already has a working V-curve autofocus (`src/autofocusing.py`): it
steps the focuser over N exposures (`FOCUSnnnnn.fits`, position encoded in the
name), hands the files to **PlaneWave's external `ps3cli --server`** which
returns a best-focus position + tolerance from a quadratic V-curve over each
image's **star RMS diameter**, then persists `known_as_good_position` to the
config DB. A second path delegates to PWI4's native autofocus.

Two problems with the ps3cli dependency, per our self-calibration design
(`unit-self-calibration-design` §1): it requires an **external server + a UC4/Orca
star catalog** (not offline/self-contained), and **RMS/FWHM-type diameters are a
poor focus metric for an f/3 parabola** — pronounced coma makes off-axis PSFs
asymmetric even at best focus. The design argues for **HFD (half-flux diameter)**:
a scalar, well-behaved far from focus and insensitive to PSF asymmetry.

**Goal:** replace the analysis engine with a **self-contained, in-process HFD
V-curve** — local star detection + HFD + fit — dropping ps3cli and the catalog,
while keeping the existing orchestration and result schema unchanged.

**Key seam:** `src/focus_analysis.py::analyze_focus_files(files) -> PS3AutofocusStatus`
is already hardware-free (position comes from file names) and is the *only* thing
`autofocusing.py` and the replay harness call. Swap its internals; keep its
signature and the `PS3FocusAnalysisResult` schema → callers unchanged.

## Design

### New: `src/imaging/hfd.py` — the metric
Reuse the photutils detection pattern from `src/imaging/optical_center.py`
(`Background2D` + `MedianBackground`, `detect_threshold`/`detect_sources`,
`SourceCatalog`).
- `half_flux_diameter(stamp, cx, cy, r_out)` — per star, on the background-subtracted,
  negative-clamped stamp: the standard flux-weighted estimator
  $\text{HFD} = 2\,\dfrac{\sum_i v_i\, r_i}{\sum_i v_i}$ over pixels within `r_out`
  ($r_i$ = distance from the centroid). Robust and asymmetry-tolerant.
- `frame_hfd(image, ...) -> (hfd_median, n_stars)` — detect sources; **restrict to
  near-axis stars** (coma inflates off-axis HFD): keep sources within a central
  radius fraction (`near_axis_frac`, the "middle-third" prior — the optical center
  is unknown during focus, so use the geometric center). Compute per-star HFD,
  return the **robust median** over the kept stars and the count. Reject saturated
  / blended / too-few-pixel sources.

### Rewrite `src/focus_analysis.py` internals (keep schema + signature)
- Keep the Pydantic models `PS3FocusSample` / `PS3FocusAnalysisResult` /
  `PS3AutofocusStatus` (the `star_rms_diameter_pixels` field now carries **HFD** —
  documented; renaming is optional and would touch plotting).
- `analyze_focus_files(files, timeout=…, host=…, port=…)` becomes self-contained
  (host/port retained but ignored for back-compat):
  1. For each file: parse focus position from the **`FOCUSnnnnn` name** (fallback
     to the `FOCUSPOS` FITS header), compute `frame_hfd` → one `PS3FocusSample`
     (`is_valid`, `focus_position`, `num_stars`, HFD).
  2. **V-curve fit** on the valid samples: fit $D^2 = a\,x^2 + b\,x + c$ — a *linear*
     least-squares (`np.polyfit(x, D**2, 2)`), robust and matching the existing
     `vcurve_a/b/c` semantics. Require $a>0$ (concave-up) for `has_solution`.
     Best focus $x^\* = -b/2a$; min diameter $D_{\min}=\sqrt{c-b^2/4a}$.
  3. **Tolerance** = focuser offset at which the fitted diameter rises by a set
     fraction $f$ (e.g. 2.5 %, as today): $\Delta x = \sqrt{D_{\min}^2\,((1+f)^2-1)/a}$.
  4. Return `PS3AutofocusStatus(is_running=False, analysis_result=…, errors=…)`.
- Drop the `PS3CLIClient` import; add `numpy` + the `hfd` helpers. Keep
  `FocusAnalysisError` for "too few valid samples / no concave solution" so
  `autofocusing.py`'s start-vs-finish retry logic still applies.

### Config — `src/common/config/unit.py` `AutofocusConfig`
Add HFD/detection params (with sensible defaults): `nsigma` (detection), `min_stars`
(per frame), `near_axis_frac`, `hfd_r_out` (aperture), and the tolerance fraction.
(`src/common/` is the `MAST_common` submodule → sync the change to the other
checkouts.)

### Remove the ps3cli runtime dependency
- `src/app.py` (≈ lines 84–100): stop launching `ps3cli --server`; drop the
  `PS3CLI_CATALOG` requirement. Leave the **PWI4-native autofocus** path untouched
  as the fallback. `src/PlaneWave/ps3cli_client.py` / `ps3cli_locate.py` become
  unused (leave in place or remove in a follow-up).

`src/autofocusing.py` is **unchanged** (it already consumes `PS3FocusAnalysisResult`).

## Files

- **New**: `src/imaging/hfd.py` — HFD per star + per-frame metric.
- **Rewrite (internals)**: `src/focus_analysis.py` — self-contained `analyze_focus_files`; same models/signature.
- **Modify**: `src/common/config/unit.py` — `AutofocusConfig` fields (submodule-synced).
- **Modify**: `src/app.py` — remove ps3cli server launch / catalog dependency.
- **Reuse**: photutils detection pattern from `src/imaging/optical_center.py`; orchestration in `src/autofocusing.py`; replay harness `tests/autofocus/validate_autofocus_solve.py`.

## Verification

1. **Synthetic sequence**: generate Gaussian PSFs whose width varies with a known
   defocus offset (a few star positions per frame), at a range of focuser
   positions; assert the analyzer recovers the injected vertex within tolerance and
   that HFD rises monotonically away from it.
2. **Replay on real data**: run the existing `tests/autofocus/validate_autofocus_solve.py`
   over captured `Autofocus/{NNNN}/FOCUS*.fits` bundles; compare the self-contained
   best-focus to ps3cli's stored result (`status.json`) — expect agreement within
   the tolerance band.
3. **Unit-level HFD checks**: HFD increases off-axis at fixed focus (coma) — confirms
   the near-axis restriction matters; median is stable vs star count.
4. **End-to-end (manual, on a unit)**: run `start_autofocus` with `ps3cli` NOT
   running; confirm it converges and persists `known_as_good_position`.

## Out of scope (future, per design §1/§4)
Two-phase acquisition / cold-start / donut handling for far-from-focus, and the
thermal (mirror-temperature) focus-seed model — separate plans.
