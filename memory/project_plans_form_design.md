---
name: Plans form design decisions
description: Design decisions for the MAST plans management GUI form, capabilities, and notification system
type: project
---

## Capabilities

- `can_submit_plans` — scientists: can submit new observation plans
- `can_manage_plans` — admins: can execute, postpone, cancel, delete, revive, approve plans
- `owner` is set server-side from `request.user` on submission; hidden in the form UI
- Edit button shown if user is plan owner OR has `can_manage_plans`

## Plan Form — Card Grid Layout

- **Widget**: card grid (not accordion, not tabs)
- **Desktop only**
- Each category = one card; collapsed by default for new plans
- Clicking a card toggles it open/closed (always, regardless of edit mode)
- Edit capability (owner or canManagePlans) controls whether fields inside are editable or read-only
- **Validity indicators on card border**: green = changed+valid, red = changed+invalid (error message underneath card); unchanged = default border
- **Summary fields**: `"summary": True` in `ui` hints → shown in collapsed card
- **Three action buttons**: Submit/Save (active only if form valid), Cancel (exit edit mode + restore all), Restore (revert changes but stay in edit mode)
- For **new plan**: all cards start collapsed
- `owner` field: hidden in form, shown as non-editable label in card header

## Plan Form — Data Flow

- On entry: deep-copy fetched plan → `originalValues`, `editedValues`
- On Cancel: discard `editedValues`, restore from `originalValues`
- On Restore: revert `editedValues` to `originalValues`, stay in edit mode
- On Submit: compute diff (JS-side, recursive) between `editedValues` and `originalValues`; send diff + ULID to backend endpoint
- For **new plan**: send full `editedValues` (no original to diff against)
- Backend: applies diff to existing Plan, re-validates via Pydantic, writes TOML
- `owner` always set server-side from `request.user`

## Plan Form — Context Awareness

- `requested_units`: shown (editable if authorized) in all contexts except in-progress
- `allocated_units`: shown read-only only in in-progress context
- Form receives a `context` parameter (e.g. `"in_progress"`, `"new"`, `"pending"`)

## Pydantic UI Hints (implemented)

Fields use `json_schema_extra` with `"ui"` key:
```python
Field(..., json_schema_extra={
    "ui": {
        "label": "...", "widget": "text|number|select|checkbox|textarea|datetime|radio-date-picker",
        "unit": "...", "tooltip": "...", "hidden": False, "editable": True,
        "required": True, "options": [...], "summary": True,
        "options_key": "filter_options",   # resolve options from NewPlanTemplate extras
        "default": ...,                    # shown as fallback in UI when value is null
        "section": "Name" or {"label": "Name", "tooltip": "..."},  # only first field in section needs tooltip
    },
    "error_message": "...",
    "required_capabilities": ["can_manage_plans"],
})
```

`extract_field_metadata_recursive()` in `units/config_utils.py` recurses into BaseModel subfields, producing a nested dict. Top-level nested models → `{_is_group: True, label, fields: {...}}` = one card category. Handles `Optional[Model]` transparently; treats `Union[A, B]` as scalar.

Server-side: pass `plan.model_dump_json()` and `json.dumps(extract_field_metadata_recursive(Plan))` directly — no intermediate dicts.

## Tooltips (global)

- `x-tooltip="expr"` Alpine directive defined in `base.html` — use on any Alpine-rendered element
- `data-bs-toggle="tooltip"` + MutationObserver for static (non-Alpine) elements
- All ⓘ icons use class `info-icon` (soft blue, hover brightens, `cursor: help`)
- Tooltips: white background, dark text, left-aligned, `html: true`

## get_new_plan Response (`NewPlanTemplate`)

- `ulid`: freshly allocated
- `target`: `{ra_hours: 0.0, dec_degrees: 0.0}`
- `spec_assignment`: `{instrument: null, exposure_duration: 0.0, ...}`
- `spec_defaults`: `{"highspec": {exposure_duration, number_of_exposures}, "deepspec": {...}}`
- `filter_options`: list of ThAr filter values from `Config().get_specs().wheels["ThAr"].filters`

When user selects an instrument, JS populates `exposure_duration` and `number_of_exposures` from `spec_defaults[instrument]`.
When filter select is rendered, JS resolves `options_key: "filter_options"` from template data.

**Known gap**: nested models (e.g. `target.repeats`) may not be pre-populated in `get_new_plan` response; JS falls back to `field.default` for display. Long-term fix: initialize all nested models with defaults in `get_new_plan()`.

## Plans Page — Plan States

States: `submitted → pending → in-progress → completed/failed`
Also: `pending/submitted → deleted`, `pending → postponed → pending` (revive), `in-progress → canceled`

**Submitted folder**: new entry point. Scientists submit plans here. Admins approve (→ pending) or delete.

## Plans Page — In-Progress Block

Shows either a single Plan or a Batch (discriminated by presence of `plans` list in response).

**Batch display:**
- Shows merged `spec_assignment` + `predicted_duration`
- Lists constituent Plans, each with:
  - **Goto**: scrolls to that plan's collapsed card in Pending tab (switches tab if needed)
  - **Details**: opens/expands that plan's card in Pending tab

## Batch Model (`common/models/batches.py`)

- `Batch` is an ad-hoc entity created by the Scheduler as the next unit of work
- Contains `list[Plan]`, merged `spec_assignment`, `predicted_duration`
- Merge logic: `exposure_duration` = max, `number_of_exposures` = max, `calibration.lamp_on` = any, ND filter = strongest
- All plans must share the same instrument (enforced by assertion)
- `immediate: bool` — for immediate execution vs forecasted

## Notifications

Existing `NotificationTypes` in `common/notifications.py` has `"ui_notification"` and `"assignment_notification"` as placeholders.

**To implement:**
```json
{ "type": "ui_notification", ... }
{ "type": "assignment_resource", "ulid": "...", "storage_path": "..." }
{ "type": "assignment_outcome",  "ulid": "...", "result": "success|failure|abortion", "details": "..." }
```

On `assignment_outcome`: GUI simply calls `fetchPlans()` — stateless, backend is source of truth. No local state transitions.

**Why:** Keep GUI stateless; `fetchPlans()` on outcome notification drives all display updates.

## RepeatsModel (`common/models/constraints.py`)

Moved from `ConstraintsModel` to `Target` (as `repeats` field). Contains:
- `every`: select using `WhenToRepeat` StrEnum values, default "Only once"
- `nights`: int, default 1, range 1–100
Both fields in "Reschedule" section with tooltip.
