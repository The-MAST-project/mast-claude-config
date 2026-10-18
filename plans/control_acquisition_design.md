# Control-driven acquisition: `start_acquisition`, `acquisition_status`, `abort_acquisition`

> MAST_control gets three endpoints that take a list of units to one sky position and
> into guiding, in parallel: start each unit up if needed, optionally run `focus_on_star`,
> then `start_acquisition_and_guiding` with handover, and report progress as a plain-text
> table.
>
> **Status: plan only, not implemented. All design questions closed (2026-10-18).**
> Code baseline: MAST_common `master` @ `1c8efd1`, MAST_unit `main` @ `32fb342`,
> MAST_control `master` @ `e791152`.
>
> **Prerequisite, done:** MAST_common#170. `UnitApi` was a process-wide singleton, so
> every `UnitApi(hostname=...)` after the first talked to the first unit. It is now one
> instance per unit name (or `ipaddr`), and this design depends on that.

## 1. Why

An operator who wants several units on one target has to drive each unit by hand: start
it up, wait, maybe focus, acquire, watch for guiding. Plans can do this but carry a
spectrograph assignment, scheduling and file-state machinery that an engineering session
does not need. This is a lightweight path, coordinates in and guiding units out, with a
status readout made for an operator rather than a program.

## 2. Decisions taken with the user

- **Endpoints:** `start_acquisition`, `acquisition_status`, `abort_acquisition`, all under
  the OpenAPI tag `acquisition`.
- **One current acquisition, no ids.** Running overlapping acquisitions on the same units
  is the operator's responsibility. A new `start_acquisition` **aborts the current one**,
  if there is one (section 6.3).
- **Units are checked against the site's `deployed_units`,** and units in
  `units_in_maintenance` are refused.
- **Opstate:** `initialized` and `shutdown` are started up first; `startedup` proceeds
  directly; anything else fails the unit.
- **Operational, or "only cooling".** A unit is fit when `operational`, or when every entry
  in `why_not_operational` is the imager's cooling-down reason. Control decides this, by a
  shared prefix constant (section 4.3).
- **Busy units fail.** A unit whose `why_busy` is non-empty, for any reason other than this
  acquisition, fails. This is per unit; the others carry on.
- **`autofocusing`** in the table means `status.autofocusing` *or*
  `UnitActivities.FocusingOnStar`. The status field covers only the V-curve autofocuser.
- **The unit reports its acquisition outcome** in `FullUnitStatus` (section 5). Today it
  reports none, and inferring one from activities races the poll. The outcome carries no
  id: a unit never runs more than one acquisition at a time, and it replaces its outcome
  before the endpoint answers (4.1).
- **Success is guiding locked on a star:** PHD2's state is exactly `Guiding`. Being
  *told* to guide does not count, nor does PHD2's `LostLock` (5.1).
- **A timeout aborts that unit** (`PUT unit/abort`) and fails it. An unattended unit does
  not keep working after control has given up on it.
- **Timeouts:** the wait for guiding uses the plans' `timeout_to_guiding` (600 s, as one
  shared constant). Startup and `focus_on_star` get 600 s each.
- **Errors:** each unit carries a list of errors, printed under the table.
- **Aborting units:** a new start waits up to 30 s for the previous acquisition's units to
  clear `Aborting`. If any requested unit is still `Aborting` after that, or was aborting
  for another reason, **the whole new start is refused.**

## 3. The flow

```text
start_acquisition(units, ra, dec, autofocus_on_star)
  validate inputs ............................ refuse the whole start on any problem
  abort the current acquisition, if any
  fetch status of the requested units
  any requested unit Aborting (after <=30 s) ... refuse the whole start
  one worker per unit, in parallel:
      opstate initialized | shutdown -> PUT startup, wait for startedup   (600 s)
      opstate startedup                -> go on
      otherwise                        -> failed
      fit?   operational, or only cooling                   else failed
      busy?  why_busy == {}                                 else failed
      if autofocus_on_star: PUT focus_on_star, wait for the outcome (600 s)
                            solved -> go on                 else failed
      PUT start_acquisition_and_guiding(skip_sky, handover)
      wait for this acquisition's outcome (timeout_to_guiding)
                            guiding -> guiding              else failed
  return at once: the workers run in the background
```

## 4. MAST_common

### 4.1 Acquisition outcome on the unit status (`models/statuses.py`)

```python
class AcquisitionState(StrEnum):
    RUNNING = "running"   # accepted, phases or guider calibration in progress
    GUIDING = "guiding"   # guiding, locked on a star (PHD2 state "Guiding")
    ENDED = "ended"       # guiding stopped after it had locked
    FAILED = "failed"
    ABORTED = "aborted"   # cancelled (Acquiring cleared / unit/abort)


class AcquisitionOutcome(BaseModel):
    state: AcquisitionState
    errors: list[str] = []
    started_at: str       # ISO UTC
    ended_at: str | None = None
```

