---
name: astrometry-index-image-validation
description: Astrometry indexes live on D:\mast-indexes (ImDisk). As of 2026-06-18 the drive is a SPARSE 32GB image BUILT ON THE UNIT from a staged index-file seed (was a baked ~15GB image); validation mandatory (no skips). solve-field silently skips a corrupt index -> verify scans stdout/stderr and warns.
metadata: 
  node_type: memory
  type: project
  originSessionId: fe8833d2-b3ef-4810-a6a4-90a94adf1586
---

**UPDATE 2026-06-18 (supersedes the image-format details below):** The monolithic
~15GB baked image is gone. The seed is now just the index FITS files
(`C:\MAST\mast-indexes`, staged as `<payload>\mast-indexes`); `provide-imdisk.ps1`
builds a **sparse 32GB NTFS image** `MAST-32GB-indexes-5202+5203.img` on the unit
(sparse file + `imdisk -a -m D: -s 32G` + quick NTFS format + robocopy the seed),
32GB logical / ~10GB allocated, mounted at `D:` via `imdisk -a -m D: -s 32G -f <image>`
(boot task `MAST-ImDisk-Persistent`). Reboot-persistence + sparseness validated on the
dev VM. Host populates the seed once via `build/extract-index-seed.ps1` (extracts from
the legacy 15GB image). mast02 is the reference unit already on this layout. See the
2026-06-18 DECISIONS.md entry. Index *content* (series 5202+5203, ~96 files / ~9.85GB)
and the validation behavior below are unchanged.

The astrometry index data is a ~15GB **ImDisk file-backed image**
`MAST-15GB-indexes-5202+5203.img`, mounted as `D:` with indexes at
`D:\mast-indexes` (series 5202+5203, ~96 files / ~9.7GB). Historically the image
+ the smoke FITS `C:\MAST\full-frame.fits` were supplied out-of-band and were
**absent on the dev VM**, so `verify-astrometry.ps1` and
`mast-validation/validate_mastrometry.py` took `solve=skipped` paths and went
green WITHOUT ever solving. Fixed 2026-05-27 (see DECISIONS.md):

- **No skips.** Both stages now hard-FAIL when the FITS or indexes are missing.
- **Staged via pipeline.** `build-mast.ps1` stages the image + FITS from the build
  host's `C:\MAST\MAST-15GB-indexes-5202+5203.img` and `C:\MAST\full-frame.fits`
  ("use these paths for now"). `provide-imdisk.ps1` copies the image to the
  persistent `C:\MAST\Shared\<name>.img` and mounts `D:` in-session;
  `provide-astrometry.ps1` places `full-frame.fits` at `C:\MAST\full-frame.fits`.
- **Corrupt-index detection.** `solve-field` silently skips an index it cannot
  load (e.g. missing kdtree header -> still structurally valid FITS, so
  `fitsverify` passes) and converges via the others. `verify-astrometry.ps1`
  and `validate_mastrometry.py` scan solver stdout/stderr/errors for
  `Failed to add index "..."` / `Failed to load index from path ...` /
  `Kdtree header was not found` and emit a **HARD FAIL** (2026-05-28; the
  earlier warn-default + `-FailOnIndexLoadError` switch was removed -- a
  corrupt staged index is always invalid, dev or prod). `-AllowMissingAvx`
  does NOT relax this.
- **Dev-VM AVX escape.** The VBox VM CPU lacks AVX, so astrometry-engine
  SIGILLs (signal 4) during the solve. `build-mast.ps1 -TestMode` injects
  `-AllowMissingAvx` / `--allow-missing-avx` so that specific failure becomes
  a SKIP with `solve=skipped reason=avx_missing`. Prod (no TestMode) hard
  FAILs. See [[astrometry-avx-vm]].

Gotchas: dev VM `D:`/`E:` are the VBox install/autounattend CD-ROMs, so `D:` must
be freed for the index mount (operator remaps the optical drive). The 15GB image
now flows through staging + SMB every run and is SHA256'd in the build-manifest
payload hash (slower builds) -- accepted "for now"; future: content-addressed /
pre-seed delivery + exclude bulk assets from the hash. See
[[project_astrometry_install]], [[project_mongodb_setup]].
