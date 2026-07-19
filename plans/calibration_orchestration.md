# Unit calibration orchestration — the `/calibrate` endpoints

> **Status: DESIGN (rev. 2026-07-19), not implemented.** Endpoint contract for
> unit self-calibration: one orchestrator plus three standalone phase endpoints.
> The per-phase analysis exists to varying degrees (stage: `StageCalibrator`
> full loop; optical-center + focus: analysis built, **write-side + a coma-slope
> fit still to add**). Sibling designs: `stage_geometry_design.md` (this folder);
> `MAST_unit/docs/{autofocus_design,optical_center_design}.md` (unit repo).
> On-sky validation: `on-sky-calibration-test-harness.md` (this folder).

## Endpoints

```
POST /calibrate                    ?force=false                 # orchestrate all
POST /calibrate/focuser            ?force=false&ra=&dec=        # focus only
POST /calibrate/optical_center     ?force=false&ra=&dec=        # optical center only
POST /calibrate/stage              ?force=false&ra=&dec=&move_to_spec=false
```

All return a `CanonicalResponse` **immediately**; the work runs in the background
under an activity (below), pollable via `/status` and abortable. Every phase
**logs what it is doing and why** (`init_log`) at each decision point — slew,
stage move, focuser move, regime choice, gate pass/fail, DB write.

- **`force`** (default `false`) — when false, a phase whose product already
  exists in the DB is **skipped**; when true it is redone. **There is no
  staleness/temperature model in v1**: "needs doing" == "product absent". To
  force a redo, pass `force=true` *or* delete the product from the DB.
- **`ra` / `dec`** (optional) — pointing for the phase. Resolution order:
  explicit param → `calibration.coord.{ra,dec}` in the DB → default `ra = LST`
  (transit), `dec = 20°`. The phase slews there and tracks before acquiring.
- **`move_to_spec`** (stage only, default `false`) — park at the solved spec
  position on success instead of retracting.

## The routine owns the order (focus → optical_center → stage)

"Order is significant" means **one dependency order the physics fixes**, not the
order a caller types:

```
focuser  →  optical_center  →  stage
```

- Clean **coma lives at best focus** (defocused → the star is a pupil-donut with
  no usable coma), so **focus precedes optical_center**.
- **stage** runs **last**: it *inserts* the folding mirror (obstructs the field);
  focus and optical_center need a clear field.

`/calibrate` runs the three in this order, skipping any whose product exists
(unless `force`). It is the **only** thing that sequences them.

## Prerequisites: hardware is made to happen; products fail hard

Two kinds of precondition, handled differently — the core rule:

- **Hardware state** a phase needs, it **makes happen** on entry, with no
  assumption of inter-phase carry-over: slew to the pointing, `unit.stage.home()`
  (retracts the mirror — confirmed) for the field-clearing phases, and set
  `unit.focuser.position` to the focus it needs.
- **Calibration products** a phase needs, it **requires** — if absent it
  **fails with an error**; it never silently runs another phase to make them.

A phase can tell whether it runs inside the orchestrator by checking the
**umbrella** `UnitActivities.Calibrating`. The rule is deliberately the same on
both branches (a small, intentional duplication that keeps each endpoint's
contract self-evident):

- **inside** `/calibrate` (umbrella active): the orchestrator already ran the
  prerequisites in order — but the phase still re-checks and **fails** if a
  product it needs is missing (a bug, not a state to paper over).
- **standalone** (umbrella not active): same check, same failure. A bare
  `POST /calibrate/stage` with no `calibration.optical_center` in the DB is an
  error, not an implicit full calibration.

Per-phase products required (hard-fail if absent):

| Phase | Requires (product) | Makes happen (hardware) |
|---|---|---|
| `focuser` | *none* (always runnable) | slew to coord; `stage.home()` |
| `optical_center` | `calibration.focuser.best_position` | slew; `stage.home()`; `focuser.position = calibration.focuser.best_position` |
| `stage` | `calibration.optical_center` **and** `calibration.focuser.best_position` | slew; `focuser.position = best_position`; insert mirror & sweep |

## Activities & single-flight

- `/calibrate` **sets/unsets the umbrella `UnitActivities.Calibrating`**.
- Each phase sets/unsets **its own** flag for its duration:
  `CalibratingFocus`, `CalibratingOpticalCenter`, `CalibratingStage`.
- **One calibration at a time**: starting any phase while any `Calibrating*`
  flag is active is rejected. `/status` exposes the umbrella + active sub-phase.

## Abort & safety

- `is_safe` flipping **false mid-run aborts and stows**. No focuser/stage
  restore is attempted (no inter-phase context by design); the next phase that
  needs a given state re-establishes it.
- A phase persists to the DB **only on full success** — never a partial write.
  On failure/abort the DB is left untouched, so a half-done phase simply looks
  "absent" and reruns next time.

## Per-phase contracts

### `POST /calibrate/focuser` — HFD autofocus (single pass)

