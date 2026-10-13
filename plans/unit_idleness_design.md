# Unit idleness, and shutting down an idle unit

> The unit measures how long it has had nothing to do and, if configured, shuts itself down
> after `minutes_to_autoshutdown_on_idle`. Busy-ness is one predicate, `Unit.why_busy`; the idle
> clock is two marks kept in `Unit.ontimer`; both are published in `FullUnitStatus`.
>
> **Status: plan only — not implemented; all design questions closed (rev. 2026-10-13).**
> Code baseline: MAST_common `master` @ `20c1548`, MAST_unit `main` @ `4f403e8`.
>
> **Revisions.** 2026-10-06: first version (the unit as a failsafe behind MAST_control).
> 2026-10-12: `why_not_idle` renamed `why_busy`; `was_shut_down` out of the predicate; computed on
> demand (endpoint-admission). **2026-10-13 (this version):** the unit shuts *itself* down, on a
> per-unit configured idle time; `ImagerActivities.CoolingDown` does not count as busy; the
> clock runs only while `opstate == RUNNING`, in both opmodes, and restarts at `startup`. No
> longer tied to endpoint admission, which is decided separately.

## 1. Why

A unit left running with nothing to do keeps its covers open, its mount energised, its cooler
on. Nothing today notices: `FullUnitStatus` shows a snapshot of activities but no history, so no
consumer can act on *how long* nothing has happened.

The cost of a wrong answer is asymmetric. Reading "idle" while the unit works stops science;
reading "busy" while it is idle only wastes power and wear. Every choice below leans to "busy".

## 2. Configuration

```python
# UnitConfig (MAST_common config/unit.py), top-level beside opmode and power_down_on_shutdown
minutes_to_autoshutdown_on_idle: int = 0   # 0 disables; otherwise at least 5
```

- **0 disables auto-shutdown**, and is the default: a unit whose config holds no value never
  shuts itself down. This is also the off switch for an engineering session.
- **Otherwise at least 5**, enforced by a validator, so the config fails to load with a clear
  message rather than a unit shutting down a minute after its last command.
- **Read live** each `ontimer` tick, so an edit takes effect without a restart.

## 3. Busy: `why_busy`

```python
Unit.why_busy -> dict[str, list[str]]   # {"unit": ["Guiding"], "covers": ["Closing"]}; {} when idle
Unit.is_busy  -> bool                   # bool(why_busy)
Unit.is_idle  -> bool                   # not is_busy
```

One entry per owner with something active, valued from that owner's `activities_verbal`:

