---
name: project_real_unit_d_drive_imdisk
description: "On real MAST units D: is occupied, so the imdisk index-image mount is skipped and astrometry/mast-validation verify fail"
metadata: 
  node_type: memory
  type: project
  originSessionId: d4f0e3ee-734e-470c-99e7-fc21b3eb335d
---

First real-hardware (non-VM) provision run against mast01 (2026-05-31) failed 0/1 cycles. Root cause of 3 of the 5 failures: the imdisk provider logged `[INFO] D: already in use; skipping immediate mount. Existing mount left intact.` so the ~15GB astrometry index image was never mounted at `D:\mast-indexes`. That cascaded into hard FAILs: `astrometry-verify` ("no astrometry index files reachable"), `mast-validation` ("no_index_dir (D:\mast-indexes)"), and `mast-validation-verify` (smoke marker missing).

On the dev VM, D: was free for ImDisk to claim. On a real unit D: is already in use by something else (physical partition or a leftover/stale mount) - still needs confirmation of exactly what occupies D: (WinRM was unusable post-reboot when triaging; check `Get-Volume`/`imdisk -l` on the unit).

**Why:** The imdisk provider's "mount index image as D:" choice is a VM-era assumption that does not hold on real hardware. **How to apply:** before re-running on a real unit, decide the index-image mount letter dynamically (or free/confirm D:), and re-test. Smoke markers in results.json for `astrometry`/`chrome` showed *_ok despite step failures because mast01 had been provisioned before - treat smoke markers on a previously-provisioned unit as possibly stale. Related: [[project_astrometry_index_image_validation]], [[project_ps_winrm_exit_hang]].
