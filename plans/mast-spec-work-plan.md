# MAST_spec: what is left after the lint burn-down

*Continuation plan for `MAST_spec` after 2026-09-05, when the repo went from 119 ruff
findings to zero, gained its first CI, and had three acquisition-path bugs fixed. Every
claim here was checked against a `common` clone in sync with origin -- 0 behind, 0 ahead --
rather than inferred. Nothing was measured by running the service, because the service
cannot be run off the telescope (§3).*

**Status: current as of 2026-09-06, `master` at `483f6f1`.** §2.1 and §2.2 are done, and
the client half of the abort migration went with them (MAST_common#100). §2.4 -- the import
blocker -- now unlocks more than anything else on the list, whatever its number says.

---

## 1. Where it stands

| | |
|---|---|
| `ruff check` | **0**, from 119 |
| `ruff format --check` | passing |
| CI | lint only, blocking, `ubuntu-latest`, ruff pinned at 0.16.0 |
| Branch protection | on: requires `lint`, no up-to-date requirement, 0 required reviews, admins can override |
| Routes served | **44**: 35 PUT (state-changing), 9 GET (readers) -- §2.2 |
| `@endpoint` declarations | **0** of 44 |
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

### 2.3 Adopt the endpoint contract

Zero `@endpoint(` declarations, and `common.endpoints` is not imported at all. Spec calls
FastAPI's **native** `router.add_api_route` method, which at the call site looks almost
identical to `common`'s enforcing free function:

```python
router.add_api_route(path, tags=[tag], endpoint=self.status)   # spec -- FastAPI's
add_api_route(router, path, endpoint=self.status)              # common's -- enforcing
```

What spec forgoes meanwhile:

- **No import-time refusal** of a handler that has not declared itself, which is the
  mechanism that stops the declared surface drifting from the served one -- the specific
  failure the retired `endpoint_` prefix suffered.
- **No `enveloped()` wrapper**, so handlers can still return a bare value, a `None`, or let
  an exception escape rather than always answering a `CanonicalResponse`.
- **No tier or area tags** in Swagger; spec's `tags=` are hand-written strings rather than
  read from the declaration.

The relevant `MAST_common` PRs are #58 (the decorator), #69 (`factory=True`), #72 (the tag
is the tier, published as `x-stability`), #75 (`x-completion`), #99 (grouping by area) and
**#86**, which made `tags=` advisory rather than refused *specifically so this repo could
migrate file by file*. Its docstring names "MAST_spec has 29 such call sites". Adoption need
not be a flag day.

### 2.4 File the import blocker

`import spec` blocks indefinitely on a bare checkout, reaching for the config database and
the operational share. **It has no issue of its own.** The reasoning currently survives only
in MAST_spec#63, which is closed as not-planned, and in the testing section of #68.

Check **MAST_spec#43** first -- "Process start moves hardware here too: lifespan calls
`spec.startup()`, which unparks the Zaber stages and moves the filter wheels" -- which
sounds like the same root cause seen from the other end, and may make this a comment rather
than a new issue.

### 2.5 Exercise the three acquisition fixes on the instrument

All three are live on `master` and none can be regression-tested until §2.4 is solved:

- **MAST_spec#64** -- the fiber stage now repositions when it is *not* already at
  `deepspec`. It previously moved only when it already was.
- **MAST_spec#66** -- `abort()` no longer leaves the frame to be read out and saved.
- **MAST_spec#67** -- `abort()` during a readout no longer does nothing.

The first changes *when* the stage moves; the other two change *whether a frame is
produced*. Worth a deliberate pass before the next Deepspec run.

### 2.6 Decide what abort means during a readout

`GreatEyes.abort()` now stops an exposure, not a readout -- a boundary arrived at by fixing
two bugs, not by anyone choosing it. `ge.GetMeasurementData_DynBitDepth` is a blocking
ctypes call already in flight, so the frame still lands on disk.

Two defensible answers are set out in **MAST_spec#68**. Note the constraint that decides
between them: a cancellation flag cannot interrupt the SDK call, so the earliest realistic
cancel point is *after* it returns and *before* the FITS is written. That buys "no file",
not "instrument free sooner".

### 2.7 Retire the `endpoint_` prefix

15 methods remain: 5 in `spec.py`, 10 in `stage/stage.py`. The convention was ratified for
retirement on 2026-08-10, after measurement on MAST_unit found it wrong in both directions
-- 26 routed operations sat on unprefixed methods, and ten `endpoint_`-named methods were
routed by nothing at all. Falls out of §2.3 naturally.

### 2.8 Loose ends

- The two `C901` directives read "too complex for flake8". **This repo has no flake8**; ruff
  runs that rule. One word, whenever something else touches those lines.
- `StageActivities.Aborting` (MAST_common#70) is used in `stage/stage.py`, but the camera
  `abort()` methods set no aborting flag at all. Fold into §2.6.
- The Newton `SetShutter(mode=2)` hardware question has **no issue**. It lives only in
  MAST_spec#55's body and in the comment at `_NEWTON_HONOURS_CLOSED_SHUTTER`. The finding is
  worth keeping findable: nine frames at a steady -9.804 C, a 10 us bias at 63899 ADU of
  65535, and an excess over the pedestal that runs *backwards* with integration time
  (10 us -> +63649, 5 s -> +81, 60 s -> +29). No model of "the sensor sees nothing" gives
  that, and diagnosing it needs someone who knows the camera.
- Confirm `resolve_object_name` (MAST_common#62, #92) genuinely is not spec's job. Zero uses
  here; target resolution probably belongs to control, but that was not verified.

---

## 3. One blocker, three consequences

`import spec` reaching for the config database and the operational share is why:

1. the CI added in MAST_spec#57 is **lint only** -- a test job would hang the build, or pass
   having proved nothing (§3.2 of `code-validation-and-ci-guidelines.md`);
2. §2.5 has to happen **on the telescope**, with no suite to catch a regression afterwards;
3. §2.6 cannot be **validated** once decided.

It is the highest-leverage item here and the only one that unlocks others. `MAST_unit`'s
workflow is the template for the test job that becomes possible afterwards -- two checkouts
side by side, with `PYTHONPATH: ${{ github.workspace }}` standing in for `mast.pth`.

---

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
