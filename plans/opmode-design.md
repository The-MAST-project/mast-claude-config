# MAST operating modes — `opmode`

> How a unit or spec machine reaches its operational state, selected by a new `opmode`
> field with two values, `operated` and `controlled` (plus `tested`, a CI-only mode selected
> by environment and never stored); and a reported `opstate` of
> `initializing` / `initialized` / `running` / `shutdown`. Consumed by the units, the spec, and
> the (not yet built) MAST supervisor. Spans MAST_common, MAST_unit, MAST_spec and
> MAST_control, which is why it belongs in `mast-claude-config/plans/` rather than one repo.
>
> **Status: plan only — not implemented; all design questions closed (rev. 2026-10-06).**
> Code baseline: MAST_common `master` @ `02e5a42`, MAST_unit `main` as of 2026-09-16.

## Context

A unit today has exactly one way to come up: `app.main()` builds the `Unit`, uvicorn enters
the lifespan, and `Unit.start_lifespan` calls `startup()`, which opens the mirror covers,
homes the mount, moves the stage to the `Sky` preset and drives the focuser. That sequence
runs unconditionally, at process start, whatever the sun is doing.

That is wrong for two situations we now need:

- **A supervisor-driven fleet.** The control machine wants to wake a unit, wait for it to
  report ready-but-idle, and issue `startup` only when safety and work permit — then
  `shutdown` when safety diminishes, and `powerdown` at dawn. Today a unit that boots opens
  its covers whether or not anyone asked.
- **CI.** There is no way to start the app without a config database and hardware, so the
  entry point itself is never exercised — pytest imports modules, it never runs `main()`. CI
  avoids the database and the hardware by per-test discipline, not by any structural guard.

There is also a dead stub in the way: `OperatingMode` at [common/utils.py:422-441](../../common/utils.py#L422)
is binary `debug`/`production` off a `MAST_DEBUG` env var, has **zero call sites**, and its
`production_mode()` is broken — `not OperatingMode.debug_mode` without the call parentheses,
so it returns `False` unconditionally. The name is occupied by code that has never run.

**The outcome:** one `opmode` value, resolved from one place, deciding how far a machine takes
itself on boot — and a reported `opstate` (`initialized` / `running` / `shutdown`, §4) that a
supervisor, or a test, can poll. Health is not part of it: that stays in the existing
`operational` and `why_not_operational` fields.

## 1. The two mechanisms

Three modes, but only two decision points, and separating them dissolves the circularity in
the provenance chain:

| | decided in | decided when | source |
|---|---|---|---|
| `tested` vs the rest | `app.main()` | before `Config()` exists | **env only** |
| `operated` vs `controlled` | `Unit.start_lifespan` | after `Config()` exists | env, then DB, then default |

`tested` must be readable without the config DB, yet the DB is source #2. It is resolvable
because `main()` asks only the environment.

## 2. `common/opmode.py` (new)

A new top-level module. Not `common/config/__init__.py` (imports pymongo at module scope,
which `tested` must avoid); not `common/utils.py` (imports numpy/astropy/filer, and is where
the dead class lives). It imports `os`, `enum` and `get_logger`, nothing else.

```python
class OpMode(StrEnum):                     # the values a real machine can have
    OPERATED   = "operated"                # a person runs the app; it starts at once
    CONTROLLED = "controlled"              # the supervisor runs the app; it waits for startup

class OpState(StrEnum):                    # revised 2026-10-06, see §4
    INITIALIZING = "initializing"; INITIALIZED = "initialized"
    RUNNING = "running"; SHUTDOWN = "shutdown"

OPMODE_ENV = "MAST_OPMODE"
DEFAULT_OPMODE = OpMode.OPERATED
TESTED = "tested"                          # CI-only MAST_OPMODE value -- not an OpMode (below)
```

**The two modes are named for who is in charge of the machine** — *renamed 2026-10-06*, from
`automatic`:

> `operated` — a person (the operator) runs the app from VSCode, and it starts the machine
> immediately. `controlled` — the control machine's supervisor runs the app, and it waits for
> `startup`.

`operated` was chosen over `manual`, which reads as "nothing happens until someone commands it"
— the opposite of this mode, which starts the machine with no command at all; it is
`controlled` that waits. The names rely on MAST's meaning of *operator* as a person (in plain
English "operated" and "controlled" are near-synonyms), which is why this definition goes
wherever the enum is declared or documented.