Add `acquisition: AcquisitionOutcome | None = None` to `FullUnitStatus`, next to `opstate`.
**`None` means "not reported"** (an older unit, or none since the unit started), using the
same pattern and reasoning as `opstate` and `why_busy`. Never default it to an empty
outcome.

**There is no id.** A unit runs one acquisition at a time, and it replaces `outcome` with a
fresh `RUNNING` one *before* `start_acquisition_and_guiding` answers (5.1). Control's
worker polls one call at a time, so the first status it reads after a successful PUT
already carries this acquisition's outcome, never the previous one's.

### 4.2 One `timeout_to_guiding` (`models/plans.py`)

Add `DEFAULT_TIMEOUT_TO_GUIDING: float = 600`. Use it in `Plan.timeout_to_guiding`'s
`Field(default=...)` (also its `le=`), in MAST_control's `NewPlanTemplate`
(`planning.py:137`), and here.

### 4.3 The cooling reason (`models/statuses.py`)

Add `COOLING_DOWN_REASON = "imager: cooling down"`. The unit builds both of its cooling
messages from it, and control matches `reason.startswith(COOLING_DOWN_REASON)`. Rewording the
message on the unit can then never silently break control's match.

### 4.4 `parse_target` (`parsers.py`)

Move `parse_target` from MAST_unit `flux_metering/session.py` to `common/parsers.py`,
unchanged. The unit imports it from there (`unit.py:67`, `flux_metering/session.py`), and
control uses it to convert the RA/Dec it validated with `RA_PATTERN` / `DEC_PATTERN`.

### 4.5 Tests

- `AcquisitionOutcome` round-trips through `FullUnitStatus`, and a status with no
  `acquisition` key parses to `None`.
- `Plan().timeout_to_guiding == DEFAULT_TIMEOUT_TO_GUIDING`.
- `parse_target`: decimal, colon- and space-separated sexagesimal, `None`/`""` passthrough,
  RA of exactly 0.

## 5. MAST_unit

### 5.1 Record the outcome (`acquirer.py`)

- `Acquirer.outcome: AcquisitionOutcome | None = None`.
- **`endpoint_start_acquisition_and_guiding`:** after every refusal check passes and just
  before `Thread(...).start()`, set a fresh `outcome` (`RUNNING`, `started_at` now).
  Setting it *before* the endpoint answers means control's first poll after the PUT always
  reads this acquisition's outcome, never the previous one's. A refusal (missing components, bad coordinates, both gains)
  returns errors from the PUT, as today, and leaves `outcome` alone.
- **`run_acquisition`:** when `do_acquire` returns a failure: `ACQUISITION_CANCELLED` sets
  `ABORTED`; any other failure string, or an exception, sets `FAILED` with it in `errors`.
  Set `ended_at`.
- **Handover (`acquirer.py:449-457`):** the `while ... UnitActivities.Guiding` loop
  checks `guider.is_locked` each pass (5.2) and sets `GUIDING` the first time it is true.
  If the loop exits *before* that, the run fails: `"guiding stopped before locking on a
  star"`. If it exits after, the outcome is `ENDED`. A unit stuck calibrating or never
  locking stays `RUNNING`, and control's `timeout_to_guiding` handles that case (6.4).
- **Status:** `Unit.status()` puts `acquisition=self.acquirer.outcome` in `FullUnitStatus`.

### 5.2 `Guider.is_locked`

"Locked on a star" is PHD2's application state being **exactly `Guiding`**.
`PHD2Connector._is_guiding` (`phd2.py:624`) cannot be reused: it also counts `LostLock`,
and it feeds `status.guiding`, which keeps its meaning. Add `Guider.is_locked`:

- **PHD2:** `get_status()[0] == "Guiding"`. Not `Calibrating`, `Selected`, `LostLock` or
  `Paused`.
- **`SolvingGuider`:** has no star lock, so it is its own `is_guiding`.

### 5.3 Fix: a refused handover is reported as success

`PHD2Connector.start_guiding` can refuse without raising `Guiding` (binning or bpp
mismatch, `phd2.py:1554-1566`). `Guider.start_guiding` (`guiding.py:82`) discards that
response. The acquirer's `while self.unit.is_active(UnitActivities.Guiding)` then exits at
once, the mount stops tracking, and `do_acquire` returns `None`: **success**. This has to be
fixed, or control would wait the full `timeout_to_guiding` on a unit that has already given
up. The fix: `Guider.start_guiding` returns the backend's `CanonicalResponse`, and the
handover returns `"handover to guiding failed: <errors>"` when it failed.

### 5.4 The cooling reason

`Imager.why_not_operational` (`imagers/__init__.py:374-379`) builds both of its messages
from `COOLING_DOWN_REASON`. The text stays the same.

