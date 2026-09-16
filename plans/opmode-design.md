# MAST operating modes — `opmode`

> How a unit or spec machine reaches its operational state, selected by a new `opmode`
> field with three values: `automatic`, `controlled`, `tested`; and a reported `state` of
> `standing-by` / `running` / `tested`. Consumed by the units, the spec, and
> the (not yet built) MAST supervisor. Spans MAST_common, MAST_unit, MAST_spec and
> MAST_control, which is why it belongs in `mast-claude-config/plans/` rather than one repo.
>
> **Status: plan only — not implemented; all design questions closed (rev. 2026-09-16).**
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
itself on boot — and a reported `state` of `standing-by` / `running` / `tested` that a
supervisor, or a test, can poll. Health is not part of it: that stays in the existing
`operational` and `why_not_operational` fields.

## 1. The two mechanisms

Three modes, but only two decision points, and separating them dissolves the circularity in
the provenance chain:

| | decided in | decided when | source |
|---|---|---|---|
| `tested` vs the rest | `app.main()` | before `Config()` exists | **env only** |
| `automatic` vs `controlled` | `Unit.start_lifespan` | after `Config()` exists | env, then DB, then default |

`tested` must be readable without the config DB, yet the DB is source #2. It is resolvable
because `main()` asks only the environment.

## 2. `common/opmode.py` (new)

A new top-level module. Not `common/config/__init__.py` (imports pymongo at module scope,
which `tested` must avoid); not `common/utils.py` (imports numpy/astropy/filer, and is where
the dead class lives). It imports `os`, `enum` and `get_logger`, nothing else.

```python
class OpMode(StrEnum):
    AUTOMATIC  = "automatic"
    CONTROLLED = "controlled"
    TESTED     = "tested"

class MachineState(StrEnum):
    STANDING_BY = "standing-by"; RUNNING = "running"; TESTED = "tested"

OPMODE_ENV = "MAST_OPMODE"
DEFAULT_OPMODE = OpMode.AUTOMATIC
```

