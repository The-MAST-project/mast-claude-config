# Control-driven acquisition as a generated plan

> MAST_control gets three endpoints that take a list of units to one sky position and into
> guiding: `start_acquisition`, `acquisition_status`, `abort_acquisition`. An acquisition is
> **the execution of a plan that control generates** -- target RA/Dec, the requested units,
> optionally `focus_on_star`, and no spectrograph. Plans and acquisitions run on **one
> engine**, which replaces the stepped `probe -> dispatch -> wait_for_guiding` phases with
> one worker thread per unit and a quorum.
>
> **Status: plan only, not implemented.** Reworked on 2026-10-19 around the generated plan;
> the 2026-10-18 version designed a separate acquisition path. Open points are in section 11.
> Code baseline: MAST_common `master` @ `df2669f`, MAST_unit `main` @ `9fc7be6`,
> MAST_control `master` @ `abbfe8d`.
>
> **Prerequisite, done:** MAST_common#170. `UnitApi` is one instance per unit name (or
> `ipaddr`), not a process-wide singleton, and the per-unit workers depend on that.

## 1. Why

An operator who wants several units on one target drives each unit by hand: start it up,
wait, maybe focus, acquire, watch for guiding. Plans were meant to do this, and the
2026-10-18 design added a second, lighter path beside them. Reading the plan path showed
the two are the same job -- validate units, check each is operational, optionally focus, acquire
with handover, wait for guiding, abort on demand -- and that the plan path does not
currently work (section 4.1). So there is one engine, and an acquisition is a plan with no
spectrograph.

## 2. Decisions taken with the user

- **One code base.** `start_acquisition` generates a plan; plan execution and acquisitions
  share the engine in section 5.
- **The generated plan** carries only `target.ra_hours`, `target.dec_degrees`,
  `requested_units` and `autofocus` (default `False`). `spec_assignment` is `None`, and the
  engine then never probes or uses the spectrograph.
- **`autofocus` means `focus_on_star`**, for every plan, not the V-curve autofocuser.
- **Success is a quorum of units guiding**: `UnitActivities.Guiding` is set **and** the
  guider reports `is_guiding`. `Guider.is_guiding` follows PHD2's `is_locked` (section 6.2).
- **One worker thread per unit.** Each unit succeeds (guiding) or fails in its own time.
  The plan succeeds once `quorum` units succeed, and fails as soon as that becomes
  impossible. No stage waits for every unit.
- **The generated plan is written to a TOML file, then loaded from it**, which gives it a
  ULID and the same event trail and folder moves as any plan. It is `approved = true`
  (nothing else will approve it: it skips `pending/`) and `production = false` (an
  engineering acquisition, not science). Appendix A shows one.
- **Every unit's transitions are events in the plan file**, not only the plan's outcome,
  so the file says which units made the quorum and why the others did not.
- **The engine creates the plan's run folder**, for every plan.
- **Plan files carry no empty tables.**
- **`requested_units` may not be empty.** It names the units, or is `"any"`: the plan
  does not care which units it gets. `"any"` is independent of the spectrograph -- every
  unit feeds both instruments, through the common slit. The `required_units` count goes,
  because `quorum` says how many must succeed.
- **`allocated_units` is renamed `scheduled_units`**: it says who fills it.
- **`requested_exposure_duration`** (and `requested_number_of_exposures`) move from
  `Target` into `SpectrographModel`, required only when `instrument` is not `None`.
- **Existing plan files are rewritten once** (section 3.5), not migrated on every load.
- **Run-time state leaves the `Plan` model.** The model is the plan; a `PlanExecution`
  holds the workers.
- **The unit's `execute_assignment` goes.** The workers drive the unit's own endpoints.
- From the 2026-10-18 design, still in force: units are checked against the site's
  `deployed_units` and refused when in `units_in_maintenance`; `initialized` and
  `shutdown` are started up first, `startedup` goes on, anything else fails the unit; a
  unit passes the operational check when `operational` or only cooling; a busy unit fails; a timeout aborts that
  unit; the unit reports its acquisition outcome; a new start waits up to 30 s for units
  still `Aborting`.

## 3. The plan model (MAST_common)

### 3.1 Units and quorum (`models/plans.py`)

**`requested_units`** is a list of **unit specifiers** (`parse_units`, `parsers.py:13`:
`w`, `wis:w`, `ns:north:9`, `ns:10-17`, `ns:1,3,5`), not bare names, or the word `"any"`.

- **People read and write `"any"`; code always sees a list.** A
  `field_validator(mode="before")` turns any string into a one-element list, so
  `"any"` becomes `["any"]` and `"mast01"` becomes `["mast01"]`. A `field_serializer`
  writes `["any"]` back as `"any"`, so files, the API and the GUI show the word. Only
  `"any"` has the special spelling; a one-unit list stays a list.

  ```python
  ANY_UNITS = "any"

  requested_units: list[str] = Field(min_length=1, ...)

  @field_validator("requested_units", mode="before")
  @classmethod
  def _a_string_is_one_entry(cls, v):
      return [v] if isinstance(v, str) else v

  @field_serializer("requested_units")
  def _any_is_a_word(self, v: list[str]):
      return ANY_UNITS if v == [ANY_UNITS] else v
  ```

