# MEMORY.md

## Reminders
- [ORCID account check](reminder_orcid.md) — verify if ORCID developer account exists before configuring OAuth

## Project
- [Plans form design decisions](project_plans_form_design.md) — card grid layout, capabilities, data flow, notifications, Batch model
- [Plans feature - work in progress](project_plans_wip.md) — what's done, what's next, files changed
- [Plans — Science model & search feature](project_plans_science_search.md) — Science Pydantic model, makedb tool, searchable fields design
- [Plans — mockup plans TODO](project_plans_mockup.md) — 50 WD mockup plans, mockup.scientist user, submitted/pending deployment
- [MAST_gui cleanup map](project_mast_gui_cleanup.md) — dead stub apps, duplicate files, artifacts; checklist for future cleanup
- [Security approach — JWT](project_security.md) — JWT everywhere: Django GUI, FastAPI backends, mast-api.sh shell script
- [Resources sidebar & nginx setup](project_resources_sidebar.md) — Grafana iframe via /resources/ nginx location, nginx change still needs sudo
- [Sidebar submenu implementation](project_sidebar_submenus.md) — Bootstrap Collapse, not custom JS; why it was changed
- [WIP skills](project_wip_skills.md) — /wip-commit and /wip-status skills in ~/.claude/skills/
- [Spec 3D rendering design](project_spec_3d_rendering.md) — ModelUpdater, SSE integration, realtime/simulated modes, data field in activities
- [Unit self-calibration design](unit-self-calibration-design.md) — design-only: autofocus (HFD/coma), optical-center null, thermal focus seed, calibration invocation/status, pick-off stage geometry, config-DB storage

### MAST_unit — mount guiding / solve_and_correct (2026-06-19)
- [mount.is_moving is a slew detector](mount-is-moving-is-a-slew-detector.md) — axis rms_error>3"/1"; was misused as a settle gate (all such sites now migrated); definition now fits its slew-completion/telemetry uses
- [solve_and_correct channel mismatch](solve-and-correct-gradual-offset-channel-mismatch.md) — root cause of slow/erratic convergence: polled axis0/axis1 progress after commanding ra/dec; FIXED, now on wait_until_settled
- [wait_until_settled settle-gate fix](wait-until-settled-settle-gate-fix.md) — Mount helper matching wait signal to move type; wired into all settle-gate sites; ApproachMode enum added; not hardware-verified

