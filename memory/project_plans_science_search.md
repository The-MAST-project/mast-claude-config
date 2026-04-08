---
name: Plans — Science model & search feature design
description: Science Pydantic model design and plans search feature decisions from iPhone session
type: project
---

## Science Model

Add a `Science` Pydantic model with:
- `science_class`: free-text `str` (NOT an enum — vocabulary is emergent from actual plans)
- `science_case`: free-text multiline `str` (human-readable rationale)

Embed as a nested field in `Plan`.

Known science class values in use: WD pollution, WD binary RV, transient follow-up, WD exoplanet transit.

## Plan Model Additions

- `science: Science` — new nested model (above)
- `mockup: bool` — flag for mockup/test plans

## Plans Search Feature

- Individual Plan fields get `"searchable": True` in their `json_schema_extra`
- Searchable fields: `science_class`, `science_case` (free text), target name, spectrograph, owner/user
- Search available in two places: Django plans page GUI and Python CLI tool on the server
- Search type branches by field: free-text fields → substring/regex; enum-like fields → exact match

### makedb tool (science_classes.json)

A `makedb`-style tool scrapes all plan TOML files, extracts unique `science_class` strings, deduplicates, and writes `science_classes.json`.

- CLI search tool loads this JSON for its selection list
- Django GUI fetches it (either as static file or via FastAPI endpoint) to populate the science_class dropdown

**Why:** Keeps vocabulary emergent from actual plans rather than hardcoded in an enum. Adding a new science class requires no code change.
