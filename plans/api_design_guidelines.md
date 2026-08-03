# MAST — API Design Guidelines

**Scope:** MAST backend hosts — unit, spectrograph, control.
**Author:** Arie Blumenzweig, Weizmann Institute of Science
**Date:** 3 August 2026

**Status:** Sections 2, 3 and 5 are in force. **Section 4 is a proposal and has not been
decided.** Section 6 lists what remains open. Undecided material is carried here so there is a
single place to look — not because it has been agreed.

**Tracking (added 2026-08-03).** This document states the intended conventions; it is not a
description of the current tree. On the **unit** — the pilot host — the work of getting there is
tracked by
[MAST_unit#42 MAST unit endpoint contract (tracking)](https://github.com/The-MAST-project/MAST_unit.2024-12-12/issues/42)
and its sub-issues, and each section below carries a *Tracking (unit)* line naming the issue that
owns it. Sibling epics for **control** and **spec** are deliberately held until the unit contract
is ratified, so the links here are unit-only by design. Where the unit does not yet comply, the
issue says so rather than this document.

---

## 1. Purpose

This document records the API conventions in force across MAST backend hosts, proposes a
convention for HTTP return codes, and states the abort semantics for long-running operations.

---

## 2. Existing conventions

These are already applied consistently across MAST hosts.

**Uniform verbs per host.** Every backend exposes `status` and
`execute_assignment(assignment: <Type>Assignment)`, plus host-specific operations
(`acquisition_and_guiding(coordinates)`, `autofocus` on units).

**Pydantic models throughout.** Endpoint parameters and return values are typed models rather
than loose dictionaries — the same models used for MongoDB serialisation.

**CanonicalResponse envelope.** Every response has the form `{api_version, value, errors}`
(`common/canonical.py`), so callers have a single unwrapping path regardless of endpoint.

**Global authentication.** Applied as a FastAPI dependency rather than per-route decoration,
with a public router carved out for `/health` and documentation endpoints.

**Proxy transparency.** Endpoints must behave identically whether addressed directly or through
the nginx reverse proxy.

*Tracking (unit):* uniform verbs are the CONTRACT tier of #42, with the names promoted to a shared
cross-repo enum in
[#35 Endpoint names are stringly-typed across unit↔control](https://github.com/The-MAST-project/MAST_unit.2024-12-12/issues/35).
The CanonicalResponse envelope is invariant 4 of #42, remediated in
[#47 Uniform response envelope remediation](https://github.com/The-MAST-project/MAST_unit.2024-12-12/issues/47)
(PR stack #68 → #69 → #70, plus #73 and #74); it is not yet uniform on the unit, which is what
#47 exists to fix. Global authentication is
[#45 API authentication / authorization layer](https://github.com/The-MAST-project/MAST_unit.2024-12-12/issues/45),
parked. Enforcement of all of the above lives in
[#52 Contract + regression pytest suite](https://github.com/The-MAST-project/MAST_unit.2024-12-12/issues/52).

---

## 3. Endpoint behaviour guidelines

1. Endpoints perform all checks that may result in rejecting the request, and return canonical
   errors accordingly.
2. Endpoints are preferably asynchronous.
3. Long-running operations are performed in threads, by functions named `do_<operation>`.
   Dispatch is via `asyncio.to_thread` rather than a bare `threading.Thread`: the awaitable it
   returns captures the function's exception instead of losing it to stderr, and gives the host
   a single registry of what is in flight.
4. Endpoints — whether immediate or long-duration — return `CanonicalResponse_ok`, in the
   long-duration case after initiating the thread.
5. Endpoints depending on external services return canonical errors as soon as they detect that
   the service is unreachable or unresponsive.

*Tracking (unit), per guideline:*

1. Rejection checks in the endpoint — invariant 4 of #42 (#47), with the handler kept thin by
   [#34 Refactor: thin the API layer](https://github.com/The-MAST-project/MAST_unit.2024-12-12/issues/34)
   (invariant 6).
2. & 3. Async endpoints and `asyncio.to_thread` dispatch —
   [#81 Dispatch long-running operations via asyncio.to_thread; async endpoint handlers](https://github.com/The-MAST-project/MAST_unit.2024-12-12/issues/81).
   Every handler is a synchronous `def` today and all nine dispatch sites use a bare
   `threading.Thread`, so the two halves are one change; it is sequenced after the #47/#37
   integration branch (#77) merges, because it rewrites the same handler signatures. The
   `do_<operation>` **naming** in guideline 3 is already universal in the unit and is now
   **invariant 9** of #42 — formalised so the renames in flight
   ([#41 Endpoint naming](https://github.com/The-MAST-project/MAST_unit.2024-12-12/issues/41)'s
   `acquire_images`, #34's extracted spiral method) land against a stated rule, with a static
   check in #52.
4. Long-duration endpoints returning `CanonicalResponse_ok` after starting the thread — already
   the target contract in
   [#43 Uniform completion-detection contract](https://github.com/The-MAST-project/MAST_unit.2024-12-12/issues/43)
   (invariant 3), item 1: fire-and-flag. See also open question 2 below.
5. Prompt canonical errors on a dead dependency — now **invariant 8** of #42, a property of every
   route rather than a per-site fix. Enforced in #52 by a per-route external-dependency
   declaration plus a refusing stand-in for PWI4 / PHD2 in the existing test harness.
   [#15 Detect and handle PWI4 crashes during acquisition](https://github.com/The-MAST-project/MAST_unit.2024-12-12/issues/15)
   is an instance of it, not its home.

---

## 4. HTTP return codes — proposed convention

> **Proposal — not decided.** Nothing below is in force. See open question 1.

The `CanonicalResponse` envelope carries `errors` independently of the HTTP status layer, so a
decision is required on whether the two should agree.

*Tracking (unit): open for deliberation, deliberately **not** filed as an issue.* The audit input
is recorded under "Needs a decision — HTTP return codes" on #42. Three findings from it bear on the
proposal as written:

- **A prerequisite the mapping needs.** `CanonicalResponse.errors` is `list[str] | None`
  (`common/canonical.py`) — free-text strings with no failure class, across ~70 construction sites
  in the unit. Nothing can be lifted to a `4xx`/`5xx` by rule today, only by matching on prose. So
  the task is less "pick a mapping" than "give the envelope a machine-readable failure class, then
  derive the code from the class" — a `MAST_common` change, and the step that makes the convention
  enforceable rather than advisory.
- **The population does sort onto §4.2's rows,** which is the encouraging part: parameter
  validation, busy/wrong-state, dependency-down and unhandled-exception sites are all clearly
  separable in the existing code.
- **Two cases §4.2 has no row for.** *Relayed errors* — several sites stringify a sub-call's
  envelope into a parent error string, and `common/api.py` flattens a remote host's exception into
  local strings; whether a relayed downstream failure is this host's `503` or a `502` is
  unanswered, ~10 sites depend on it, and it is the row most likely to drive control's retry policy
  wrong. *Off-response-path `errors`* — the unit's autofocus analysis record persists an `errors`
  list that never reaches HTTP, so the rule should be scoped to the response envelope explicitly.

*Sequencing:* this is kept out of the #47 stack on purpose. #47 keeps `/unit/status` byte-for-byte
on the wire, which is precisely why it needs no cross-repo lockstep; status codes would create that
lockstep with control and gui, neither of which branches on HTTP status today. The migration is
additive when it happens — `errors` keeps its shape, with the class alongside.

### 4.1 The choice

**Option A — envelope only.** Every response is HTTP 200; success and failure are distinguished
solely by whether `errors` is empty. Simplest for in-house Python clients, which never branch on
HTTP status. The cost is observability: nginx access logs and HTTP-level metrics show uniform
200s while hosts are rejecting every request.

**Option B — status code plus envelope (recommended).** The failure class is mapped to an HTTP
status code *and* fully described in `errors`. The status code serves nginx, monitoring, and
retry logic; the envelope serves the operator and carries the detailed error list. Each addresses
a different reader.

### 4.2 Proposed mapping

| Condition | Status | Notes |
|---|---|---|
| Success, including accepted long-running operations | `200` | Consider `202 Accepted` for operations that only start a thread |
| Parameter validation failure | `422` | Matches FastAPI's own Pydantic validation behaviour; hand-written checks should align rather than conflict |
| Resource busy or in wrong state (mount already claimed, detector not yet cold) | `409` | The request is well-formed but cannot be served now |
| Required external service unreachable or unresponsive (PWI4, PHD2) | `503` | Signals transient failure — retry may succeed |
| Unhandled internal error | `500` | Should also appear in `errors` and in the log |

### 4.3 Governing rule

**4xx means the request was wrong — do not retry. 5xx means the request may succeed later —
retry is reasonable.** Validation errors are 4xx; dead-dependency errors are 5xx. Held to
consistently, this lets clients implement retry policy from the status code alone, without
parsing `errors`.

---

## 5. Abort semantics

### 5.1 Meaning

**Abort stops the operation immediately, in place.** No attempt is made to return the hardware to
a safe state or to any prior state — a slew halts where it is, a stage stops mid-travel. Abort is
therefore fast, uniformly available, and cannot itself fail partway through a recovery sequence.

*Tracking (unit):* the whole of §5 is
[#80 Abort holds an Aborting activity until the device is confirmed at rest](https://github.com/The-MAST-project/MAST_unit.2024-12-12/issues/80),
a sibling of invariant 3 under #42. The unit currently does the opposite of §5.2: every component
ends the operation's activity at the moment the stop is issued (`mount.py`, `stage.py`,
`focuser.py`), so `/status` reports idle while the device decelerates; `Aborting` exists in no unit
component enum except a never-set `StageActivities.Aborting` (which is why the dead-flag lint,
[#44 Static check: activity-flag start/end balance](https://github.com/The-MAST-project/MAST_unit.2024-12-12/issues/44),
should flag it); and `Unit.abort()` busy-waits on autofocus with no bound, the failure §5.2's last
paragraph forbids. The at-rest predicates §5.2 names all already exist, and `common/stopping.py`
holds an unused `StoppingMonitor` that is exactly the confirmed-at-rest sampler — so this is wiring
rather than new machinery.

§5.1's second paragraph is now **invariant 7** of #42 in its own right. It is the precondition that
makes stop-in-place abort sound: #80 is not correct without it, so the two are tracked together and
tested together in #52 as an abort-then-operate pair.

**Bringing resources to a usable state is the responsibility of the next operation, not of
abort.** Every endpoint drives the resources it needs into their required state before performing
its task, and therefore tolerates finding them wherever an earlier abort left them. No operation
may assume it inherits a known resting position.

### 5.2 Mechanism

Components are timer-driven: each holds a `RepeatTimer` (`common/utils.py`) whose `ontimer()`
observes hardware state and ends activities when it sees them complete. Abort follows that same
path rather than introducing a second one.

**Abort is issued as a device-level stop.** Most hardware exposes a stop-what-you-are-doing
interface — `pw.focuser_stop()`, `pw.mount_stop()`, `abort_exposure()` — and abort uses it rather
than attempting to interrupt the code that started the operation. Python cannot interrupt a
running thread, so no other mechanism is available.

> *Note (2026-08-03):* `abort_exposure()` here is the **driver-level** call, not the
> `imager/abort_exposure` route. #42 slates that endpoint for removal as redundant with `/abort`
> (no readout) plus `/stop_exposure` (readout); confirmed with Arie that the removal does not
> conflict with this section.

**A component holds an `Aborting` activity from the stop command until the device is confirmed at
rest.** `abort()` ends the operation's own activity, starts `Aborting`, and issues the stop;
`ontimer()` ends `Aborting` once the hardware reports stationary — `is_stationary` for the
focuser, `is_slewing` for the mount. Ending the operation's activity at the moment the stop is
issued reports the component idle while it is still decelerating, and the next endpoint then
commands a device still in motion.

**The activity flag is the cancellation token.** Procedures spanning several components poll
`is_active(<Component>Activities.Aborting)` between steps. No separate `threading.Event` is
required, and the existing `Activities` machinery (`common/activities.py`) supplies the abort's
timing and UI notification for free.

**Waits for an abort to complete are bounded.** A caller waiting for `Aborting` to clear does so
with a timeout. A stop command that never takes effect must surface as a component stuck in
`Aborting`, visible in `status`, rather than as a hung abort endpoint.

### 5.3 Operations dispatched to threads

`asyncio.to_thread` supplies no cancellation of its own. Cancelling the awaiting task raises
`CancelledError` on the async side while the worker thread runs on to completion. It captures the
function's exception and identifies what is in flight; it does not stop the work. Aborting such
an operation remains the device stop plus the `Aborting` flag, with the thread observing that
flag at its next checkpoint and unwinding.

---

## 6. Open questions

1. Do canonical errors carry non-200 HTTP status codes? (Section 4)
2. How does the outcome of a long-running operation reach the caller — operation handle or
   `status`? (Section 3, guideline 4)
3. Should long-duration endpoints return `202` rather than `200` on acceptance?
4. What is the recovery procedure for hardware resources left claimed by a host restart?

*Status of each, unit side (2026-08-03):*

1. **Open, being deliberated.** Option B is the direction, but the prerequisite is a failure class
   on the envelope — see the tracking note in §4. Not filed as an issue on purpose; the audit input
   is on #42.
2. **Already answered by #43** rather than open: fire-and-flag, with completion read from a
   machine-readable `x-completion` declared per route (same mechanism as the tier tags in
   [#39 Tag endpoints by contract tier in the OpenAPI/Swagger schema](https://github.com/The-MAST-project/MAST_unit.2024-12-12/issues/39)),
   plus one shared bounded `await_activity_clear(flag, deadline)` helper in `MAST_common`. No
   operation handle. That helper now serves abort as well (§5.2), so its deadline semantics are
   specified with both callers in mind.
3. **Rides with question 1, and may be moot.** If #43's target item 5 gives `CanonicalResponse` an
   explicit accepted-vs-done distinction, a `202` duplicates it at the status layer. Worth deciding
   after that, not alongside question 1.
4. **Untracked before now; parked under #42's future directions.** Distinct from
   [#50 Unit driver should assert PDU power-loss recovery mode on connect](https://github.com/The-MAST-project/MAST_unit.2024-12-12/issues/50):
   that is about the power state on the way up, this is about ownership left dangling by a host that
   died holding a mount, a stage or a camera. Needs a decision from Arie before it can be scoped.

---

## Appendix — unit-side tracking map (2026-08-03)

| This document | Unit issue |
|---|---|
| §2 uniform verbs per host | #42 CONTRACT tier, #35 (shared name enum) |
| §2 CanonicalResponse envelope | #42 invariant 4 → #47 (#68/#69/#70, #73, #74) |
| §2 global authentication | #45 (parked) |
| §3 g1 rejection checks in the endpoint | #42 invariant 4 → #47; thin handler #34 (invariant 6) |
| §3 g2 async endpoints | #81 (after #77) |
| §3 g3 `asyncio.to_thread` dispatch | #81 (after #77) |
| §3 g3 `do_<operation>` naming | #42 **invariant 9** — already compliant, formalised; check in #52 |
| §3 g4 `_Ok` after starting the thread | #43 target item 1 |
| §3 g5 prompt error on a dead dependency | #42 **invariant 8**; enforced in #52; #15 is an instance |
| §4 HTTP return codes | open for deliberation; audit input on #42 |
| §5.1 no inherited resting position | #42 **invariant 7** |
| §5.2 / §5.3 abort mechanism | #80; dead `Aborting` flag in #44; bounded waits share #43's helper |
| §6 Q1 / Q3 | open — see §4 |
| §6 Q2 | answered by #43 |
| §6 Q4 | parked under #42 future directions |

Enforcement of every row above that is a rule rather than a one-off lands in #52, which is
manifest-driven and xfail-keyed per sub-issue, so the suite records the gaps until each is closed.