- **Validation:** at least one entry; `"any"` only as the sole entry; every other entry
  must parse with `parse_units`. `parse_units` never sees `"any"` -- its pattern would read
  it as a unit called "any".
- **`Plan.requested_unit_names() -> list[str] | None`**: the specifiers expanded to unit
  names, or `None` for `"any"`. Nothing else reads the raw field, so nothing iterates it
  expecting names.

**`required_units: int` is removed.** `quorum` says how many units must succeed.

**`quorum: int = 1`.** A `model_validator` checks `1 <= quorum <= len(names)` when the
plan names its units. For `"any"` the count is not known until the units are resolved, so
it is checked there (5.6).

**`allocated_units` is renamed `scheduled_units`**, the scheduler's choice of units, empty
until a scheduler fills it. The scheduler produces no batches today
(`Scheduler.make_immediate_batch` returns `[]`), so for now it is always empty and plans
run on what they requested.

**Resolving the units** is one function in MAST_control, used by the scheduler, by
`/plans/execute` and by `start_acquisition`, so `"any"` works on every path:

```python
def resolve_units(plan: Plan, site: Site) -> list[str]:
    """The unit names a plan runs on."""
    if plan.scheduled_units:
        return plan.scheduled_units
    names = plan.requested_unit_names()        # None for "any"
    if names is not None:
        return names
    return deployed_not_in_maintenance(site)   # "any": the instrument plays no part
```

`"any"` resolves to every deployed unit not in maintenance. It does not filter on
operational state: each unit's worker checks opstate, operational and busy (5.4), a non-operational unit
fails on its own, and the quorum decides whether enough were usable.

`NewPlanTemplate` in MAST_control (`planning.py:133`) already has `requested_units`; it
loses nothing, and its `timeout_to_guiding` switches to `DEFAULT_TIMEOUT_TO_GUIDING`.

**Other uses of the name `allocated_units`, which is not renamed blindly:**

- **MAST_gui's plan filter** (`static/js/plans.js:433`) is commented "Requested units
  (any match)" but reads `p.allocated_units`, which nothing fills, so the unit filter
  matches no plan. It switches to `requested_units`, and a plan with `"any"` matches every
  unit filter.
- **`ScrapingResults.allocated_units`** (`plan_scraping.py:18`) is a third meaning: the
  units seen across all plans, which the GUI offers in its unit picker (`plans.js:80`,
  `117`). It is renamed `known_units`. `ScrapingResults.required_units` goes with the plan
  field.
- `common/tasks/template.toml`, `common/tasks/dummy-target.toml`,
  `control/docs/full-plan-example.toml`, `control/docs/scheduler-design.md` and the field
  list in `common/CLAUDE.md` follow the rename.
- **`control/docs/scheduler-design.md` section 3.4 is wrong on one point**: it pools
  "operational units feeding the required spectrograph". Every unit feeds both
  instruments; the pool for `"any"` is every deployed unit not in maintenance. Its "empty
  `requested_units`" mode becomes `"any"`.

### 3.2 Exposure fields move into the spectrograph model (`models/spectrographs.py`)

`Target.requested_exposure_duration` and `Target.requested_number_of_exposures` move to
`SpectrographModel`, under the same names and `json_schema_extra`. A `model_validator`
requires `requested_exposure_duration` when `instrument is not None`.
`requested_number_of_exposures` keeps its default of 1. `Target` keeps what describes the
sky: coordinates, `max_exposure_duration`, `repeats`.

`Batch.model_post_init` reads both fields from `plan.target` today
(`batches.py:53-67`), and switches to `plan.spec_assignment`.

### 3.3 Run-time state out of the model

`Plan` carries `controller`, `unit_apis`, `committed_unit_apis`, `spec_api`, `terminated`
and `timings` as pydantic fields, hidden from the UI and excluded by hand when the plan is
written (`submit_plan`, `planning.py:409`). They move to `PlanExecution` (section 5.2), and
so do `probe`, `dispatch`, `wait_for_guiding`, `expose`, `wait_for_spec_done`, `terminate`,
`abort`, `fetch_statuses` and `api_coroutine`. `Plan` keeps the fields, the validators,
`from_toml_file` and `add_event`.

### 3.4 Writing a plan file: `plan_to_toml`

One helper in `models/plans.py`, `plan_to_toml(plan) -> str`, is the only way a plan
reaches a file: `model_dump(mode="json", exclude_none=True)`, then **every empty table is
removed, recursively** (a dict left with no keys after `exclude_none`, such as
`[target.science]` when `ScienceModel` has nothing set), then `tomlkit.dumps`. Empty arrays
are kept: `scheduled_units = []` says "not scheduled". `submit_plan`, the plan generator
(7.1) and the rewrite tool (3.5) all use it. `exclude_defaults` is not the tool: it would
also drop meaningful defaults such as `merit = 1`.

### 3.5 One-off rewrite of the plan files

A tool, `control/tools/rewrite_plans_2026_10.py`, run once on mast-ns-control against every
plan folder:

