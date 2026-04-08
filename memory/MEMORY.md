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

## Feedback
- [Opinion shorthand — ???](feedback_opinion_shorthand.md) — when user types ???, they want my opinion/thoughts/suggestions
- [SSH key auth on Windows](feedback_ssh_windows.md) — use C:\ProgramData\ssh\administrators_authorized_keys, not ~/.ssh/authorized_keys
- [json_schema_extra formatting style](feedback_json_schema_extra_formatting.md) — one entry per line, tooltips never wrapped
- [MAST_common sync rule](feedback_mast_common_sync.md) — changes under any common/ must be synced to all other checkouts
- [Modal form design policy](feedback_form_design.md) — horizontal layout: col-4 bold right-aligned label, col-8 input, row mb-2
- [HTML indentation style](feedback_html_indentation.md) — 2-space indentation in all HTML templates, never tabs
- [Post-change instructions](feedback_post_change_instructions.md) — always state restart/refresh needed after changes
