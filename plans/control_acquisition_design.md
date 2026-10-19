# Control-driven acquisition as a generated plan

> MAST_control gets three endpoints that take a list of units to one sky position and into
> guiding: `start_acquisition`, `acquisition_status`, `abort_acquisition`. An acquisition is
> **the execution of a plan that control generates** -- target RA/Dec, the requested units,
> optionally `focus_on_star`, and no spectrograph. Plans and acquisitions run on **one
> engine**, which replaces the stepped `probe -> dispatch -> wait_for_guiding` phases with
> one worker thread per unit and a quorum.
>
> **Status: plan only, not implemented.** Reworked on 2026-10-19 around the generated plan;
> the 2026-10-18 version designed a separate acquisition path. No questions are open.
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
  ULID and the same event trail and folder moves as any plan. It is `owner = "mast"`,
  `approved = true` (nothing else will approve it: it skips `pending/`) and
  `production = false` (an engineering acquisition, not science). Appendix A shows one.
- **Every unit's transitions are events in the plan file**, not only the plan's outcome,
  so the file says which units made the quorum and why the others did not.
- **The engine creates the plan's run folder**, for every plan.
- **Plan files carry no empty tables.**
- **`requested_units` may not be empty.** It names the units, or is `"any"`: the plan
  does not care which units it gets. `"any"` is independent of the spectrograph -- every
  unit feeds both instruments, through the common slit. The `required_units` count goes,
  because `quorum` says how many must succeed.
- **`allocated_units` is renamed `scheduled_units`**: it says who fills it.
- **The exposure fields move from `Target` into `SpectrographModel`**:
  `requested_exposure_duration` (required only when `instrument` is not `None`),
  `requested_number_of_exposures`, `max_exposure_duration` and `repeats`. `Target`
  describes the sky only.
- **Existing plan files are rewritten once** (section 3.5), not migrated on every load.
- **Run-time state leaves the `Plan` model.** The model is the plan; a `PlanExecution`
  holds the workers.
- **The unit's `execute_assignment` goes.** The workers drive the unit's own endpoints.
- **`Guider.is_engaged`** keeps today's meaning of `is_guiding` (`Guiding` or `LostLock`) for
  idleness and stop/abort, while `is_guiding` means locked (6.2).
- **`start_acquisition` refuses while a science plan is in progress**; it aborts only a
  previous acquisition.
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

Four fields move from `Target` to `SpectrographModel`, under the same names, defaults and
`json_schema_extra`. They all describe what the spectrograph does, and a plan without one
has no use for them:

| Field | Default | In `SpectrographModel` |
| --- | --- | --- |
| `requested_exposure_duration` | `None` | **required when `instrument is not None`** (a `model_validator`) |
| `requested_number_of_exposures` | `1` | unchanged |
| `max_exposure_duration` | `None` | unchanged |
| `repeats: RepeatsModel` | `every = "Only once"`, `nights = 1` | unchanged |

`Target` keeps what describes the sky: `name`, `magnitude`, `ra_hours`, `dec_degrees`,
`science`. A generated plan, which has no `spec_assignment`, therefore has no exposure
fields and no `repeats` at all (Appendix A).

Every reader follows the move:

- `Batch.model_post_init` reads the exposure fields from `plan.target`
  (`batches.py:53-67`), and switches to `plan.spec_assignment`.
- MAST_control's `NewPlanTemplate` (`planning.py:142-152`) builds them into its `target`
  dict, and moves them into `spec_assignment`.
- MAST_gui's `plan_new.js:137` and `plan_view.js:68` read
  `getFieldValue('target', 'requested_exposure_duration')` and `requested_number_of_exposures`
  by section, and switch to `'spec_assignment'`.
- `control/tools/generate_mockup_plans.py:208` writes them under `[target]`, and moves them;
  the checked-in plans under `control/tools/mockup_plans/` are regenerated (or put through
  the rewrite tool, 3.5).

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
- A target with a `name` but without both coordinates usable is resolved (3.8), its
  coordinates written in and a `resolved` event appended. A name that does not resolve is
  reported and the file left alone. The tool needs the network, on mast-ns-control.
- `target.requested_exposure_duration`, `requested_number_of_exposures`,
  `max_exposure_duration` and `[target.repeats]` move into `[spec_assignment]`. A plan
  with no `[spec_assignment]` and any of them set is reported and left alone: there is no
  spectrograph for them to describe.
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
- `parse_target` is **already in `common/parsers.py`** at the baseline. MAST_unit still
  defines its own copy (`flux_metering/session.py:1412`, imported at `unit.py:67`); it
  switches to common's and deletes the copy.

**Coordinates: decimal and sexagesimal alike, one parser.** Every path that takes RA/Dec --
`Target`'s validators, `parse_target`, the `RA_PATTERN` / `DEC_PATTERN` query patterns --
ends in `parse_angle` (`parsers.py:163`), which reads floats, decimal strings and colon- or
space-separated sexagesimal through astropy's `Angle`, then range-checks without wrapping:
RA in decimal **hours** `[0, 24)`, Dec in decimal degrees `[-90, 90]`. A plan file may write
`ra_hours = 12.5125` or `ra_hours = "12:30:45"`. An RA written in degrees (`187.6875`) is
refused as out of range, not wrapped onto another part of the sky. This is already so at
the baseline; nothing here changes it, and nothing may bypass it with `float()`.

