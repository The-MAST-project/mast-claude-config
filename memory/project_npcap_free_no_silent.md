---
name: npcap-free-no-silent
description: Free Npcap installer ignores /S and all feature flags (OEM-only); hangs invisibly on Session 0. RESOLVED 2026-05-27 by moving install to interactive bootstrap; npcap provider is now verify-only.
metadata: 
  node_type: memory
  type: project
  originSessionId: d3e6bb15-ec6f-4fae-8e2d-d93adb59e731
---

The `npcap-X.YY.exe` we ship in MAST_provisioning (assets/npcap-1.88.exe) is the
**free** edition. Silent install (`/S`) and all feature flags (`/loopback_support=`,
`/winpcap_mode=`, `/admin_only=`, `/dlt_null=`, `/prior_driver=`, `/D=`, etc.) are
**OEM-only**. The free installer accepts the flags on the command line but ignores
them and unconditionally renders the NSIS "Installation Options" page.

**Why:** Confirmed on 2026-05-26 on mast-unit (192.168.56.113). Provide-npcap.ps1
launched the installer via SYSTEM scheduled task with `/S /loopback_support=yes
/winpcap_mode=yes /admin_only=no /dlt_null=yes`. The npcap-1.88.exe process hung
for ~2.5h in Session 0 with 1 thread / 0.09s CPU / 122KB WS / no children.
`%WINDIR%\Temp\nsc*.tmp\options.ini` contained the 9-field options dialog
(LOOPBACK, ADMIN_ONLY, DOT11, WINPCAP checkboxes, etc.) and `final.ini` had the
Finish page - definitive proof the GUI page got extracted and was waiting for a
Next click that can never come on Session 0. NPFInstall.exe was never spawned;
setupapi.dev.log had **zero** npcap entries, so the previously suspected
filtered-token / driver-trust hypotheses are downstream of a barrier the installer
never reached. Publisher pre-trust (Nmap Software LLC, thumbprint
0629C303220B256580AABA536A1A3C060B87E3A2) in LocalMachine\TrustedPublisher worked
fine - just irrelevant at this stage.

**RESOLVED 2026-05-27 (option 4):** Npcap install moved out of the WinRM provider
pipeline entirely into `client/bootstrap-winrm.ps1`, which runs interactively as a
full (unfiltered) admin token. The operator clicks through the installer GUI once,
which sidesteps both the un-dismissable options page (Session 0) and the filtered
token. The installer asset moved from `server/providers/npcap/assets/` to
`client/assets/npcap-1.88.exe`; `vm/build-autounattend-iso.ps1` stages it at the ISO
root next to bootstrap (newest `npcap-*.exe` wins). The `npcap` provider is now
**verify-only**: `provide-npcap.ps1` asserts the service/driver are present and
(re)registers the `npcapwatchdog` task. See DECISIONS.md 2026-05-27.

**How to apply:** Do NOT reintroduce installer-running logic into `provide-npcap.ps1`
or chase token-elevation / driver-trust / silent-flag fixes. To bump the Npcap
version, drop a new `npcap-*.exe` in `client/assets/`. See
[[mast-provisioning-upstream]].
