---
name: astrometry-avx-vm
description: "astrometry.net binaries need AVX/AVX2/FMA; the VirtualBox dev VM CPU exposes only sse4_2, so astrometry-engine dies with SIGILL. VBox could not expose AVX2 to the guest on the Meteor Lake host. The dev VM cannot validate a real solve."
metadata: 
  node_type: memory
  type: project
  originSessionId: fe8833d2-b3ef-4810-a6a4-90a94adf1586
---

The prebuilt astrometry.net binaries (`astrometry.tgz`) are compiled with
**AVX/AVX2/FMA**. The VirtualBox `mast-unit` VM's virtual CPU exposes only
**`sse4_2`** (no avx/avx2/fma), so `astrometry-engine` crashes with **signal 4
(SIGILL, illegal instruction)** the moment real solving starts -- AFTER it has
already extracted sources and (with fitsio installed) passed removelines. This
is NOT the corrupt index and NOT a script bug: confirmed by removing the corrupt
index entirely and still getting SIGILL, and by `/proc/cpuinfo` showing only
`sse4_2`.

**Tried to expose AVX2 in VBox 7.2.8 on the host (Intel Core Ultra 7 155H,
Meteor Lake hybrid) -- FAILED:**
- `VBoxManage setextradata mast-unit VBoxInternal/CPUM/IsaExts/AVX 1` (+AVX2):
  VM boots, but guest still reports AVX/AVX2 absent
  (`IsProcessorFeaturePresent(39/40)` = False -- VBox didn't enable the CPUID
  bit + XSAVE/OS-AVX state). `FMA3` is not a valid IsaExts key (startvm errors
  VERR_CFGM_CONFIG_UNKNOWN_VALUE).
- `--cpu-profile host` is the VBox **default** anyway (key is `cpu-profile`, not
  `CPUProfile`); no extra AVX. (A `controlvm screenshotpng` showed the desktop;
  WinRM is just slow to come up after a cold boot / CPU change -- the long
  "Restarting" screens were Windows reconfiguring after CPU-setting changes +
  an interrupted pending-reboot, not an AVX boot crash.)

Conclusion: **VBox cannot give this guest AVX2 on this hybrid host**, so the dev
VM cannot run a real astrometry solve. Options not yet chosen: (1) validate
astrometry only on real MAST hardware (has AVX2); (2) ship AVX-free astrometry
binaries (rebuild astrometry.tgz with conservative -march) for VM/test; (3) use
a hypervisor that exposes AVX2 (Hyper-V/VMware/WSL2) or a non-hybrid host.

**Resolved (dev-VM only) by `-AllowMissingAvx` (2026-05-28):** `build-mast.ps1`
injects `-AllowMissingAvx` (PS) / `--allow-missing-avx` (py) into the
astrometry-verify and mast-validation commands when `-TestMode` is set. The
provider then detects `killed by signal 4` / `SIGILL` in stderr and treats it
as SKIPPED (`solve=skipped reason=avx_missing`) instead of FAIL. Production
runs (no `-TestMode`) keep the hard FAIL. Corrupt-index files are a hard FAIL
regardless of the flag. See DECISIONS.md 2026-05-28,
[[astrometry-index-image-validation]], [[project_astrometry_install]].

VM recovery note: hard `controlvm poweroff` of a dirty/pending-reboot VM, plus
CPU-setting changes, left it cycling on "Restarting" for a long time; restoring
the `post-prepare` snapshot recovers it (it is an online/saved-state snapshot, so
a clean CPU config lets it resume). If WinRM doesn't return after a cold boot, the
guest host-only IP may have shifted -- re-run vm/sync-dev-unit-hosts.ps1.