### 3.8 Targets by name: resolve once, record the result

A target may be given by its coordinates, by its object name (`Target.name`, the existing
field, shown in the GUI as "Name"), or both. **Precedence, the same as the unit's
`Acquirer._target_coordinates` (`acquirer.py:570`):**

1. **Both coordinates present and valid**: used as given; the name is a label and is not
   resolved.
2. **Otherwise, the name, if there is one**, resolved by `resolve_object_name`
   (`common/object_resolver.py:539`: TNS and both Sesame mirrors at once, moving targets
   refused without a network call, a 15 s budget, the answering service recorded).
   "Otherwise" covers missing **and** unusable: a coordinate that will not convert is not
   a coordinate.
3. **Otherwise the target is invalid**, and says which it was: no coordinates and no
   name; coordinates supplied but unusable and no name; or a name that did not resolve.
   A name that fails to resolve never falls through to anything.

**`parse_target` gains the name** and stays the one place the rule lives:

```python
def parse_target(
    ra_j2000_hours: str | float | None,
    dec_j2000_degs: str | float | None,
    object_name: str | None = None,
    resolve_timeout: float = TOTAL_TIMEOUT_SECONDS,
) -> tuple[float | None, float | None, ResolvedObject | None]:
    """(ra, dec, None) when the coordinates were used as given; (ra, dec, resolved) when the
    name was resolved; raises ValueError (ObjectNameError for a name) otherwise."""
```

Without a name it behaves as today, so existing callers are unchanged. The unit's
`_target_coordinates` keeps only its rule 3 -- the mount's current position, which only the
unit has -- on top of `parse_target`, instead of its own copy of rules 1 and 2.

**Resolution happens once, when a plan is written, never when it is loaded.** Plans are
loaded constantly -- every folder refresh, every scrape, every GUI listing -- and a
validator that resolved would put up to 15 s of network on each. So:

- **`Target`'s validator never resolves.** It requires both coordinates, valid, as today.
  `ra_hours` / `dec_degrees` stay required in the model.
- **`resolve_target(target: dict) -> tuple[dict, EventModel | None]`** in
  `models/targets.py` runs on the raw dict before the `Plan` is built: it applies
  `parse_target` with `target.get("name")`, writes the decimal coordinates into the dict,
  and returns the `resolved` event when it resolved. Every path that writes a plan calls
  it: `submit_plan`, `start_acquisition` (7.1) and the rewrite tool (3.5).
- **The file then carries the coordinates**, so every later load meets rule 1 and never
  touches the network. The name stays in the file as the label.

**The `resolved` event** records where the coordinates came from, because a misresolution
is invisible everywhere below it -- the mount slews, guiding locks, and the spectrum is of
the wrong sky:

```toml
[[events]]
what = "resolved"
details = ["M101 -> ra=14.053500h dec=+54.348750d via simbad@cds", "canonical name: M 101"]
```

When coordinates were supplied but unusable and the name won, the event says so first:
`"coordinates unusable (ra='25:00:00', dec='+20:15:00'), resolved the name instead"`.

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
guiding is recorded as a `unit-stopped-guiding` event (5.9). The engine does not stop the
exposure for it: whether to stop an exposure belongs to whoever starts it, and is out of
scope here (section 10).

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
| `resolved` | a name was resolved when the plan was written (3.8) | `<name> -> ra=... dec=... via <service>`, the canonical name |
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

Parameters:

- `units: list[str]`, a `Query`, at least one: unit specifiers, or `units=any`, which
  becomes `requested_units = "any"`.
- `ra_j2000_hours`, `dec_j2000_degs`: optional, the same `Query(pattern=RA_PATTERN /
  DEC_PATTERN)` as the unit's `focus_on_star`.
- `object_name: str | None = None`, resolved when the coordinates are not both usable
  (3.8). At least one of the two -- both coordinates, or a name -- is required.
- `autofocus_on_star: bool = False`.
- `quorum: int | None = None`: defaults to `len(units)`; required with `units=any`, where
  the count is not known until the units are resolved.

1. Build the plan: `resolve_target` (3.8) gives `target.ra_hours` / `target.dec_degrees`
   as decimals, and `target.name` is the `object_name`; then `requested_units`,
   `autofocus`, `quorum`, `owner = "mast"`, `approved = true`, `production = false`, no
   `spec_assignment`, and an event `EventModel(what="generated",
   details=["start_acquisition", "ra=<as typed>", "dec=<as typed>", "object=<as typed>"])`
   that keeps what the operator typed, followed by the `resolved` event when a name was
   resolved. Validate it as a `Plan`; refuse on any error -- including a name that does
   not resolve (`"could not resolve 'M1O1' -- ..."`).
