# MAST_spec: what is left after the lint burn-down

*Continuation plan for `MAST_spec` after 2026-09-05, when the repo went from 119 ruff
findings to zero, gained its first CI, and had three acquisition-path bugs fixed. Every
claim here was checked against a `common` clone in sync with origin -- 0 behind, 0 ahead --
rather than inferred. Nothing was measured by running the service, because the service
cannot be run off the telescope (§3).*

**Status: current as of 2026-09-06, `master` at `03f362f`.** Seven of eight items are done.
**Only §2.5 is left, and it is now the whole of the risk**: three days of change to the HTTP
surface, the abort path and the acquisition path sit on `master` with nothing having run any
of it. The blocker that makes that unavoidable is **MAST_spec#77**.

---

## 1. Where it stands

| | |
|---|---|
| `ruff check` | **0**, from 119 |
| `ruff format --check` | passing |
| CI | lint only, blocking, `ubuntu-latest`, ruff pinned at 0.16.0 |
| Branch protection | on: requires `lint`, no up-to-date requirement, 0 required reviews, admins can override |
| Routes served | **44**: 35 PUT (state-changing), 9 GET (readers) -- §2.2 |
| `@endpoint` declarations | **32**, plus 6 files using the ABC generator -- §2.3 |
| Routes bypassing the contract | **0** |
| Tests | none, and none possible today (§3) |

The lint work is finished and enforced. What remains is **contract debt against
`MAST_common`** plus a testing blocker.

---

## 2. Open work, in the order I would take it

Numbered by order, not by size.

### 2.1 Serve `/spec/abort` at all -- DONE 2026-09-06, MAST_spec#69

*This section originally read "accept `PUT` on abort", on the assumption that a route
existed and had the wrong verb. Investigating it found no route at all. The corrected
account is kept because the mistake is instructive: the `MAST_common` comment that framed
this as a verb migration was itself working from that assumption.*

`MAST_common`'s plan client aborts the spectrograph with

```python
tasks.append(self.api_coroutine(self.spec_api, method="GET", sub_url="abort"))
```

`SpecApi.base_url` is `http://<host>:<port>{BASE_SPEC_PATH}` and `get(sub_url)` appends
`/{sub_url}`, so the request is `GET /mast/api/v1/spec/abort`.

**`spec.py` did not register that route.** It served `status`, `startup`, `shutdown`,
`powerdown`, `acquire` and four `simulate/...` routes at that base. Every `/abort` in the
repo was on a sub-path the client never asks for -- `/deepspec/abort`, `/highspec/abort`,
`/fw/abort`, `/stages/abort` -- so the fleet's spectrograph abort had been answering **404**
every time it was called, not 405 at some future point.

`Spec.abort()` existed all along and does the right thing
(`traverse_components_and_call("abort")`). It was simply never routed. MAST_spec#69
registers it with `methods=["GET", "PUT"]`, so neither side has to be deployed first.

**This unblocks MAST_common#51.** The comment holding the client on `GET` says spec's abort
route "has not been checked for PUT" -- there was no route to check. The client can move to
`PUT` whenever it likes; `GET` comes out on MAST_common#113.

**The client half followed the same day.** MAST_common#100 moved
`Plan.abort()`'s spectrograph call from `GET` to `PUT`, which it had to once §2.2 made the
route `PUT`-only. Both call sites in that method now read `method="PUT"`.

**MAST_common#51 is deliberately still open.** Its definition of done is "verified against a
unit running the swept routes", and nothing here has touched hardware. The code is in place
in both repos; the verification is not, and closing the issue on a code change would repeat
the mistake that produced the 404 -- a note asserting a route's state that nobody checked.

**Still unverified here too:** the route was confirmed by parsing `spec.py`, not by serving
it, because of §3. One `curl` against `mast-ns-spec` settles it.

### 2.2 Give state-changing routes a verb -- DONE 2026-09-06, MAST_spec#70

**PUT-only, in one step.** 35 state-changing routes now declare `methods=["PUT"]`; the 9
readers -- `/status`, `/position`, the wheel listing -- stay `GET`.

