# Plan: `focus_on_star` — narrow-field autofocus on one isolated star at the focus center

## Context
The unit is already focused fleet-style via `/calibrate/focuser` (HFD V-curve, full frame). We want an
on-demand refinement: pick one isolated GAIA DR3 star, put it on the **focus center** with
mastrometry (no guiding), and run a short HFD V-curve analysed only in a small box (fov_percent of the
frame) around the focus center. The caller gives a sky position and a magnitude limit; the routine chooses the star.

Decisions taken with the user:
- The autofocus method = the existing **HFD V-curve** (`FocuserCalibrator` internals + `analyze_focus_samples`).
- **Focus center = the fibre pixel `(fiber_x, fiber_y)`** from `unit_conf.guiding.rois[fcu]` — the same point the
  `spec` acquisition phase aims at. The calibrated optical center (`calibration.products.optical_center`) is still
  work in progress; switching to it later is a change to one helper (`focus_center_bin1`), not to the solver.
- Star rule: **G mag ≥ star_magnitude** (no brighter than the limit); choose the brightest such star
  (closest to the limit), tiebreak by distance from the sky position; no star brighter than it in the box.
- fov_percent is **linear**: box = p% of frame width × p% of height (10% → 829×564 px), centred on the focus center.
- On success: **move the focuser only** — no `known_as_good_position`, no calibration product. On failure: return
  to the start position. Artifacts saved.

Facts found: catalog at `\\last0\catalogs\GAIA\DR3` is **catsHTM** (`GAIADR3_htm.hdf5` index,
`GAIADR3_htmColCell.mat`, 5246 `GAIADR3_htm_NNNN00.hdf5`); **h5py is not a dependency**. Mastrometry's `spec` phase
already crops symmetrically about the fibre and sets CRPIX there (`solvers/mastrometry.py:184-201`), so acquisition
needs **no solver change**. `Acquirer.do_acquire` moves the stage to SPEC on FCU v2 after solving (and may hand over
to guiding), so we bypass it and call `Solver.solve_and_correct(phase="spec")` directly.

## MAST_common
1. `activities.py` — append `UnitActivities.FocusingOnStar = auto()` **after `Aborting`** (end-only rule).
2. `paths.py` — add `"focus_on_star": "FocusOnStar"` to `CALIBRATION_PHASE_FOLDERS` → `<night>/Calibration/FocusOnStar/<NNNN>`.
3. `config/calibration.py` — new `FocusOnStarSettings` hung on `CalibrationSettings.focus_on_star`
   (`default_factory`); `json_schema_extra` one key per line, tooltips on one line. Fields:
   catalog (`catalog_root=r"\\last0\catalogs\GAIA\DR3"`, `catalog_name="GAIADR3"`, `mag_column="phot_g_mean_mag"`),
   search (`search_radius_deg=0.5`, `search_growth=2.0`, `max_search_radius_deg=4.0`, `isolation_margin_px=80`,
   `apply_proper_motion=True`), endpoint defaults (`fov_percent=10`, `star_magnitude`, `steps=5`, `ticks_per_step=50`),
   exposure/analysis (`exposure`, `binning=1`, `max_tries=1`, `tolerance_frac`, `min_fit_r2`, `min_edge_rise`,
   `max_best_hfd_px`, `max_saturation_retries=2`).
4. Tests: defaults test; `test_imports.py` still green.

## MAST_unit (`unit/src`)
**Pure helpers**
- `imaging/fov.py` (new): `frame_shape_bin1(imager)`, `focus_center_bin1(unit_conf, fcu)` → `(fiber_x, fiber_y)` from
  `guiding.rois[fcu]` (the single place to switch to the calibrated optical center later),
  `fov_box_size(shape, p)`, `fov_box(shape, center, p, binning)` (shifted inward, never shrunk).
- `imaging/hfd.py`: optional `box=` on `measure_sweep_hfd` (l.321) / `frame_hfd` (l.268) replacing
  `_disk_crop_box`: crop to box padded by `r_max+stamp_pad`, keep only stars whose centroid is in the inner box,
  never fall back to full frame. `analyze_focus_samples` forwards `**hfd_kw`, so vcurve.py is unchanged.
- `catalogs/catshtm.py` (new): `CatsHtm(root, name, files_per_hdf=100)` with `columns()` (scipy `loadmat`, h5py
  fallback if v7.3) and `cone_search(ra_deg, dec_deg, radius_deg, columns)` — HTM recursion from root trixels with
  catsHTM's pole test, leaf datasets `htm_<ID>` in file `floor(ID/100)*100`, column-major transpose, radians,
  exact distance filter. Index cached per process; missing files/datasets logged, not fatal. **Lazy `import h5py`.**
- `focus_on_star/star_selection.py` (new): `isolation_radius_deg` (half-diagonal of box + margin × pixel scale —
  a circle, camera PA unknown), `select_focus_star(...)` (rule above), `find_focus_star(...)` (grow radius; query
  radius = r + iso_r so edge neighbours are seen; optional PM propagation from 2016.0).

**Solver**: no change — `phase="spec"` already aims at the fibre pixel.

