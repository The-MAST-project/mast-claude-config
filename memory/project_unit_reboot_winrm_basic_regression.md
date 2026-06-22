---
name: project_unit_reboot_winrm_basic_regression
description: "After the provisioning reboot, mast01 WinRM-over-HTTP-Basic regressed (401), blocking post-run triage"
metadata: 
  node_type: memory
  type: project
  originSessionId: d4f0e3ee-734e-470c-99e7-fc21b3eb335d
---

On the 2026-05-31 real-hardware run, the `reboot` provider (last step) rebooted mast01 at end of provisioning. Afterward the orchestrator's unit health check got `WinError 10061` (connection refused, unit still rebooting), and later triage from the host got `401 InvalidCredentialsError` from WinRM 5985 even though port 5985 AND ssh 22 were open and ping worked. Same creds (`.\mast`) had worked at run start.

Likely cause: after reboot the network profile flips back to Public (or AllowUnencrypted resets), so WSMan refuses unencrypted HTTP Basic - exactly the failure mode `bootstrap-winrm.ps1` works around at first setup.

**Why:** post-reboot the unit is not reliably reachable over the harness's HTTP-Basic WinRM, so post-provision verification/triage breaks. **How to apply:** for post-reboot triage use SSH (port 22, mast/physics, enabled by bootstrap) instead of WinRM, or re-assert Private profile + AllowUnencrypted on the unit. Consider whether the `reboot` provider should re-ensure WinRM-Basic usability (or the harness reconnect via SSH) after the final reboot. Related: [[project_ps_winrm_exit_hang]].
