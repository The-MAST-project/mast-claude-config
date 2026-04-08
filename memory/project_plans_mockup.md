---
name: Plans — mockup plans status
description: Status of the 50 WD mockup plans — DONE
type: project
---

## Status: DONE

50 WD mockup plans deployed. All owned by `mockup.scientist`
(UUID `e9838c7e-90d9-47c7-94e3-4b049e59f9ae`).

- ~25 in `submitted/`, ~25 in `pending/`
- Instruments: mix of DeepSpec and HighSpec
- Science classes: WD Pollution, WD Atmospheric Composition, WD Binary RV,
  WD Exoplanet Transit, Cataclysmic Variable, Flash Spectroscopy, ULTRASAT Follow-Up, Variable Star
- One intentionally broken plan (`PLAN_01KMTBEQ0MCR232Q6WQGBNKJ27.toml`) — missing `target` field

Owner field was originally written as the string `"mockup.scientist"` (not UUID);
patched in-place to use the UUID via `sed`.
</content>
</invoke>