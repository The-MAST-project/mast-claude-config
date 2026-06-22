---
name: project-zwo-camera-driver-not-installed
description: "zwo provider's silent /S camera-driver install never binds the ASICAMUSB3 driver (Session-0 publisher-trust prompt)"
metadata: 
  node_type: memory
  type: project
  originSessionId: 757282d6-47c9-448c-bc71-7da888d305b9
---

The `zwo` provider runs `ZWO_ASI_Cameras_driver_Setup_V3.25.exe` with NSIS silent `/S` (`MAST_provisioning/server/providers/zwo/provide-zwo.ps1`). The installer's only driver is **ASICAMUSB3** (the ZWO ASI camera USB driver: `ASICAMUSB3.inf/.sys/.cat`, x64 + x86 under `driver\`). Under headless WinRM Session 0 the kernel-driver step hits the un-dismissable "trust this publisher?" prompt, so the **camera driver never actually binds** — yet the installer still exits 0 and the run reports SUCCESS. (Earlier I mis-identified this as a "USB2.0/ASI120" component; corrected 2026-06-16 — there is no separate USB2.0 driver in the installer, it's the one camera driver.)

The verify step (`module.json`) only checks for `ASIStudio.exe`, so it does not catch the missing driver.

FIXED 2026-06-16 (DECISIONS entry that date): applied the same pre-trust + pnputil pattern as `stage`/`usbpcap`/`npcap`. `provide-zwo.ps1` now imports the catalog publisher cert into `LocalMachine\TrustedPublisher` then runs `pnputil /add-driver ASICAMUSB3.inf` (add-driver only, no /install -- no camera attached during provisioning; Windows auto-binds on plug-in), before the installer block and outside the ASIStudio idempotent guard. Assets added: `server/providers/zwo/assets/zwo-driver-publisher.cer` (SUZHOU ZWO EV cert, issuer GlobalSign GCC R45 EV CodeSigning CA 2020, thumbprint `6BACCFE26EA1137F17609E622311112FE056E632`; timestamped so valid despite past NotAfter) + x64 driver payload under `assets/driver/x64/` (inf/sys/cat + WdfCoInstaller01009.dll, all four needed co-located per the inf). module.json: those 5 files added to commandfiles (build-mast flattens assets/* to staging root); verify now also requires `asicamusb3.inf` in `pnputil /enum-drivers`. Reference impl: `server/providers/stage/provide-stage.ps1`. Driver files cracked out of the NSIS installer with 7-Zip (installed via winget) into `C:\MAST\zwo-driver-extract\`. NOT yet built/tested on a unit.
