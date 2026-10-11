# Plan: `focus_on_star` — narrow-field autofocus on one isolated star at the optical center

## Context
The unit is already focused fleet-style via `/calibrate/focuser` (HFD V-curve, full frame). We want an
on-demand refinement: pick one isolated GAIA DR3 star, put it on the **optical center** with
mastrometry (no guiding), and run a short HFD V-curve analysed only in a small box (fov_percent of the
frame) around the optical center. The caller gives a sky position and a magnitude limit; the routine chooses the star.

Decisions taken with the user:
- The autofocus method = the existing **HFD V-curve** (`FocuserCalibrator` internals + `analyze_focus_samples`).
- Star rule: **G mag ≥ star_magnitude** (no brighter than the limit); choose the brightest such star
  (closest to the limit), tiebreak by distance from the sky position; no star brighter than it in the box.
- fov_percent is **linear**: box = p% of frame width × p% of height (10% → 829×564 px), centred on the OC.
- On success: **move the focuser only** — no `known_as_good_position`, no calibration product. On failure: return
  to the start position. Artifacts saved.

Facts found: catalog at `\\last0\catalogs\GAIA\DR3` is **catsHTM** (`GAIADR3_htm.hdf5` index,
`GAIADR3_htmColCell.mat`, 5246 `GAIADR3_htm_NNNN00.hdf5`); **h5py is not a dependency**; mastrometry only aims
at the sky-ROI center or the fibre (`solvers/mastrometry.py:176-206`); `Acquirer.do_acquire` moves the stage to
SPEC on FCU v2, so we bypass it and call `Solver.solve_and_correct` directly.

## MAST_common
1. `activities.py` — append `UnitActivities.FocusingOnStar = auto()` **after `Aborting`** (end-only rule).
2. `const.py:19` — `SolvingPhase = Literal["sky", "spec", "optical_center"]`.
3. `paths.py` — add `"focus_on_star": "FocusOnStar"` to `CALIBRATION_PHASE_FOLDERS` → `<night>/Calibration/FocusOnStar/<NNNN>`.
4. `config/calibration.py` — new `FocusOnStarSettings` hung on `CalibrationSettings.focus_on_star`
   (`default_factory`); `json_schema_extra` one key per line, tooltips on one line. Fields:
   catalog (`catalog_root=r"\\last0\catalogs\GAIA\DR3"`, `catalog_name="GAIADR3"`, `mag_column` — set from ColCell),
   search (`search_radius_deg=0.5`, `search_growth=2.0`, `max_search_radius_deg=4.0`, `isolation_margin_px=80`,
   `apply_proper_motion=True`), endpoint defaults (`fov_percent=10`, `star_magnitude`, `steps=5`, `ticks_per_step=50`),
   exposure/analysis (`exposure`, `binning=1`, `max_tries=1`, `tolerance_frac`, `min_fit_r2`, `min_edge_rise`,
   `max_best_hfd_px`, `max_saturation_retries=2`).
5. Tests: defaults test; `test_imports.py` still green.

## MAST_unit (`unit/src`)
**Pure helpers**
- `imaging/fov.py` (new): `frame_shape_bin1(imager)`, `optical_center_bin1(unit_conf, shape)` (product if
  `.matches(...)`, else frame center — same rule as `FocuserCalibrator._low_coma_zone`, focuser.py:476),
  `fov_box_size(shape, p)`, `fov_box(shape, oc, p, binning)` (shifted inward, never shrunk).
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

**Solver aims at the OC**
- `solving.py:270` — pass `phase` through when `"sky"` or `"optical_center"`.
- `solvers/mastrometry.py` — `case "optical_center":` no crop; `refpix` from `optical_center_bin1` via
  `pixel_grid.orig_to_grid_fits(c+1, downsample_factor)`; make the "refpix=center" log conditional.
  focus_on_star refuses if the solver isn't mastrometry.

**Small refactors**
- `calibration/phases/focuser.py:727` — `_still_calibrating` checks a class attribute `RUN_ACTIVITIES`
  (default `(CalibratingFocus, Calibrating)`) so a subclass can abort on its own flag.
- `calibration/calibrator.py:276` — lift `_zenith_dec` to module-level `zenith_dec(unit)`; method delegates.

