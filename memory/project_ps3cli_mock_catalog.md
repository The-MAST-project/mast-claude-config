---
name: project_ps3cli_mock_catalog
description: ps3cli --server boot contract (mock UC4/Orca catalog) and the LocalSystem discovery blocker
metadata: 
  node_type: memory
  type: project
  originSessionId: adcb216f-dbad-478a-9f78-708d1f251ba1
---

The 2024 `ps3cli` (`ps3cli-2024-09-10`, the ~4 MB special `--server` build) is used by MAST_unit **only for autofocus analysis** (`begin_analyze_focus` on port 8998), NOT for plate solving. But `ps3cli --server` validates a star catalog at startup and exits (code 2, "Catalog files not found") if absent.

**Minimal mock catalog to satisfy bootup** (proven empirically on the VM):
- `<cat>\UC4\Index.UC4` - must exist; content irrelevant (0 B OK)
- `<cat>\Orca\Orca0025.orc` - must exist and be NON-empty (>=1 byte; validator reads it)
- `<cat>\Orca\StarOrca0025.orc` - non-empty
- `<cat>\Orca\DistOrca0025.orc` - non-empty
- The 180 zone files `Z000.UC4`..`Z179.UC4` are NOT read at boot (only during real solving). Filenames were recovered by extracting UTF-16LE strings from ps3cli.exe.

**Discovery blocker:** `mast-unit` runs as **LocalSystem** (NSSM `install` with no `ObjectName`), so the app's `Path.home()` is `C:\Windows\system32\config\systemprofile`, not `C:\Users\mast`. Both `_locate_ps3cli_dir()` and `_locate_ps3cli_catalog()` in app.py fall back to `Path.home()`, so under the service they find NEITHER ps3cli.exe (extracted to `~mast\Documents\PlaneWave\ps3cli`) nor the catalog. Fix = the app's own first-priority override env vars, set at Machine scope in provisioning: `PS3CLI_DIR=C:\Users\mast\Documents\PlaneWave\ps3cli` and `PS3CLI_CATALOG=C:\Users\mast\Documents\Kepler`.

RESOLVED 2026-06-11: the `needs_console` switch in MAST_common `ensure_process_is_running` was a misdiagnosis of this catalog failure (ps3cli exits code 2 with/without a console when the catalog is missing; stays up with/without when present). Removed the param entirely from MAST_common/process.py + the submodule copy, and dropped `needs_console=True` from app.py's ps3cli call. OPEN QUESTION: whether the MOCK catalog suffices for actual autofocus analysis (`begin_analyze_focus`) or whether that path reads real UC4/Orca data - only `--server` boot is proven so far.

NOTE: the catalog-aware app.py (`_locate_ps3cli_catalog` + `--root-path`) is the NEWER local `MAST_unit.2024-12-12` copy; the VM's deployed `C:\MAST\repos` copy was still the OLDER version (`ps3cli.exe --server --port=8998`, no catalog discovery). Full live verification needs the newer app.py deployed. See [[project_mast_provisioning_upstream]].
