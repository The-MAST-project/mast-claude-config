---
name: Spec 3D rendering design
description: Design decisions for the Three.js spectrograph model viewer — modes, ModelUpdater, SSE integration, animations
type: project
---

## Two modes
- **Realtime** (`Live`): driven by SSE notifications from the spec backend
- **Simulated**: driven by the offcanvas control panel (Controls button shown only in simulated)

## Mode toggle
- Bootstrap form-switch in page header (not offcanvas), fixed width label `Live` / `Simulated`
- Offcanvas border: green in realtime, red in simulated
- Controls button: hidden in realtime, visible in simulated

## ModelUpdater class (JS)
- `applyStatus(spec)` — snaps all parts from `MastCache` via `GET /specs/api/status/`
- `applyNotification(update)` — handles SSE card events (see below)
- `tickTweens(now)` — eased animation loop for fiber and disperser tweens
- `_debouncedFetch()` — 300 ms debounce on any DOM spec update

## Spec → 3D model trigger map

### Stage cards (`component = 'stage'`, from `StageActivities`)
Preset value in `card.data.target.value` determines which tween:
- `Deepspec` / `Highspec` → fiber tween (`_startFiberTween`)
- `Ca` / `Mg` / `Halpha` → disperser+focus tween (`_startDisperserTween`)
- `end` card → cancel tween + debounced fetch

### Acquiring cards
- `component = 'deepspec'` start/end → deepspec light path on/off
- `component = 'highspec'` start/end → highspec light path on/off

### Filter wheel card (`component = 'wheel'`)
- `start` with `data.target.value = <index>` → rotate filter wheel

### Fallback: DOM SSE
Any DOM update id matching `stages|wheels|lamps` → debounced `applyStatus` fetch

### Periodic
120-second poll in realtime mode

## Fiber stage physics (Zaber LRQ300AL-E01T3A)
- `FIBER_NATIVE_PER_MM = 10080`, `FIBER_MAX_SPEED_MM_S = 54` → 544,320 native/s
- Real presets: `Deepspec = 1,300,460` / `Highspec = 2,713,701` native
- Full travel ~2.6 s; duration clamped [500, 3000] ms

## Disperser/focus stage
- `DISPERSER_PRESETS_NATIVE` and `DISPERSER_NATIVE_PER_SEC` are **placeholders** (TODO: real values)
- Code fully in place; both stages animated together via single `disperser` tween

## Component name mapping (common/activities.py)
- `StageActivities` → `'stage'`
- `DeepspecActivities` → `'deepspec'`
- `HighspecActivities` → `'highspec'`
- `WheelActivities` → `'wheel'` (added in common commit 641cf6d)

## `data` field in activities
- `start_activity(activity, data={"target": {"type": "preset", "value": <name>}})` in stage.py and wheel.py
- Passed through `CardUpdateSpec.data` → SSE card → JS `card.data.target.value`

## Why:
Clean separation: SSE carries discrete start/end events; ModelUpdater interpolates motion. No polling. Existing SSE infrastructure reused.

## How to apply:
When touching common, sync all four submodule checkouts. Disperser/focus tweens will become real once native preset positions are measured from mast-wis-spec hardware.
