# Unit idleness: how long has a unit had nothing to do

> Two monotonic marks on `Unit` (`active_since`, `idle_since`), maintained by a single
> evaluation in `Unit.ontimer`, and published in `FullUnitStatus` as `idle_seconds`,
> `active_seconds` and `why_not_idle`. The consumer is an inactivity shutdown: MAST_control
> decides normally, and the unit's own timer is a failsafe for when control is unreachable.
>
> **Status: plan only — not implemented; all design questions closed.** Needs no new activity
> flag, no change to `Activities` or `Component`, and no override of `start_activity` /
> `end_activity` — three mechanisms that were each designed and then rejected (§5). Code
> baseline: MAST_common `master` @ `2a9ff59`, MAST_unit `main` @ `dcefc18`, 2026-10-06.
> Branch `feat/active-idle-since` exists in MAST_unit, empty.

## 1. Why

Nothing today answers "how long has this unit had nothing to do". The information is almost
all present — `FullUnitStatus` nests every component's `activities_verbal`, and the unit's own
flags are on the envelope — but it is a snapshot with no history, so no consumer can act on
duration.

Two consumers want that duration, and both want to *power something down* on the strength of
it:

- **MAST_control** may shut down a unit, or a group, idle for longer than some period.
- **The unit's own timer** may shut itself down, as a failsafe.

That is what makes this more than a status nicety. The field is an input to turning a telescope
off, so the cost of a wrong answer is asymmetric: reading "idle" when the unit is working loses
science, while reading "busy" when it is idle only wastes power.

## 2. What "idle" means

```
idle  ⇔  not was_shut_down
      ∧  Unit.activities == 0
      ∧  no component reports an activity
      ∧  not guider.is_guiding
```

Each term earns its place:

- **`not was_shut_down`.** A shut-down unit is idle by definition, so without this term the
  predicate stays true for ever and an inactivity shutdown re-fires on every poll.
  `do_shutdown` already sets `_was_shut_down` and `ComponentStatus` already publishes it.
- **`Unit.activities == 0`** covers the unit's own work: `Acquiring`, `Positioning`
  (`acquirer.py`), `Autofocusing`, `AutofocusingPWI4`, `AutofocusAnalysis`
  (`autofocusing.py`), `Solving`, `Correcting` (`solving.py`), `FluxMetering`
  (`flux_metering/session.py`), `Calibrating` (`imaging/stage_geometry.py`), `Dancing`,
  `Exposing`, `StartingUp`, `ShuttingDown` (`unit.py`).
- **Component activities** cover what the unit level cannot see. Every `UnitActivities` flag
  comes from unit-level code, so a direct `PUT /mount/goto_ra_dec_j2000`, `PUT /imager/expose`,
  or a focuser, stage or covers move sets **no unit flag at all**. Without this term an
  engineering night — an operator driving components directly — reads as idle throughout.
- **`guider.is_guiding`** is the science interlock. See §4.

A component that cannot be read is **not** a term here. That is what `operational` and
`why_not_operational` are for, and routing it there keeps `why_not_idle` purely about activity.

## 3. Tracking is not an activity, and a tracking unit with no claim on it is idle