- **`"unit"`** — `UnitActivities`. Every one is unit-level work.
- **each component** — mount, covers, focuser, stage, imager (the wrapper's flags *and* its
  backend's). A direct `PUT /mount/goto_ra_dec_j2000` or a covers move raises no unit flag, so
  without this a development session would read as idle throughout.
- **guiding** — see §5.

**Excluded: `ImagerActivities.CoolingDown`.** The camera cooling to its set point after
`startup` (a minute or two) is the camera preparing, not the unit doing something for someone.
It keeps the imager non-operational (MAST_unit#320) but does not count as busy.

**Keyed by owner, never by unioned integers.** Flag names repeat across enums (`StartingUp` in
10, `ShuttingDown` in 10) and their bit values overlap, so only the verbal form under a
structural key is a sound union.

**Computed on demand** from in-memory flags (each owner's `Activities.lock`, no hardware
access). The one exception is guiding (§5).

`Unit.is_idle` overrides the inherited `Activities.is_idle` (the unit's own flags only); its
one existing caller gets the stricter answer.

## 4. Tracking is not busy

`Mount.is_tracking` is a state with no start or end. A mount left tracking after its work is
**residue, not work**, and counting it would keep a unit from ever going idle until someone
remembered to stop it. Safe to ignore, because **shutdown stops tracking unconditionally**:
`Mount.shutdown()` disconnects, which disables both axes. (`Unit.abort()`, which shutdown also
calls, may leave tracking running — the `was_tracking_before_guiding` rule — so the disconnect,
not the abort, is what this rests on.)

## 5. Guiding is busy: the science interlock

While guiding, this unit's light is being used: the spectrograph is integrating on its fibre,
something the unit cannot otherwise see. Guiding stops if anything ends the session, and
guiding is coextensive with the exposure (a drift off the fibre ruins it anyway), so "guiding"
and "in use" are the same interval. *(Premise: no unguided science. If that changes, revisit.)*

The predicate asks **`guider.is_guiding`** — for PHD2, its live `app_state` — **or**
`UnitActivities.Guiding`. Either true reads busy, so a divergence between the flag and PHD2
fails safe. `PHD2Connector.is_guiding` is a socket round trip, so `ontimer` caches it each tick
(`_guiding_live`) and `why_busy` reads the cache, at most 2 s old.

Since MAST_unit#308, a PHD2 that drops its connection reads disconnected, and `is_guiding` is
False — correctly: guiding really did stop.

## 6. The idle clock

Two monotonic marks on `Unit`, `idle_since` and `active_since`, maintained by **one evaluation
per `ontimer` tick** (2 s), which also caches guiding (§5) and runs the auto-shutdown (§7):

- **Only while `opstate == RUNNING`.** In `INITIALIZED` there is nothing to shut down; in
  `SHUTDOWN` it already is. Outside `RUNNING` both marks are cleared and nothing is published.
- **Restarted at `startup`.** `startup` is an explicit "I want this unit", so idleness counts
  from when startup finishes (the unit's `StartingUp` ends — a busy interval like any other).
- **Busy → idle** stamps `idle_since`; **idle → busy** stamps `active_since`. Overlapping
  activities (`Acquiring` then `Solving`, ending `Acquiring` first) leave the unit active until
  the last one ends.

Three alternatives were weighed and rejected in the 2026-10-06 version, and the reasons stand:
overriding `start_activity` / `end_activity` sees only unit-level transitions; components pushing
into the unit has no correct place to hook (MAST_spec's components share the ABC with no unit)
and still needs a poll; deriving durations at `status()` time has no remembered transition.

## 7. Auto-shutdown

On a tick where the unit is `RUNNING`, idle, `minutes_to_autoshutdown_on_idle > 0`, and
`idle_seconds >= minutes * 60`:

- the unit calls its own `shutdown()` — exactly what `PUT /shutdown` does: abort (nothing to
  abort, it is idle), close the covers, disconnect, cooler off, `opstate = SHUTDOWN`;
- one INFO line says why: `auto-shutdown: idle for 30 min (minutes_to_autoshutdown_on_idle=30)`;
- it cannot fire twice: the opstate is no longer `RUNNING`, so the clock is cleared.

**`shutdown`, not `powerdown`.** Power stays the controller's decision (opmode-design §4a).

**Both opmodes.** A development session that should not end on its own sets the unit's value
to 0.

MAST_control may still decide to shut units down on its own criteria (plans, weather); that is
its business and goes through the same `PUT /shutdown`. The unit's own rule needs no controller.

## 8. What is published

Three optional fields on `FullUnitStatus` (MAST_common `models/statuses.py`), beside `opmode` /
`opstate`:

```python
idle_seconds:   float | None = None
active_seconds: float | None = None
why_busy:       dict[str, list[str]] | None = None
```

**Durations, not marks** — a monotonic timestamp means nothing outside the process.

### `None` means unknown, and that is load-bearing

`why_busy` must **not** default to `{}`. The status models ignore unknown keys, so:

| | effect |
|---|---|
| old consumer, new unit | the extra keys are dropped |
| new consumer, old unit | the consumer's model has the fields, so **defaults apply** |

With a `{}` default, a new controller reading an old unit would see "nothing keeps this unit
busy" — our encoding for idle. With `None`: `None` unknown (an old unit, or control's fabricated
`BasicUnitStatus`), `{}` known and idle, non-empty known and busy.

`idle_seconds` is `None` whenever `why_busy` is non-empty, and both are `None` outside `RUNNING`.

## 9. Out of scope

- **Endpoint admission** (mast-claude-config#36), which will reuse `why_busy` but decides its
  own exclusions separately.
- **Per-component idleness.**
- **Unguided science** (§5's premise).

## 10. Work items

1. **MAST_common** — `UnitConfig.minutes_to_autoshutdown_on_idle` with its validator and GUI
   metadata; the three `FullUnitStatus` fields, with the `None` semantics in their docstring.
2. **MAST_unit**, same branch name — `why_busy` / `is_busy` / `is_idle`; `_guiding_live`; the
   marks and the auto-shutdown in `ontimer`; the clock reset at `startup`; `status()` wiring.
   Both merge together.

## 11. Verification

- `why_busy`: a component activity alone is busy; `ImagerActivities.CoolingDown` alone is
  idle; PHD2 guiding with the unit's flag down is busy (via the cache).
- The clock: busy→idle and idle→busy stamp the marks (fake clock); overlapping activities stay
  active until the last ends; nothing runs outside `RUNNING`; `startup` restarts it.
- Auto-shutdown: fires at the configured minutes and not before; logs once; does not fire at 0;
  does not fire twice; a config change applies on the next tick.
- Config: 0 and 5 load; 1–4 are refused.
- Status: `idle_seconds` is `None` while busy; all three `None` outside `RUNNING`.
- On mast00: with a value of 5, a started unit left alone shuts down after 5 minutes.