### 5.5 Tests

- The outcome moves `RUNNING` -> `GUIDING` -> `ENDED` on a stubbed handover;
  `RUNNING` -> `FAILED` on a phase failure and on an exception; `RUNNING` -> `ABORTED` on
  cancel.
- It stays `RUNNING` while PHD2 reports `Calibrating`, and becomes `GUIDING` only on
  `Guiding`, never on `LostLock`.
- `Guiding` ending before a lock gives `FAILED`, "guiding stopped before locking on a star".
- A refused `start_guiding` ends `FAILED` with the guider's errors (the 5.3 regression).
- A refused endpoint call leaves the previous `outcome` untouched.
- The status carries `acquisition`.

## 6. MAST_control

New module `control/control/acquisition.py`. `Controller.api_router` includes its routes,
as it does `planner.add_routes`.

### 6.1 Endpoints

All three are under the `acquisition` tag, at `Const.BASE_CONTROL_PATH` +:

| Path | Method | Returns |
| --- | --- | --- |
| `/start_acquisition` | PUT | `CanonicalResponse`: `"ok"`, or errors if the whole start is refused |
| `/acquisition_status` | GET | `PlainTextResponse`: the table (6.5) |
| `/abort_acquisition` | PUT | `CanonicalResponse` |

`start_acquisition` parameters:

- `units: list[str]`, a `Query`, at least one.
- `ra_j2000_hours`, `dec_j2000_degs`: required, the same `Query(pattern=RA_PATTERN /
  DEC_PATTERN)` and descriptions as the unit's `focus_on_star`, converted with
  `parse_target`.
- `autofocus_on_star: bool = False`.

**Whole-start refusals:** no units; a unit not in any managed site's `deployed_units`; a
unit in `units_in_maintenance`; coordinates that do not convert. Duplicate names are
silently dropped.

### 6.2 State

```python
class UnitAcquisitionState(StrEnum):
    PENDING, STARTING_UP, FOCUSING, ACQUIRING, GUIDING, FAILED, ABORTED

@dataclass
class UnitAcquisition:
    name: str
    state: UnitAcquisitionState = PENDING
    errors: list[str] = field(default_factory=list)

@dataclass
class Acquisition:
    units: dict[str, UnitAcquisition]
    ra_j2000_hours: float
    dec_j2000_degs: float
    autofocus_on_star: bool
    cancelled: Event
```

`Acquisitions` (owned by the `Controller`) holds `current: Acquisition | None` under a lock,
and **its own** `ThreadPoolExecutor(max_workers=20)`. The controller's executor
(`max_workers=25`) feeds the status cache, so 20 units' long-running workers on it would
starve the cache.

The state lives in memory only and is lost if control restarts. The `start_acquisition`
docstring says so.

### 6.3 `start_acquisition`

1. Validate (6.1). Refuse on any problem.
2. If there is a `current`, abort it (6.6) and keep its unit names.
3. Fetch the status of every requested unit, in parallel (5 s timeout). An unreachable
   unit fails on its own and does not refuse the start.
4. For the previous acquisition's units, wait up to **30 s** for `Aborting` to clear. If
   any *requested* unit is still `Aborting` after that, or is `Aborting` without having
   been in the previous acquisition, **refuse the whole start**:
   `"<unit>: still aborting"`.
5. Make the new `current` and submit one worker per unit. Answer `"ok"` at once.

### 6.4 The per-unit worker

Each worker polls **its own unit**: `UnitApi(hostname=name).get("status")` (and
`focus_on_star_status`), every **3 s**, via `asyncio.run` as the status cache does. It
deliberately does not read control's status cache, which refreshes each unit only every
30 s (`controller.py:463`). Every wait also returns as soon as `cancelled` is set.

Every failure appends an error prefixed with its step (`startup:`, `focus_on_star:`,
`acquisition:`) and sets `FAILED`.

1. **Opstate.** `initialized` or `shutdown`: `PUT startup`, `STARTING_UP`, then wait for
   `opstate == startedup` (600 s). `startedup`: go on. `None`: fail with "opstate not
   reported". Anything else: fail with "opstate is `<x>`".
2. **Fit.** Go on if `operational`, or if `why_not_operational` is non-empty and every entry
   starts with `COOLING_DOWN_REASON`. Otherwise fail with the reasons. An empty list with
   `operational == False` fails with "not operational, no reason given".
3. **Busy.** `why_busy == {}`: go on. `None`: fail with "busy state not reported".
   Non-empty: fail with `"busy: <owner>: <flags>; ..."`.
Steps 4 and 5 need no "is this the new run?" check. Both unit endpoints replace their
state before answering (`FocusOnStarSession.start`, `session.py:208-234`; 5.1), so the
first poll after a successful PUT already reads the new run.

