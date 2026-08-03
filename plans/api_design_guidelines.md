# MAST — API Design Guidelines

**Scope:** MAST backend hosts — unit, spectrograph, control.
**Author:** Arie Blumenzweig, Weizmann Institute of Science
**Date:** 3 August 2026

**Status:** Sections 2, 3 and 5 are in force. **Section 4 is a proposal and has not been
decided.** Section 6 lists what remains open. Undecided material is carried here so there is a
single place to look — not because it has been agreed.

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

---

## 4. HTTP return codes — proposed convention

> **Proposal — not decided.** Nothing below is in force. See open question 1.

The `CanonicalResponse` envelope carries `errors` independently of the HTTP status layer, so a
decision is required on whether the two should agree.

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