**`focus_on_star/session.py` (new)** — `FocusOnStarSession` (start/abort/status/require_can_start, thread, flag)
and `FocusOnStarRun(FocuserCalibrator)` with `RUN_ACTIVITIES=(FocusingOnStar,)`, reusing `_goto`, `_wait_stage`,
`_expose`, `_sweep`, `_recentre`, `_move_focuser`, `_clamp`; never `calibrate()` / `_persist`.
Run sequence:
1. Sky position: zenith → (`pw.status().site.lmst_hours`, `zenith_dec`); ra/dec given → those; else mount's current J2000.
2. Geometry: frame shape, OC, fov box, isolation radius.
3. `find_focus_star` → fail clearly if none.
4. `stage.home()` + wait; `_goto(star)` (tracking on).
5. Set a fresh `Acquisition` on `unit.acquirer.latest_acquisition`; `solve_and_correct(..., phase="optical_center",
   parent_activity=FocusingOnStar, handover none)`; `finally` end a stray `Solving` flag and release the folder.
6. Seed = current focuser position; `st = settings.focuser.model_copy(update={images: steps, spacing: ticks_per_step, exposure, binning})`.
7. Probe frame: verify a source near box center, back off exposure if saturated.
8. `_sweep` → `analyze_focus_samples(..., box=box)` + `max_best_hfd_px` gate; `_recentre` if tries remain.
   Skip `_acquire_near_focus` (full-frame star-count triage is meaningless here).
9. Solved → move to best; else → back to start. `finally`: end exposure series, `plot_vcurve`, `save_status`,
   `focus_on_star.json` (params, star, OC source, box, seed, outcome), `move_to_shared`, end flag.

Refusals (before any motion): missing components; no `calibration.products.focuser`; a conflicting
activity active (Calibrating*, Autofocusing*, Acquiring, Guiding, FluxMetering, FocusingOnStar); `steps` even or < 3;
zenith=True with ra/dec, or only one of ra/dec.

**`unit.py` wiring**: add `FocusingOnStar` to `_ABORTABLE_WORK` (l.95-112); `self.focus_on_star = FocusOnStarSession(self)`
next to flux_metering (~l.284); abort hook in `abort()` (~l.740);
`PUT /unit/focus_on_star` (`zenith=True, ra_j2000_hours=None, dec_j2000_degs=None, fov_percent=10, star_magnitude, steps=5,
ticks_per_step=50`; `@endpoint(tier=Tier.OPERATION, completion=UnitActivities.FocusingOnStar)`; coords parsed by
`flux_metering.session.parse_target`; description notes the routine chooses the star) and
`GET /unit/focus_on_star_status`, added in `api_router` (~l.2096).
Optionally make `Calibrator._start` and `Autofocuser.start_autofocus` refuse while `FocusingOnStar`.

**Dependency**: `unit/requirements.txt` add pinned `h5py` (numpy-2.5-compatible) with an importer comment.

## Tests
- `test_catshtm_reader.py` — synthetic depth-2 HTM catalog in `tmp_path` (index, 2 data files, ColCell via
  `savemat`): exact cone result, RA seam, pole, missing files, column subset.
- `test_focus_on_star_selection.py` — mag rule, tiebreak, isolation reject/accept, radius growth, PM.
- `test_fov_box.py` — 829×564 at 10%, edge shift, binning, OC fallback.
- `test_hfd_box.py` — out-of-box stars ignored, edge stamps unclipped, synthetic defocus series solves.
- `test_focus_on_star_run.py` (fakes) — flag balanced on every exit; no `_persist` / `Config().set_unit`;
  focuser ends at best / at start; abort mid-sweep; refusals.
- `solvers/tests` — crpix for `optical_center` equals `orig_to_grid_fits(cx+1, 2)`.
- Shape-gate replay: subsample recorded sweeps to 5×50 ticks to set `min_edge_rise`/`min_fit_r2` defaults.
- Contract suite (`tests/contract/`) passes.

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
2. Standalone catalog query at zenith for a few LSTs (incl. Galactic plane); time the cold index load over SMB.
3. `pytest unit/tests common/tests`; `ruff check`.
4. Daytime dry run: refusals, star selection visible in status, `/unit/abort` mid-run clears the flag.
5. On sky after `/calibrate/focuser`: run at zenith, explicit ra/dec, and current position; check star lands near
   the OC in the probe frame, V-curve artifacts in `Calibration/FocusOnStar/<NNNN>/`, best ≈ calibrated best, config DB unchanged.

## Risks to watch
- ±100-tick sweep may not pass calibration shape gates → focus_on_star's own gate defaults, set from replay.
- Saturation of a single star → probe frame with exposure back-off; tune magnitude/exposure on sky.
- `solve_and_correct` early-return leaves `Solving` set (handled locally; upstream fix separate).
- `\\last0` unreachable → load on the run thread, report the share as unreachable (speed itself measured fine).