2. If an acquisition-only plan is in progress, abort it and wait up to **30 s** for its
   units to clear `Aborting`. If any requested unit is still `Aborting` after that, or is
   `Aborting` for another reason, refuse: `"<unit>: still aborting"`. If a plan **with a
   spectrograph** is in progress, refuse: `"plan <ulid> is in progress"`. A science plan is never
   aborted to make room for an acquisition.
3. Write the TOML with `plan_to_toml` (3.4) **straight into `in-progress/`** as
   `PLAN_<ulid>.toml`, a fresh ULID. It bypasses `submitted/` and `pending/`: nothing
   would approve it there.
4. Load it back with `Plan.from_toml_file`, and hand it to `Controller.execute`. Answer
   with the ULID at once; the execution runs in the background.

A generated plan appears in the plan folders like any other and ends in `completed/`,
`failed/` or `canceled/` with its events.

**`submit_plan` no longer requires an instrument.** Its check "spec_assignment.instrument
must be specified" (`planning.py:402`) is removed: a plan without a spectrograph is valid
wherever it comes from, so a person can write and submit the same plan control generates.
A submitted plan still goes through `submitted/` and `pending/` and runs only once
approved. `submit_plan` runs `resolve_target` (3.8) before writing, so a submitted plan
that names its object is stored with coordinates. The bare minimum a person writes, by
coordinates or by name:

```toml
requested_units = ["mast01", "mast03", "mast05"]

[target]
ra_hours = "12:30:45"
dec_degrees = "+20:15:00"
```

```toml
requested_units = ["mast01", "mast03", "mast05"]

[target]
name = "M101"
```

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
- `Target` no longer accepts `repeats` or `max_exposure_duration`; `SpectrographModel`
  carries all four exposure fields with their defaults.
- `AcquisitionOutcome` round-trips through `FullUnitStatus`; a status without
  `acquisition` parses to `None`.
- `parse_target`: decimal, colon- and space-separated sexagesimal, `None`/`""`, RA of 0 (already
  covered in common at the baseline).
- `Target`: `ra_hours = 12.5125` and `"12:30:45"` load to the same value; an RA of
  `187.6875` (degrees) and a Dec of `91` are refused.
- `parse_target` with a name: both coordinates valid -> used, the name not resolved (no
  network call); one coordinate missing or unusable -> the name resolved; no name -> as
  today; a name that does not resolve -> `ObjectNameError`, never a fallback. The resolver is
  stubbed: no network in tests.
- `resolve_target` writes the coordinates into the dict and returns the `resolved` event;
  unusable coordinates plus a name give the "coordinates unusable" detail first.
- `Target` never resolves: a name without coordinates fails validation on load.

**The rewrite tool**: `allocated_units` renamed with its value; an empty `requested_units`
becomes `"any"`; a quorum above an explicit list is reported and the file untouched;
all four exposure fields moved, `repeats` included; a spectrograph-free plan carrying any
of them reported and untouched; `--dry-run` writes nothing; every output loads.
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
- `submit_plan` accepts a plan with no `spec_assignment`; it lands in `submitted/`.
- `submit_plan` and `start_acquisition` with only `object_name` store the resolved
  coordinates and the `resolved` event; an unresolvable name refuses the request.
- No spectrograph call is made when `spec_assignment` is `None`.
- The table: columns, `True (cooling)`, `-`/`?`, errors.

## 9. Rollout

Deployment moves by pin bumps in MAST_provisioning `tools/mast-repos.tsv`. `common` has one
row, shared by the unit, control and spec roles, so a common bump reaches every machine.

1. **Additive, common + unit together.** common: `AcquisitionOutcome`,
   `COOLING_DOWN_REASON`, `parse_target`'s `object_name` (3.8). unit: 6.1-6.5, its own
   `parse_target` replaced by common's, and `_target_coordinates` built on it.
   Nothing in common's plan model changes yet, so control and spec are unaffected.
   Removing `execute_assignment` is safe: control's plan path cannot reach it (4.1 #1).
2. **The model and the engine, together, on control.** common: 3.1-3.4, `resolve_target`. control: the
   engine, the endpoints, `NewPlanTemplate`. gui: the plan forms (the moved exposure
   fields, no `required_units`, `"any"` as a unit choice), the unit filter on
   `requested_units`, `ScrapingResults.known_units`, and `plan_new.js` / `plan_view.js`
   reading the exposure fields from `spec_assignment`. Run the rewrite tool (3.5) on mast-ns-control before
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
- **Stopping a spectrograph exposure because units stopped guiding.** The engine records it
  (5.7); deciding to stop belongs to whoever starts the exposure.

## Appendix A. A generated plan, start to end

The request:

```text
PUT /mast/api/v1/control/start_acquisition?units=mast01&units=mast03&units=mast05
    &ra_j2000_hours=12:30:45&dec_j2000_degs=+20:15:00&autofocus_on_star=true&quorum=2
```

`in-progress/PLAN_01JAD8Q4ZK7V3M2XG9T6R5N0HB.toml` as `start_acquisition` writes it (7.1).
No `[spec_assignment]` or `constraints`: they are `None` and dropped. No
`[target.science]`: it is empty and pruned (3.4).

```toml
ulid = "01JAD8Q4ZK7V3M2XG9T6R5N0HB"
owner = "mast"
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