`StrEnum`, not `Literal`. The repo already answered this: `LimitFrameMode`
([common/config/phd2.py:16-51](../../common/config/phd2.py#L16)) is the existing
per-unit config mode field, and it is a `StrEnum` with `json_schema_extra` UI metadata. A
`StrEnum` *is* a `str`, so `mode == "operated"` works and `model_dump()` emits the bare
literal. Copy that file's field declaration line for line.

**Three functions:**

- `tested_mode_requested() -> bool` — `MAST_OPMODE` is `tested`. Touches no config, no DB.
  This is what `main()` asks first (§3).
- `opmode_from_env() -> OpMode | None` — source #1 alone. Touches no config, no DB.
- `resolve_opmode() -> OpMode` — env → config → `operated`. On env miss, imports `Config`
  *function-locally* and dispatches on `load_local_config().machine_role`: `unit` →
  `Config().get_unit().opmode`, `spec` → `Config().get_specs().opmode`, `control` → the
  default. Any exception → WARNING + `operated`.

Role dispatch belongs in `common`, matching `notifications._build_initiator` and
`init_log` (guarded by `common/tests/test_role_consumers.py`), so MAST_spec calls one
function rather than re-implementing the chain.

**An unrecognised `MAST_OPMODE` raises `ValueError`** naming the value and the legal ones —
exactly as `resolve_log_level`
([common/mast_logging.py:259-277](../../common/mast_logging.py#L259)) does, and for a sharper
reason: `MAST_OPMODE=controled` silently degrading to `operated` means a unit opens its covers
while the supervisor believes it is parked. Accept `.strip().lower()`.

**`tested` is CI-only, and outside both enums** — *decided 2026-10-06*. It never reaches a real
unit: whether the app is started by the supervisor or by an operator in VSCode, the mode it
reads from the database is `operated` or `controlled`. So `tested` is not an `OpMode` member
and has no `OpState`:

- The database cannot hold it **by type**: the config field is an `OpMode`, which has no such
  member, so a stored `"tested"` fails validation like any other bad value. No dedicated
  validator is needed. (The first draft added one, because its `OpMode` had three members.)
- `main()` asks `tested_mode_requested()` before anything else and, if so, runs the test app
  and returns (§3) — before `resolve_opmode()` is ever called.
- If `tested` reaches `opmode_from_env()` anyway, it raises, naming `tested` as a CI-only
  value that only `main()` accepts. A unit with `MAST_OPMODE=tested` set by hand runs the
  harmless test app, never a hardware path.

**Delete `OperatingMode` from `common/utils.py`** in the same PR. Grep MAST_spec, MAST_control
and MAST_gui for `OperatingMode` / `production_mode` / `debug_mode` / `MAST_DEBUG` first — the
`common` clone is shared, so the deletion reaches every consumer on a machine the moment it is
pulled. Do **not** reuse the name: `OpMode` keeps a stale importer's `ImportError` honest.

## 3. What each mode does

### `operated` — nothing observable changes

> `operated` — a person (the operator) runs the app from VSCode, and it starts the machine
> immediately. `controlled` — the control machine's supervisor runs the app, and it waits for
> `startup`.


`resolve_opmode()` returns `OPERATED` when the env is unset and no `opmode` key exists,
carried by the pydantic default. `Unit.start_lifespan` gains a branch whose `operated` arm is
the existing `self.startup()` call verbatim.

The field **must** have a default: `get_unit` merges `units.common` with the per-unit delta
([common/config/__init__.py:746-777](../../common/config/__init__.py#L746)), and a
required field absent from `common` raises for every unit in the fleet at once.

### `controlled` — initialized, then wait

The key finding: **priming already happens in the constructors.** `Mount.__init__`,
`Covers.__init__`, `Stage.__init__`, `Focuser.__init__` and `Imager.__init__` each power their
outlet and connect ([mount.py:176-187](../../unit/src/mount.py#L176),
[covers.py:103-110](../../unit/src/covers.py#L103),
[stage.py:206-232](../../unit/src/stage.py#L206),
[focuser.py:64-76](../../unit/src/focuser.py#L64)). Everything that *moves* is in
`startup()`:

| component | the line that moves hardware |
|---|---|
| covers | [covers.py:330](../../unit/src/covers.py#L330) → `open()` |
| mount | [mount.py:281-282](../../unit/src/mount.py#L281) — fans on, `find_home()` |
| focuser | [focuser.py:109-112](../../unit/src/focuser.py#L109) — enable, move |
| stage | [stage.py:497](../../unit/src/stage.py#L497) — move to `Sky` |
| camera | [ascom.py:581](../../unit/src/imagers/ascom.py#L581) / [zwo.py:214](../../unit/src/zwo.py#L214) — cooler |

So the `controlled` branch of `start_lifespan` is nearly a no-op: call the existing
`Unit.connect()` ([unit.py:337-342](../../unit/src/unit.py#L337)), set
`opstate = INITIALIZED`, log. **The mount's axes are energised while waiting** — *decided*;
`connect()`'s mount setter runs `mount_enable(0)`/`mount_enable(1)`
([mount.py:250-255](../../unit/src/mount.py#L250)), servos hold torque, nothing homes.

The branch goes in `Unit.start_lifespan` ([unit.py:651-653](../../unit/src/unit.py#L651)),
**not** `app.py` — `app.py` is deliberately `Unit`-free (`from unit import Unit` lives inside
`main()` at :322) and its lifespan branches only on `unit is None`.

### `tested` — a live FastAPI app with no hardware behind it

The tester must be able to: reach `status` (eventually) and read `opmode: "tested"`, exercise the
FastAPI track, and then `quit` to end the process. So `tested` is not "start nothing" — it is
"start the web stack and nothing else".

Insert at the top of `main()`, ahead of `start_supporting_processes()` (:294):

```python
if tested_mode_requested():      # env only: the config DATABASE is never consulted for this
    return run_tested_app()
```

Skipped: `start_supporting_processes()` (:294), `Config()` (:300), `start_watching()` (:312),
`get_service` (:314), `from unit import Unit` (:322), `Unit()` (:325). Note what is *not*
skipped: `load_local_config()` is a file read with no database behind it, so `init_log` and
`Filer` behave as they always do — see the CI note below.

`create_app(None)` is already supported and already tested — the lifespan branches on it at
[app.py:219-224](../../unit/src/app.py#L219), and
`unit/tests/test_app_factory.py:92-97,124-129` exercise that path. But it mounts **no** routes
(that is precisely what `test_create_app_without_a_unit_mounts_no_component_routes` asserts), so
`tested` needs two of its own.

**`tested_router(base_path, server)` — a new factory in `common/opmode.py`**, so the unit and
the spec share one implementation and one contract. It imports `fastapi` function-locally,
keeping `opmode.py` importable in a bare context. Two routes, on the real paths so a client
needs no special-casing:

| route | returns |
|---|---|
| `GET <base_path>/status` | `CanonicalResponse(value={"opmode": "tested", ...})` -- no `opstate`: there is no lifecycle (§4) |
| `PUT <base_path>/quit` | `CanonicalResponse_Ok`, then the process exits |

`base_path` is passed in by the caller — `Const.BASE_UNIT_PATH` from MAST_unit's `app.py`,
`Const.BASE_SPEC_PATH` from MAST_spec's. It cannot be derived from `machine_role`, because that
would mean reading the bootstrap TOML, and a CI container has none.

**`quit` is mounted only in `tested` mode.** A route that kills the process is a
denial-of-service on a production unit. It is not a new capability on `Unit` — `Unit.quit()`
([unit.py:471-478](../../unit/src/unit.py#L471)) stays unrouted as it is today.

**Exit through uvicorn, not `os._exit`.** `run_tested_app()` builds the server explicitly rather
than calling `uvicorn.run`, so `quit` can ask it to stop:

```python
def run_tested_app():
    app = create_app(None)
    server = uvicorn.Server(uvicorn.Config(app, host=TESTED_HOST, port=TESTED_PORT))
    app.include_router(tested_router(Const.BASE_UNIT_PATH, server))
    server.run()          # returns when `quit` sets server.should_exit
```

`quit` sets `server.should_exit = True` and returns. uvicorn then finishes the response, runs the
lifespan's shutdown half, and exits 0 — so the test exercises teardown too, which a `SIGKILL`
would skip and which is half the point of testing the FastAPI track.

Add module constants `TESTED_HOST = "127.0.0.1"` and `TESTED_PORT = 8000` — loopback, so a CI
runner is not reachable from the network.

**CI prerequisite.** `init_log` builds a `DailyFileHandler` under `Filer().machine_log_root()`
([common/mast_logging.py:368-372](../../common/mast_logging.py#L368)), which on
Linux is `/Storage/mast-share/MAST` — unwritable in a bare container, and the error is not
caught. Have CI set `MAST_CONFIG` to a checked-in test TOML whose `location.root` is a temp
directory. That is consistent with the design, not a hole in it: `tested` avoids the config
**database**, and `LocalConfig` is a local file with no database behind it.

## 4. The reported `opstate`

*Revised 2026-10-06: four lifecycle values replace `standing-by` / `running`.*

The unit and the spec report two new values in their status: `opmode`, and an `opstate`.

```
initializing ──(end of start_lifespan, controlled)──▶ initialized ──startup──▶ running ⇄ shutdown
                                                                                startup / shutdown
```

| value | meaning | set |
|---|---|---|
| `initializing` | the process is constructing the machine and bringing it up | in `Unit.__init__` |
| `initialized` | up, and no lifecycle command received yet: awaiting the first `startup` | at the end of `start_lifespan`, `controlled` only |
| `running` | the last lifecycle command received was a `startup` | on receipt of `startup` |
| `shutdown` | the last lifecycle command received was a `shutdown` | on receipt of `shutdown` |

**Each value names where the machine is in its lifecycle, and nothing else.** `initialized` and
`shutdown` are deliberately distinct. The first draft had a single `standing-by` for both, at
the cost of conflating "never started" with "started and then shut down" -- which are not
physically the same (after a shutdown the mount is parked and its outlet may be cut, and the
covers are closed). The distinction now costs one enum value and no extra field, and it makes
the unit-level `was_shut_down` redundant (components keep theirs). `initialized` also says
something on its own: an app the supervisor believed `running` that now reports `initialized`
has restarted.

**`initializing` is never seen over HTTP**, and that is accepted (§4a, decided 2026-10-06).
uvicorn opens its port only after the lifespan's startup half has returned, so by the time any
client can ask, the state has already moved on. It exists so the value is defined from the first
line of `Unit.__init__`, and for logs. To a client, "port not open yet" is how initializing
looks.

**Transitions out of `initialized`:** `startup` → `running`; `shutdown` → `shutdown` (a
supervisor making a never-started machine safe). `initialized` is entered once per process and
never again.

**Repeats are idempotent.** A `shutdown` at a machine already in `shutdown` stays `shutdown`, so
the supervisor's "make safe" path can be sent blindly.

**`opstate` says which lifecycle command the machine is living under, not whether it is
healthy.** Health stays exactly where it already is: `operational` and `why_not_operational` on
the same status object. There is no `failed` and no `ready`: a unit that came up with
`_init_errors` is `initialized` *and* `operational: false`, which is more informative than
either alone, and "started and working" is `running` and `operational` (§11, no `READY`). That
is also why the running state is called `running` and not `operational`:
`ComponentStatus.operational` is an existing bool meaning "detected, connected, no complaints",
and it is `True` in `initialized` too.

**A `tested` process has no `opstate`.** It builds no `Unit`, so there is no lifecycle to
report; its status carries `opmode: "tested"` and nothing else of this kind (§3). It runs only in
CI and never on a real unit (§2), so no real consumer ever sees it.

`opstate` cannot be derived from what exists. A fresh `controlled` boot and a fully started unit
are **identical** on the wire today: `was_shut_down=False`, `operational=True`, `activities=0`.

Do not reuse `UnitActivities` for it -- CLAUDE.md makes the bitmask cross-repo co-owned, and
these are lifecycle positions, not activities in flight; a supervisor waiting for an activity
named after a resting state to clear waits for ever.

A read-only property over one private attribute, with **one writer per transition**:

- `_opstate = INITIALIZING` at the start of `Unit.__init__`, in **all** modes
- `→ INITIALIZED` at the end of `Unit.start_lifespan`, in `controlled` only (in `operated`,
  `start_lifespan` calls `startup()` instead, which sets `RUNNING`)
- `→ RUNNING` on entry to `startup()` ([unit.py:264-273](../../unit/src/unit.py#L264)),
  before the thread is spawned
- `→ SHUTDOWN` on entry to `shutdown()` ([unit.py:304-315](../../unit/src/unit.py#L304))

**Transitions fire on receipt of the command, not on its completion** -- "got a startup" is the
requirement's own wording, and it keeps `opstate` independent of `ontimer`, which §5.2 shows is
exactly the machinery that can stop running. A supervisor that needs "startup finished, and it
worked" polls `operational`, or waits on the `x-completion: activity:StartingUp` contract the
endpoint already publishes. That is one fact per field rather than one field trying to carry
liveness, progress and health at once.

The supervisor loop: power the computer (and, under `controlled`, start the app) → poll until the
port answers with `opstate == "initialized"` → `PUT /startup` → poll until `operational` → work
→ `PUT /shutdown` → poll until `opstate == "shutdown"` and `ShuttingDown` has cleared →
optionally `PUT /powerdown`.

The mode is resolved **once, on first read** — in practice by `start_lifespan`, before uvicorn
opens its port — and cached for the life of the process (`OpmodeBase.opmode`; `_opmode` is
`None` until then). *Revised 2026-10-06*: the first draft resolved it in `Unit.__init__`. Under
§4a's design nothing observable separates the two: `resolve_opmode()` never raises (an unreadable
configuration yields the default and a WARNING), and both moments precede the port opening, so
no client can tell. Lazy has one small advantage: a test that builds a `Unit` by hand and never
reads the mode never touches the configuration. For `unit/tests/test_config_is_live.py` it is a
read-once value like the construction-time ones, which that guard does not detect on its own
(`reads_configuration` matches `self.conf`/`unit_conf` chains and the literal
`Config().<method>()` form, not `resolve_opmode()`).

## 4a. Machine lifecycle

*Added 2026-10-06.* §3-§4 describe the modes and the reported state; this section is the
sequence a machine actually goes through, from process start to process exit, and who drives
each step. It applies to the unit and the spec alike -- "the top component" below is `Unit`
or the spec's equivalent.

**Who starts the app** -- *decided 2026-10-06*:

| opmode | started by | how |
|---|---|---|
| `controlled` | the mast-supervisor | runs the role's app (`MAST_unit` or `MAST_spec` `app.py`), per `machine_role` |
| `operated` | the operator | from VSCode, which the supervisor opens; the supervisor never starts the app here |

This keeps the supervisor plan's decision as it stands (under `operated` it launches VSCode,
never the app, and it refuses `controlled` until stage 3 of §8 lands).

**The sequence:**

1. **`main()`, before uvicorn starts:** `Unit()` sets `opstate = INITIALIZING` and constructs
   every component, as `Unit.__init__` does today through `_try_init`: each constructor
   initialises its attributes, powers its outlet and connects (§3). A component whose
   constructor fails is `None`, and its failure is recorded in `_init_errors`.
   `create_app(unit)` then includes the routes of the components that exist.
2. **`app.lifespan`** calls the top component's `start_lifespan()`, yields while the app
   serves, then calls its `end_lifespan()`. This is the unit's shape today.
3. **`start_lifespan()`**: under `operated`, calls `startup()` (→ `RUNNING`); under
   `controlled`, sets `opstate = INITIALIZED` and returns, leaving the machine to wait for the
   `startup` endpoint.
4. **The opmode is read in one place: the top component.** Components do not branch on it. A
   per-component check would start a component before its siblings exist, and makes a component
   unconstructible without a parent's mode. The existing checks in `mount.py` (lines 178, 287,
   316, 361 on 2026-10-05) move up into `Unit` as part of this.
5. **`startup()`** (the top component's endpoint) sets `opstate = RUNNING` on receipt (§4),
   then asks each component to start, each independently (§5.1). A component's `startup()`
   tries to make it operational; whether it succeeded is reported in `operational` /
   `why_not_operational`, not in `opstate`.
6. **`shutdown()`** sets `opstate = SHUTDOWN` on receipt, aborts in-flight work (§5.3), then
   asks each component to shut down. A component's `shutdown()` performs its shutdown
   activities, sets `_was_shut_down = True`, and calls its own `powerdown()` if
   `power_down_on_shutdown` is set.
7. **`end_lifespan()`** calls the top component's `shutdown()`, waits for `ShuttingDown` to
   clear (§11: indefinitely), and only then does process teardown -- cancelling the timer and
   setting the shutdown event, which §5.2 moves out of `do_shutdown`.

**Construction stays where it is, and the port stays closed until it is done** -- *decided
2026-10-06, for simplicity and the least code change.* The alternative was to bring the hardware
up on a background thread, so the port would open at once and `initializing` would be visible
over HTTP. It was rejected: it needs component `status()` to tolerate half-connected hardware
from another thread, rules for commands that arrive mid-bring-up, and constructors split into an
attributes-only half and a `bring_up()`. What the chosen design accepts in return:

- **Nothing is served until construction and `start_lifespan()` are done.** uvicorn completes
  the lifespan's startup half before it opens its port (`uvicorn/server.py` `Server.startup`:
  `await self.lifespan.startup()` precedes `create_server`; checked in 0.50.1). So
  `initializing` is never observed over HTTP, and the first state a client ever sees is
  `initialized` (or `running`, under `operated`).
- **A hung constructor looks like a dead process** -- no port, no `why_not_operational`. The
  supervisor bounds its wait for the port, as it bounds every other wait (§11: timeouts belong
  to the supervisor).
- **No command can arrive during initialization**, because nothing is listening. The questions
  "what does a `startup` during bring-up do" disappear rather than needing answers.
- **Routes stay conditional.** A component that failed to construct has no routes, as today;
  the unit says why in `_init_errors` and `why_not_operational`.

**No `READY` state** -- *decided 2026-10-06*. "Startup received and every component
operational" is `opstate == RUNNING and operational`, two fields the supervisor already reads. A
`READY` would fold health into `opstate`, against §4, and would need exit transitions for a
component that fails later in the night -- detected by `ontimer`, the machinery §5.2 shows can
stop.

**Components carry no `opstate`.** Only the top component reports one. A component reports
`operational` and `was_shut_down`, as it does today; per-component states could disagree with
the top one, and nothing needs them.

**`power_down_on_shutdown` lives in the config database** -- *decided 2026-10-06*. It is a
machine-level setting, not a per-component one:

| machine | document | field on |
|---|---|---|
| unit | `units.common`, overridable in a unit's own delta | `UnitConfig` |
| spec | `specs` | `SpecsConfig` |

`get_unit` merges `units.common` with the per-unit delta, so the fleet-wide value is set once
and a single unit can differ by carrying the key in its own document. Being in the database
makes the behaviour configurable for now; the intent is to **hard-code it once the right
behaviour is settled**, and the field goes away then.

The field needs a pydantic default, for the reason §3 gives for `opmode`: a field absent from
`units.common` would otherwise fail every unit at once. **The default is `False`** --
*decided 2026-10-06*: after a `shutdown`, every component stays powered until a `powerdown`
from the control machine. **Whether and when to power off is the decision of the scheduler on
the control machine**, not of the unit. The database value overrides the default per machine;
Arie sets it to `False` in the documents by hand.

**This changes today's behaviour, deliberately.** Until 2026-10-06 the mount and the covers
powered off on every `shutdown`, unconditionally (the covers in `ontimer`, on reaching
`Closed`); the focuser, stage and imager did not. An earlier revision of this section said the
`False` default "keeps today's behaviour" -- that was wrong. Under `operated`, where nothing sends
`powerdown`, a sun-up `shutdown` now leaves the mount and covers energised too.

`json_schema_extra` waits for a boolean widget, which no config field has yet (§6).

## 5. Prerequisite bug fixes — the real work

`controlled` runs start→shut→start repeatedly. `operated` runs it at most once per process,
which is why none of these has ever been noticed. **All four must land before any unit is
configured `controlled`.**

1. **`do_startup` has no error containment.** [unit.py:256-258](../../unit/src/unit.py#L256)
   is `[comp.startup() for comp in self.components]` — one raising component skips every
   component after it and leaves `UnitActivities.StartingUp` set, so the supervisor blocks all
   night. Fix it the way `Unit.status()` (:392-398) and `Unit.abort()` (:530-548) already do:
   attempt each independently, collect into `self.errors`, end the activity in a `finally`.
   **Highest-value change in the plan.**

2. **`do_shutdown` performs process teardown.** [unit.py:275-283](../../unit/src/unit.py#L275)
   calls `self.timer.cancel()` and `self.unit_shutdown_event.set()`. `unit-timer-thread` runs
   `ontimer`, the *only* thing that ends `StartingUp`/`ShuttingDown` — cancel it and the next
   `startup` can never complete, and `startup()`'s guard at :268 then refuses every further
   attempt. **The start→shut→start cycle is broken today.** Move both lines into
   `end_lifespan` (:647-649), after a bounded wait for `ShuttingDown` to clear.

3. **`do_shutdown` aborts only the guider.** Call `self.abort()` first — *decided* — so an
   exposure or flux-metering run does not continue while the covers close. This changes
   `operated` behaviour too, deliberately, and lands while the fleet is still `operated` so
   any regression surfaces under the mode in production.

4. **`powerdown` blocks the request thread.** `Unit.powerdown` (:289-298) spins
   `while self.is_shutting_down` with no deadline, *on the thread serving the HTTP request*,
   so the caller hangs and a uvicorn worker is held. Same shape in `mount.py:302-308`,
   `focuser.py:130-135`, `imagers/__init__.py:145-150`.

   **The fix is the thread, not a deadline.** Run `Unit.powerdown` on a
   `unit-powerdown-thread` as `startup`/`shutdown` already do, return immediately, and let the
   caller watch `PoweringDown` clear. Waiting indefinitely is then internal and harmless, and
   consistent with §11's decision that timeouts belong to the supervisor rather than to the
   unit. `covers.powerdown` (:351-359) keeps its `MOVE_TIMEOUT_SECONDS` — it is already
   written that way and there is no reason to unpick it.

## 6. Config, wire, and the `powerdown` endpoint

**Config fields.** `opmode: OpMode = OpMode.OPERATED` on `UnitConfig`
([common/config/unit.py:69-89](../../common/config/unit.py#L69)) and `SpecsConfig`
([common/config/specs.py:76-87](../../common/config/specs.py#L76)), each with the
`json_schema_extra` UI block modelled on `LimitFrameConfig.mode`. No validator: the `OpMode`
type itself excludes `tested` (§2).
Observe CLAUDE.md:216 — one key-value entry per line, never wrap a tooltip.

**Wire.** The two new status fields are `opmode` and `opstate` — named as a pair, and
deliberately not `mode` and `state`, both of which are already ambiguous in this codebase
(`CoversState`, `LimitFrameMode`, `ComponentStatus.operational`). They go on a small
`OperatingStatus` mixin in `common/models/statuses.py` carrying
`opmode: OpMode | None = None` and `opstate: OpState | None = None`, added to
`FullUnitStatus` (:757) and `SpecStatus` (:860).

`| None = None` is load-bearing. `common` is one shared clone, so the control host gets these
fields the moment it pulls — before any unit sends them. A defaulted `opstate = INITIALIZED`
would have control read "initialized" for a unit that is actually running: a
plausible-but-wrong value on a safety-adjacent field, worse than a missing one. Note the
deliberate asymmetry — **config field non-optional with a default** (the merge requires it),
**status field optional defaulting to `None`** (it is a report, and "not reported" is
information). Say so in the docstrings.

Add `FullUnitStatus`/`unit.py`/`status` to `CONSTRUCTION_SITES` in
`unit/tests/test_status_fields_are_populated.py:34-38` — a field declared and never passed is
exactly the bug class these two are exposed to.

**`powerdown` endpoint.** `Unit.powerdown()` exists with no route and no caller. Add beside its
siblings at [unit.py:1688-1689](../../unit/src/unit.py#L1688), `Tier.CONTRACT`
(supervisor orchestration, not an operator verb), with a new `UnitActivities.PoweringDown`
**appended at the end** of the enum (common/activities.py:326) — legitimate because we set it.

**It powers down components only** — *decided*. No `SwitchedOutlet` is ever built for the
`Computer` outlet, and a process switching off its own PDU port cannot acknowledge the request.
The controller owns waking and killing the machine; say so in the endpoint's docstring, because
the name over-promises.

## 7. Spec machine

`Config().get_specs()` reads a single document — one spec per site, no per-machine granularity.
`resolve_opmode()`'s role dispatch covers it with no new API. MAST_spec (not checked out here)
needs the `main()` branch, `run_tested_app()` with `Const.BASE_SPEC_PATH`, `opmode`,
`_opstate`, the `start_lifespan` branch and a `powerdown` endpoint. Note `SpecStatus`
derives from `PowerStatus, BaseStatus`, **not** `ComponentStatus` — which is why the mixin
exists. The `tested` half is shared outright: same `tested_router`, same two routes, same
`opmode: "tested"`, only the base path differs.

## 8. Work items, in dependency order

| stage | repo | contents | safe because |
|---|---|---|---|
| 1 | common | `opmode.py` (enums, resolver, `tested_mode_requested`, `tested_router`); config fields; `OperatingStatus` mixin; delete `OperatingMode`; tests; `DECISIONS.md` | nothing reads any of it yet |
| 2 | unit | the four fixes in §5 | stand on their own merit; land under `operated` |
| 3 | unit | `_opmode`, `_opstate` (four states, §4), `OpState` renamed in common, status fields, lifespan branch, `run_tested_app()` + the `main()` branch, `powerdown` route | no unit configured `controlled` yet |
| 4 | CI | a smoke job: launch `app.py` with `MAST_OPMODE=tested` and a test `MAST_CONFIG`, poll `status` until it answers `opmode: "tested"`, `PUT quit`, assert exit 0 | first end-to-end coverage of the app's own entry point, which pytest never touches |
| 5 | DB | write `opmode = "operated"` into `units.common`, then flip units to `controlled` | `set_unit` persists only the delta, so per-unit is one key |
| 6 | spec/control/gui | mirror stages 2-3; read `opmode`/`opstate`; build the supervisor | |

**Ordering constraint:** stage 1 must land *and be pulled everywhere* before stage 3 ships.

## 9. Verification

**Unit tests** — house style: subclassed fakes, `object.__new__(Config)`, no Mongo, no hardware.

- `common/tests/test_opmode.py` — env beats config; config beats default; default is
  `operated` when no document carries the key (this doubles as the "adding the field breaks no
  existing unit" guard); a bad env value raises; case/whitespace tolerated; role dispatch for
  `spec` and `control`; unreachable config → `operated` + WARNING. **The critical one:** point
  `MAST_CONFIG` at a nonexistent path so any config read would raise, and assert
  `tested_mode_requested()` is still true with `MAST_OPMODE=tested` — that pins the circularity
  fix structurally. And `opmode_from_env()` raises on `tested`, naming it CI-only.
- `common/tests/test_opmode_config_field.py` — defaults; `opmode="tested"` raises in both
  models (by type: `OpMode` has no such member); `json_schema_extra["ui"]["options"] == [m.value for m in OpMode]`.
- `common/tests/test_operating_status_on_the_wire.py` — both fields `None` by default; a
  legacy payload with neither key validates; `model_dump()` emits bare strings.
- `unit/tests/test_opmode_startup.py` — under `operated`, `start_lifespan` calls `startup()`;
  under `controlled` it does not, and leaves `opstate == INITIALIZED`; in `controlled`,
  covers/mount/stage are never asked to move.
- `unit/tests/test_tested_mode.py` — with `MAST_OPMODE=tested` and `uvicorn.Server.run`
  monkeypatched: `Config.__init__` (monkeypatched to raise) is never reached, and the app's
  routes are **exactly** `<base>/status` and `<base>/quit` — no component routes, no
  `/mount/startup`. Then, over `TestClient`: `GET status` returns `opmode == "tested"` and no
  `opstate`; `PUT quit` returns ok **and** sets `server.should_exit`. The
  no-subprocess half is free — `unit/tests/conftest.py:53-122` raises on any spawn.
- `common/tests/test_tested_router.py` — the router factory in isolation: it mounts on the
  `base_path` it is given (so MAST_spec gets `/mast/api/v1/spec/...`), `status` answers a
  well-formed `CanonicalResponse`, and `quit` is present **only** through this factory — assert
  no `quit` route exists on an app built the ordinary way.
- `unit/tests/test_startup_contains_a_component_failure.py` — one component raises; every
  other is still attempted, the failure lands in `self.errors`, `StartingUp` is ended.
- `unit/tests/test_shutdown_then_startup_again.py` — `do_shutdown` no longer cancels the
  timer or sets the event; **start → shut → start ends `running` with `operational` true**
  (the §5.2 regression guard); `end_lifespan` does both.
- `unit/tests/test_opstate_transitions.py` — `initializing` from the start of `__init__`;
  `initialized` after `start_lifespan` under `controlled`, even with `_init_errors` set (health
  belongs to `operational`, not `opstate`); `running` on entry to `startup()` **before** the
  thread finishes; `shutdown` on entry to `shutdown()`, from `initialized` as well as from
  `running`; **a `shutdown` from `shutdown` stays `shutdown`** (idempotence); `startup` from
  `shutdown` → `running`; and `model_dump()` emitting the bare lower-case literals, which a JS
  consumer depends on.

Add `common.opmode` to `CORE` in `common/tests/test_imports.py:37-42`.

**Free coverage:** `unit/tests/contract/test_endpoint_declarations.py` reddens if either half
of `endpoint_powerdown` is forgotten; `test_activity_flag_balance.py` demands a matching
`end_activity` for `PoweringDown`; `test_completion_declarations.py` covers the new
`x-completion`.

**End to end, on mast00** (the bench unit, PDU `mastps00` at 10.23.1.75):

1. `MAST_OPMODE=tested python src/app.py` (with `MAST_CONFIG` pointing at the test TOML) →
   serves; `GET /mast/api/v1/unit/status` returns `opmode: "tested"`, no `opstate`;
   `/docs` lists only `status` and `quit`; no PWI4 or ps3cli process appears; nothing touches
   Mongo. Then `PUT /mast/api/v1/unit/quit` → the response arrives, the lifespan's shutdown half
   runs, the process exits 0. **Run this on a machine with no config DB reachable** — that is
   the case it exists for.
2. `MAST_OPMODE=controlled python src/app.py` → `GET /mast/api/v1/unit/status` reports
   `opstate: "initialized"`, `opmode: "controlled"`. **Confirm physically: covers shut, mount not
   homed, stage not at `Sky`, focuser unmoved.**
3. `PUT /startup` → `opstate` goes `running` immediately; covers open, mount homes, stage moves;
   `operational` goes `true` once `StartingUp` clears.
4. `PUT /shutdown` → `opstate` becomes `shutdown`; covers close, mount parks.
5. **`PUT /startup` again → `running`, and `operational` goes `true` a second time.** This is
   the cycle that is broken today; if `operational` never returns, §5.2 did not land.
6. `PUT /powerdown` → component outlets off, process still serving, `Computer` outlet untouched.
7. Unset `MAST_OPMODE`, restart → `operated`, byte-identical behaviour to today.

## 10. What this does NOT do

- **No supervisor.** The word appears nowhere in MAST today. This plan gives it something to
  poll and call; building it is separate work in MAST_control.
- **No enclosure or AC control.** The controlling machine owns those.
- **No unit self-power-off.** See §6.
- **No per-machine spec config.** One `specs` document, as today.
- **Does not make CI hardware-safe.** Stage 4 covers the entry point, but Mongo writes, PDU
  HTTP, outbound HTTP and ASCOM/pyximc instantiation remain ungated in production code paths.
- **`tested` mode serves no component routes.** It proves the FastAPI track is alive and that
  teardown works; it cannot exercise `/mount/startup` or any other hardware verb, because no
  `Unit` exists. Testing those still means fakes under pytest.

## 11. Decisions taken

All five questions this plan opened have been answered. Recorded here rather than deleted,
because the reasoning is the part that is expensive to reconstruct.

**`MAST_OPMODE` may carry all three values.** The `MAST_PROJECT` removal
(common/DECISIONS.md:366-400) looked like a precedent against env vars carrying deployment
shape. It is not: that variable was correcting a *mixup* — for a while `MAST_PROJECT` held the
machine role, which is not what its name meant — and the fix was to move the role into a TOML
field, not to forbid environment variables. So there is no standing decision to argue with, and
`MAST_OPMODE=controlled` on a bench machine is legitimate.

Note in passing: `MAST_PROJECT` is gone from the code in MAST_common and MAST_unit (no reader,
no setter; `common/tests/test_local_config.py:75` deliberately sets it to prove it is inert),
but it is **still set machine-wide** on mast00 — `MAST_PROJECT=unit` in the registry, left by
provisioning. Harmless, unread, and it returns on the next provision run until
MAST_provisioning stops setting it.

**No startup deadline.** A component that wedges leaves `StartingUp` set and the unit sits
`running` and never `operational`. The unit does not impose its own timeout — the supervisor
does, because it is the party that knows how long it is willing to wait and what to do next
(`shutdown` and retry, or take the unit out of the pool). This keeps the unit's job to
reporting truthfully rather than guessing.

**`powerdown` does not change `opstate`.** A powered-down unit reports `shutdown`, which is
accurate — it awaits a `startup`. `PowerStatus.powered` already carries the difference, and the
supervisor reads both fields. `powerdown` is not a lifecycle position, so it gets no `opstate` value.

**No `tested` watchdog.** A `tested` process runs until `quit`. A CI job that dies before
quitting leaves it running until the runner is torn down, which on a GitHub runner is
automatic. Revisit only if a self-hosted runner shows it is needed.

**`end_lifespan` waits indefinitely** for `ShuttingDown` to clear before teardown. Same
principle as the startup deadline: the unit does not cut its own shutdown short, and nssm's
kill timeout is the backstop that already exists. This is why §5.4's fix is the *thread*, not
a deadline — an unbounded wait is fine once it is not holding an HTTP request open.

**`opstate` has four lifecycle values: `initializing`, `initialized`, `running`, `shutdown`**
(2026-10-06), replacing `standing-by` / `running`. `initialized` (never started) and `shutdown`
(started, then shut down) are now distinct rather than conflated. See §4.

**Construction stays in `Unit.__init__`, before uvicorn; nothing is served until it and
`start_lifespan()` finish** (2026-10-06), for simplicity and the least code change. Accepted
consequence: `initializing` is never visible over HTTP, and a client first sees `initialized`.
A background bring-up thread was considered and rejected. See §4a.

**`tested` is CI-only, environment-only, and in neither enum** (2026-10-06). The database
holds only `operated` or `controlled`, and the type enforces it. `main()` intercepts `tested`
before the mode is resolved. A `tested` process reports `opmode: "tested"` and no `opstate`.
See §2.

**`automatic` is renamed `operated`** (2026-10-06). The modes are named for who is in charge:
an operator (`operated`) or the control machine (`controlled`). `manual` was considered and
rejected as reading like "passive". See §2 for the definition. Free to do now: no unit or spec
document in the config database carries an `opmode` key yet.

**The opmode is resolved lazily, on first read** (2026-10-06), not in `Unit.__init__`. First read
is `start_lifespan`, before the port opens; `resolve_opmode()` never raises. See §4.

**No `READY` opstate** (2026-10-06). See §4a: `RUNNING and operational` already says
"started and working", and a `READY` would bring health into `opstate`.

**The operator starts the app under `operated`; the supervisor only under `controlled`**
(2026-10-06). Keeps the supervisor plan's existing decision. See §4a.

**`power_down_on_shutdown` is a config-DB field, per machine** (2026-10-06): on `UnitConfig`
(set in `units.common`, overridable per unit) and on `SpecsConfig` (the `specs` document).
Defaults to `False`: components stay powered after `shutdown` until the control machine's
scheduler sends `powerdown`. This ends the mount's and covers' unconditional power-off at
shutdown. Configurable while the right behaviour is unsettled, to be hard-coded once it is.
See §4a.

## 12. Still to check

Not decisions — work that could not be done from the machine this was written on.

1. **`unit-timer-thread` now lives from `__init__` to process exit**, including through a
   post-shutdown `shutdown`, where it polls PWI4 autofocus status (:584-645). Cheap, but
   confirm it is acceptable with the mount parked and powered off.
2. **Cross-repo greps:** MAST_spec / MAST_control / MAST_gui for `OperatingMode`,
   `production_mode`, `debug_mode` and `MAST_DEBUG` before the deletion in stage 1; and for any
   status model setting `extra="forbid"` before adding the two status fields.
3. **MAST_provisioning** — stop setting `MAST_PROJECT` machine-wide, and clear the existing
   value on the fleet. Unrelated to this plan's behaviour; noted because it is the last live
   trace of the variable.
4. **Rename `OpState` in the code.** `common/opmode.py` has `STANDBY` / `RUNNING`; this plan now
   specifies `INITIALIZING` / `INITIALIZED` / `RUNNING` / `SHUTDOWN` (§4). Nothing is on the
   wire yet, and the only uses outside `common` are two lines in `unit/src/mount.py` (288,
   316), which move into `Unit` anyway (§4a).

## Provenance

Written 2026-09-16 against MAST_common `master` @ `02e5a42` and the MAST_unit clone beside it.

Requirement stated by Arie in session, including the `standing-by` / `running` / `tested`
vocabulary and the rule that health stays in `operational` / `why_not_operational`. Nine
decisions were ratified in the same session, in three rounds: first the four in §3-§6 (mount
energised in standby; `tested` rejected in the DB; `powerdown` covers components only;
`shutdown` aborts in-flight work); then the `tested` mode's live `status`/`quit` surface and the
dropping of a fourth state, `standing-down`, in favour of returning to `standing-by`; then the
five in §11, which closed every question the first draft left open.

The bias in that last round is worth naming, because it should guide the implementation: on
three of five — the startup deadline, the `tested` watchdog, the `end_lifespan` bound — the
answer was *do not add a timeout*. Timeouts belong to the supervisor, which knows what it is
willing to wait for; the unit's job is to report truthfully and not to guess on its owner's
behalf. Where a wait is genuinely a problem, the fix is to move it off the request thread
(§5.4), not to cap it.

**Revised 2026-10-06** with Arie, in session: the machine-lifecycle section (§4a); `opstate`
redefined as `initializing` / `initialized` / `running` / `shutdown` (§4), which undoes the first
draft's merging of "never started" and "shut down" into `standing-by`; no `READY` state; the
operator, not the supervisor, starts the app under `operated`; `power_down_on_shutdown` as a
config-DB field defaulting to `False`; construction left before uvicorn, accepting that
`initializing` is never visible over HTTP; `tested` kept, as a CI-only mode outside
`OpMode` and `OpState`; and `automatic` renamed `operated` (Arie's choice over `manual`). A
background bring-up thread was weighed and declined for simplicity -- the trade-off is set out
in §4a.

The `opmode`, `standby` and `standdown` identifiers were verified to have zero occurrences in
either repo before being chosen.
