---
name: project_autofocus_solve_validation
description: ps3cli focus analysis works on the dev VM (no AVX issue); autofocus solve extracted to focus_analysis.py + validated by tests/autofocus harness
metadata: 
  node_type: memory
  type: project
  originSessionId: dd70074a-6ea3-496c-ad5c-686c28ae29b0
---

The ps3cli autofocus-solve path was made testable and validated end-to-end on the dev VM (mast-unit @ 192.168.56.113 / mast-wis-01).

- The pure ps3cli step was lifted out of `Autofocuser.do_start_autofocus` into `src/focus_analysis.py:analyze_focus_files(files, timeout, host, port)` (returns `PS3AutofocusStatus`; raises `FocusAnalysisError(phase="start"|"finish")`). `autofocusing.py` imports the PS3* models + the function from there. The focuser position is encoded in the `FOCUSnnnnn.fits` filename, so analysis needs no focuser hardware.
- Validation harness: `tests/autofocus/validate_autofocus_solve.py` + `expected.json` + bundled `fits/<series>/`. Runs the production code path against recorded sweeps; exit 0 = all series solved within tolerance. Supports `"expect_solution": false` for negative controls.
- Bundled FITS came from the control host share `/Storage/mast-share/MAST/mast00/` — picked the sweeps that had a saved `status.json` (ground truth kept as `status.reference.json`): 2 solved (best≈21380 and ≈22500) + 1 no-solution negative control.

KEY FINDING: unlike astrometry-engine (which SIGILLs on this VBox VM for lack of AVX — see [[project_astrometry_avx_vm]]), **ps3cli `--server` boots AND runs focus analysis fine on the VM**. The 4MB `--server` build is at `C:\Users\mast\Documents\PlaneWave\ps3cli\ps3cli-2024-09-10\ps3cli.exe`; catalog at `C:\Users\mast\Documents\Kepler` (machine env PS3CLI_DIR/PS3CLI_CATALOG were empty, app.py falls back to default locations — see [[project_ps3cli_mock_catalog]]). Solved positions reproduced production ground truth to <0.2 ticks; 3/3 series passed.

Split: MAST_unit carries ONLY production code (focus_analysis.py + autofocusing.py refactor + the shared locator src/PlaneWave/ps3cli_locate.py, imported by app.py). ALL validation tooling + fixtures live in provisioning -- the FITS are NOT in MAST_unit (the user explicitly required this).

Wired into provisioning: new provider `MAST_provisioning/server/providers/mast-autofocus-validation/` (order 3000, after planewave + mast-validation), modeled on mast-validation. Contents: module.json, provide-*.ps1, validate_autofocus_solve.py (the runner; imports MAST_unit via `--unit-src`, like validate_mastrometry.py), assets/autofocus-fits.zip (the FITS bundle). The provide script locates the MAST_unit clone + venv, extracts the zip to C:\MAST\autofocus-fits (hard-fails if zip is an unresolved lfs pointer), runs the runner with the venv python (reuses running ps3cli `--server` on 8998 if up, else `--start-server`), writes a smoke marker the `verify` checks. Providers auto-discovered by `order` (no registry edit).

FITS storage: `assets/autofocus-fits.zip` (~24MB, series subdirs + expected.json) is git-lfs tracked via provisioning's EXISTING `.gitattributes` rule `server/providers/*/assets/*.zip filter=lfs`. Build flattens `assets/*` to staging root, so a single zip (not loose files) preserves the series structure. No unit-side git-lfs needed; only the provisioning server checkout must `git lfs pull`.

ps3cli discovery is DRY: `locate_ps3cli_dir()`/`locate_ps3cli_catalog()` live in MAST_unit `src/PlaneWave/ps3cli_locate.py`; both app.py and the validation runner import them (runner via --unit-src). No more duplicated locator.

Validated end-to-end on the VM via the provide script in staging layout: 3/3 pass, smoke marker written, verify exit 0. Note: VM test files get wiped on snapshot restore (post-prepare). Full clone-from-remote provisioning test needs the MAST_unit branch pushed + the provisioning autofocus-fits.zip committed/lfs-pushed first.
