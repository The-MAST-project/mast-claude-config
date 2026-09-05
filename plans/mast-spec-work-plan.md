# MAST_spec: what is left after the lint burn-down

*Continuation plan for `MAST_spec` after 2026-09-05, when the repo went from 119 ruff
findings to zero, gained its first CI, and had three acquisition-path bugs fixed. Every
claim here was checked against `master` at `562a1a1` and against a `common` clone in sync
with origin -- 0 behind, 0 ahead -- rather than inferred. Nothing was measured by running
the service, because the service cannot be run off the telescope (§3).*

**Status: current as of 2026-09-05.** One item has an external deadline that is not in this
repo's control (§2.1). One item unlocks three others (§3).

---

## 1. Where it stands

| | |
|---|---|
| `ruff check` | **0**, from 119 |
| `ruff format --check` | passing |
| CI | lint only, blocking, `ubuntu-latest`, ruff pinned at 0.16.0 |
| Branch protection | on: requires `lint`, no up-to-date requirement, 0 required reviews, admins can override |
| Routes served | **43, all GET** |
| `@endpoint` declarations | **0** of 43 |
| Tests | none, and none possible today (§3) |

The lint work is finished and enforced. What remains is **contract debt against
`MAST_common`** plus a testing blocker.

---

## 2. Open work, in the order I would take it

Numbered by order, not by size.

### 2.1 Accept `PUT` on abort -- this one has a removal date

`MAST_common`'s plan client already aborts **units** with `PUT` (MAST_common#98). The
spectrograph is carried by an explicit exception, and the comment granting it says exactly
why it exists:

```python
# The spectrograph stays on GET: MAST_spec's abort route has not been checked for
# PUT, and breaking it to tidy the units would trade one silent failure for another.
# Same migration, separately (MAST_common#51, removal on #113).
tasks.append(self.api_coroutine(self.spec_api, method="GET", sub_url="abort"))
```

When that line goes, **spec answers 405 on the fleet's abort path**. The same comment, about
the units half of the migration, calls that "the last verb that should fail quietly".

The deadline is not in this repo's control and nothing here will warn about it. The fix is
small -- `methods=["GET", "PUT"]` on the abort routes for a migration window, then drop
`GET` -- and doing it alone removes the exposure without waiting for §2.2.

Abort routes: `deepspec.py`, `highspec.py`, `filter_wheel/wheel.py`, `stage/stage.py`, and
one commented out in `cameras/andor/newton.py`.

Blocks: **MAST_common#51** (open).

### 2.2 Give state-changing routes a verb

**Not one of spec's 43 `add_api_route` calls passes `methods=`**, so FastAPI's default
applies and `startup`, `shutdown`, `abort` and `expose` are all served as `GET`. §2.1 is one
instance of this; doing §2.2 properly subsumes it.

Tracked: **MAST_spec#56** ("34 GET-by-default routes, and the two the plan client already
calls").

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
