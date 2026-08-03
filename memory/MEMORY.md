# MEMORY.md

Shared, cross-cutting working-style preferences for the MAST team. Project-specific
context, design plans, and machine-specific notes deliberately do NOT live here —
durable engineering knowledge belongs in each repo's `CLAUDE.md` / `docs/`, and
in-progress or machine-local notes stay in each developer's local `~/.claude` memory.

## Reference
- [MAST fleet topology](reference_fleet_topology.md) — machines/IPs/sites, mast-share Samba (creds mast/physics), per-host SSH access, Windows per-session drive-mapping gotcha
- [Integration branch per MAST repo](reference_repo_branches.md) — `MAST_common`/`MAST_control`/`MAST_spec` integrate on `master`, the rest on `main`; single `origin` remote, no `upstream`

## Project
- [Prometheus monitoring of the Windows fleet](project_prometheus_windows.md) — windows_exporter on units, Prometheus on the control machine; onboarding steps
- [SwitchedOutlet polish plan](switched-outlet-polish-plan.md) — PLANNED after calibration works: own PR against MAST_common main; ranked defects (tri-state collapse, silent power_on_or_off, dead _from_group, hostname fallback); mechanical-then-behavioural staging, tests first, cross-repo call-site survey
- [`Mount.is_moving` is a tracking-quality signal, not a motion one](mount-is-moving-is-a-slew-detector.md) — MAST_unit; PWI4 rms thresholds mirror the GUI, so in wind it reads True while parked on target and `while mount.is_moving` stalls

## Feedback
- [Comment out, don't delete, when disabling temporarily](feedback_comment_dont_delete.md) — preserves position for re-enablement
- [Never run git writes/pushes unprompted](feedback_no_unprompted_git_writes.md) — no commit/push/rm/reset/rebase/tag without an explicit request in the current turn; read-only git is fine
- [Throwaway tests live outside module trees](feedback_throwaway_tests_outside_modules.md) — one-off assessments get a fresh top-level dir; never nest in a source module
- [Opinion shorthand — `???`](feedback_opinion_shorthand.md) — when the user types `???`, they want opinion/suggestions, not task execution
- [Post-change instructions](feedback_post_change_instructions.md) — after code/config changes, state what's needed: restart backend / restart Django / refresh page
- [SSH key auth on Windows](feedback_ssh_windows.md) — add public keys to `C:\ProgramData\ssh\administrators_authorized_keys`, not the per-user file
- [Weizmann HTTP proxy](feedback_weizmann_proxy.md) — route GitHub git access through `http://bcproxy.weizmann.ac.il:8080` (direct always times out); env var, not git config
- [Use no_proxy for internal MAST machines](feedback_no_proxy.md) — bypass the proxy for internal fleet hosts (10.23.x, localhost); external URLs still go through it
- [GitHub over SSH — tunnel through proxy](feedback_github_ssh_proxy.md) — port 22 blocked; SSH over 443 to ssh.github.com via nc ProxyCommand in ~/.ssh/config; use SSH keys, not PATs
