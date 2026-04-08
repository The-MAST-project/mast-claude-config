---
name: MAST_gui cleanup map
description: Dead code, stub apps, duplicate files, and artifacts in MAST_gui identified for future cleanup
type: project
---

No React/MUI remnants were found — that previous attempt was already fully removed.

**Why:** Accumulated dead code from abandoned app stubs, old naming conventions, and filesystem accidents.
**How to apply:** Work through the checklist below item by item, confirming each removal before touching anything.

---

## Cleanup Checklist

### Stub/incomplete apps (installed but never finished)
- [ ] `plans/` — stub views + no templates; real plans work is in `core/views/plans.py`. Remove app or fold into core.
- [ ] `assignments/` — single stub view, no template, no models
- [ ] `specs/` — single stub view, imports non-existent `config` module

### Duplicate / shadow apps
- [ ] `dashboard/` — full app (urls.py, views.py, templates/dashboard/index.html) but never included in main urls.py; active dashboard served by `MAST_gui/views.py`
- [x] `safety/` — deleted (was old name for `mast_safety/`; not in INSTALLED_APPS or urls.py)

### Duplicate files
- [ ] `templates/units/list copy.html`
- [ ] `static/css/colors copy.css`

### Corrupted template files (contain Python source, not HTML)
- [ ] `templates/units/unit_detail.html`
- [ ] `templates/units/unit_list.html`

### Orphaned views in `accounts/views.py`
- [ ] `login_view()` — superseded by Django built-in LoginView
- [ ] `logout_view()` — superseded by Django built-in LogoutView
- [ ] `profile_view()` — superseded by `profile()`
- [ ] `register()` — superseded by allauth
- [ ] `user_switcher()` — no route, no template

### Auth backend redundancy
- [ ] `accounts/auth_backend.py` (1.9K) — likely superseded by `accounts/backends.py` (7.0K, the one in settings.py). Verify then delete.

### Filesystem artifacts
- [ ] `D:/` directory at project root — Windows path artifact (~632K, dated subdirectories). Likely accidental backup/transfer artifact.
- [ ] `dashboard/.vscode/` — editor config inside app directory
- [ ] `templates/units/# Code Citations.md`
- [ ] `MAST_gui/# Code Citations.md`