`StrEnum`, not `Literal`. The repo already answered this: `LimitFrameMode`
([common/config/phd2.py:16-51](../../common/config/phd2.py#L16)) is the existing
per-unit config mode field, and it is a `StrEnum` with `json_schema_extra` UI metadata. A
`StrEnum` *is* a `str`, so `mode == "automatic"` works and `model_dump()` emits the bare
literal. Copy that file's field declaration line for line.

**Two functions:**

- `opmode_from_env() -> OpMode | None` — source #1 alone. Touches no config, no DB. This is
  what `main()` calls.
- `resolve_opmode() -> OpMode` — env → config → `automatic`. On env miss, imports `Config`
  *function-locally* and dispatches on `load_local_config().machine_role`: `unit` →
  `Config().get_unit().opmode`, `spec` → `Config().get_specs().opmode`, `control` → the
  default. Any exception → WARNING + `automatic`.

Role dispatch belongs in `common`, matching `notifications._build_initiator` and
`init_log` (guarded by `common/tests/test_role_consumers.py`), so MAST_spec calls one
function rather than re-implementing the chain.

**An unrecognised `MAST_OPMODE` raises `ValueError`** naming the value and the three legal
ones — exactly as `resolve_log_level` ([common/mast_logging.py:259-277](../../common/mast_logging.py#L259))
does, and for a sharper reason: `MAST_OPMODE=controled` silently degrading to `automatic`
means a unit opens its covers while the supervisor believes it is parked. Accept
`.strip().lower()`.

**`tested` is rejected in the database** by a `model_validator(mode="after")` on `UnitConfig`
and `SpecsConfig` — *decided*. A service resolves `tested` before the DB is read, so a stored
value could never be honoured; failing loudly beats storing a lie. The env accepts three
values, the DB two, by design.

**Delete `OperatingMode` from `common/utils.py`** in the same PR. Grep MAST_spec, MAST_control
and MAST_gui for `OperatingMode` / `production_mode` / `debug_mode` / `MAST_DEBUG` first — the
`common` clone is shared, so the deletion reaches every consumer on a machine the moment it is
pulled. Do **not** reuse the name: `OpMode` keeps a stale importer's `ImportError` honest.

## 3. What each mode does

### `automatic` — nothing observable changes

`resolve_opmode()` returns `AUTOMATIC` when the env is unset and no `opmode` key exists,
carried by the pydantic default. `Unit.start_lifespan` gains a branch whose `automatic` arm is
the existing `self.startup()` call verbatim.

The field **must** have a default: `get_unit` merges `units.common` with the per-unit delta
([common/config/__init__.py:746-777](../../common/config/__init__.py#L746)), and a
required field absent from `common` raises for every unit in the fleet at once.

### `controlled` — standby, then wait

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

So `standby()` is nearly a no-op: call the existing `Unit.connect()`
([unit.py:337-342](../../unit/src/unit.py#L337)), set the state, log. **The mount's
axes are energised in standby** — *decided*; `connect()`'s mount setter runs
`mount_enable(0)`/`mount_enable(1)` ([mount.py:250-255](../../unit/src/mount.py#L250)),
servos hold torque, nothing homes.

The branch goes in `Unit.start_lifespan` ([unit.py:651-653](../../unit/src/unit.py#L651)),
**not** `app.py` — `app.py` is deliberately `Unit`-free (`from unit import Unit` lives inside
`main()` at :322) and its lifespan branches only on `unit is None`.

### `tested` — a live FastAPI app with no hardware behind it

The tester must be able to: reach `status` (eventually) and read `state: "tested"`, exercise the
FastAPI track, and then `quit` to end the process. So `tested` is not "start nothing" — it is
"start the web stack and nothing else".

Insert at the top of `main()`, ahead of `start_supporting_processes()` (:294):

```python
mode = opmode_from_env()          # not resolve_opmode(): the config DATABASE is source #2
if mode is OpMode.TESTED:
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
| `GET <base_path>/status` | `CanonicalResponse(value={"opmode": "tested", "state": "tested", ...})` |
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

## 4. The reported `state`

The unit and the spec report two new values in their status: `opmode`, and a `state` of
`standing-by` | `running` | `tested`.

| value | meaning |
|---|---|
| `standing-by` | awaiting a `startup` — or, after a `shutdown`, a `startup` or a `powerdown` |
| `running` | got a `startup` |
| `tested` | `opmode` is `tested`: the web stack is up, there is no hardware behind it |

**There is no separate `standing-down`.** A `shutdown` returns the entity to `standing-by`,
because that is precisely what it is: idle, awaiting the next instruction. Two states for the
lifecycle, not three — and the supervisor's "make safe" path becomes naturally idempotent,
since a `shutdown` arriving at an already-idle unit lands where it already was.

The cost is that `standing-by` conflates "never started" with "started and then shut down",
which are not physically identical — after a shutdown the mount is parked and its outlet cut
and the covers are closed, whereas a freshly-constructed unit has the mount connected and
energised but unhomed. Both accept the same next commands, so the supervisor does not care. If
something ever does, `was_shut_down` already distinguishes them on the same status object
([common/interfaces/components.py:129-138](../../common/interfaces/components.py#L129)) —
which is the argument for *not* spending a state value on the distinction.

`tested` deliberately appears in both enums. The redundancy earns its place on the wire: a
client that reads only `state` learns from the single value that this process has no hardware
and will never transition, without having to cross-reference `opmode`. It is terminal — set
once, never left, and the lifecycle transitions below cannot occur because no `Unit` exists to
make them.

**`state` says which lifecycle command the machine is living under, not whether it is
healthy.** Health stays exactly where it already is: `operational` and `why_not_operational`
on the same status object. That separation is what keeps `state` a three-value enum — there is
no `failed`, because a unit that came up with `_init_errors` is `standing-by` *and*
`operational: false`, which is more informative than either alone. It is also why the running
state is called `running` and not `operational`: `ComponentStatus.operational` is an existing
bool meaning "detected, connected, no complaints", and it is `True` in standby too.

`state` cannot be derived from what exists. A fresh `controlled` boot and a fully started unit
are **identical** on the wire today: `was_shut_down=False`, `operational=True`, `activities=0`.

Do not reuse `UnitActivities` — CLAUDE.md:200-214 makes the bitmask cross-repo co-owned, and
these are steady states, not activities in flight; a supervisor waiting for a `StandingBy`
*activity* to clear waits for ever.

A read-only property over one private attribute, with **one writer per transition** — now just
two lines, both in existing methods:

- `_state = STANDING_BY` at the end of `Unit.__init__`, in **all** modes
- `→ RUNNING` on entry to `startup()` ([unit.py:264-273](../../unit/src/unit.py#L264)),
  before the thread is spawned
- `→ STANDING_BY` on entry to `shutdown()` ([unit.py:304-315](../../unit/src/unit.py#L304))

**Transitions fire on receipt of the command, not on its completion** — "got a startup" is the
requirement's own wording, and it keeps `state` independent of `ontimer`, which §5.2 shows is
exactly the machinery that can stop running. A supervisor that needs "startup finished, and it
worked" polls `operational`, or waits on the `x-completion: activity:StartingUp` contract the
endpoint already publishes. That is one fact per field rather than one field trying to carry
liveness, progress and health at once.

The supervisor loop: power the computer → poll until `state == "standing-by"` →
`PUT /startup` → poll until `operational` → work → `PUT /shutdown` → poll until
`state == "standing-by"` again → optionally `PUT /powerdown`.

Resolve the mode **once**, at construction (`self._opmode = resolve_opmode()`), and add the
entry to `CONSTRUCTION_TIME` in `unit/tests/test_config_is_live.py:71-76`. **That guard will
not catch this on its own** — `reads_configuration` (:131-151) matches `self.conf`/`unit_conf`
chains and the literal `Config().<method>()` form, and `resolve_opmode()` matches neither.
Extend it to know the function, in the same change.

## 5. Prerequisite bug fixes — the real work

`controlled` runs start→shut→start repeatedly. `automatic` runs it at most once per process,
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
   `automatic` behaviour too, deliberately, and lands while the fleet is still `automatic` so
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

**Config fields.** `opmode: OpMode = OpMode.AUTOMATIC` on `UnitConfig`
([common/config/unit.py:69-89](../../common/config/unit.py#L69)) and `SpecsConfig`
([common/config/specs.py:76-87](../../common/config/specs.py#L76)), each with the
`json_schema_extra` UI block modelled on `LimitFrameConfig.mode` and the no-`tested` validator.
Observe CLAUDE.md:216 — one key-value entry per line, never wrap a tooltip.

**Wire.** A small `OperatingStatus` mixin in `common/models/statuses.py` carrying
`opmode: OpMode | None = None` and `state: MachineState | None = None`, added to
`FullUnitStatus` (:757) and `SpecStatus` (:860).

`| None = None` is load-bearing. `common` is one shared clone, so the control host gets these
fields the moment it pulls — before any unit sends them. A defaulted `state = STANDING_BY`
would have control read "standing-by" for a unit that is actually running: a
plausible-but-wrong value on a safety-adjacent field, worse than a missing one. Note the
deliberate asymmetry — **config field non-optional with a default** (the merge requires it), **status field optional
defaulting to `None`** (it is a report, and "not reported" is information). Say so in the
docstrings.

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
`standby()`, `_state`, the `start_lifespan` branch and a `powerdown` endpoint. Note `SpecStatus`
derives from `PowerStatus, BaseStatus`, **not** `ComponentStatus` — which is why the mixin
exists. The `tested` half is shared outright: same `tested_router`, same two routes, same
`state: "tested"`, only the base path differs.

## 8. Work items, in dependency order

| stage | repo | contents | safe because |
|---|---|---|---|
| 1 | common | `opmode.py` (enums, resolver, `tested_router`); config fields + validator; `OperatingStatus` mixin; delete `OperatingMode`; tests; `DECISIONS.md` | nothing reads any of it yet |
| 2 | unit | the four fixes in §5 | stand on their own merit; land under `automatic` |
| 3 | unit | `_opmode`, `standby()`, `_state`, status fields, lifespan branch, `run_tested_app()` + the `main()` branch, `powerdown` route | no unit configured `controlled` yet |
| 4 | CI | a smoke job: launch `app.py` with `MAST_OPMODE=tested` and a test `MAST_CONFIG`, poll `status` until it answers `state: "tested"`, `PUT quit`, assert exit 0 | first end-to-end coverage of the app's own entry point, which pytest never touches |
| 5 | DB | write `opmode = "automatic"` into `units.common`, then flip units to `controlled` | `set_unit` persists only the delta, so per-unit is one key |
| 6 | spec/control/gui | mirror stages 2-3; read `opmode`/`state`; build the supervisor | |

**Ordering constraint:** stage 1 must land *and be pulled everywhere* before stage 3 ships.

## 9. Verification

**Unit tests** — house style: subclassed fakes, `object.__new__(Config)`, no Mongo, no hardware.

- `common/tests/test_opmode.py` — env beats config; config beats default; default is
  `automatic` when no document carries the key (this doubles as the "adding the field breaks no
  existing unit" guard); a bad env value raises; case/whitespace tolerated; role dispatch for
  `spec` and `control`; unreachable config → `automatic` + WARNING. **The critical one:** point
  `MAST_CONFIG` at a nonexistent path so any config read would raise, and assert
  `MAST_OPMODE=tested` still resolves — that pins the circularity fix structurally.
- `common/tests/test_opmode_config_field.py` — defaults; `opmode="tested"` raises in both
  models; `json_schema_extra["ui"]["options"] == [m.value for m in OpMode]`.
- `common/tests/test_operating_status_on_the_wire.py` — both fields `None` by default; a
  legacy payload with neither key validates; `model_dump()` emits bare strings.
- `unit/tests/test_opmode_startup.py` — `automatic` calls `startup()` not `standby()`, and
  vice versa; in `controlled`, covers/mount/stage are never asked to move.
- `unit/tests/test_tested_mode.py` — with `MAST_OPMODE=tested` and `uvicorn.Server.run`
  monkeypatched: `Config.__init__` (monkeypatched to raise) is never reached, and the app's
  routes are **exactly** `<base>/status` and `<base>/quit` — no component routes, no
  `/mount/startup`. Then, over `TestClient`: `GET status` returns `state == "tested"` and
  `opmode == "tested"`; `PUT quit` returns ok **and** sets `server.should_exit`. The
  no-subprocess half is free — `unit/tests/conftest.py:53-122` raises on any spawn.
- `common/tests/test_tested_router.py` — the router factory in isolation: it mounts on the
  `base_path` it is given (so MAST_spec gets `/mast/api/v1/spec/...`), `status` answers a
  well-formed `CanonicalResponse`, and `quit` is present **only** through this factory — assert
  no `quit` route exists on an app built the ordinary way.
- `unit/tests/test_startup_contains_a_component_failure.py` — one component raises; every
  other is still attempted, the failure lands in `self.errors`, `StartingUp` is ended.
- `unit/tests/test_shutdown_returns_to_standing_by.py` — `do_shutdown` no longer cancels the
  timer or sets the event; **start → shut → start ends `running` with `operational` true**
  (the §5.2 regression guard); `end_lifespan` does both.
- `unit/tests/test_state_transitions.py` — `standing-by` after `__init__` in every mode, even
  with `_init_errors` set (health belongs to `operational`, not `state`); `running` on entry to
  `startup()` **before** the thread finishes; back to `standing-by` on entry to `shutdown()`;
  **a `shutdown` from `standing-by` leaves it `standing-by`** (the idempotence the two-state
  model buys); and a round trip of `model_dump()` emitting the hyphenated literal, which a JS
  consumer depends on.

Add `common.opmode` to `CORE` in `common/tests/test_imports.py:37-42`.

**Free coverage:** `unit/tests/contract/test_endpoint_declarations.py` reddens if either half
of `endpoint_powerdown` is forgotten; `test_activity_flag_balance.py` demands a matching
`end_activity` for `PoweringDown`; `test_completion_declarations.py` covers the new
`x-completion`.

**End to end, on mast00** (the bench unit, PDU `mastps00` at 10.23.1.75):

1. `MAST_OPMODE=tested python src/app.py` (with `MAST_CONFIG` pointing at the test TOML) →
   serves; `GET /mast/api/v1/unit/status` returns `state: "tested"`, `opmode: "tested"`;
   `/docs` lists only `status` and `quit`; no PWI4 or ps3cli process appears; nothing touches
   Mongo. Then `PUT /mast/api/v1/unit/quit` → the response arrives, the lifespan's shutdown half
   runs, the process exits 0. **Run this on a machine with no config DB reachable** — that is
   the case it exists for.
2. `MAST_OPMODE=controlled python src/app.py` → `GET /mast/api/v1/unit/status` reports
   `state: "standing-by"`, `opmode: "controlled"`. **Confirm physically: covers shut, mount not
   homed, stage not at `Sky`, focuser unmoved.**
3. `PUT /startup` → `state` goes `running` immediately; covers open, mount homes, stage moves;
   `operational` goes `true` once `StartingUp` clears.
4. `PUT /shutdown` → `state` returns to `standing-by`; covers close, mount parks.
5. **`PUT /startup` again → `running`, and `operational` goes `true` a second time.** This is
   the cycle that is broken today; if `operational` never returns, §5.2 did not land.
6. `PUT /powerdown` → component outlets off, process still serving, `Computer` outlet untouched.
7. Unset `MAST_OPMODE`, restart → `automatic`, byte-identical behaviour to today.

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

**`powerdown` does not change `state`.** A powered-down unit reports `standing-by`, which is
accurate — it awaits a `startup`. `PowerStatus.powered` already carries the difference, and the
supervisor reads both fields. The state enum stays at three values.

**No `tested` watchdog.** A `tested` process runs until `quit`. A CI job that dies before
quitting leaves it running until the runner is torn down, which on a GitHub runner is
automatic. Revisit only if a self-hosted runner shows it is needed.

**`end_lifespan` waits indefinitely** for `ShuttingDown` to clear before teardown. Same
principle as the startup deadline: the unit does not cut its own shutdown short, and nssm's
kill timeout is the backstop that already exists. This is why §5.4's fix is the *thread*, not
a deadline — an unbounded wait is fine once it is not holding an HTTP request open.

## 12. Still to check

Not decisions — work that could not be done from the machine this was written on.

1. **`unit-timer-thread` now lives from `__init__` to process exit**, including through a
   post-shutdown `standing-by`, where it polls PWI4 autofocus status (:584-645). Cheap, but
   confirm it is acceptable with the mount parked and powered off.
2. **Cross-repo greps:** MAST_spec / MAST_control / MAST_gui for `OperatingMode`,
   `production_mode`, `debug_mode` and `MAST_DEBUG` before the deletion in stage 1; and for any
   status model setting `extra="forbid"` before adding the two status fields.
3. **MAST_provisioning** — stop setting `MAST_PROJECT` machine-wide, and clear the existing
   value on the fleet. Unrelated to this plan's behaviour; noted because it is the last live
   trace of the variable.

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

The `opmode`, `standby` and `standdown` identifiers were verified to have zero occurrences in
either repo before being chosen.