- `required_units` is dropped.
- `allocated_units` is renamed `scheduled_units`, its value kept.
- An empty or missing `requested_units` becomes `"any"`: under the scheduler design an
  empty list already meant "the scheduler chooses". A plan whose `quorum` is above the
  length of its explicit `requested_units` is reported and left alone.
- `target.requested_exposure_duration` / `requested_number_of_exposures` move into
  `[spec_assignment]`.
- Every rewritten file must load with the new `Plan`; the tool reports any that do not and
  changes nothing in a file it cannot make valid. `--dry-run` lists the changes.

It runs in the same deployment as the model change (section 9), before control starts.

### 3.6 Acquisition outcome on the unit status (`models/statuses.py`)

Unchanged from the 2026-10-18 design:

```python
class AcquisitionState(StrEnum):
    RUNNING = "running"   # accepted, phases or guider calibration in progress
    GUIDING = "guiding"   # guiding, locked on a star
    ENDED = "ended"       # guiding stopped after it had locked
    FAILED = "failed"
    ABORTED = "aborted"   # cancelled (Acquiring cleared / unit/abort)


class AcquisitionOutcome(BaseModel):
    state: AcquisitionState
    errors: list[str] = []
    started_at: str       # ISO UTC
    ended_at: str | None = None
```

`FullUnitStatus.acquisition: AcquisitionOutcome | None = None`, next to `opstate`. `None`
means "not reported" (an older unit, or none since it started), as with `opstate` and
`why_busy`. There is no id: a unit runs one acquisition at a time and replaces its outcome
before `start_acquisition_and_guiding` answers.

### 3.7 Shared constants and `parse_target`

- `DEFAULT_TIMEOUT_TO_GUIDING: float = 600` in `models/plans.py`, used by
  `Plan.timeout_to_guiding` (default and `le=`) and `NewPlanTemplate`. **Already in
  common** at the baseline; only `NewPlanTemplate` still hardcodes 600.
- `COOLING_DOWN_REASON = "imager: cooling down"` in `models/statuses.py`. The unit builds
  its cooling messages from it; control matches `reason.startswith(COOLING_DOWN_REASON)`.
- `parse_target` moves from MAST_unit `flux_metering/session.py` to `common/parsers.py`,
  unchanged.

## 4. What the current plan path does, and why it is replaced

### 4.1 Defects found reading it (2026-10-19, not run)

1. **It cannot pass `probe`.** `Plan.execute` fills a local `unit_apis` list
   (`plans.py:798`) and never assigns `self.unit_apis`, so `probe` rejects with "no units
   assigned to this task".
2. **`time.sleep(20)` in `async` code** (`plans.py:724`, `758`) blocks control's event
   loop -- every endpoint and the status cache -- for 20 s per poll.
3. **`Plan.abort` sends nothing.** It builds the abort coroutines and never awaits them.
4. **`wait_for_guiding` can succeed falsely.** It keeps only responses whose value is a
   `ComponentStatus` instance, so with none `all([])` is `True`; unreachable units drop out
   of the test; and it reads the `Guiding` activity, which a unit in `LostLock` still has.
5. **`dispatch` pairs units with the wrong responses.** `committed_unit_apis` is indexed by
   response position, but units with no matching assignment are skipped when the tasks are
   built.
6. **The unit's `do_execute_assignment` acquires only after an autofocus.** The acquisition
   is inside `if assignment.plan.autofocus:` (`unit.py:1713`), so a plan without autofocus
   does nothing, after the endpoint answered `Ok`.