A dual-verb window was written first and then replaced with the end state, deliberately: a
window's cost is that nothing ever forces the callers to move, so the routes sit accepting
either indefinitely. Taking the break in one step puts the remaining work where it actually
lives, which is mostly `MAST_control`.

**The break is real and was accepted knowingly.** Any caller still sending `GET` to a
state-changing spec route gets 405. The one that mattered was `MAST_common`'s plan client,
whose abort call moved to `PUT` in MAST_common#100 the same day; `MAST_gui` and anything
driven by hand or bookmark have not been updated. The reasoning and the known callers are
recorded above `spec.py`'s route list, so whoever meets a 405 finds the answer at the routes.

**A count correction, because it produced a confident wrong number.** This repo was never
"43 routes, all GET". Nine already declared `PUT` -- five in `highspec.py`, four
`simulate/...` in `spec.py`. A `grep -c "methods="` restricted to lines that also contained
`add_api_route` missed every one of them, because those registrations span several lines and
the keyword sits on a different line. Re-measured by parsing the AST. **34 GET-by-default**
is exactly what MAST_spec#56's title said, and #56 was right the whole time.

**Not done here, and not planned:** enumerating every route a consumer calls and diffing it
against what spec serves. §2.1 and MAST_spec#47 are two known instances of a client asking
for something spec does not serve, so the audit would likely find more -- but it was
considered on 2026-09-06 and declined. Do not pick it up from this document without asking.

**Still open from this:** the handlers return bare values or `None` rather than a
`CanonicalResponse`. That is the `enveloped()` half of MAST_spec#56 and arrives with §2.3.

### 2.3 Adopt the endpoint contract -- DONE 2026-09-06, MAST_spec#71-#76

Six PRs, one per component. `router.add_api_route` no longer appears anywhere: every route
goes through `common`'s registration, so an undeclared handler stops the process at import
rather than shipping untiered.

**The trade taken.** Swagger regroups: ~21 lifecycle routes leave their per-component tags
for the flat `Component interface (contract)`, and operator verbs become
`<Component> (operator)`. The tag is derived from the tier and there is deliberately no
override. This was weighed against keeping the operator-facing grouping and decided in favour
of adoption, on the same terms MAST_unit took -- with the machine-checkable half deferred
until the import path is unblocked, since a repo that cannot run tests cannot benefit from
guarantees a test would assert.

**Two shapes, not one.** `Spec`, `Deepspec`, `Highspec` and `Chiller` are `Component`s, so
`register_component_endpoints` generates their four interface verbs from the ABC.
`FilterWheels` and `StageController` are **not** -- they are collections whose routes take a
`wheel` or `stage_name` -- so all their verbs are `OPERATION`, including startup / shutdown /
abort. Declaring those `INTERFACE` would claim an ABC guarantee that does not hold.

**Highspec needed `factory=True`.** Three of its routes handle `self.camera` methods, and the
two cameras do not share an exposure signature -- the endpoint deliberately publishes
whichever is configured, so `/docs` describes the machine in front of you. A facade method
would have one fixed signature and be wrong for one camera. The declaration cannot ride on the
camera either: the contract stamps its marker on the handler, and a bound method refuses the
attribute. A `functools.wraps`'d closure takes the marker and keeps `__wrapped__`, so
`inspect.signature` still resolves to the camera's parameters. Binding the camera at
registration was accepted as the decision, not a limitation -- publishing a per-camera schema
and rebinding at runtime cannot both be true.

**What it found on the way**, none of which was the point:

- **MAST_common#101** -- `add_api_route` ignores `declaration.methods` and silently serves
  `GET`. Only `register_component_endpoints` reads the declaration. Every consumer adopting
  the contract hits this; MAST_spec passes `methods=` twice as a workaround.
- **A malformed base path** -- the chiller served at `/mast/api/v1/specchiller`, a missing
  separator. Fixed in #72. Same family as §2.1: a route registered where nobody asks.
- **A hand-rolled envelope deleted** -- `Spec.endpoint_status` was
  `CanonicalResponse(value=self.status())`, which is exactly what `enveloped()` does.

