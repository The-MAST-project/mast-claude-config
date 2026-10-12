# Endpoint admission and sequencing

> One admission decision for every HTTP request a unit receives, taken from the unit's
> `opstate`, what it is busy with (`why_busy`), and what kind of request it is. While the unit
> starts up or shuts down it does nothing else; while it is busy it answers only status, abort
> and shutdown; once shut down it answers only status, startup, shutdown and powerdown. An
> admission lock closes the check-then-run race between two requests. Replaces
> `refuse_while_shutting_down` in MAST_unit `app.py`.
>
> **Status: plan only — not implemented. Design agreed 2026-10-12; open items in §12.**
> Code baseline: MAST_common `master` @ `14890ae`, MAST_unit `main` @ `f76987b`, plus MAST_unit
> branch `unit-startingup-gaps` @ `9a4f420` (the StartingUp / ShuttingDown dispatch flags this
> plan relies on, §8). Builds the busy predicate of
> [unit_idleness_design.md](unit_idleness_design.md) first, with three revisions recorded there.
> Mode names: this plan says **production** / **development** for today's `controlled` /
> `operated`; the rename is a separate change it does not depend on (§7).

## 1. Goals

1. While the unit is **starting up or shutting down**, it does nothing else.
2. While the unit is **busy**, a client may only read status, abort what is going on, or shut
   the unit down.
3. Once the unit has been **shut down**, a client may only read status, start it up, or power
   it down.
4. A **production** unit is governed only through the unit's own endpoints. Component
   endpoints are for development.