**Small refactors**
- `calibration/phases/focuser.py:727` — `_still_calibrating` checks a class attribute `RUN_ACTIVITIES`
  (default `(CalibratingFocus, Calibrating)`) so a subclass can abort on its own flag.
- `calibration/calibrator.py:276` — lift `_zenith_dec` to module-level `zenith_dec(unit)`; method delegates.

**`focus_on_star/session.py` (new)** — `FocusOnStarSession` (start/abort/status/require_can_start, thread, flag)
and `FocusOnStarRun(FocuserCalibrator)` with `RUN_ACTIVITIES=(FocusingOnStar,)`, reusing `_goto`, `_wait_stage`,
`_expose`, `_sweep`, `_recentre`, `_move_focuser`, `_clamp`; never `calibrate()` / `_persist`.
Run sequence:
1. Sky position: zenith → (`pw.status().site.lmst_hours`, `zenith_dec`); ra/dec given → those; else mount's current J2000.
2. Geometry: frame shape, focus center (fibre pixel), fov box, isolation radius.
3. `find_focus_star` → fail clearly if none.
4. `stage.home()` + wait; `_goto(star)` (tracking on).
5. Set a fresh `Acquisition` on `unit.acquirer.latest_acquisition`; `solve_and_correct(..., phase="spec",
   parent_activity=FocusingOnStar)` with the same imager settings and tolerance the acquirer's spec phase uses
   (acquirer.py:325-380); no stage move to SPEC, no guiding handover. `finally` end a stray `Solving` flag and release the folder.
6. Seed = current focuser position; `st = settings.focuser.model_copy(update={images: steps, spacing: ticks_per_step, exposure, binning})`.
7. Probe frame: verify a source near box center, back off exposure if saturated.
8. `_sweep` → `analyze_focus_samples(..., box=box)` + `max_best_hfd_px` gate; `_recentre` if tries remain.
   Skip `_acquire_near_focus` (full-frame star-count triage is meaningless here).
9. Solved → move to best; else → back to start. `finally`: end exposure series, `plot_vcurve`, `save_status`,
   `focus_on_star.json` (params, star, focus center, box, seed, outcome), `move_to_shared`, end flag.

Refusals (before any motion): missing components; no `guiding.rois[fcu]`; no `calibration.products.focuser`;
a conflicting activity active (Calibrating*, Autofocusing*, Acquiring, Guiding, FluxMetering, FocusingOnStar);
`steps` even or < 3; zenith=True with ra/dec, or only one of ra/dec.

**`unit.py` wiring**: add `FocusingOnStar` to `_ABORTABLE_WORK` (l.95-112); `self.focus_on_star = FocusOnStarSession(self)`
next to flux_metering (~l.284); abort hook in `abort()` (~l.740);
`PUT /unit/focus_on_star` (`zenith=True, ra_j2000_hours=None, dec_j2000_degs=None, fov_percent=10, star_magnitude, steps=5,
ticks_per_step=50`; `@endpoint(tier=Tier.OPERATION, completion=UnitActivities.FocusingOnStar)`; coords parsed by
`flux_metering.session.parse_target`; description notes the routine chooses the star and that `star_magnitude` is Gaia G) and
`GET /unit/focus_on_star_status`, added in `api_router` (~l.2096).
Optionally make `Calibrator._start` and `Autofocuser.start_autofocus` refuse while `FocusingOnStar`.

**Dependency**: `unit/requirements.txt` add pinned `h5py` (numpy-2.5-compatible; 3.16.0 verified) with an importer comment.

## Tests
- `test_catshtm_reader.py` — synthetic depth-2 HTM catalog in `tmp_path` (index, 2 data files, ColCell via
  `savemat`): exact cone result, RA seam, pole, missing files, column subset.
- `test_focus_on_star_selection.py` — mag rule, tiebreak, isolation reject/accept, radius growth, PM.
- `test_fov_box.py` — 829×564 at 10%, edge shift, binning, focus center taken from `guiding.rois[fcu]`.
- `test_hfd_box.py` — out-of-box stars ignored, edge stamps unclipped, synthetic defocus series solves.
- `test_focus_on_star_run.py` (fakes) — flag balanced on every exit; `solve_and_correct` called with `phase="spec"`;
  no stage move to SPEC, no guiding; no `_persist` / `Config().set_unit`; focuser ends at best / at start; abort mid-sweep; refusals.
- Shape-gate replay: subsample recorded sweeps to 5×50 ticks to set `min_edge_rise`/`min_fit_r2` defaults.
- Contract suite (`tests/contract/`) passes.

## As built (2026-10-11) — where the code differs from the plan above
Branches `focus-on-star` in MAST_common (73f03aa) and MAST_unit (e5e0844).
- **Settings fields are documented with comments**, not `json_schema_extra`: that is the style of
  `config/calibration.py`. Added `catalog_epoch=2016.0`.
- **Stage:** the run puts the stage where the acquirer's spec phase does before solving (Sky on FCU v2,
  Spec on v1) and keeps it there for the sweep, instead of `stage.home()`. FCU v1 is untested.