### 2.4 File the import blocker -- DONE 2026-09-06, MAST_spec#77

*This section said "`import spec` blocks indefinitely, reaching for the config database and
the operational share". That was the symptom. Walking every module's top-level AST found six
import-time side effects, two of which command hardware.*

**`import spec` switches on a camera's outlet.** `spec.py:49-53`, at module scope: constructing
`SwitchedOutlet` reads the config, `.detected` probes the PDU over the network, and
`.power_on()` energises the Highspec camera. The comment above it states the requirement
correctly -- the camera must be on before `Newton.startup()` -- and then satisfies it as early
as it is possible to satisfy it.

**`import` also starts camera threads.** `cameras/greateyes/greateyes.py:1316` spawns a thread
per band at module scope, each calling `make_camera` ->
`GreateyesFactory.get_instance(band=band)`, and the import returns before they finish.

Also at import: `deepspec = Deepspec()`, `spec = Spec()` in `app.py`, a ctypes call into the
greateyes DLL, and `ctypes.CDLL(...)` for QHY.

**Filed separately from #43, deliberately.** #43 is that starting the *service* commands
hardware (`lifespan` calls `spec.startup()`). This is that *importing a module* does -- one
layer earlier and strictly worse, since it needs no service: pytest collection, a docs build,
or an editor's language server is enough. They share the principle from
`MAST_unit.2024-12-12#118` but not the fix, and fixing either alone leaves the other.

### 2.5 Exercise the changes on the instrument -- PARTLY DONE 2026-09-06

**Everything else on this list is done. This is where all of the accumulated risk sits.**

**Update, 2026-09-06 evening.** The service was run on the instrument four times. That
settled the HTTP surface and the startup path, and left the abort and acquisition paths
untouched. What is now verified live:

- the service starts, all four Deepspec bands connect, `/docs` and `/openapi.json` answer
- `/spec/fw/status`, `/spec/fw/position`, `/spec/stages/status`, `/spec/chiller/status`,
  `/spec/deepspec/status`, `/spec/highspec/status`, `/spec/status` all answer as
  `CanonicalResponse` envelopes
- `why_not_operational` reports genuine conditions (`highspec: camera is CoolingDown`, and
  the two filter wheels that are physically absent)

**Still unexercised, and still the accumulated risk:** the abort path on all three cameras,
and the acquisition path. Neither has been driven once. An abort issued mid-readout remains
the single most valuable test on this list.

Three days of change are on `master` and **none of it has been run**. Each PR was verified
carefully -- by parsing route tables, comparing before/after surfaces, driving state machines
against stubs, and reading two vendor SDK documents -- but that is verification by reading. The
repo cannot import itself off the telescope (§3), so nothing else was available.

What is unverified, by area:

**The HTTP surface** -- every route in the service changed shape.

