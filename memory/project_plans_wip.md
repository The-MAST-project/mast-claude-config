---
name: Plans feature - work in progress
description: Exact state of code changes for the plans capability/form work, what's done and what's next
type: project
---

## What's done (complete, committed)

### User model & display names
- `User.display` field (CharField max 64, blank); `generate_display` / `unique_display` helpers
- `unique_display` disambiguation: `first.last` → `first.j.last` (middle initial) → `first.last.2`
- Migration `0008`: renames `middle_name` → `middle`, adds `display`
- `unique_display` wired into social auth adapter, `local_signup`, `register` views
- `create_mockup_users` management command — `mockup.scientist` + `mockup.operator` (no usable password)
- `export_users` management command — writes `plans/files/users.json` for mast-plan-find
- `GET /api/users/` Django endpoint (uid + display, active+registered users only)
- Backfill: existing users with empty display get `unique_display` set on first `export_users` run

### Common models (MAST_common, synced to both MAST_control and MAST_gui)
- `ScienceModel` (`classification`, `case`) in `common/models/science.py`; embedded in `Target`
- `mockup: bool` field on `Plan` model
- `Plan.from_toml_file` ValidationError: logging removed (was `logger.error`), exception propagates to caller
- `common/paths.py` was removed from MAST_common; `mast-plan-find` now uses hardcoded `PLANS_ROOT`

### mast-plan-find CLI tool
- `-scrape`: collects owner UUIDs + classifications from all plan TOMLs; resolves UUIDs via `users.json`
- `-list-owners`: shows display name + UUID table
- `-list-criteria`: lists all searchable fields and boolean predicates
- `-count`: output only match count, not the full list
- `-owner.name <value>`: search by display name (resolves UUID→display via users.json)
- `-owner.uuid <value>`: search by raw UUID (exact match)
- `owner=` in search output always shows display name
- Broken/invalid plans silently skipped (`suppress(Exception)` in both scrape and search)
- `PLANS_ROOT` + `FILES_FOLDER` constants replace removed `PathMaker`
- `known_classifications.json` initialised in files folder on first `ensure_files_folder()`

### 50 WD mockup plans
- All in `submitted/` and `pending/` pools
- All owned by `mockup.scientist` UUID (`e9838c7e-90d9-47c7-94e3-4b049e59f9ae`)
- One intentionally broken plan (missing `target`) — silently skipped by scraper/search
- Science classifications: WD Pollution, WD Atmospheric Composition, WD Binary RV,
  WD Exoplanet Transit, Cataclysmic Variable, Flash Spectroscopy, ULTRASAT Follow-Up, Variable Star

### Plans page (MAST_gui)
- `index.html`: card-grid accordions per tab, in-progress block, all state tabs, actions dropdowns
- `_plan_tab_pane.html`: reusable partial; per-tab action buttons (approve/execute/postpone/revive/delete)
- `_plan_cards.html`: card-grid view via `planViewCards()` Alpine mixin
- `plan_new.html` + `plan_new.js`: full card-grid new-plan form (complete)
- Owner display resolved via `ownerName()` / `ownerUrl()` using `owners` map from Django view

### FastAPI (MAST_control)
- `PlanState.submitted`, `submitted_folder`, `submitted → pending` transition
- `GET /plans/new`, `POST /plans/submit` routes
- `get_new_plan()`, `submit_plan()` implementations

## What's next (in order)

1. **Wire up assignment notifications** — extend `NotificationTypes` and Django Channels consumer
   to handle `assignment_resource` and `assignment_outcome`; on outcome call `fetchPlans()`
2. **Search feature (GUI side)** — search UI on plans page; reads `scraping_results.json`
   (classifications) and `users.json` (owners) from `plans/files/`; `makedb` obsoleted by `-scrape`
</content>
</invoke>