### MAST_provisioning & unit setup (Windows host)
- [Sibling repos cloned on Desktop/MAST](project_sibling_repos_layout.md) — control/gui/spec(+mast-claude-config) cloned for cross-repo config-change visibility; control on master, gui has a Windows-illegal `<app>` path needing sparse-checkout, spec's common pin is missing
- [LOCKED plan: TOML bootstrap config](project_config_file_plan_locked.md) — full locked implementation plan for eli/configuration-file (LocalConfig + C:\WIS\<role>.toml loader, Mongo-only, validate-on-startup); site NEVER from hostname
- [eli/configuration-file branch (both repos)](project_configuration_file_branch.md) — branch moving hard-coded values from MAST_common config/__init__.py into a .toml file; lives on The-MAST-project not the fork
- [MAST_common base is master, not main](project_mast_common_base_master.md) — PR base / diff target for MAST_common is master (upstream/master); main has no merge base
- [MAST_provisioning upstream / fork layout](project_mast_provisioning_upstream.md) — `upstream` = The-MAST-project, `origin` = elibrody-weizmann fork; "fetch latest" means `git fetch upstream`
- [ZWO camera driver never binds under /S — FIX STASHED](project_zwo_usb2_driver_skipped.md) — `/S` install hits Session-0 publisher-trust prompt; pre-trust cert fix implemented but UNCOMMITTED + untested on a unit
- [NTP priority-list plan (stashed)](project_ntp_priority_list_plan.md) — timesync ordered list (RPI@Naot Smadar, Weizmann internal, prov server #3, Windows default); BLOCKED on RPI + Weizmann IPs
- [ps3cli mock catalog + LocalSystem discovery](project_ps3cli_mock_catalog.md) — ps3cli --server boot contract (UC4\Index.UC4 + 3 non-empty Orca\*.orc); needs PS3CLI_DIR/PS3CLI_CATALOG machine env vars
- [Free Npcap installer has no working silent mode](project_npcap_free_no_silent.md) — /S flags are OEM-only; install moved to interactive bootstrap, npcap provider now verify-only
- [Autofocus solve extracted + validated on VM](project_autofocus_solve_validation.md) — ps3cli focus analysis works on dev VM; solve lifted into src/focus_analysis.py, validated by tests/autofocus harness
- [astrometry.net 0.97 installed in C:\cygwin64](project_astrometry_install.md) — bins at /usr/local/astrometry/bin; indexes at D:\mast-indexes (don't delete); ansvr removed
- [Astrometry index image + mandatory validation](project_astrometry_index_image_validation.md) — D:\mast-indexes via ImDisk; sparse 32GB image built on the unit from a staged index-file seed; validation no longer skips
- [solve-field needs /usr/lib/lapack on PATH](project_astrometry_lapack_path.md) — otherwise removelines fails with numpy ImportError; prepend both C:\cygwin64\bin AND /usr/lib/lapack
- [astrometry needs AVX; dev VM CPU lacks it](project_astrometry_avx_vm.md) — astrometry-engine SIGILLs on the VBox VM (only sse4_2); needs real HW / AVX-free binaries / other hypervisor
- [Real units have D: occupied; imdisk index mount skipped](project_real_unit_d_drive_imdisk.md) — "D: already in use" breaks astrometry-verify + mast-validation on real hardware
- [MongoDB setup & VM test routing](project_mongodb_setup.md) — MongoDB 8.3.1 on host, mast DB seeded, -VmTestRun flag added to bootstrap-winrm.ps1
- [Proxy mode is explicit, not probed](project_proxy_mode_explicit.md) — `run-prov-test.py --proxy-mode {weizmann,direct}` (default weizmann); runs from home MUST pass `--proxy-mode direct`
- [bcproxy breaks WinINet/CryptoAPI cert revocation](project_proxy_cert_revocation.md) — cryptnet revocation fails through bcproxy; provide-proxy clears WPAD + mast-net.ps1 revocation toggle
- [Cygwin setup-x86_64.exe is broken in this shell](project_cygwin_setup_network_quirk.md) — WinINet error 12007; use cygwin-pkg-install.ps1 manual installer instead
- ["Unit finished but run_ps keeps ticking" has two causes](project_ps_winrm_exit_hang.md) — triage with `Get-Process wsmprovhost`: alive=unit-side PSEventJob hang, gone=host-side pywinrm dead socket
- [build-mast.ps1 emits JSON with UTF-8 BOM](project_ps_build_mast_utf8_bom.md) — Python readers must use vm_lib.load_json_file / parse_json_text, not raw json.loads
- [Post-reboot WinRM-Basic regresses on the unit](project_unit_reboot_winrm_basic_regression.md) — after the provisioning reboot mast01 gives 401 on WinRM 5985; use SSH (22, mast/physics) for triage

## Feedback
- [Opinion shorthand — ???](feedback_opinion_shorthand.md) — when user types ???, they want my opinion/thoughts/suggestions
- [SSH key auth on Windows](feedback_ssh_windows.md) — use C:\ProgramData\ssh\administrators_authorized_keys, not ~/.ssh/authorized_keys
- [json_schema_extra formatting style](feedback_json_schema_extra_formatting.md) — one entry per line, tooltips never wrapped
- [MAST_common sync rule](feedback_mast_common_sync.md) — changes under any common/ must be synced to all other checkouts
- [Modal form design policy](feedback_form_design.md) — horizontal layout: col-4 bold right-aligned label, col-8 input, row mb-2
- [HTML indentation style](feedback_html_indentation.md) — 2-space indentation in all HTML templates, never tabs
- [Post-change instructions](feedback_post_change_instructions.md) — always state restart/refresh needed after changes
- [DECISIONS.md is append-only](feedback_decisions_md.md) — never edit older entries; only prepend new dated entries
- [Comment out, don't delete, when disabling temporarily](feedback_comment_dont_delete.md) — preserves position for re-enablement
- [Cygwin-consumed config files need LF line endings](feedback_cygwin_cfg_crlf.md) — use [IO.File]::WriteAllText, not Set-Content; CRLF leaves trailing \r and opendir fails silently
- [Throwaway tests live outside module trees](feedback_throwaway_tests_outside_modules.md) — one-off assessments get a fresh top-level dir under C:\MAST\<name>\; never nest in MAST_unit src
- [Never run git writes/pushes unprompted](feedback_no_unprompted_git_writes.md) — no commit/push/rm/reset/rebase/tag without explicit request in the current turn; read-only git is always fine