- `/mast/api/v1/spec/abort` exists at all (#69); it answered 404 for months.
- 35 routes are `PUT`-only (#70). A caller still sending `GET` now gets 405 -- deliberately.
- Every route re-registered through `common` (#71-#76): responses are now `CanonicalResponse`
  envelopes and every Swagger tag changed.
- The chiller moved from `/specchiller/...` to `/spec/chiller/...` and gained three routes (#72).

**The abort path** -- rewritten on all three cameras.

- Aborting an exposure no longer produces a frame (#66), works at all during a readout (#67),
  and no longer races its own readout trigger (#83).
- Abort now discards the frame on all three cameras (#85, #86), and the QHY600 has an abort for
  the first time (#84).

**The acquisition path.**

- The fiber stage repositions when it is *not* already at `deepspec` (#64) -- it previously
  moved only when it already was.
- `Stage.__init__` raises `ValueError` on an unknown name instead of `AttributeError` one line
  later (#78).

A `curl` per route plus an abort issued mid-readout would settle most of it. Worth doing before
the next Deepspec run rather than after, and worth doing as one deliberate pass rather than
incidentally.

### 2.6 Decide what abort means during a readout -- DONE 2026-09-06, MAST_spec#85, #86

**The answer: abort discards the frame. No exception, no per-camera contract.**

| camera | mechanism | PR |
|---|---|---|
| Newton | `Aborting` checked before `SaveAsFITS` -- the SDK gives no signal that an acquisition was aborted rather than completed | #85 |
| greateyes | `Aborting` checked before the FITS is built | #85 |
| QHY600 | `CancelQHYCCDExposingAndReadout` drops the blocking `GetQHYCCDSingleFrame` into a failure branch that already existed | #86 |

`Aborting` was added to `NewtonActivities` and `GreatEyesActivities` in MAST_common#103, and to
the module-local `QHYActivities` in #86. It means *"a frame is still to be discarded"* rather
than *"an abort happened"* -- raised and cleared immediately when nothing is in flight -- which
is what makes it worth waiting on.

**The issue was filed on a false premise, and finding that out was most of the work.** It
assumed the greateyes could not discard a frame, which framed the decision as "uniform contract
vs. per-camera honesty". The vendor PDF says otherwise: `GetMeasurementData_DynBitDepth` obtains
*"the last measurement performed"*, and after `StopMeasurement` a fetch returns
`MeasurementStopped`. The constraint did not exist, so neither did the dilemma.

What is true, and applies to all three cameras: **an abort during the readout is not the same
case as an abort during the exposure.** The first was already handled -- clearing `Exposing`
stops the readout ever starting (#66, #67, #83). The second is what the issue was about, and no
SDK rescues it, because by then the measurement is complete and the data is valid.

Two defects were found on the way and fixed separately:

- **#83** -- both cameras made the hardware idle *before* clearing `Exposing`, so both raced
  their own readout trigger on every abort. On the Newton, whose handler is woken by driver
  events rather than polling, that race was the expected sequence rather than a coincidence.
- **#84** -- `QHY600.abort()` did nothing at all. Its body was `return super().abort()`, which
  resolves to `Component.abort`, an abstract method whose body is a docstring. The whole chain
  from the plan client down was a no-op on that camera while every layer reported success.

### 2.7 Retire the `endpoint_` prefix -- DONE 2026-09-06, MAST_spec#79

14 methods remain: 4 in `spec.py`, 10 in `stage/stage.py`. (`endpoint_status` went with §2.3,
which deleted it.)

The convention was ratified for retirement on 2026-08-10, after measurement on MAST_unit found
it wrong in both directions -- 26 routed operations sat on unprefixed methods, and ten
`endpoint_`-named methods were routed by nothing at all.

**§2.3 has now made it redundant rather than merely disliked.** A `@endpoint(` grep returns
this repo's surface exactly, which is the property the prefix was chosen for and did not
deliver. Renaming is therefore a tidy-up with no remaining argument against it -- but it
touches names across ten routed methods in a repo with no tests, so it wants its own diff
rather than riding along with something else.

### 2.8 Loose ends -- DONE 2026-09-06

- **The `C901` directives named flake8** (#80). This repo has none; ruff runs that rule. The
  reason is kept and sharpened to the argument §6 of the CI guidelines makes.
- **The Newton `SetShutter(mode=2)` finding** is now **MAST_spec#81**, with the ADU table and
  the arithmetic that rules out the innocent reading. It had been living only in #55's body and
  a code comment.
- **The camera `Aborting` flag** turned out not to be a loose end at all: neither camera enum
  had such a member, so it was a cross-repo change whose meaning depended on §2.6. It landed
  with that decision rather than separately.
- **`resolve_object_name`** (MAST_common#62, #92) is confirmed **not** spec's job -- it is used
  only by `common`'s own tests, by no service at all.

## 3. The blocker, now filed as MAST_spec#77

`import spec` reads the config database, probes a PDU, **switches on a camera's outlet** and
starts threads that connect to cameras -- before any function is called (§2.4).

That is why:

1. the CI added in MAST_spec#57 is **lint only** -- a test job would hang on the config read,
   or on a runner with network access attempt a PDU call;
2. §2.5 has to happen **on the telescope**, with no suite to catch a regression afterwards;
3. §2.6 cannot be **validated** once decided.

**The cost is larger than it was when this document was written.** Everything merged on
2026-09-05 and 2026-09-06 -- the fiber-stage guard, both abort fixes, the missing
`/spec/abort`, the verb sweep, and all six endpoint-contract PRs -- was verified by parsing
source or by exercising stub objects. **Nothing in three days was verified by running this
service.** The bugs that were found were found by reading registrations, which is also why two
routes registered where nobody asks (#69, #72) survived for months.

`MAST_unit`'s workflow is the template for the test job that becomes possible afterwards --
two checkouts side by side, with `PYTHONPATH: ${{ github.workspace }}` standing in for
`mast.pth`.

## 4. Verified as already done

Checked, not assumed. The `common` clone is exactly in sync with origin, so the stale-clone
hazard in `MAST_common/CLAUDE.md` does not apply.

| `MAST_common` change | Status in spec | Evidence |
|---|---|---|
| #41 `make_autofocus_folder` takes the instrument | Adopted -- closes the old consumer follow-up | `subfolder=self.name` |
| #67 products filed by observing night | Adopted transitively | via `PathMaker()` |
| #57 / #59 folder claim and merge | Adopted | 17 sites |
| #94--#96 config live store | Accessor-compatible, nothing to change | spec calls only `get_service`, `get_specs` |
| #91 frame types, #90 greateyes gain literals | Adopted | merged 2026-09-05 |
| every `common` symbol spec imports | All resolve | 74 names across 23 modules |

---

## 5. What landed on 2026-09-05

Eleven PRs: **#55** frame types (Newton `mode=2` held behind a flag), **#57** CI created,
**#58** two QHY scratch files excluded (119 -> 80), **#59** safe autofixes (80 -> 63),
**#60** FastAPI `Body()` exempted from B008, **#61** Zaber exceptions narrowed, **#62** the
C901 threshold raised to 20 with two outliers annotated, **#64** the lint campaign
(63 -> 26), **#65** the default stage unit named (first green build), **#66** and **#67**
the two abort fixes.

Also: branch protection enabled on `master`; MAST_spec#63 closed as not-planned; #68 opened;
and three stale claims corrected in this repo (#12), one of which had been copied into a
plan document *and had work prescribed around it*.

## 5a. What landed on 2026-09-06

**MAST_spec#69** -- `/mast/api/v1/spec/abort` is served at all. `Spec.abort()` had existed
and been routed nowhere, so the fleet's abort path had been answering 404.
**MAST_spec#70** -- 35 state-changing routes to `PUT`, 9 readers left on `GET`.
**MAST_common#100** -- the plan client aborts the spectrograph with `PUT`, closing the window
#70 opened.

A theme across all three: each was framed as one problem and turned out to be another.
"Add `PUT` to the abort route" found no route; "43 routes, all GET" was 34, because the
measurement missed multi-line registrations; and MAST_common#51's step 2 instructs consumers
to bump a submodule gitlink that has not existed since MAST_unit#94. That last one is now
the **third** document found carrying the stale submodule claim, after this repo's CI
guidelines and its docs-site plan -- both corrected in #12.

---

## 5b. What landed later on 2026-09-06

**MAST_spec#71-#76** -- the endpoint contract, one PR per component, ending with the
`factory=True` treatment for Highspec's camera routes. **MAST_spec#77** -- the import blocker,
filed. **MAST_common#101** -- filed, the `declaration.methods` trap.

The pattern from §5a held all day: each item was framed as one problem and turned out to be
another. "Adopt the contract in chiller" found a malformed base path. "Declare the camera
routes" found that a bound method cannot carry the marker. "File the import blocker" found
that the import energises hardware rather than merely blocking.

---

## 5c. The abort path, 2026-09-06

**MAST_common#103** -- `Aborting` for the two shared camera enums. **MAST_spec#79** -- the
`endpoint_` prefix retired. **#80** -- the `C901` directives stop naming flake8. **#83** -- both
aborts stop racing their own readout trigger. **#85** -- abort discards the frame on the Newton
and greateyes. **#86** -- the QHY600 gets an abort at all, and discards too. **#78** -- `Stage`
takes a `SpecStageNames`. Issues filed: **#81** (Newton shutter mode), **#84** (closed by #86).

**The pattern from §5b held to the end, and twice it was my own reasoning that was wrong.**

- "Adopt the contract in chiller" found a malformed base path.
- "Declare the camera routes" found that a bound method cannot carry the contract's marker.
- "File the import blocker" found that the import energises hardware rather than merely blocking.
- "Fix the abort ordering" found that the Newton's race is the expected sequence, not a
  coincidence -- and then that the QHY600 had no abort at all.
- **Twice a claim was made from a function's name and its position in a call sequence, and was
  wrong.** `GetMeasurementData_DynBitDepth` was assumed to transfer from the sensor; the vendor
  PDF, in the tree the whole time, says it obtains *"the last measurement performed"*. The
  correction inverted which camera was the constrained one.

In a repo where nothing can be executed, a plausible reading of code is not evidence. The
documents that were available -- two vendor PDFs, an SDK docstring, the enum's own guidance --
settled more questions than the code did.

---

## 5d. What landed on 2026-09-06, evening

Four PRs, each verified on the instrument before merging rather than after.

**MAST_spec#89** -- dropped the module-scope `deepspec = Deepspec()`. Nothing imported the
name; `Deepspec` is a singleton, so it was the same object `app.py` builds. Its only effect
was to force construction, and therefore camera binding, at import.

**MAST_spec#91** -- two live bugs, both found by watching a real service start.

- `FilterWheels._wheel_by_name` iterated `filter_wheels.wheels`, a module-scope name that
  does not exist. **Every filter-wheel endpoint was dead** -- `get_status`, `get_position`
  and `move`. Lint could not see it: the only other occurrence is inside
  `if __name__ == "__main__":`, which is module scope, so F821 saw a legitimate binding
  while the block never ran under import. **A `__main__` block silently satisfies the
  linter for names used at runtime.** An AST scan for the same shape across the repo found
  one other instance, in `cameras/qhy/qhy600-bug.py`, already excluded as a scratch file.
- Six corrupted degree signs across five lines of `greateyes.py`: bytes `D6 B2 C2 B0`, a
  UTF-8 degree sign decoded as cp1255 (this machine's Hebrew ANSI codepage) and re-encoded.
  Baked into the source, not introduced by the log handler.

**MAST_spec#90** -- `Spec.startup()` dispatches onto a daemon thread and returns. The long
operations already dispatched (`cool_down`, `move`, `unpark` set an activity flag and their
`RepeatTimer` clears it); only the serial synchronous calls around them blocked. Measured
live: the traverse returns in 0.81 s while the Newton cools for 1 m 55 s behind it, and
`/docs` answers in 30 ms.

A second commit was needed after the first: `traverse_components_and_call` stops at the
first component that raises, so "come up degraded" would have meant *nothing after the
failure starts at all*. `chiller` is first in `components_dict`, so one unreachable chiller
would have cost every camera, wheel and shutter its startup -- silently. It now takes
`isolate_failures`, which only `startup` passes.

**MAST_common#107** -- `DliPowerSwitch.get()`/`put()` opened a fresh `httpx.Client` per
call: a new TCP connection plus a Digest 401 challenge round trip, for a single outlet read.
150 ms per read, against 15 ms with a reused client. Each component reads the outlets several
times over (`powered` calls `is_on()`, `operational` calls it again, `why_not_operational` a
third time), so `/spec/status` was doing several dozen of them.

Measured on the instrument, before merging:

| | before | after |
|---|---|---|
| `/spec/status` | 11,131 ms | **~2,950 ms** |
| `deepspec` | 3,472 ms | 2,112 ms |
| `highspec` | 714 ms | 84 ms |
| `chiller` | 445 ms | 45 ms |

Pooling introduces one failure per-request clients cannot have -- a keep-alive the PDU closed
while idle -- which is retried once on a fresh connection. `TimeoutException` is deliberately
excluded: that path already waited, and retrying only doubles it.

Two corrections worth keeping: an earlier reading of ~950 ms was taken with three of four
cameras still booting and is not comparable; and `common/` is the shared clone, so #107
reaches MAST_unit, MAST_control and MAST_gui at their next start.

**The bottleneck has moved.** `deepspec` is now 2.1 s of the remaining 2.9 s, and that is
greateyes SDK calls across four cameras, not outlet reads.

## 5e. Open: camera reconnect costs ~50 s on every restart -- found 2026-09-06

Four-for-four across the day's restarts: all four bands fail their first
`ConnectToSingleCameraServer`, power-cycle, and wait 25 s to reboot.

**Root cause, two halves that compound.** `GreatEyes.shutdown()` warms up, sets
`shutdown_event` and sets `_was_shut_down` -- it never calls `DisconnectCamera` /
`DisconnectCameraServer`. The only disconnect is in `__del__`, a finalizer. And shutdown
never runs at all: **zero `ShuttingDown` lines in the whole day's log across four restarts**,
because the process is terminated rather than stopped. So the camera server holds a session
bound to a dead TCP connection. The next process's `try_connect_camera` does attempt cleanup
first -- hence `DisconnectCamera -> False` in the log -- but the SDK's `addr` handle is
process-local and cannot release a dead process's session.

Options, in the order worth taking them:

1. **Retry once before power-cycling.** Nobody has tried simply waiting a few seconds and
   reconnecting without the reboot. Diagnostic: it reveals whether the server times out a
   dead peer on its own, and that answer decides whether the rest is worth doing.
2. **Poll instead of blind-sleeping 25 s.** `time.sleep(boot_delay)` at greateyes.py:299 is
   unconditional. Retrying every ~2 s up to `boot_delay` returns as soon as the camera is
   ready and never waits longer than today. Free.
3. **Disconnect in `shutdown()` AND make shutdown run.** The correct fix, but it needs both
   halves -- the disconnect alone buys nothing while shutdown never executes. It also never
   fully solves it: a crash or power loss still strands a session, so the recovery path has
   to survive regardless.
4. **Camera-side session timeout.** The cameras have a web page on port 80. Vendor-dependent,
   may not exist, but the only option that fixes it at source.

**Not worth trying: parallelising the probes.** They already are -- four threads, all cycling
within 200 ms of each other. The ~50 s is one camera's serial cost, not four queued.

Also seen but not investigated: a `start_tls.failed` on the `NotificationWorker` at
16:10:39Z.

## 6. Three bugs the lint work turned up

None were the point of the exercise, and the first is the reason the rest are worth
recording.

**`not self.fiber_stage.at_preset != "deepspec"`.** `!=` binds tighter than `not`, so the
guard read `== "deepspec"` -- the block moved the fiber stage to deepspec **only when it was
already there**, and skipped the move in exactly the case that needed it. Ruff's own
`SIM202` fix for that line is `== "deepspec"`, which is faithful to the double negative and
**would have preserved the bug permanently**. A mechanical autofix pass would have locked it
in, which is an argument for reading semantic-looking fixes rather than batching them.
(MAST_spec#64)

**`abort()` left `Exposing` set.** `ge.StopMeasurement` makes `DllIsBusy` false, so
`on_timer`'s next tick saw `is_active(Exposing) and not DllIsBusy`, stamped `end_utc` and
`mid_utc` as though the exposure had completed, started the readout thread and saved the
frame. The `mid_utc` on such a frame is the midpoint of nothing, since the integration was
cut short at an unrecorded point. (MAST_spec#66)

**`abort()` returned early on `not DllIsBusy`.** That is precisely the readout state --
`on_timer` starts the readout thread *because* it went false -- so aborting during a readout
did nothing whatever. (MAST_spec#67)

A fourth, smaller one: `stage.py` caught bare `Exception` around `conn.detect_devices()`, so
an `AttributeError` or a typo in that block was reported as "cannot detect Zaber devices"
with `detected = False` -- **a software fault presenting as absent hardware**, which is the
worst possible place to send someone debugging. (MAST_spec#61)