`Mount.is_tracking` ([mount.py:446](../../unit/src/mount.py#L446)) is a **state**: it has no
start, no end and no duration. Activities in this codebase carry `Timing` and a start/end
lifecycle, so forcing tracking into that shape would be modelling it wrongly.

More than that, it should not appear in the predicate at all. Tracking with nothing claiming
the unit is **residue, not work** — the mount was left tracking after whatever was using it
finished. Treating it as "busy" would mean a unit could never become shutdown-eligible until
someone remembered to stop tracking.

This is safe because **shutdown stops tracking unconditionally**, and by a route that does not
depend on getting anything subtle right:

- `do_shutdown` calls `comp.shutdown()` for every component (`unit.py:308`).
- `Mount.shutdown()` disconnects, and its docstring is explicit: *"**No park.** MAST has no
  defined park position: disconnecting disables both axes…"* Disabled axes cannot track.

Note it is **not** `Unit.abort()` that does this, and it is just as well. `do_shutdown` does not
call `abort` at all, and abort deliberately *may leave tracking running*: it reuses the
acquisition/guiding stop verb, *"notably the `was_tracking_before_guiding` rule, which decides
whether tracking is left running and is easy to get wrong"* (`unit.py:592`). Shutdown-by-
disconnect is the blunt instrument this argument needs; abort is not.

## 4. `UnitActivities.Guiding` is the science interlock — no new flag

The unit's "my light is being used" signal has to cover the case local introspection cannot
see: the spectrograph integrating on this unit's fibre, which the unit knows nothing about.

A new `UnitActivities.DoingScience`, set on assignment and released by control, was designed
for this and **rejected in favour of the `Guiding` flag that already exists** — started at
[phd2.py:1487](../../unit/src/phd2/phd2.py#L1487) and
[solving_guider.py:56](../../unit/src/solving_guider.py#L56), ended at `solving_guider.py:95`,
and stopped by `Unit.abort()` at `unit.py:622` whenever `Acquiring` or `Guiding` is active.

Four reasons:

1. **Guiding is coextensive with the exposure.** If guiding stops mid-integration the target
   drifts off the fibre and the spectrograph's exposure is ruined anyway. "Guiding" and "my
   light is in use" are the same interval in practice. *(Premise: no unguided science is
   foreseen. If that changes, this section is the first thing to revisit.)*
2. **No enum change.** `UnitActivities` is append-only and shared with MAST_control and
   MAST_gui, where a renumbering silently changes what a numeric comparison means. It also
   avoids a live collision: on `master` the enum ends at `FluxMetering = 16384`, and
   `StabilityCampaigning = 32768` exists on the unmerged mount-stability branch — a
   `DoingScience` landing first would take 32768 and force that branch to move. The same
   collision was already resolved once, on 2026-10-01.
3. **No lease machinery.** `DoingScience` needed renewal, an expiry, a rule for who may end it
   and a timeout constant. All of it existed only to survive control dying or a unit
   restarting.
4. **It is backed by observable external state, so the restart hole closes by itself.**
   `DoingScience` was pure intent: in memory, lost on restart, hence the lease. PHD2 is a
   separate process that survives a unit restart, and `Guider.is_guiding`
   ([guiding.py:249](../../unit/src/guiding.py#L249)) delegates to the backend, which answers
   truthfully per backend: `PHD2Connector.is_guiding` reads PHD2's live `app_state`
   ([phd2.py:1390](../../unit/src/phd2/phd2.py#L1390)), while `SolvingGuider.is_guiding`
   returns the flag (`solving_guider.py:102`), which for an in-process guider *is* the truth.

**So the predicate asks `guider.is_guiding`, not `is_active(UnitActivities.Guiding)`.** For
PHD2 the flag is a *mirror* of `app_state`, not the source, and the two can diverge:

| | consequence |
|---|---|
| flag true, PHD2 not guiding | unit looks busy; shutdown never fires — **fail-safe** |
| flag false, PHD2 guiding | unit looks idle **while guiding** — the dangerous one |

Asking the interface lets the live state win, and gets restart recovery for nothing. This is a
known-live problem area: MAST_unit#250 is *"phd2: stop answering from remembered state"* and
#275 is PHD2 answering after the guide camera is unpowered.

## 5. One evaluation point: `Unit.ontimer`

The marks are maintained by the existing 2 s `RepeatTimer`
([unit.py:234](../../unit/src/unit.py#L234)), which evaluates the whole predicate each tick and
stamps a mark when it flips. 2 s granularity is irrelevant for a quantity thresholded at tens
of minutes, and `ontimer` is already where derived state and flag-ending live.

Three other mechanisms were designed and rejected:

**(a) Overriding `Unit.start_activity` / `end_activity`.** This was the original idea and it
works — `Component(ABC, Activities)`, `Unit(Component)`, nothing in `Activities` calls
`self.end_activity`, so a `super()` call is clean. It was rejected because those overrides see
only *unit-level* transitions, so they cannot maintain a predicate that includes components.
Concretely: the mount slews on a direct call, no unit flag changes, neither override fires, and
the status publishes `idle_seconds: 1840` beside `why_not_idle: {"mount": ["Slewing"]}` — two
fields contradicting each other once per transition.

An asymmetric variant is sound — `start_activity` may stamp *active* (a running unit activity
proves not-idle locally), while `end_activity` must do nothing (unit flags at zero prove
nothing about components) — but it buys only ~2 s of latency and adds a second writer to the
same two fields from arbitrary threads. Not worth a lock and a precedence rule.

**(b) Components pushing into the unit.** `Mount`, `Covers` and `Stage` all take
`unit: "Unit"`, so a component could bump the unit's marks from its own `start_activity` /
`end_activity`. Rejected because:

- it still cannot see tracking, so a poll would be needed anyway — two mechanisms where one
  suffices;
- the hook has nowhere correct to live. `Component.__init__(self, activities_type)` knows
  nothing of a unit, and MAST_spec's components subclass the same ABC with no unit at all, so a
  hook there must be optional and duck-typed, i.e. a silent no-op when unwired. Not
  hypothetical even inside the unit: `Focuser.__init__(self, unit=None)` already defaults to
  none;
- "is anything *else* still busy" is a fan-out read regardless — the poll, run per transition
  instead of per tick, and so more often;
- these fire from PHD2 callbacks, timers and acquisition threads, so every hook would need a
  lock and would risk deadlock if invoked while a component holds its own `Activities.lock`.

**(c) Deriving everything at `status()` time, with no marks.** Rejected: a duration needs a
remembered transition instant, and `status()` is called at the caller's whim.

## 6. What is published

Three optional fields on `FullUnitStatus`
([statuses.py:770](../../common/models/statuses.py#L770)) — and nothing else in MAST_common:

```python
idle_seconds:   float | None = None
active_seconds: float | None = None
why_not_idle:   dict[str, list[str]] | None = None
```

**Durations, not the monotonic marks.** `time.monotonic()` is seconds since an arbitrary epoch,
meaningful only inside the process and reset by a restart; a consumer receiving
`active_since: 183472.6` can do nothing with it. This follows the rule `Timing` already states:
*"The timestamps stay for reporting; only the elapsed measurement needs a clock that cannot
move."* Monotonic internally for the arithmetic, durations on the wire.

**`why_not_idle` is a dict keyed on `"unit"`, `"mount"`, … and valued from `activities_verbal`.**
A flat list of `"mount: Slewing"` strings was considered, to match `why_not_operational`'s
shape, and the dict is better here: the names collide badly across enums — `StartingUp` appears
in 10, `ShuttingDown` in 10, `Exposing` in 8, `Aborting` in 8 — so a structural key solves by
construction what string qualification would solve by convention. The same evaluation produces
the dict and the marks, so the two cannot disagree.

`why_not_idle["unit"]` duplicates `FullUnitStatus.activities_verbal`, inherited from
`ComponentStatus`. That is deliberate: it makes the dict self-contained so no consumer has to
special-case the unit's own entry alongside its components'.

**Never union the `activities` integers.** The enums are separate and their bit values overlap,
so an integer OR across components is meaningless. The verbal form is the only sound union.

**Build it from values `status()` has already collected**, not by re-reading components.
`status()` isolates each component read precisely so one sick component cannot cost the whole
response — a crossed PHD2 reply took the unit's entire status down on 2026-09-08 (MAST_unit#222).
A union that re-polled would reintroduce that single point of failure.

### `None` means unknown, and that is load-bearing

All three default to `None`, and `why_not_idle` **must not** default to `{}`. The status models
set no `extra=`, so pydantic ignores unknown keys, which makes the two skew directions behave
differently:

| | effect | a caller's `hasattr` guard |
|---|---|---|
| old control, new unit | extra keys dropped; attribute absent | **works** |
| new control, old unit | control's model has the fields, so **defaults apply** | **inert** |

In the second case a `{}` default would be read as *"nothing is keeping this unit busy"* —
our encoding for idle — so a freshly-deployed control talking to a not-yet-updated unit could
shut down a unit that is actively guiding. With `None`:

- `None` → **unknown**: an old unit, or control's fabricated `BasicUnitStatus`
- `{}` → known, and idle
- non-empty → known, and busy

A forgotten guard then yields "unknown" rather than "idle": defensive by construction rather
than by convention, which matters because the guards are caller discipline spread across
repos. Same reasoning as `ConfigHealth` reporting degraded rather than letting a stale boot
cache look normal.

**`BasicUnitStatus` gets nothing.** It is control's fabrication on behalf of a unit that will
not answer, so it never carries these fields — and a unit that is not answering is not
idle-eligible on inactivity grounds. Whatever is done about a silent unit is a different
decision, and a rule written as `if idle_seconds > threshold` against a missing value is one
careless line from treating silence as eternal idleness.

## 6a. Why nothing else goes to MAST_common

| | why not |
|---|---|
| `activities.py` | no new enum member — §4 is what buys that |
| `ComponentStatus` | unit-scoped by decision, so MAST_spec's components stay untouched |
| `BasicUnitStatus` | see above |
| a new type alias | `dict[str, list[str]]` is plain. **Not** `ActivitiesVerbal`, which is `list[str] \| None`, and these values are non-empty by construction |
| config models | the failsafe threshold is control-side and out of scope (§8) |

## 7. Shutdown authority

Two actors can act on this, so they need a hierarchy rather than a race.

**MAST_control decides normally.** It is the only thing that can see the plan queue and the
spectrograph, and it is the actor with the broader picture.

**The unit's own timer is a failsafe**, with a **much longer** threshold, for when control is
unreachable. That is not hypothetical: control was down for days at the start of October 2026,
during which the units kept observing. If the two thresholds were comparable they would race
and double-shutdown; a far longer unit threshold means it acts only once control has clearly
stopped managing it.

**Arm it observe-only first.** Log the decision it *would* have made for several nights before
it can power anything down — the same pilot-then-commit shape the mount-stability campaign
used. An auto-shutdown that fires with no recorded reason is the same class of mistake as
MAST_unit#281, where a 100 % campaign failure rate looked perfectly healthy.

## 8. Deliberately out of scope

- **The shutdown decision itself**, on either side. This plan delivers the measurement.
- **The failsafe threshold** — a number, and whether it is per-unit config.
- **Per-component idleness.** If it is ever wanted, the marks move to `Component` and the
  fields to `ComponentStatus`; nothing here forecloses that.
- **Unguided science.** Premised absent (§4). Its arrival reopens the interlock question.

## 9. Verification

- `ontimer` stamps `active_since` and clears `idle_since` when the predicate flips to busy, and
  the reverse — exercised with a fake clock rather than by waiting.
- **Overlapping activities**: `Acquiring` then `Solving`, ending `Acquiring` first, must leave
  the unit active with `active_since` unchanged; only the last end makes it idle. This is the
  normal acquisition shape, not an edge case.
- **A component activity alone** — mount slewing with no unit flag — makes the unit non-idle
  and appears in `why_not_idle`. This is the case the rejected overrides got wrong, so it is
  the test that pins the choice of mechanism.
- **Guiding via the interface**: a backend reporting `is_guiding` true with no
  `UnitActivities.Guiding` flag set must still read as busy.
- `was_shut_down` makes the unit not idle-eligible, so an inactivity shutdown cannot re-fire.
- `idle_seconds` and `why_not_idle` never disagree: whenever the dict is non-empty,
  `idle_seconds` is `None`.
- A sick component does not break the union, and does not silently read as idle — it shows in
  `operational` / `why_not_operational`.

## 10. Sequencing

1. **MAST_common** — the three fields on `FullUnitStatus`, with the `None`-means-unknown
   semantics in their docstring. Three lines plus a comment. Merge first: the unit's CI
   resolves MAST_common by matching branch name, else `master`, so a same-named branch keeps
   the unit green at every step.
2. **MAST_unit** — the two marks on `Unit`, the `ontimer` evaluation, `why_not_idle`, the
   `status()` wiring and the tests. Branch `feat/active-idle-since`.
3. Separately, later: the control-side decision, and the unit failsafe behind observe-only
   logging.