- **Acquirer refactor:** `Acquirer.spec_phase_imager_settings()` / `spec_phase_tolerance()` extracted from
  `do_acquire`, so focus_on_star solves exactly as the spec phase does instead of copying its overrides.
- **Endpoint parameters** other than zenith/ra/dec default to `None` and fall back to `FocusOnStarSettings`,
  so per-unit defaults live in the config DB.
- **End state:** solved → tracking left on (the star stays put); failed or aborted → tracking stopped, as a
  failed acquisition leaves it. An aborted run leaves the focuser where it is; only a failed one returns it.
- **Unit status** does not carry focus_on_star; `GET /unit/focus_on_star_status` is the only view.
- **Near-focus precondition** (2026-10-18): a `/calibrate/focuser` product is preferred; without one, a set
  `focuser.known_as_good_position` (> 0, the last ps3cli autofocus, where the focuser goes at startup) is accepted.
  The status reports which as `focus_reference`. mast00 had no product and `known_as_good_position = 13267`.
- **Found, not fixed (pre-existing, separate issues):**
  - `Solver.solve_and_correct`'s synthesised-acquisition branch (no `latest_acquisition`) passes `conf=` to
    `Acquisition`, whose constructor no longer takes it — a `TypeError` if that branch ever runs.
    focus_on_star always sets `latest_acquisition` first, so it never takes that branch.
  - The cancelled early `return False` in `solve_and_correct` leaves `Solving` set; focus_on_star clears it.
- **h5py** is pinned at 3.16.0 in `unit/requirements.txt` but is not yet installed on any unit; until it is,
  only focus_on_star fails there (lazy import, clear error).
- Tests: 51 new in MAST_unit + 5 in MAST_common (reader on a synthetic HTM catalog, selection, box geometry, HFD box, run sequence);
  full unit suite 877 passed; common 717 passed.

## Catalog layout — verified 2026-10-11 (h5py 3.16.0, numpy 2.5.1, from mast00 over SMB)
- `GAIADR3_htmColCell.mat` is MATLAB v5 → `scipy.io.loadmat` works. `ColCell` (53 names) + `ColUnits`.
  Needed columns (0-based): `RA`=0 (rad), `Dec`=1 (rad), `Epoch`=2 (2016), `PMRA`=7 (mas/yr), `PMDec`=9 (mas/yr),
  **`phot_g_mean_mag`=26** → `mag_column = "phot_g_mean_mag"`.
- `GAIADR3_htm.hdf5`: dataset **`GAIADR3_HTM`**, float32, stored **(13, 699048)** → transpose. Columns: Level, Father,
  Son1-4, Poles1Lon, Poles1Lat, Poles2Lon, Poles2Lat, Poles3Lon, Poles3Lat (rad), Nsrc. IDs and son IDs are **1-based**
  (row index + 1). Roots = IDs 1-8 (Father NaN). Levels 0-8; 524288 leaves, first leaf ID 174761. Also a junk `ColNames` dataset — ignore it.
- Data: file `GAIADR3_htm_{floor(ID/100)*100:06d}.hdf5`, dataset `htm_{ID:06d}`, float64 stored **(53, N)**, rows sorted by Dec;
  each also has an `htm_{ID:06d}_Ind` companion (unused). Read only the needed rows: `ds[[0,1,7,9,26], :]`.
- Pole test `all(angdist(point, pole) < pi/2 + r)` descending from the 8 roots is **complete**: a 0.5° cone equals the
  2° cone cut to 0.5° at (0,+30), (90,+30), (277.5,+30), (10,+89.8), (359.9,0).
- Timing: full index read 0.38 s (36 MB). Cone 0.5°: 26-30 leaves, 3-4 files, 0.35-0.55 s. Cone 1°: 70-100 leaves,
  0.4-1.3 s. So SMB speed is not a risk; caching the index per process is still worth it.
- Star density at zenith (dec +30.05), 1° cone: G<10: 31-63 stars, G<12: 147-472, G<14: 702-2621 (LST 0h / 6h / 18.5h).

## Verification
1. ~~Step 0~~ done, see above.
2. `pytest unit/tests common/tests`; `ruff check`.
3. Daytime dry run: refusals, star selection visible in status, `/unit/abort` mid-run clears the flag.
4. On sky after `/calibrate/focuser` (or at `known_as_good_position`): run at zenith, explicit ra/dec, and current position; check the star lands on
   the fibre pixel in the probe frame, the stage stays clear and no guiding starts, V-curve artifacts in
   `Calibration/FocusOnStar/<NNNN>/`, best ≈ calibrated best, config DB unchanged.

## Risks to watch
- ±100-tick sweep may not pass calibration shape gates → focus_on_star's own gate defaults, set from replay.
- Saturation of a single star → probe frame with exposure back-off; tune magnitude/exposure on sky.
- `solve_and_correct` early-return leaves `Solving` set (handled locally; upstream fix separate).
- `\\last0` unreachable → load on the run thread, report the share as unreachable (speed itself measured fine).
- The fibre pixel is a stand-in for the optical center; if they differ much, the box sits off-axis (more coma).
  Revisit when the optical-center calibration is done.