4. **`focus_on_star`** (if `autofocus_on_star`). `PUT focus_on_star` with `zenith=false`
   and the coordinates, and set `FOCUSING`. Errors from the PUT fail the unit. Poll
   `focus_on_star_status` until `active == False` (600 s). `outcome == "solved"`: go on.
   Otherwise fail with the run's `errors`, or with its `outcome` if there are none.
5. **Acquire.** `PUT start_acquisition_and_guiding` with the coordinates, `skip_sky=True`
   and `handover_automatically_to_guider=True`, and set `ACQUIRING`. Errors from the PUT
   fail the unit. Poll (`DEFAULT_TIMEOUT_TO_GUIDING`) until `status.acquisition.state` is
   no longer `RUNNING`:
   - `GUIDING` (locked on a star): set `GUIDING`, and the worker is done.
   - `FAILED`, `ABORTED` or `ENDED`: fail with the outcome's errors.
   - `acquisition` is `None`: fail with "unit does not report acquisition outcome" (an
     older unit).
6. **Timeout** at any step: `PUT unit/abort` on that unit, then fail it with
   `"<step>: timed out after <n> s, unit aborted"`.

### 6.5 `acquisition_status`

No `current`: `"no acquisition"`. Otherwise, fetch every unit's status fresh, in parallel
(5 s), so the table is live even for units whose worker has finished:

```text
unit    state      opstate    operational  autofocusing  why_busy                 guiding
------  ---------  ---------  -----------  ------------  -----------------------  -------
mast01  guiding    startedup  True         False         unit: Guiding            True
mast03  focusing   startedup  True         True          unit: FocusingOnStar     False
mast05  failed     startedup  False        False         -                        False

errors:
  mast05: fit: mount: not connected

Done: False (not guiding: mast03, mast05)
```

- `operational` prints `True (cooling)` when only cooling keeps it from `True`.
- `why_busy`: `{}` prints `-`, `None` prints `?`, and an unreachable unit prints
  `unreachable` across its status columns.
- **`Done: True`** only when every unit's `state` is `GUIDING`. Otherwise `Done: False`
  with the units that are not guiding.
- Fixed-width columns, sized to the longest value. This is for an operator's eyes and a
  terminal; anything a program needs comes from the unit statuses themselves.

### 6.6 `abort_acquisition`

No `current`: error `"no acquisition"`. Otherwise, set `cancelled`, then `PUT unit/abort`
on every unit of the acquisition, in parallel. The unit's abort stops `focus_on_star`,
the acquisition and guiding. Every unit not already `FAILED` becomes `ABORTED`, with
"aborted by operator". `current` stays, so `acquisition_status` still shows how it ended.

### 6.7 Tests

These use a fake `UnitApi` scripted per unit (sequences of statuses and PUT responses).
No network, no sleeps (the poll interval and timeouts are injectable):

- **Validation:** undeployed, in maintenance, bad RA, duplicates dropped.
- **Opstate:** `initialized` and `shutdown` start up; `startedup` skips startup; `None`
  fails.
- **Fit:** only-cooling passes; cooling plus another reason fails; empty-but-not-operational
  fails.
- **Busy:** non-empty fails; `None` fails.
- **`focus_on_star`:** `solved` goes on; `failed` fails the unit and skips acquisition.
- **Acquire:** `RUNNING` keeps waiting; `GUIDING` succeeds; `FAILED` carries the unit's
  errors; `None` fails with "does not report".
- **Timeout:** fails the unit and sends `unit/abort`.
- **Abort:** non-failed units become `ABORTED`; abort is sent to all.
- **New start over a running one:** aborts it; refuses if a unit stays `Aborting` past the
  wait.
- **Table:** columns, `True (cooling)`, `-`/`?`, the `Done` line, and the errors section.

## 7. Rollout order

1. **MAST_common** (section 4). Every field is optional, so pulling it changes nothing for
   older units or control.
2. **MAST_unit** (section 5), then deploy to the units. The unit imports `parse_target`
   from `common`, so each unit's `common` clone must be pulled with it.
3. **MAST_control** (section 6), and also switch `NewPlanTemplate` to
   `DEFAULT_TIMEOUT_TO_GUIDING`.

A unit still on old code fails with "unit does not report acquisition outcome" at step 5,
which says what is wrong. It does not hang.

## 8. Out of scope

- Persisting acquisitions across a control restart.
- Any spectrograph involvement. Plans remain the path for science.
- Running acquisitions on one unit set while another acquisition is running elsewhere.
  There is one `current`.

## 9. Decided after review

- **Workers after `GUIDING`: left as is.** A worker stops polling once its unit is guiding.
  If guiding then stops or loses its lock, `state` still says `guiding`; the live `guiding`
  and `why_busy` columns of `acquisition_status` show what is really happening.