7. **Nothing reports an outcome.** The assignment thread returns silently on failure
   (MAST_unit#156).
8. **`add_event` after `terminate` writes to the old path.** `terminate` moves the file but
   `model_extra["toml_file"]` is not updated.
9. **No plan ever has a run folder.** `PathMaker.make_run_folder()` (`common/paths.py:237`)
   has no caller, so `run_folder` is always `None`, and control's
   `_handle_assignment_notification` fails `assert self.in_progress.run_folder is not None`
   (`controller.py:929`) on every product notification a unit sends.

So nothing that works today is lost by replacing it.

### 4.2 What it does that is kept

The single `Controller.in_progress` slot; the plan-folder state machine and its file moves;
`EventModel` events appended to the TOML; `timeout_to_guiding`; quorum; the run folder
and the `AssignmentNotification` symlinks of the products (section 6.5).

## 5. The engine (MAST_control)

### 5.1 Where it lives

`control/control/execution.py`. Execution only ever runs on control, so the engine is
control's, and common keeps the model. `Controller.execute(plan)` builds a `PlanExecution`
and runs it; the `in_progress` slot holds the execution.

`Batch` execution is **out of scope** (section 10). `Batch.execute` and its phase methods
call the `Plan` methods that move here, so they are removed with them; `Batch` stays a
model for scheduling.

### 5.2 State

```python
class UnitRunState(StrEnum):
    PENDING, STARTING_UP, FOCUSING, ACQUIRING, GUIDING, FAILED, ABORTED

@dataclass
class UnitRun:
    name: str
    state: UnitRunState = PENDING
    errors: list[str] = field(default_factory=list)

class PlanExecution:
    plan: Plan
    toml_path: Path                 # follows the file through every move (4.1 #8)
    file_lock: Lock                 # every read-modify-write of the plan file
    run_folder: Path
    units: dict[str, UnitRun]
    cancelled: Event
    outcome: Literal["running", "completed", "failed", "aborted"]
```

**The run folder.** At start the execution calls `PathMaker.make_run_folder()`
(`<shared>/runs/<observing-night>/run-<NNNN>`), sets `plan.run_folder`, and records it with
the `executing` event (5.9). The unit product notifications are symlinked under it,
`<run_folder>/<unit>/<shared_subpath>`, as `_handle_assignment_notification` already does.

**The file lock.** `add_event` reads, edits and rewrites the whole TOML, and with one
thread per unit two units can finish at once. Every event write and every move of the file
holds `file_lock`.

`PlanExecution` owns **its own** `ThreadPoolExecutor(max_workers=20)`: one thread per unit.
The controller's executor (`max_workers=25`) feeds the status cache, and 20 long-running
workers on it would starve the cache.

### 5.3 The flow

```text
execute(plan)
  units = resolve_units(plan, site)        (3.1)
  validate units ...................... fail the plan on any problem (5.6)
  one worker per unit, in parallel (5.4)
  coordinator, on every worker's state change:
      guiding >= quorum ................ plan succeeded  (5.5)
      failed  >  len(units) - quorum ... plan failed, now
  if succeeded and plan.spec_assignment is not None:
      expose, wait for the spectrograph (5.7)
  terminate: event, move the file
```

### 5.4 The per-unit worker

Each worker polls **its own unit** (`UnitApi(hostname=name).get("status")`, and
`focus_on_star_status`) every **3 s**, via `asyncio.run` as the status cache does. It does
not read control's status cache, which refreshes each unit every 30 s
(`controller.py:463`). Every wait also returns as soon as `cancelled` is set. Every failure
appends an error prefixed with its step and sets `FAILED`:

| Prefix | The unit stopped |
| --- | --- |
| `startup:` | starting up, or in an opstate it cannot start from |
| `operational:` | not operational, for a reason other than cooling |
| `busy:` | busy with something other than this plan |
| `focus_on_star:` | in `focus_on_star` |
| `acquisition:` | in the acquisition phases, before the handover to the guider |
| `guiding:` | after the handover, without a star lock |
| `status:` | **control could not learn the unit's state**: unreachable, or a field it needs not reported |

Every prefix but `status:` means the unit answered and said no, in its own words. `status:`
means control could not ask, so the unit's own state is unknown, and it says so.

**Unreachable.** A failed status poll is retried; a unit unreachable for **30 s** in a row
fails with `"status: unreachable for 30 s"`. A shorter outage only delays the step it is in.

1. **Opstate.** `initialized` or `shutdown`: `PUT startup`, `STARTING_UP`, wait for
   `opstate == startedup` (600 s). `startedup`: go on. `None`: fail, "status: opstate not
   reported". Anything else: fail, "startup: opstate is `<x>`".
2. **Operational.** Go on if `operational`, or if `why_not_operational` is non-empty and every
   entry starts with `COOLING_DOWN_REASON`. Otherwise fail with the reasons; an empty list
   with `operational == False` fails with "not operational, no reason given".
3. **Busy.** `why_busy == {}`: go on. `None`: fail, "status: busy state not reported". Non-empty:
   fail, `"busy: <owner>: <flags>; ..."`. (`CoolingDown` is not in `why_busy`, so a unit
   that is only cooling passes both 2 and 3.)
4. **`focus_on_star`**, if `plan.autofocus`. `PUT focus_on_star` with `zenith=false`, the
   coordinates and `plan_ulid`; set `FOCUSING`. Errors from the PUT fail the unit. Poll
   `focus_on_star_status` until `active == False` (600 s). `outcome == "solved"`: go on.
   Otherwise fail with the run's `errors`, or its `outcome` if there are none.
5. **Acquire.** `PUT start_acquisition_and_guiding` with the coordinates, `skip_sky=True`,
   `handover_automatically_to_guider=True` and `plan_ulid`; set `ACQUIRING`. Errors from
   the PUT fail the unit. Poll until `status.acquisition.state` is no longer `RUNNING`
   (`plan.timeout_to_guiding`):
   - `GUIDING`, **and** `UnitActivities.Guiding` in the unit's activities, **and**
     `status.guiding` (which is `Guider.is_guiding`, 6.2): set `GUIDING`.
   - `FAILED` or `ABORTED`: fail with the outcome's errors, prefixed `acquisition:`, or
     `guiding:` when the unit had handed over (`UnitActivities.Guiding` was seen) -- e.g.
     "guiding: guiding stopped before locking on a star" (6.1).
   - `ENDED`: fail, "guiding: guiding ended", with the outcome's errors.
   - `acquisition` is `None`: fail, "status: unit does not report acquisition outcome".
6. **Timeout** at any step: `PUT unit/abort` on that unit, then fail it with
   `"<step>: timed out after <n> s, unit aborted"`. In step 5 the step is `guiding` if the
   unit's activities include `UnitActivities.Guiding` at the timeout -- the acquisition
   finished and PHD2 is calibrating or never locked: `"guiding: no star lock within 600 s,
   unit aborted"` -- and `acquisition` otherwise.

Steps 4 and 5 need no "is this the new run?" check: both unit endpoints replace their state
before answering (`FocusOnStarSession.start`, `session.py:208-234`; 6.1), so the first poll
after a successful PUT reads the new run.

A worker whose unit is `GUIDING` stops polling. If guiding later stops, its state still says
`guiding`; `acquisition_status` shows the live columns (7.2).

### 5.5 Quorum and completion

- **Succeeded** when `quorum` units are `GUIDING`.
- **Failed** as soon as `failed > len(units) - quorum`, without waiting out the others'
  timeouts. The remaining workers are cancelled and their units aborted.
- **Workers still running at success keep running**, so a late unit can still reach
  guiding and join. They stop on abort, on their own timeout, or when the plan terminates.

The plan's quorum defaults to 1. The generated plan's `quorum` is `len(units)` unless
`start_acquisition` is given one (7.1).

### 5.6 Validation (the whole plan fails)

On the units `resolve_units` returns (3.1), so on expanded names, never on specifiers: no
units (`"any"` on a site with none deployed outside maintenance); a unit not in any managed
site's `deployed_units`; a unit in `units_in_maintenance`; fewer units than `quorum`
(`"quorum 3, only 2 units eligible"` -- the only place an `"any"` plan's quorum is
checked); coordinates that `parse_target` cannot convert. Duplicate names are dropped.

### 5.7 The spectrograph phase

Only when `spec_assignment` is not `None` **and** its `instrument` is not `None`. A
generated plan never has one, so it never touches the spectrograph.

At success, the spectrograph is checked (operational, `activities == Idle`) and sent its
assignment, then polled until idle -- today's `expose` and `wait_for_spec_done`, moved onto
the execution and using `Event.wait`, not `time.sleep`. While it exposes, a unit that stops
guiding is reported in the plan's events; the exposure is not stopped for it (section 11).

### 5.8 Terminate and abort

- **Terminate** appends `EventModel(what=<outcome>, details=...)` to the TOML at
  `toml_path`, moves the file to `completed/` or `failed/` (an aborted plan to
  `canceled/`), updates `toml_path`, and frees `Controller.in_progress`.
- **Abort** sets `cancelled`, then `PUT unit/abort` on every unit of the plan, in parallel,
  and, when the spectrograph phase has started, `PUT spec/abort`. Each is awaited and its
  failure recorded in the events (4.1 #3). Units not already `FAILED` become `ABORTED`,
  "aborted by operator".

The execution object stays reachable after it terminates, so `acquisition_status` can still
show how it ended (7.2).

### 5.9 Events

Every event is an `EventModel` appended under `file_lock` as it happens, so the file is the
plan's log even if control dies mid-run.

| `what` | When | `details` |
| --- | --- | --- |
| `generated` | `start_acquisition` wrote the plan (7.1) | the request, coordinates as typed |
| `executing` | the execution started | `run_folder: <path>`, `units: [...]`, `quorum: <n>` |
| `unit-starting-up` | a worker sent `startup` | `<unit>` |
| `unit-focusing` | a worker sent `focus_on_star` | `<unit>` |
| `unit-acquiring` | a worker sent `start_acquisition_and_guiding` | `<unit>` |
| `unit-guiding` | a unit reached `GUIDING` | `<unit>` |
| `unit-failed` | a unit reached `FAILED` | `<unit>: <step>: <error>`, one per error |
| `unit-aborted` | a unit reached `ABORTED` | `<unit>: <reason>` |
| `exposing` | the spectrograph phase started (5.7) | the instrument |
| `unit-stopped-guiding` | during the exposure, a guiding unit stopped | `<unit>` |
| `completed` / `failed` / `aborted` | terminate (5.8) | the quorum line, then `failed: <units>` |

A `unit-*` event is written on the state change only, never per poll.

## 6. MAST_unit

### 6.1 Record the outcome (`acquirer.py`)

As in the 2026-10-18 design:

- `Acquirer.outcome: AcquisitionOutcome | None = None`.
- `endpoint_start_acquisition_and_guiding`: after every refusal check passes and just
  before `Thread(...).start()`, set a fresh `RUNNING` outcome. A refused call returns its
  errors and leaves `outcome` alone.
- `run_acquisition`: `ACQUISITION_CANCELLED` sets `ABORTED`; any other failure string, or an
  exception, sets `FAILED` with it in `errors`. Set `ended_at`.
- Handover (`acquirer.py:449-457`): the `while ... UnitActivities.Guiding` loop sets
  `GUIDING` the first time `guider.is_guiding` is true (6.2). If the loop exits before that,
  the run fails, "guiding stopped before locking on a star"; after it, `ENDED`.
- `Unit.status()` puts `acquisition=self.acquirer.outcome` in `FullUnitStatus`.

### 6.2 `is_guiding` means locked; `is_engaged` keeps today's meaning

- `PHD2Connector.is_locked`: PHD2's application state is exactly `Guiding`. Not
  `Calibrating`, `Selected`, `LostLock` or `Paused`.
- `Guider.is_guiding` returns the backend's `is_locked` (PHD2), and is what `status.guiding`
  and the completion test (5.4 step 5) read. `SolvingGuider` has no star lock, so its
  `is_locked` is its `is_guiding`.
- **`Guider.is_engaged`** is added with today's meaning, `Guiding` or `LostLock`
  (`PHD2Connector._is_guiding`, `phd2.py:624`). Two callers move to it, because "locked"
  is the wrong question for them:
  - **Idleness** (`unit.py:921`). With `is_guiding`, a unit that briefly loses its star
    would read as idle -- and its comment says "guessing 'not guiding' could shut down a
    unit the spectrograph is integrating on".
  - **Stop and abort** (`guiding.py:237`). With `is_guiding`, a unit in `LostLock` would
    never be told to stop, and PHD2 would keep looping after an abort.

### 6.3 Fix: a refused handover is reported as success

`PHD2Connector.start_guiding` can refuse without raising `Guiding` (binning or bpp mismatch,
`phd2.py:1554-1566`), and `Guider.start_guiding` (`guiding.py:82`) discards the response.
The acquirer's `while ... Guiding` loop exits at once, the mount stops tracking, and
`do_acquire` returns `None`: success. `Guider.start_guiding` returns the backend's
`CanonicalResponse`, and the handover returns `"handover to guiding failed: <errors>"`.

### 6.4 The cooling reason

`Imager.why_not_operational` (`imagers/__init__.py:374-379`) builds both messages from
`COOLING_DOWN_REASON`. The text stays the same.

### 6.5 `execute_assignment` goes; the product notifications move

`endpoint_execute_assignment`, `do_execute_assignment` and the unreferenced
`start_acquisition_and_guiding_for_assignment` are removed. What they did that the engine
still needs is the `AssignmentNotification` telling control where the products are, so
control can symlink them into the plan's run folder. It moves to the endpoints the workers
call:

- `start_acquisition_and_guiding` and `focus_on_star` take an optional `plan_ulid: str |
  None = None`. When it is set, the unit sends the `in-progress` notification with the
  acquisition folder (`shared_subpath="acquisition"`) or the focus_on_star run folder
  (`shared_subpath="focus_on_star"`), relative to the shared root, as today.
- An operator calling them by hand passes no `plan_ulid` and nothing is sent.

`UnitAssignment` is then no longer received by any unit; whether it stays in common is
decided with the spectrograph's `SpectrographAssignment`, which still uses it.

## 7. The acquisition endpoints (MAST_control)

All three under the OpenAPI tag `acquisition`, at `Const.BASE_CONTROL_PATH` +:

| Path | Method | Returns |
| --- | --- | --- |
| `/start_acquisition` | PUT | `CanonicalResponse`: the plan's ULID, or errors |
| `/acquisition_status` | GET | `PlainTextResponse`: the table (7.2) |
| `/abort_acquisition` | PUT | `CanonicalResponse` |

### 7.1 `start_acquisition`

Parameters: `units: list[str]` (a `Query`, at least one; unit specifiers, or `units=any`, which becomes `requested_units = "any"`); `ra_j2000_hours`,
`dec_j2000_degs` (required, the same `Query(pattern=RA_PATTERN / DEC_PATTERN)` as the
unit's `focus_on_star`); `autofocus_on_star: bool = False`; `quorum: int | None = None`
(defaults to `len(units)`; required with `units=any`, where the count is not known until the units are resolved).

1. Build the plan: `target.ra_hours` and `target.dec_degrees` as decimals from
   `parse_target`, `requested_units`, `autofocus`, `quorum`, `approved = true`,
   `production = false`, no `spec_assignment`, and an event
   `EventModel(what="generated", details=["start_acquisition", "ra=<as typed>",
   "dec=<as typed>"])`, which keeps the coordinates the operator typed. Validate it as a
   `Plan`; refuse on any error.
2. If an acquisition-only plan is in progress, abort it and wait up to **30 s** for its
   units to clear `Aborting`. If any requested unit is still `Aborting` after that, or is
   `Aborting` for another reason, refuse: `"<unit>: still aborting"`. If a plan **with a
   spectrograph** is in progress, refuse (section 11).
3. Write the TOML with `plan_to_toml` (3.4) **straight into `in-progress/`** as
   `PLAN_<ulid>.toml`, a fresh ULID. It
   bypasses `submitted/` and `pending/`, and so `submit_plan`'s "instrument must be
   specified" check, which stays for submitted plans.
4. Load it back with `Plan.from_toml_file`, and hand it to `Controller.execute`. Answer
   with the ULID at once; the execution runs in the background.

A generated plan appears in the plan folders like any other and ends in `completed/`,
`failed/` or `canceled/` with its events.

### 7.2 `acquisition_status`

The current execution, or the last one if none is running; `"no acquisition"` if there has
been none since control started. It fetches every unit's status fresh, in parallel (5 s),
so the table is live even for units whose worker has finished:

```text
plan 01JA...  completed (quorum 2 of 3)

unit    state      opstate    operational  autofocusing  why_busy                 guiding
------  ---------  ---------  -----------  ------------  -----------------------  -------
mast01  guiding    startedup  True         False         unit: Guiding            True
mast03  focusing   startedup  True         True          unit: FocusingOnStar     False
mast05  failed     startedup  False        False         -                        False

errors:
  mast05: operational: mount: not connected
```

- `operational` prints `True (cooling)` when only cooling keeps it from `True`.
- `autofocusing` is `status.autofocusing` or `UnitActivities.FocusingOnStar`.
- `why_busy`: `{}` prints `-`, `None` prints `?`; an unreachable unit prints `unreachable`
  across its status columns.
- Fixed-width columns, sized to the longest value. It works for any plan, not only
  generated ones.

### 7.3 `abort_acquisition`

Aborts the current execution (5.8). No current execution: error `"no acquisition"`.

## 8. Tests

**MAST_common**

- `requested_units=[]` is refused; `quorum` of 0 or above the named units is refused.
- `"any"` loads as `["any"]` and dumps as `"any"`; `"mast01"` loads as `["mast01"]` and
  dumps as a list; `["any", "mast01"]` is refused; `requested_unit_names()` is `None` for
  `"any"` and the expanded names for specifiers (`ns:1,3`); a quorum above the unit count
  is accepted for `"any"`.
- `plan_to_toml` writes `scheduled_units`, never `allocated_units`.
- `SpectrographModel(instrument=...)` without `requested_exposure_duration` is refused;
  with `instrument=None` it is accepted.
- `AcquisitionOutcome` round-trips through `FullUnitStatus`; a status without
  `acquisition` parses to `None`.
- `parse_target`: decimal, colon- and space-separated sexagesimal, `None`/`""`, RA of 0.

**The rewrite tool**: `allocated_units` renamed with its value; an empty `requested_units`
becomes `"any"`; a quorum above an explicit list is reported and the file untouched;
exposure fields moved; `--dry-run` writes nothing; every output loads.

**MAST_unit**

- The outcome moves `RUNNING -> GUIDING -> ENDED` on a stubbed handover; `FAILED` on a phase
  failure and on an exception; `ABORTED` on cancel; untouched by a refused call.
- `is_guiding` is true on PHD2 `Guiding` only; `is_engaged` on `Guiding` and `LostLock`.
- Idleness reads `is_engaged`: a unit in `LostLock` is not idle.
- Stop/abort reads `is_engaged`: a unit in `LostLock` is told to stop.
- A refused `start_guiding` ends `FAILED` with the guider's errors.
- `plan_ulid` sends the notification; no `plan_ulid` sends none.

**MAST_control** (a fake `UnitApi` scripted per unit, injectable poll interval and
timeouts, no network, no sleeps)

- Validation: undeployed, in maintenance, bad RA, duplicates dropped, run on expanded names.
- `resolve_units`: `scheduled_units` wins; then the expanded `requested_units`; `"any"` gives
  every deployed unit not in maintenance, whatever the instrument; `"any"` with fewer
  eligible units than `quorum` fails at once, "quorum 3, only 2 units eligible".
- Opstate, operational, busy and `focus_on_star` cases, as in the worker steps.
- Acquire: `RUNNING` waits; `GUIDING` with `Guiding` and `guiding=True` succeeds; `GUIDING`
  with `guiding=False` keeps waiting; `FAILED` carries the unit's errors; `None` fails.
- **Quorum**: 2 of 3 succeeds while the third is still running, and the third keeps
  running; 2 failures of 3 with quorum 2 fails at once and aborts the third.
- Timeout fails the unit and sends `unit/abort`. In step 5, a timeout with
  `UnitActivities.Guiding` set fails `guiding:`, without it `acquisition:`.
- An outcome `FAILED` after the handover fails `guiding:`; before it, `acquisition:`.
- `status:`: a unit unreachable for 30 s in a row fails; one unreachable for less, then
  answering, does not; `opstate`, `why_busy` or `acquisition` not reported each fail
  `status:`.
- Abort awaits every `unit/abort` and records failures.
- A generated plan is written to `in-progress/`, loaded back with a ULID, and ends in
  `completed/` with its events; `toml_path` follows the move.
- Every unit transition writes one event; polls write none; two workers finishing at once
  both land in the file (the lock).
- The execution creates the run folder and records it; a product notification is
  symlinked under it.
- `plan_to_toml` drops `[target.science]` when empty, keeps `scheduled_units = []`, keeps
  `merit = 1`.
- `start_acquisition` over an acquisition aborts it; over a spectrograph plan refuses.
- No spectrograph call is made when `spec_assignment` is `None`.
- The table: columns, `True (cooling)`, `-`/`?`, errors.

## 9. Rollout

Deployment moves by pin bumps in MAST_provisioning `tools/mast-repos.tsv`. `common` has one
row, shared by the unit, control and spec roles, so a common bump reaches every machine.

1. **Additive, common + unit together.** common: `AcquisitionOutcome`,
   `COOLING_DOWN_REASON`, `parse_target`. unit: 6.1-6.5, importing `parse_target` from
   common. Nothing in common's plan model changes yet, so control and spec are unaffected.
   Removing `execute_assignment` is safe: control's plan path cannot reach it (4.1 #1).
2. **The model and the engine, together, on control.** common: 3.1-3.4. control: the
   engine, the endpoints, `NewPlanTemplate`. gui: the plan forms (the moved exposure
   fields, no `required_units`, `"any"` as a unit choice), the unit filter on
   `requested_units`, and `ScrapingResults.known_units`. Run the rewrite tool (3.5) on mast-ns-control before
   control starts. This is the **first MAST_control pin bump since `8f6a917`**, so it also
   carries every control commit since.

A unit still on step-0 code fails at step 5 with "unit does not report acquisition
outcome". It does not hang.

## 10. Out of scope

- **Executing a `Batch`.** The scheduler produces none today. When it does, a batch is
  several plans sharing units and one spectrograph exposure, and needs its own design on
  top of `PlanExecution`.
- **Resuming after a control restart.** The generated plan's file survives, in
  `in-progress/`, but nothing picks it up. A file found in `in-progress/` at start-up is
  logged; what to do with it is not decided here.
- Running two plans at once. There is one `in_progress`.

## 11. Open

- **`is_engaged`** (6.2) is this design's proposal, not a decision. The alternative is to
  keep `is_guiding` as today and add `is_locked` for the completion test only.
- **`start_acquisition` while a spectrograph plan runs**: refuse (proposed), or abort it as
  an acquisition is aborted?
- **A unit that stops guiding during the spectrograph exposure** (5.7): record it
  (proposed), or stop the exposure when guiding drops below quorum?
- **The generated plan's `owner`**: none today. If the endpoints learn who calls them, it
  should be recorded.

## Appendix A. A generated plan, start to end

The request:

```text
PUT /mast/api/v1/control/start_acquisition?units=mast01&units=mast03&units=mast05
    &ra_j2000_hours=12:30:45&dec_j2000_degs=+20:15:00&autofocus_on_star=true&quorum=2
```

`in-progress/PLAN_01JAD8Q4ZK7V3M2XG9T6R5N0HB.toml` as `start_acquisition` writes it (7.1).
No `[spec_assignment]`, `owner` or `constraints`: they are `None` and dropped. No
`[target.science]`: it is empty and pruned (3.4).

```toml
ulid = "01JAD8Q4ZK7V3M2XG9T6R5N0HB"
mockup = false
merit = 1
timeout_to_guiding = 600.0
autofocus = true
too = false
approved = true
production = false
quorum = 2
requested_units = ["mast01", "mast03", "mast05"]
scheduled_units = []

[target]
ra_hours = 12.5125
dec_degrees = 20.25

[target.repeats]
every = "Only once"
nights = 1

[[events]]
what = "generated"
details = ["start_acquisition", "ra=12:30:45", "dec=+20:15:00"]
when = "2026-10-19T19:42:07.311204+00:00"
```

The same file in `completed/`. The execution added `run_folder` when it started, and the
events as they happened (5.9). mast05 failed its operational check; mast01 and mast03 focused,
acquired and reached guiding, and the second of them made the quorum.

```toml
ulid = "01JAD8Q4ZK7V3M2XG9T6R5N0HB"
# ... as above ...
run_folder = "/Storage/mast-share/MAST/runs/2026-10-19/run-0007"

# [target] ... as above ...

[[events]]
what = "generated"
details = ["start_acquisition", "ra=12:30:45", "dec=+20:15:00"]
when = "2026-10-19T19:42:07.311204+00:00"

[[events]]
what = "executing"
details = ["run_folder: /Storage/mast-share/MAST/runs/2026-10-19/run-0007", "units: mast01, mast03, mast05", "quorum: 2"]
when = "2026-10-19T19:42:07.402113+00:00"

[[events]]
what = "unit-failed"
details = ["mast05: operational: mount: not connected"]
when = "2026-10-19T19:42:09.870155+00:00"

[[events]]
what = "unit-focusing"
details = ["mast01"]
when = "2026-10-19T19:42:10.118020+00:00"

[[events]]
what = "unit-focusing"
details = ["mast03"]
when = "2026-10-19T19:42:10.241877+00:00"

[[events]]
what = "unit-acquiring"
details = ["mast01"]
when = "2026-10-19T19:45:02.660934+00:00"

[[events]]
what = "unit-acquiring"
details = ["mast03"]
when = "2026-10-19T19:45:40.093571+00:00"

[[events]]
what = "unit-guiding"
details = ["mast01"]
when = "2026-10-19T19:47:51.002418+00:00"

[[events]]
what = "unit-guiding"
details = ["mast03"]
when = "2026-10-19T19:48:30.554901+00:00"

[[events]]
what = "completed"
details = ["quorum reached: 2 of 3 guiding (mast01, mast03)", "failed: mast05"]
when = "2026-10-19T19:48:30.561337+00:00"
```

The products are linked under the run folder as the units report them:
`run-0007/mast01/focus_on_star`, `run-0007/mast01/acquisition`, and the same for mast03.