`CalibratingFocus`. Slew to coord; `stage.home()`. **Low-coma zone** for star
selection: read `calibration.optical_center.{center, low_coma_radius}`; if the
center **or** `low_coma_radius` is missing, fall back to the **image center and a
radius of `0.6 · min(nx, ny) / 2`** (inscribed, stays on-chip). Then run the
self-contained HFD routine:

1. **Phase-0 triage** on a reference frame at the seed position → `near` /
   `far` / `empty` (`imaging.hfd.assess_focus_regime`).
2. **Far → donut jump** (`imaging.donut`): measure outer-diameter, one calibrated
   jump toward focus, until the V-curve brackets.
3. **Near → HFD V-curve** (`imaging.hfd` + `focus_analysis_hfd`): sweep, fit the
   vertex.

**Single pass** — no re-focus after optical_center this session; the measured
`low_coma_radius` benefits *later* sessions where the optical center is already
present. On success writes **`calibration.focuser`** (`best_position` +
`tolerance`, `best_hfd`, `n_samples`, `temperature`, `timestamp`). It does **not**
touch operational `focuser.known_as_good_position` — the ps3cli path
(`/start_autofocus`) keeps that flow independently; promoting a calibrated focus
into the operational value is a later decision.

### `POST /calibrate/optical_center` — coma-null center + low-coma radius

`CalibratingOpticalCenter`. **Requires** `calibration.focuser.best_position` (else
fail). Slew to coord; `stage.home()`; `focuser.position = best_position`. Acquire
`calibration.optical_center.number_of_frames` (default **5**) **full-frame, bin-1**
frames at that pointing; **pool all sources across the frames into one weighted
fit** (`imaging.optical_center.find_optical_center`) — the per-frame center
scatters ~10² px, so a single frame is not trustworthy. Require at least
`ceil(N/2)` frames to pass the radiality gate, else fail.

**New analysis to add**: a **coma-slope fit** `k` = ellipticity vs. field radius
about the found center (forced through the origin, coma → 0 on-axis; reuse the
per-source `e_i`, `r_i`, and fit weights the finder already computes). Then

```
low_coma_radius [px] = coma_tolerance / k
```

with `coma_tolerance` (dimensionless ellipticity, photutils `e = 1 − b/a`) read
from `calibration.optical_center.coma_tolerance` (default **0.1** in the `common`
section, per-unit overridable). If `k` is too poorly determined to trust,
store `low_coma_radius = null` (never fabricated); focus then uses its 60%
fallback disk.

On success writes **`calibration.optical_center`**: `center_x/y`,
`low_coma_radius | null`, `coma_slope`, `coma_tolerance`, `image_shape`,
`n_sources`, `residual_rms`, `radiality`, `number_of_frames`, `timestamp`,
`mechanical_epoch`. (The `OpticalCenterCalibration` model already carries these.)

### `POST /calibrate/stage` — pick-off "spec" stage position

`CalibratingStage`. **Requires** `calibration.optical_center` **and**
`calibration.focuser.best_position` (else fail). **Assert** the stored optical
center's `image_shape` equals the current full-frame bin-1 size (guards against a
camera/binning change) — mismatch fails. Slew to coord;
`focuser.position = best_position`. Run `imaging.stage_geometry.StageCalibrator`:
sweep the mirror across N inserted positions, detect the shadow at each
(`imaging.mirror_shadow.detect_mirror_shadow`), solve the stage coordinate whose
shadow centerline crosses the optical center
(`find_spec_stage_position`). On success writes **`calibration.stage`**
(`StageCalibrationConfig`), copying the optical center's `mechanical_epoch`.
End-state: **retract** the mirror unless `move_to_spec=true`.

## Config additions

- `calibration.coord.{ra, dec}` — default pointing (absent → runtime `LST`, `20°`).
- `calibration.optical_center.number_of_frames` — default `5`.
- `calibration.optical_center.coma_tolerance` — default `0.1` in `common`,
  per-unit overridable.

`mechanical_epoch` groups the geometric calibrations (optical_center, stage) for
invalidation-as-a-group; **v1 has no reset endpoint** — bump it by manually
removing/editing DB entries when the optics are serviced.

## Build status (2026-07-19)

- **Not implemented** as endpoints; `src/autofocusing.py` still drives ps3cli only.
- Phase readiness:
  - `stage` — full live loop exists (`StageCalibrator`); needs the endpoint
    wrapper + the pre-focus `focuser.position` set + `image_shape` assert.
  - `focuser` — HFD/donut analysis built (`imaging/hfd.py`, `imaging/donut.py`,
    `focus_analysis_hfd.py`); needs the live drive (`start_hfd_autofocus`-style),
    the low-coma-disk selection, and the `calibration.focuser` write.
  - `optical_center` — finder built (`imaging/optical_center.py`); needs the
    **coma-slope fit**, N-frame aggregation, and the `calibration.optical_center`
    write.
- Cross-cutting to add: the three `Calibrating*` activities + umbrella, the four
  endpoints, single-flight guard, and the `calibration.coord` /
  `number_of_frames` / `coma_tolerance` config. The Mongo write path already
  exists (`common/config` unit-delta upsert + TTL-cache clear).
```
