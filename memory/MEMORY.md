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
- [Folding-mirror shadow detection (implemented)](mirror-shadow-detection-impl.md) — src/imaging/mirror_shadow.py: tilted-band detect/mark/centerline/darken; projection sweep, band-excluded sky fill; thresholds need a clean frame to validate
- [Shadow & optical-center algorithms (logic/rationale)](mirror-shadow-optical-center-algorithms.md) — how/why: deficit ratio map, ±90° projection orientation sweep, false-positive gates, collar-matched sky fill, coma-null line-intersection fit, and the "mandate retraction, detect-as-guard" coupling decision

### MAST_unit — mount guiding / solve_and_correct (2026-06-19)
- [mount.is_moving is a slew detector](mount-is-moving-is-a-slew-detector.md) — axis rms_error>3"/1"; was misused as a settle gate (all such sites now migrated); definition now fits its slew-completion/telemetry uses
- [solve_and_correct channel mismatch](solve-and-correct-gradual-offset-channel-mismatch.md) — root cause of slow/erratic convergence: polled axis0/axis1 progress after commanding ra/dec; FIXED, now on wait_until_settled
- [wait_until_settled settle-gate fix](wait-until-settled-settle-gate-fix.md) — Mount helper matching wait signal to move type; wired into all settle-gate sites; ApproachMode enum added; not hardware-verified

## Feedback
- [Opinion shorthand — ???](feedback_opinion_shorthand.md) — when user types ???, they want my opinion/thoughts/suggestions
- [SSH key auth on Windows](feedback_ssh_windows.md) — use C:\ProgramData\ssh\administrators_authorized_keys, not ~/.ssh/authorized_keys
- [json_schema_extra formatting style](feedback_json_schema_extra_formatting.md) — one entry per line, tooltips never wrapped
- [MAST_common sync rule](feedback_mast_common_sync.md) — changes under any common/ must be synced to all other checkouts
- [Modal form design policy](feedback_form_design.md) — horizontal layout: col-4 bold right-aligned label, col-8 input, row mb-2
- [HTML indentation style](feedback_html_indentation.md) — 2-space indentation in all HTML templates, never tabs
- [Post-change instructions](feedback_post_change_instructions.md) — always state restart/refresh needed after changes
- [Weizmann HTTP proxy](feedback_weizmann_proxy.md) — http://bcproxy.weizmann.ac.il:8080; use as fallback only after direct git/curl access times out