Today only goal 1's shutdown half exists: `refuse_while_shutting_down`
([app.py:295](../../unit/src/app.py#L295)) answers `*/status` and refuses everything else while
`UnitActivities.ShuttingDown` is up. Two concrete gaps that motivated this plan:

- A `startup` arriving mid-shutdown is admitted: `startup()` checks `StartingUp`, not
  `ShuttingDown`, so it sets `opstate = RUNNING` and starts its thread while the shutdown is
  still dispatching.
- Two operations arriving within milliseconds are both admitted, since each handler raises its
  flag only after any check could have run (§5).

## 2. The admission table

Evaluated top to bottom on each request to a **unit-scope** route (§4.1); the first matching
row decides.

| # | Unit state | Admitted request classes |
|---|---|---|
| 1 | `ShuttingDown` active | READ |
| 2 | `StartingUp` active | READ, SHUTDOWN |
| 3 | `opstate == INITIALIZED` | READ, STARTUP, SHUTDOWN, POWERDOWN |
| 4 | `opstate == SHUTDOWN` | READ, STARTUP, SHUTDOWN, POWERDOWN |
| 5 | busy (§3) | READ, ABORT, SHUTDOWN |
| 6 | otherwise (`RUNNING`, idle) | everything |

Why each departure from the shortest form of the goals:

- **Row 2 admits SHUTDOWN.** Shutdown is the supervisor's make-safe verb. A startup that hangs
  (covers that never report `Open`) holds `StartingUp` until a component times out, and with
  only READ admitted nothing could stop the unit meanwhile. A shutdown during startup is
  already safe: `do_shutdown` waits, bounded, for the startup to finish dispatching before it
  touches a component (`_await_startup_dispatched`), so `covers.startup()` cannot reopen what
  the shutdown just closed.
- **Row 3 admits SHUTDOWN and POWERDOWN.** Accepting `shutdown` from `INITIALIZED` is how the
  supervisor makes safe a machine it never started (opmode-design §4a;
  `test_shutdown_from_initialized_is_accepted`).
- **Rows 4 and 3 admit SHUTDOWN again** because it is idempotent and refusing it would only
  make a caller special-case "already down".
- **Row 5 admits SHUTDOWN.** Shutdown does an intrinsic abort: `do_shutdown` aborts and waits,
  bounded, for the abort to settle before shutting components down (opmode-design §5.3). So at
  dawn the controller sends one `shutdown`, not abort → poll until idle → shutdown.
- **Row 6 admits ABORT** with nothing running. It is harmless, and refusing it would make a
  client's "stop whatever is going on" depend on knowing whether anything is.

`INITIALIZING` needs no row: it is never seen over HTTP, since uvicorn opens the port only once
`start_lifespan` has returned (opmode-design §4).

A request **already running** when the state changes is not interrupted, as today. The gate
decides admission only.

## 3. Busy: `why_busy`, `is_busy`, `is_idle`

### 3.1 Definition

```python
Unit.why_busy -> dict[str, list[str]]   # {"unit": ["Guiding"], "covers": ["Closing"]}; {} when idle
Unit.is_busy  -> bool                   # bool(why_busy)
Unit.is_idle  -> bool                   # not is_busy
```

`why_busy` holds an entry for each owner with something active, valued from that owner's
`activities_verbal`:

- **`"unit"`**: `UnitActivities`. Every one of them is unit-level work (the list is in
  unit_idleness §2).
- **each component**: `"mount"`, `"covers"`, `"focuser"`, `"stage"`, `"imager"` (wrapper *and*
  backend — the imager splits its flags between them, so both are read and merged). A direct
  `PUT /mount/goto_ra_dec_j2000` or covers move raises **no** unit flag, so without this term a
  development night reads as idle throughout.
- **guiding**: `guider.is_guiding`, under `"unit"` as `"Guiding"`, so a PHD2 that is guiding
  with the unit's flag down still reads busy (unit_idleness §4: the dangerous divergence).

Keyed by owner, not flattened: flag names collide across enums (`StartingUp` in 10,
`ShuttingDown` in 10, `Exposing` in 8, `Aborting` in 8), and a structural key resolves that by
construction. Never union the `activities` integers — the enums overlap in bit values.

**Guiding counts as busy, for hours.** During an observation only READ, ABORT and SHUTDOWN are
admitted. This is intended: guiding is the science interlock, coextensive with the
spectrograph's exposure (unit_idleness §4). Tracking does not count: it is a state with no
start or end, and residue when nothing claims the unit (unit_idleness §3).

`was_shut_down` is **not** a term. `is_idle` is exactly `not is_busy`, so including it would
make every shut-down unit read busy. The shut-down case is the table's row 4, by `opstate`;
inactivity-shutdown eligibility is `is_idle and not was_shut_down`, stated where it is used.

`Unit.is_idle` overrides the inherited `Activities.is_idle`, which reads the unit's own flags
only. Its one caller ([unit.py:1597](../../unit/src/unit.py#L1597)) gets the stricter, correct
answer. The private `_unit_is_busy()` on the unmerged `mount-stability-campaign` branch, a
hand-picked flag list, is replaced by `unit.is_busy`.

### 3.2 Computed on demand; guiding cached

`why_busy` is computed at each call, not once per `ontimer` tick as unit_idleness §5 had it. The
gate cannot use a 2 s stale answer: an operation raises its flag immediately, and a cached dict
would not show it until the next tick, which reopens exactly the race §5 closes.

On demand is cheap: `is_active` / `activities_verbal` read in-memory flags under each owner's
`Activities.lock`, with no hardware access. Unit_idleness' concern about a sick component
taking the whole status down applies to `status()`, which talks to hardware; this does not.

The one exception is guiding. `PHD2Connector.is_guiding`
([phd2.py:1399](../../unit/src/phd2/phd2.py#L1399)) calls `get_status()`, a socket round-trip
to another process, which the gate — running on the event loop, under a lock — must never
make. So `Unit.ontimer` refreshes a cached `_guiding_live` from `guider.is_guiding` each tick,
and `why_busy` reads `UnitActivities.Guiding` **or** `_guiding_live`. Either one true reads
busy, so the divergence fails safe; the cache is at most 2 s stale, and only in the
"PHD2 guiding without our flag" direction, which nothing starts in under 2 s.

### 3.3 Published

`FullUnitStatus.why_busy: dict[str, list[str]] | None = None`, with unit_idleness §6's
semantics unchanged: `None` unknown (an old unit, or control's fabricated `BasicUnitStatus`),
`{}` idle, non-empty busy. Must not default to `{}` — a new controller reading an old unit would
see "idle".

## 4. Classifying routes

### 4.1 Scope: unit or component

Every route belongs to one router, and `mount_routers` ([app.py:186](../../unit/src/app.py#L186))
already knows which: `unit.api_router`, then one per `COMPONENT_ATTRIBUTES` entry. The gate
needs that fact per route, so registration records a **scope** on each route, and the
middleware reads the matched route's scope rather than parsing its path.

| Scope | Production | Development |
|---|---|---|
| unit | the §2 table | the §2 table |
| component | READ admitted; everything else refused | ungated |

- **Unit scope is gated in development too.** The table protects the unit's own lifecycle
  whoever is calling; a developer can still drive components directly, at their own risk.
- **Component READ is admitted in production.** Harmless, and the GUI or a person debugging
  may read a component's status directly.
- Component activities still count toward `why_busy` in development, so a developer moving the
  stage makes the unit busy, and a unit operation is refused until it stops. That is the point.

**The calibrator is unit scope** (§12.1). It is in `COMPONENT_ATTRIBUTES`
([app.py:146](../../unit/src/app.py#L146)) only because it has its own router; it is not
hardware, and it raises `UnitActivities` (`Calibrating`, `CalibratingFocus`, …) like any unit
operation. Scope is therefore an explicit property of a router, not inferred from the component
list.

### 4.2 Admission class

A unit-scope route declares one class:

| Class | Meaning |
|---|---|
| `READ` | changes nothing |
| `ABORT` | stops work in progress, starts none |
| `STARTUP` | the unit's `startup` |
| `SHUTDOWN` | the unit's `shutdown` |
| `POWERDOWN` | the unit's `powerdown` |
| `OPERATION` | everything else — **the default** |

The default is fail-closed: a route nobody classified is treated as an operation, refused while
busy, never admitted as a read. Unit-scope routes as served on 2026-10-12 (mast00):

| Class | Routes |
|---|---|
| READ | `GET /status`, `/find_max_flux_status`, `/flux_metering_runs`, `/flux_metering_run_steps`, `/calibrate/status`, `/calibrate/config` |
| ABORT | `PUT /abort`, `/stop_acquisition_and_guiding`, `/stop_autofocus`, `/stop_dancing`; `POST /calibrate/abort` |
| STARTUP / SHUTDOWN / POWERDOWN | `PUT /startup`, `/shutdown`, `/powerdown` |
| OPERATION | `PUT /execute_assignment`, `/start_acquisition_and_guiding`, `/start_guiding`, `/start_autofocus`, `/expose`, `/acquire_and_find_max_flux`, `/spiral_new_path`, `/spiral_next_step`, `/spiral_previous_step`, `/spiral_correlate_steps`, `/spiral_end_path`, `/test_stage_repeatability`, `/start_dancing`; `POST /calibrate`, `/calibrate/focuser`, `/calibrate/optical_center`, `/calibrate/stage`; and `focus_on_star` (branch `focus-on-star`) |

The `stop_*` verbs are ABORT, not OPERATION: they are how a client stops the specific thing the
unit is busy with, which is exactly what row 5 must admit. A route is ABORT only if it starts
nothing: `spiral_end_path` *ends* a session but takes a final exposure and correlates it, so it
is an OPERATION. Each ABORT classification is checked against the handler body, not the name.

A spiral path raises no flag of its own ([spiral_search.py](../../unit/src/spiral_search.py)), so
stepping is admitted between steps; a step requested while the previous step's mount move is
still running is refused (`why_busy` shows `mount: Moving`) and is simply retried.

### 4.3 Where it is declared

A field on `EndpointDeclaration` ([endpoints.py:266](../../common/endpoints.py#L266)), beside
`tier` and `completion`, set at the definition site through `@endpoint(..., admission=...)`.
This reuses the existing guarantees: every served route already carries a declaration, and
registering an undeclared method is an import-time error (`add_api_route`), so a route cannot
reach the gate unclassified-by-accident — only classified-by-default, as OPERATION.

Paths outside the declared surface — `/docs`, `/openapi.json`, `/favicon.ico` — are admitted.
WebSocket routes do not pass through `@app.middleware("http")`; any the unit serves are out of
the gate's reach and must be read-only.

## 5. Sequencing: the admission lock

Check-then-run is a race. The gate reads the flags, then the handler raises its own — often
inside a thread it starts — so two operations arriving within milliseconds both see idle and
both run. The fix is an atomic claim:

1. take the admission lock (a `threading.Lock`, held for microseconds, no `await` inside);
2. evaluate §2 against the state **and** the claim (below);
3. if admitted and the class takes a claim, set it;
4. release the lock; run the handler;
5. clear the claim when the handler returns.

**Which classes claim.** OPERATION, STARTUP and POWERDOWN take the claim and are refused while
one is held, as if busy: `refused: busy (<path> in progress)`. READ and ABORT never claim and are
never blocked by one. SHUTDOWN does not claim and is not blocked by one: it is admitted while
busy anyway, and its own abort is what stops the claimed operation.

**The rule the claim depends on.** By the time a claiming handler returns, its activity flag must
already be up, so the claim hands over to the flag with no gap. `startup` and `shutdown` already
do this ("raised here rather than in the thread", [unit.py](../../unit/src/unit.py)); every
OPERATION endpoint must be audited for it (§9.1). A handler that blocks until the hardware is
done (`Completion.BLOCKING`) holds the claim for its whole duration, which also covers one that
raises no flag at all.

This is a **per-process** lock, which is the right scope: a unit is one process, and admission
is about that process's hardware.

## 6. Refusals

Kept as today: HTTP 200 with `CanonicalResponse.errors`, consistent with HTTP status codes being
parked ([endpoints.py](../../common/endpoints.py)). The message names the rule and what blocks:

```
PUT /mast/api/v1/unit/expose: refused, the unit is busy (unit: Guiding; covers: Closing)
PUT /mast/api/v1/unit/startup: refused, the unit is shutting down
PUT /mast/api/v1/unit/mount/goto_alt_az: refused, component endpoints are development-only
```

Each refusal is logged once at INFO with the same text, so the morning-after log shows what a
client tried and why it was turned away.

## 7. Production and development

The gate reads the machine's opmode through `OpmodeBase.opmode`, which is resolved once at
startup and does not change while the app runs ([opmode.py](../../common/opmode.py)). Only
component scope depends on it (§4.1).

The production/development names make the rule self-describing — production: governed by the
controller, gated; development: an engineer driving components. The rename itself (enum values,
the config DB documents, `MAST_OPMODE`, the supervisor and the GUI) is cross-repo with a config
migration, and is the second rename in a week (`automatic` → `operated`, 2026-10-06). It is a
separate change; this plan works under either set of names.

## 8. Dependencies already in place

From MAST_unit `unit-startingup-gaps` (`9a4f420`), not yet merged:

- `StartingUp` and `ShuttingDown` are ended by `ontimer` only after their dispatch has finished
  (`_startup_dispatching`, `_shutdown_dispatching`). Before that, `StartingUp` cleared 1.9 s
  into a 34 s startup (mast00, 2026-10-11), and row 2 would have opened the gate with the covers
  still opening.
- `do_shutdown` waits for an in-flight startup to finish dispatching (row 2's safety argument).
- `do_shutdown` connects on its own thread, not the request's, so a repeat `shutdown` admitted by
  rows 3–5 no longer reconnects what a running shutdown is disconnecting.

That branch merges first.

## 9. Audits before enforcing

1. **Every OPERATION endpoint raises its flag before returning** (§5). List each, with where it
   raises; fix the ones that raise inside their thread. A test per endpoint where feasible.
2. **MAST_control and MAST_gui calls to component endpoints of a unit.** In production these are
   refused (§4.1). Every such call — GUI buttons for covers, stage or focuser; the controller
   reaching into `/unit/mount/…` — needs a unit-level endpoint first. Neither repo is checked out
   on mast00, so this audit runs where they are.
3. **ABORT verbs that end a flag before the work has stopped.** `stop_autofocus`
   ([autofocusing.py:553](../../unit/src/autofocusing.py#L553)), `stop_acquisition_and_guiding`
   ([guiding.py:203](../../unit/src/guiding.py#L203)) and `calibrate/abort`
   ([calibrator.py:497](../../unit/src/calibration/calibrator.py#L497)) clear the flag at once
   and let the worker notice and unwind later. Between the two, `why_busy` reads idle while
   the old thread is still running, and the gate admits a new operation on top of it. This is
   the hazard the `_expose_cancelled` comment in `Unit.__init__` describes for `Exposing`,
   which is why that flag stays up until `do_expose` has really unwound. Each of these needs
   the same shape — signal cancellation, end the flag when the worker exits — or `why_busy`
   must also see the still-running worker.
4. **What MAST_control sends while a unit is guiding.** Row 5 admits only READ, ABORT and
   SHUTDOWN during guiding. Any correction, offset or focus call control makes mid-observation
   would start being refused; each needs a decision (an ABORT-like exemption, or a different
   flow).

## 10. Spec machine

`OpmodeBase` and the lifecycle are shared, so the spec wants the same gate. The decision itself
is a pure function in MAST_common:

```python
def admit(opstate, why_busy, claim_held, scope, admission, opmode) -> str | None:
    """None to admit; otherwise the refusal reason."""
```

Each app keeps a thin middleware that holds the lock, gathers the inputs and calls it. The unit
is built first; the spec adopts it once its routes are classified. MAST_spec is not checked out
here, so its route list is not in this plan.

## 11. Work items, in dependency order

1. **MAST_unit** — merge `unit-startingup-gaps` (§8).
2. **MAST_common** — `Admission` enum; `admission` on `EndpointDeclaration` / `@endpoint`
   (default `OPERATION`); `admit()` with its table tests; `FullUnitStatus.why_busy` (§3.3).
   Same-named branch, so the unit's CI resolves it.
3. **MAST_unit** — `why_busy` / `is_busy` / `is_idle`, the `_guiding_live` cache in `ontimer`,
   `status()` wiring.
4. **MAST_unit** — classify every unit-scope route (§4.2); record scope at registration; a test
   asserting each route's class and scope, so a new route forces a decision.
5. **MAST_unit** — replace `refuse_while_shutting_down` with the gate and the claim (§5);
   `test_shutdown_gate.py` becomes the admission test suite.
6. **Audits** (§9), then enforce. Rollout: observe-only first (§12.2).
7. Later, separately: MAST_spec (§10); the production/development rename (§7); the inactivity
   shutdown (unit_idleness §7).

## 12. Open items

1. **Calibrator scope** — this plan makes it unit scope (§4.1). Confirm: is `/calibrate` driven
   by the controller in production?
2. **Observe-only rollout** — log every would-be refusal for a few nights before enforcing, the
   pilot-then-commit shape unit_idleness §7 uses. Needs a switch (an env var or a config key) and
   a decision on its default.
3. **ABORT during `StartingUp`** — row 2 admits only READ and SHUTDOWN. Abort would let a client
   stop a startup without shutting down; nothing needs it yet.

## 13. Verification

- `admit()` against every row of §2, with the claim held and not held, in both opmodes and both
  scopes — a table-driven test, no FastAPI.
- First match wins: `ShuttingDown` with `opstate == RUNNING` and busy → row 1 (READ only).
- `why_busy`: a component activity alone (mount `Slewing`, no unit flag) is busy; PHD2 guiding
  with `UnitActivities.Guiding` down is busy via the cache; a shut-down idle unit has
  `why_busy == {}` and `is_idle`.
- The race: two OPERATION requests released together — exactly one admitted, the other refused
  with `in progress`; READ and ABORT admitted throughout.
- The handover: after a claiming handler returns, its flag is up (per endpoint, §9.1); after an
  ABORT, the flag stays up until the worker has exited (§9.3).
- Startup mid-shutdown is refused (the §1 gap); shutdown mid-startup is admitted and safe.
- Production: a component PUT is refused, a component GET admitted; development: both admitted.
- Every unit-scope route carries an explicit class, and an unclassified one gates as OPERATION.
- Refusals are 200 + `errors`, and each is logged once.
