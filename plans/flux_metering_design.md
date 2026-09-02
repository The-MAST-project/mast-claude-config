# Flux Metering — Locating the Fibre on the Imager Detector

*Design for `acquire_and_find_max_flux`: acquire a star, walk a spiral, find the pointing
that maximises light through the fibre, and measure how far that is from where acquisition
put the star. Written 2026-08-29.*

**Status: planned, not built.** Nothing in this document is implemented. Section 12 is the
sequencing: repeatability before sky coverage, and no configuration is changed by the code.

---

## 1. What is being measured

`fiber_x`, `fiber_y` in `guiding.rois[<fcu_version>]` say where the spectrograph fibre sits
on the imager detector. Everything downstream trusts that number:

| consumer | use |
|---|---|
| `solvers/mastrometry.py` | the `spec`-phase ROI is built symmetric about it, and its centre becomes the solve's `--crpix-x/--crpix-y` (via `roi_center_to_crpix`) |
| `solvers/astrometry_dot_net.py` | passed directly as `--crpix-x` |
| `guiding.py` | centre of the guiding ROI |
| `spiral_search.resolve_center` | centre of the correlation window |

The reference pixel is what makes this measurable. Because the solve's WCS is anchored at
the fibre pixel, **acquisition drives the target star onto the assumed fibre position** —
that is what "acquired" means mechanically. If the assumed position is wrong, the star
lands where we *think* the fibre is rather than where it *is*, and the fibre is fed off
axis. Nothing in the imaging chain reveals this, because the folding mirror occults the
target: the star cannot be seen sitting in the wrong place.

The fibre itself can say so, though. Walking the mount over a small spiral and watching the
light coming out of the fibre finds the pointing of best coupling. Cross-correlating the
imager frame taken there against the one taken at the start measures how far the field —
and therefore the star — moved between them:

```
fiber_true = fiber_assumed + (dx, dy)
```

**That `(dx, dy)`, in detector pixels, is the deliverable.** The hope is that it is a fixed
property of the instrument. If it proves consistent across the sky it gets added to
`fiber_x`, `fiber_y`; §12 is how that is decided and §13 is where it would be written.

---

## 2. Scope and non-goals

**In scope.** One endpoint, run by hand, on one unit, producing one JSON result per run.

**Explicitly not in scope, and each of these is a decision rather than an oversight:**

- **Not a campaign.** No mesh, no slot clock, no checkpoint, no scheduler. An operator
  chooses the target and the moment. This may change later; §12 says what would have to be
  true first.
- **One unit.** The fleet is not being calibrated. Each fibre is mounted individually, so
  the number is not expected to transfer.
- **No automatic configuration update.** `dx, dy` land in the result JSON and nowhere else.
  Applying them is a deliberate, manual act — see §13.
- **Focus drift within a run is ignored.** Focus is a pre-flight precondition (§11), not a
  covariate. It is *recorded*, not controlled mid-run.
- **Saturation is recorded, not acted on.** No pre-flight gate and no abort — a run starts
  on whatever ThorCam settings are given and finishes regardless (§5.4).

---

## 3. The procedure

```
acquire (spec phase, mastrometry, corrections on)
    |
    +-- reference frame at spiral index 0   <-- star is on the ASSUMED fibre
    |
    +-- for each spiral step:
    |       wait for the mount to settle
    |       repeat number_of_frames times:
    |           imager exposure  ]  in parallel
    |           ThorCam exposure ]
    |       flux = MEDIAN of this step's ThorCam sums (§5.6)
    |       stop when a ring adds no improvement, or a cap is hit (§4)
    |
    +-- pick the argmax index
    +-- correlate reference vs the imager frame ALREADY TAKEN at that index -> dx, dy
```

Acquisition parameters are fixed internally and are not operator-facing: approach mode
`GRADUAL_BY_RATE` (= 2), solver `mastrometry`, corrections on, `skip_sky` on,
`use_set_limit_frame` on, and no handover to the guider.

`skip_sky` is on because the fibre only sees light with the folding mirror inserted, so the
`spec` phase is the one that matters. The consequence to watch: acquisition must still
reach its 0.5″ tolerance from the spec phase alone. If it does not converge reliably
without the sky phase first, this procedure inherits that as a start-up failure rather than
as a bad measurement.

The spiral is driven through PWI4's spiral-offset API, the same one `SpiralSearch` uses.
`spiral_offset.x`/`.y` are **counts of steps**, not angles; the step size is carried
separately, so the offset in arcsec is the product.

### 3.1 The argmax frame, not a fresh one

There is no backtrack. The correlation uses the imager frame **already taken** at the argmax
index, so the run ends when the search does.

Three things follow, and the third is a cost rather than a benefit:

- **It is quicker**, by however many steps a return to the argmax cell would have taken —
  each of which carries the same ≥5 s settle as any other step.
- **The two correlated frames are closer together in time**, so less seeing and transparency
  drift separates them than would separate the reference from a frame taken after a
  backtrack.
- **The intermediate imager frames are now inputs to the result, not diagnostics.** This
  inverts the storage argument in §8.2: they can no longer be binned or dropped, because
  which one turns out to be the argmax is not known until the search ends, so every one of
  them has to be kept at full detector sampling.

The frame at the argmax is also whatever was taken there — a cloud, a cosmic ray or a
tracking glitch at that index cannot be retaken. Since every frame is kept (§8.2), such a
frame is identifiable afterwards, but only offline.

**The mount no longer ends at the best-coupling position.** It stops wherever the search
stopped, up to a ring away from the argmax. §7 says where to leave it.

---

## 4. Stopping rules

Three bounds, in the order they normally fire:

| bound | default | role |
|---|---|---|
| `patience_rings` | 1 | a complete ring with no improvement ends the search |
| `max_rings` | 6 | practical ceiling on the search |
| `max_radius_arcsec` | 10.0 | runaway guard |

**The ring is the unit, not the step.** A square spiral does not approach the optimum
monotonically: it circles the origin, so the distance to the peak rises and falls on every
ring. A rule like "flux rose then fell twice" stops at the first near-pass, which for a
peak three cells out is ring 1 — a confident wrong answer. A *complete ring* with no
improvement is the smallest statement about the neighbourhood that means anything.

**The radius cap is a guard, not the search extent.** At 0.5″ steps a 10″ cap is radius 20,
which is (2·20+1)² = **1681 cells** — hours of walking. It is not what ends a healthy run;
`max_rings` is. The cap exists for when something is actually wrong: a mis-calibrated fibre
position, or acquisition that solved onto the wrong star.

Note the two quantities the 0.5″ figures conflate. Acquisition lands within **0.5″ of the
target coordinates**; the spiral must cover the **fibre-position uncertainty**, which is a
different and probably larger number. Sizing follows the second.

**The cap needs `cos(dec)`.** `x_step_arcsec` is RA *coordinate* arcsec, so the sky angle
along that axis is `x · x_step · cos(dec)`. A radius computed as plain
`hypot(x·x_step, y·y_step)` reads 25% high at dec +41 — measured, MAST_unit#136, and
already handled in `_pixels_from_reference`.

### 4.1 Sub-cell precision

The argmax names a cell; the true optimum lies between cells. Fit a 2-D quadratic over the
3×3 neighbourhood of the argmax and take its vertex. This matters because it, not the
correlation, is where precision finer than one step comes from: at ~0.26″/px a 0.5″ step is
~1.9 px, and the correlation's measured median error is ~1.2 px (~0.31″) — comparable to a
whole step. The correlation supplies the pixel-frame anchor; the flux fit supplies the fine
positioning.

Converting the fitted vertex from cell space to detector pixels needs the rotation and
scale, which come from the acquisition WCS (§5.1).

---

## 5. Corrections and covariates

### 5.1 Subtract the acquisition residual

What the correlation measures is not the fibre error alone:

```
dx, dy = (fibre_true - fibre_assumed) + acquisition_residual
```

The residual is bounded by the 0.5″ tolerance — about **1.9 px** — against a correlation
error of ~1.2 px. Leaving it in roughly doubles the run-to-run scatter in exactly the
quantity whose consistency is the question. It is the difference between *"the offset
wanders by 3 px, so it is not fixed"* and *"it is fixed to 1 px and acquisition wanders"*.

It is already recorded: `last_delta` is written into `corrections.json` by
`solve_and_correct`. Converting it to detector pixels uses the acquisition's **WCS**, which
carries both scale and rotation — so it does not depend on `pixel_scale_at_bin1`, which is
0.0 in the configuration database today (MAST_unit#138).

**The WCS is not in full-frame coordinates.** mastrometry crops to the ROI and downsamples,
so its WCS lives in the cropped-and-downsampled frame. Go back through `solvers/pixel_grid`
rather than hand-rolling the transform.

### 5.2 Transparency drift, and why it is not corrected here

The ThorCam sees **only** the target's light through the fibre — everything around it is
black. The flux estimator is therefore trivial (background-subtracted frame sum), and the
ThorCam carries **no internal transparency reference at all**.

Over a 20–40 minute spiral, transparency drifts, and a monotonic decline pulls the argmax
earlier along the path. Near the peak — where the curve is flattest, by definition — a
percent or two is a cell or two.

**No correction is applied.** An earlier revision of this document proposed dividing the
fibre flux by ensemble photometry of the field stars in the parallel imager frame. That is
dropped, for three reasons:

- **It is a correction for a problem not yet shown to exist.** §12 runs repeatability first;
  if transparency drift is biasing the argmax, it shows up there as excess scatter. Building
  the correction before that measurement is the same mistake §5.3's observer-before-gate
  discipline exists to prevent.
- **It can be applied offline, from data already kept.** Every imager frame is saved at full
  resolution (§8.2), so the photometry can be done afterwards, checked against the frame
  timestamps, and applied retrospectively. Nothing is lost by deferring; nothing is gained by
  building it in.
- **Doing it correctly is not simple.** The folding-mirror shadow is fixed in the *detector*
  frame while the field slides across it — ~1.9 px per 0.5″ step, ~38 px over the full span —
  and the shadow has graded edges. A field star near one would show a flux change correlated
  with spiral position: exactly the artefact the correction is meant to remove, injected by
  the correction itself. Shadow-aware star selection belongs in offline analysis where the
  result can be inspected, not in the run.

What **is** kept is not photometry: a source count on the **reference frame only**. It is the
one *measured* predictor of correlation reliability — of 18 real MAST pairs, those with fewer
than ~30 matchable stars failed 5 times in 6, while those with 45 or more failed once in 13.
One `detect_sources` call per run, and it says whether to trust `dx, dy` at all.

### 5.3 The usable window, and the mirror shadow

`usable_fraction` (default 0.66) bounds a region around the configured fibre position,
keeping the coma-dominated edges of the frame out of the analysis — the correlation window,
and the region the reference frame's source count is taken over.

**Do not mask the folding-mirror shadow.** `imaging/frame_shift.py` is explicit that this
was considered and rejected: `_bg_subtract`'s 64-px background model already absorbs the
shadow (verified against a simulated band at 60% depth), and supplying a mask makes
`phase_cross_correlation` ignore `upsample_factor` and fall back to whole-pixel shifts,
costing the sub-pixel precision that is the point.

The same module explains why the correlation is plain rather than phase-normalised: on 19
real MAST pairs, phase correlation collapsed onto the zero-lag fixed-pattern peak in 18 of
them, plain cross-correlation in none. The obscuration is anticipated. Change nothing.

### 5.4 Saturation

Saturation neither gates a run nor stops one. It is **measured and reported**, and the
decision about what it means is left to whoever reads the result.

The saturation level is read from the camera at open (max ADU from its bit depth) rather
than supplied as a parameter, so the count cannot silently come to mean something different
if the camera is reconfigured or replaced. Count pixels at or above that level rather than
trusting a single one: the field is black, so one hot pixel or a cosmic ray would otherwise
make every frame look saturated.

What saturation does to the answer, so that the report can be read properly: coupling rises
toward the optimum, so saturation appears **near the peak** — precisely where it does the
most damage. A saturated peak is a plateau rather than a maximum, so the argmax becomes
arbitrary among the saturated cells, and the sub-cell quadratic of §4.1 is meaningless if
any of the nine cells around the argmax are clipped.

Since nothing stops the run, the result has to make this visible at a glance rather than
leaving it buried in the flux curve. Two top-level fields carry it:
`saturated_frame_count`, and — the one that actually matters — **`argmax_saturated`**. A run
with `argmax_saturated: true` has produced a `dx, dy` that should not be trusted.

The remedy is narrower than it looks, and worth knowing before the first bright target.
`flux_gain` defaults to 0, which is already the floor, and `flux_black_level` is a pedestal
rather than a scaling, so neither helps. The ThorCam exposure follows `seconds` (§6), so the
only lever left is **shortening `seconds` — which shortens the imager exposure with it**,
costing the field-star signal the correlation depends on.

If a target turns out to saturate at the shortest `seconds` that still gives usable imager
frames, the options are a fainter target or decoupling the two exposures. The coupling is
worth its matched integration window (§6), but it does cost this degree of freedom, and that
is the trade being made.

### 5.5 When the argmax is index 0

If acquisition already puts the star on the fibre, the argmax is index 0 — a plausible
outcome of a *successful* run at 0.5″ pointing and 0.5″ steps, not an edge case, and the
signature of a unit that is already calibrated (§12).

Without a backtrack this becomes degenerate rather than merely suspicious: the reference
frame **is** the frame at index 0, so the correlation would be handed the same array twice
and would return (0, 0) at confidence 1 by construction. **Short-circuit it** — report
`dx, dy = (0, 0)` with the argmax index, and do not run `measure_shift` at all. Feeding a
frame to itself produces a number that looks like a measurement and is not one.

`measure_shift`'s `at_origin` flag exists for the related-but-different hazard of a
fixed-pattern peak winning on two genuinely different frames, and it stays relevant for
every argmax that is *not* index 0.

Worth considering: exposing the reference **separately**, just before the spiral opens,
rather than reusing the index-0 frame. It costs one exposure, and it buys a real null
measurement whenever the argmax lands at index 0 — two frames at the same pointing, whose
measured shift is a direct read of the noise floor that §12 otherwise has to establish by
repetition.

### 5.6 Several exposures per step, reduced by the median

Each step takes `number_of_frames` imager+ThorCam pairs at one pointing. The step's flux is
the **median** of the ThorCam sums, and the imager frame the correlation would use is the one
paired with the sample **nearest that median**.

Median rather than mean because the arg-max is decided where the coupling curve is flattest
-- that is what a maximum is -- and that is exactly where one outlier has most leverage over
which cell wins. A cosmic ray, a gust or a tracking glitch moves a mean and leaves a median
alone.

Pairing the correlation frame to the median sample keeps the two halves consistent: the shift
is measured from the same instant as the flux that chose the step, rather than from an
arbitrary member of the burst. The mount does not move within a step, so the frames differ
only by seeing, noise and whatever the tracking drifted -- which is why choosing among them by
flux is defensible at all: it selects a typical moment rather than an excursion.

**Prefer an odd count.** With an odd number the median IS one of the samples, so the chosen
pair is exact. With an even number the median is interpolated, belongs to no frame, and the
choice falls between the two middle ones -- resolved deterministically, but standing for
nothing physical.

The reference frame is exposed the same way (§3), because it is the other half of the same
correlation, and treating the two sides differently would put a systematic between them that
no later analysis could separate from the answer.

**It costs time and storage linearly.** Settle is paid once per step; the exposures are serial
within it:

| | N=1 | N=3 | N=5 |
|---|---|---|---|
| per step | ~13 s | ~29 s | ~45 s |
| 81 steps (ring 4) | 18 min | 39 min | 61 min |
| 169 steps (ring 6) | 37 min | **82 min** | 127 min |
| stored, ring 6 | 15.8 GB | **47.6 GB** | 79 GB |

The storage need NOT scale, even though it currently does. Unlike the no-backtrack constraint
of §3.1, the representative frame is identified at the end of its **own step**, so only it has
to survive the run. Keeping all N is a debugging choice, and dropping the rest is a one-line
change if the volume bites.

---

## 6. The endpoint

`acquire_and_find_max_flux`, on the unit router, declared through the endpoint contract that
landed with MAST_unit#77 (`docs/adding-an-endpoint.md`):

```python
@endpoint(tier=Tier.OPERATION, completion=UnitActivities.FluxMetering)
def endpoint_acquire_and_find_max_flux(self, ...): ...
```

- **`Tier.OPERATION`** — an operator and diagnostic verb, not orchestration `MAST_control`
  depends on. The tier *is* the Swagger group, so no `tags=` (it would be ignored with a
  warning, and a check keeps the tree free of them).
- **`completion=UnitActivities.FluxMetering`** — the run outlives its response, so the caller
  is answered at once and watches that flag clear. `test_completion_flags.py` verifies the
  handler really raises the flag it advertises, and `test_activity_flag_balance.py` verifies
  it is always cleared: a flag that starts and never ends hangs a waiter forever.
- **No `factory=True`.** It exists for defaults that need loaded configuration — which is why
  `spiral_new_path` uses it — and dropping `fiber_x`/`fiber_y` from the signature removed our
  only such default.
- Registered with the helper, `PUT` because it changes state:
  `add_api_route(router, "/unit/acquire_and_find_max_flux", endpoint=..., methods=["PUT"])`.
  Never `router.add_api_route`, which would bypass the declaration refusal, the envelope and
  the tier tag at once.

Four consequences for the body, each enforced by a check:

- **Return the bare value.** The envelope is applied once at registration, so the handler
  never builds `CanonicalResponse(value=...)`; it refuses with `CanonicalResponse(errors=[…])`
  and answers `CanonicalResponse_Ok` where "ok" is genuinely the answer. It must never
  bare-`return`, return `None`, or let an exception escape.
- **No `assert` as a runtime guard** — stripped under `python -O`, and the envelope renders
  `AssertionError` as an anonymous error. Guards are `require_*` helpers returning a refusal.
- **Preflight before the expensive part**, and *a thread dispatch counts as expensive*. Every
  parameter check, component precondition and configuration check happens before the run
  starts, because a route that dispatches and answers `Ok` has already spent the request.
- **The thread target is `do_acquire_and_find_max_flux`** — dispatcher `<operation>`, target
  `do_<operation>`, enforced by `test_dispatch_naming.py`.

The status endpoint is a separate `Tier.OPERATION` route with `Completion.IMMEDIATE`, `GET`.
It returns a **typed `FluxMeteringStatus`**, which is also nested in the unit's own status as
`FullUnitStatus.flux_metering` (None until a run has happened). That is why it must be
returned bare: `FullUnitStatus` types its fields as the status models, and the contract's one
load-bearing exception is that a status returns its model rather than an envelope, since an
envelope nested in the payload breaks every consumer silently.

Carrying the step list there costs about **71 KB** at the default `max_rings` of 6, on a
status that is polled and pushed over the websocket. If that proves too heavy, the steps can
stay in this route and `result.json` and be dropped from the nested copy — one line in
`Unit.status()`.

Two parameters beyond §5.6's `number_of_frames`: `gain` (the imager's, named as the acquirer
names it minus the `_absolute` suffix) and the usual target and spiral arguments.

Run `python -m pytest tests/contract -q` — about two seconds, no hardware — before believing
any of this is wired correctly.

```python
def endpoint_acquire_and_find_max_flux(
    self,
    seconds: Annotated[float, Query(
        description="Imager exposure, used for both the acquisition and each spiral step"
    )] = 5.0,
    ra_j2000_hours: Annotated[str | float | None, Query(pattern=RA_PATTERN,  ...)] = None,
    dec_j2000_degs: Annotated[str | float | None, Query(pattern=DEC_PATTERN, ...)] = None,
    gain_absolute:  Annotated[int | None, Query(ge=..., le=...)] = asi.ASI_294MM_DEFAULT_GAIN,

    # --- spiral
    x_step_arcsec: float = 0.5,
    y_step_arcsec: float = 0.5,
    max_rings: int = 6,
    patience_rings: int = 1,
    max_radius_arcsec: float = 10.0,

    # --- ThorCam (Zelux)
    flux_gain: float = 0,
    flux_black_level: int = 3,

    # --- analysis window around the configured fibre position
    usable_fraction: float = 0.66,
):
```

Twelve parameters. **The ThorCam exposure is not one of them**: it is `seconds`, converted
to microseconds.

An earlier revision justified this by the field-star ratio needing matched integration
windows. That reason is gone with §5.2, but the tie is still the right default for a
different and simpler one: **a long integration averages over scintillation.** A
millisecond exposure samples one instant of a twinkling star, so the flux curve would carry
scintillation noise on top of the coupling signal it is meant to resolve — and the argmax is
decided exactly where that curve is flattest. Seconds of integration smooths it. One fewer
parameter is the secondary benefit, not the reason.

The two exposures should still be *started* together, and each frame should record its own
start and end timestamps: they are what make the offline transparency analysis of §5.2
possible later, and the imager path goes through PHD2 and may not begin the instant it is
asked.

**Check the exposure against the camera's range at open.** The SDK reports a valid exposure
interval; `seconds` is chosen for the imager and nothing guarantees the Zelux accepts it. If
it falls outside, fail with a clear message rather than letting the camera silently clamp to
something else — a truncated flux exposure would quietly break the matched-window argument
above while still producing plausible-looking numbers. Spawns a thread and returns `CanonicalResponse_Ok` immediately, exactly
as `start_acquisition_and_guiding` does — a 20–40 minute HTTP call is not viable. A
`find_max_flux_status` endpoint reports progress: current index and cell, ring, best flux so
far and its cell, frames taken, and why it stopped.

**Not parameters, fixed internally:** `approach_mode`, `solver_name`, `make_corrections`,
`skip_sky`, `use_set_limit_frame`, guider handover, the saturation level (read from the
camera), and `fiber_x`/`fiber_y` — the last of these coming from the configuration database
through `resolve_center`, which returns the value *and* its source string.

`seconds` now fires once per spiral step rather than a handful of times, so it multiplies
into the run length. That is the reason to think about it rather than the SNR.

---

## 7. Terminal states

Three, and they must be distinguishable in the result, because they mean different things to
whoever reads it:

| state | meaning |
|---|---|
| `converged` | a ring completed with no improvement; `dx, dy` are valid |
| `max_rings` / `max_radius` | search exhausted without converging; the argmax is the best seen, not necessarily the peak |
| `aborted` | operator called `unit/abort` |

Saturation is not among them — it does not end a run (§5.4). It is reported alongside the
terminal state, and `argmax_saturated` is what says whether the answer is usable.

`unit/abort` must stop the sequence. That needs a new `UnitActivities` flag — **appended at
the end of the enum**, since members are `auto()`-numbered and the bitmask goes on the wire —
and a branch in `Unit.abort()`, which today knows only about autofocus, the guider and the
components.

**Reset the spiral offset to zero on every ending, converged included.** Without a
backtrack the mount stops wherever the search stopped, which is an arbitrary cell up to a
ring from the argmax and of no use to anyone; leaving it there means the next operation
starts from an offset nothing downstream knows about. Returning to the acquired position is
the one predictable choice.

Parking at the best-coupling position is still available — a single `mount_offset` to the
argmax cell — but it is now a deliberate extra action rather than a side effect of how the
run ends, and it is not part of this procedure.

---

## 8. Products

`<ram>/<observing-night>/FluxMetering/<NNNN>/`, moved to
`<share>/<hostname>/<observing-night>/FluxMetering/<NNNN>/`, following
`PathMaker.make_spirals_folder` exactly.

Two details that are easy to get wrong and are already solved elsewhere: **do not join the
hostname** (`Filer().shared.root` already carries it on Windows), and the date label is an
**observing night**, which turns at 12:00 UTC.

Per run: `reference.fits`, `result.json`, and per step an imager frame, a ThorCam frame and
its metadata. There is no `final.fits` — the second half of the correlation is the
per-step imager frame at the argmax index (§3.1), which the result names.

### 8.1 MoveGuardian

Every product — imager frames, flux frames, result JSON — is written as
`protect` → write → `move_ram_to_shared`, matching `spiral_search._expose`.

The parallel imager and ThorCam exposures are safe under this: two threads, two distinct
paths, claims are reference-counted and the lock is never held across the I/O. The thing not
to do is `protect` the **run folder** while per-step writes are in flight from other
threads — overlap is bidirectional, so a folder claim blocks every file beneath it, and
`filer.py` warns that taking overlapping `protect` and `moving` claims on one thread
self-deadlocks.

### 8.2 Volume, and who moves the frames

The imager runs full-frame at bin 1, as `SpiralSearch` does, because the correlation wants
full detector sampling. **ASI294MM is 8288 × 5644, so a frame is ~94 MB** — not the ~23 MB a
bin-2 frame would be.

| steps | imager frames |
|---|---|
| 81 (through ring 4) | **~7.6 GB** |
| 169 (through ring 6) | **~15.8 GB** |

Zelux frames are small by comparison and add a few hundred MB.

**Nothing moves these off the RAM disk unless this code does.** `solving.py` records that
`astrometry_dot_net` and `planewave_cli` move the input frame themselves and **mastrometry
does not** — which is how the RAM disk filled overnight on 2026-08-04. mastrometry is the
solver this procedure mandates.

Moving each frame as it is written keeps only the in-flight backlog on the RAM disk, about
7 MB/s of sustained demand. **Call `filer.flush()` before reporting the run complete**, so
that "done" means the products are on the share rather than queued on a volatile disk.

**This volume is not optional.** Since the correlation reads the per-step frame at the
argmax index (§3.1), and which index that will be is unknown until the search ends, every
imager frame has to be kept at full detector sampling. Binning or dropping intermediates
would have cost nothing while the run ended with a fresh frame at the argmax; it now costs
the measurement.

If ~8–16 GB per run proves unacceptable, the lever is the mesh (fewer rings, larger steps)
or a return to taking a fresh frame at the argmax — not the intermediates.

---

## 9. The result

Enough to pool runs by hand later without re-running any of them:

```
dx, dy                     measured shift, detector pixels, reference -> final
confidence, at_origin      from measure_shift; MIN_CONFIDENCE = 0.10
beyond_limit               magnitude vs max_reliable_shift for the window
fiber_x, fiber_y           the configured values in force, and resolve_center's source
proposed_fiber_x/y         fiber_x + dx, fiber_y + dy
acquisition_residual       last_delta, and the same in detector pixels via the WCS
dx_corrected, dy_corrected dx, dy with the residual removed
argmax_cell, argmax_ring   and the sub-cell quadratic vertex
argmax_index, argmax_frame the step, and the imager frame the correlation actually read
argmax_saturated           whether the argmax frame was clipped -- if true, dx/dy are not usable
saturated_frame_count      how many frames clipped at all
commanded_offset_px        the argmax cell's commanded offset, cos(dec)-corrected, in pixels
flux_curve                 per index: cell, raw flux, normalised flux, saturated pixels
field_star_count           sources in the REFERENCE frame; the predictor of correlation reliability
terminal_state             one of the four in section 7
axis0/axis1 position_degs  mechanical positions, for a later flexure question
temperature, timestamps    UTC
thorcam settings           exposure, gain, black level, and the camera's saturation level
frame timestamps           start and end of each exposure, both cameras, to verify overlap
```

### 9.1 The sign convention, and the check that verifies it

Acquisition puts the star on the assumed fibre pixel. Between the reference and final
frames the whole field translated by the measured shift, and the star translated with it. So
`fiber_true = fiber_assumed + (dx, dy)` — the measured shift is *added*.

This is the likeliest bug in the whole procedure and nothing downstream would catch it. It
does not have to be taken on trust, because **the run already contains the check**: at the
argmax cell the commanded spiral offset is known, and converted to pixels it should equal
the measured shift in both magnitude and sign.

- signs disagree → the convention is inverted
- magnitudes disagree → the plate scale is wrong, and this measures it (MAST_unit#138)

Reporting `commanded_offset_px` beside `dx, dy` turns an assumption into a verified
quantity. Reporting `proposed_fiber_x/y` makes a sign error visible by eye on the first run
rather than after five.

---

## 10. Reusing what exists

Reuse the **primitives**, not the session. `SpiralSearch` is an interactive object: one
session at a time, a one-hour watchdog, and `_same_cell`/`_revisit_clause` built to help a
human confirm they backtracked correctly. An automated loop knows its own index and needs
none of that, and sharing the session object would collide with manual use.

Take directly: `imaging.frame_shift.measure_shift` and `max_reliable_shift`,
`spiral_search.resolve_center` / `resolve_margins` / `guiding_roi`, and the PWI4
spiral-offset stepping. Do not fork the correlation.

Check `max_reliable_shift` against the radius cap **up front** rather than discovering
`beyond_limit` after 40 minutes.

---

## 11. Pre-flight

1. **Focus the unit.** A defocused run gives a broad, shallow flux peak and a noisy argmax —
   not an obviously bad one. Focus is a precondition here, not a covariate.
2. **Fibre position present in configuration** — `resolve_center` falls back to the frame
   centre when it is not, which would silently measure something else entirely.
3. **ThorCam settings sane on a test exposure.** There is no gate; a bad setting costs a
   whole run.
4. **Free space on the RAM disk**, given §8.2.
5. **Target chosen for a populated field** — the field-star count predicts whether the
   correlation will work at all.
6. Mount tracking, covers open, stage at the spec position, safety normal.

---

## 12. Sequencing

**Repeatability before sky coverage.** Run several times on one target, back to back. That
scatter is the noise floor, and only variation exceeding it across the sky means anything.
Without it the first survey produces a spread with no way to tell which half of the question
it answers. It is also cheap, and it exercises the whole path before any of it is trusted.

**Then a handful of pointings.** If a survey is wanted later, note that the covariate for
flexure is **mechanical axis position**, not alt/az: on an equatorial mount the instrument's
orientation relative to gravity is set by the two axis positions. That is why they are in
the result schema even though nothing reads them yet.

**Decide the rule before collecting the data.** Something like *"spread across pointings
within 2× the single-pointing repeatability → treat as fixed, apply the mean."* Setting the
threshold after seeing the numbers is how `MIN_CONFIDENCE` and `max_best_hfd_px` went wrong,
twice, in this repository.

**The acceptance test is closed-loop.** Once a correction is applied, re-run: the argmax
should land at cell (0, 0) — see §5.5. That is a demonstration on the same instrument, not a
statistical argument, and it is why `argmax_cell` belongs at the top of the result.

---

## 13. Applying the result, when it comes to that

`Config.get_unit()` builds a unit's configuration as `units.common` **deep-merged** with an
optional unit-specific entry, so a unit-specific document need contain only the keys that
differ.

`common` carries no `fiber_x`/`fiber_y` of its own — the values already live in the unit's
own document, which is where any correction goes. The general hazard is worth stating
anyway, because the merge makes it easy: editing a value in `common` because that is where
you found it would move **every unit in the fleet**.

Nothing in this code writes configuration. `set_unit` exists; using it is a separate,
deliberate act after §12 has been satisfied.

---

## 14. Layout, SDK, tooling

```
unit/src/flux_metering/
    __init__.py
    thorcam/
        __init__.py
        thorcam.py
        sdk/            <- vendored Thorlabs bundle
```

`unit/src` is the runtime `sys.path` root — `app.py` is launched with `cwd=src` — so the
package goes under `src/`, not at the repository root.

**`thorlabs_tsi_sdk` is not on PyPI**, but it is now installed. Verified 2026-08-29 that
`thorlabs-tsi-sdk`, `thorlabs_tsi_sdk` and `thorlabs-tsi-camera` all return 404 while
`thorlabs-apt-device` returns 200 — a real absence, not a blocked request. It ships inside
Thorlabs' *Scientific Camera Interfaces* bundle as a local wheel plus native DLLs.

As of 2026-08-30 the Python package is installed in the venv from that wheel.

**An earlier revision said the native DLLs were "the remaining piece", needing a permanent
home and a DLL search path. That was wrong.** The wheel bundles them: they install into
`thorlabs_tsi_sdk/lib/`, all nine, correct architecture (x86_64 against a 64-bit Python —
worth checking, since the wheel ships both and a 32-bit DLL under a 64-bit interpreter fails
with an error that says nothing about architecture). There is no placement step and no PATH
work. **The wheel is the deployment.**

**The real dependency is the ThorCam driver**, which the wheel does NOT ship. Without it the
camera enumerates as a bare `TSI` device with problem code 28 (`CM_PROB_FAILED_INSTALL`) and
no driver, provider or service — and `discover_available_cameras()` returns an empty list, so
the failure looks exactly like "no camera plugged in". Installing ThorCam binds it: the device
becomes `Thorlabs Camera Zelux`, status OK, service `CYUSB3`, driver 1.2.3.14 from Thorlabs
Scientific Imaging. That is the MAST_provisioning item.

The API was confirmed by introspection on 2026-08-30 and maps onto this design directly:

| needed | `thorlabs_tsi_sdk.tl_camera` |
|---|---|
| saturation level from the camera (§5.4) | `TLCamera.bit_depth` |
| exposure-range check at open (§6) | `TLCamera.exposure_time_range_us` |
| the two settings that stay parameters | `gain` / `gain_range`, `black_level` / `black_level_range` |
| configure, expose, close | `arm`, `issue_software_trigger`, `get_pending_frame_or_null`, `image_poll_timeout_ms`, `disarm` |
| open the first enumerated device | `TLCameraSDK.discover_available_cameras`, `open_camera`, `dispose` |

### 14.1 The camera goes behind an interface

Not merely good practice — the Zelux is not on this machine, so it is the only way the rest
of the procedure can be built or tested at all:

```python
class FluxMeter(Protocol):
    def configure(self, exposure_us: int, gain: float, black_level: int) -> None: ...
    def expose(self) -> np.ndarray: ...
    @property
    def saturation_level(self) -> int: ...
    def close(self) -> None: ...
```

`ThorCam` implements it over the SDK above; a simulator implements it for tests and for
every part of §3 that does not involve light. It is the same injection argument that makes
`tests/test_spiral_search.py` work.

**Add the vendored SDK to `python.analysis.ignore`** in `mast-unit.code-workspace`, beside
`**/Standa/**` and `**/PlaneWave/**`, and exclude it in `ruff.toml`. Standa alone accounts
for 145,523 of the 145,871 pyright findings in `unit`; a second vendored SDK will behave the
same way, and workspace-wide diagnostics are now on.

One Zelux, so open the first enumerated device. A selection parameter can wait until there
is a second camera.

---

## 15. Open questions

- **Does acquisition reach 0.5″ with `skip_sky` on?** (§3) If not, this procedure fails at
  start-up rather than measuring badly — but it fails often.
- **Is ~8–16 GB per run acceptable?** (§8.2) It is now a hard requirement rather than a
  debugging convenience, so if it is not, the mesh has to shrink.
- **Should the reference be its own exposure** rather than the index-0 frame? (§5.5) One
  extra exposure buys a free read of the measurement noise floor whenever the argmax is 0.
- ~~**Do the native DLLs load?**~~ **Answered yes, 2026-09-02.** `TLCameraSDK()` constructs,
  `discover_available_cameras()` returns the camera, and a full `ThorCam` cycle — open,
  configure, two exposures, close — ran against the real hardware on its first attempt. The
  arm/disarm cycling works, which matters because a spiral does it hundreds of times.

- **The camera is a CS165MU**, serial 36555, 1440x1080, **10-bit** — so full scale is 1023 and
  a frame is ~3 MB. Its ranges, read from the camera: gain `(0, 480)`, black level `(0, 511)`,
  exposure `(64, 26843418)` us. A `seconds=5` run asks for 5,000,000 us, comfortably inside
  the last of those, but anything above ~26.8 s would be refused by the range check in
  `configure()` — which is what that check is for.

- **All three ThorCam settings are integers**, not floats. The SDK's setters are `c_int`
  throughout (`tl_camera_set_gain`, `tl_camera_set_black_level`), so a float reaches ctypes
  and raises `TypeError: int expected` rather than being rounded. `flux_gain` was typed
  `float` and would have failed inside a run for any non-integral value; fixed.
- **Does a `seconds`-length ThorCam exposure saturate on a typical target?** Gain 0 and
  black level 3 are settled, and the exposure now follows the imager's, so the one unknown
  is whether ~5 s at gain 0 clips near the peak. Nothing gates or stops it, so the cost of
  finding out is a run whose `argmax_saturated` comes back true — and the fix is to shorten
  `seconds`, which shortens the imager exposure with it.
- **How long does a step actually take?** The estimate is ~13–15 s (≥5 s settle floor, the
  exposure, and readout/save of a 94 MB frame), giving ~18 min through ring 4 and ~40 min
  through ring 6. Measure it on the first run; it sets every other budget here.

---

## 16. Provenance

- Reference-pixel behaviour: `solvers/mastrometry.py` (`roi_center_to_crpix`, spec-phase ROI
  symmetric about the fibre), `solvers/astrometry_dot_net.py` (`--crpix-x`).
- Correlation behaviour, the mirror-shadow decision, the phase-vs-plain result and the
  field-star-count predictor: the module note in `imaging/frame_shift.py`, measured over 19
  real MAST pairs across six nights.
- `cos(dec)` on the RA axis: MAST_unit#136, measured at dec +41 as 7.44″ for 10″ commanded.
- `pixel_scale_at_bin1 = 0.0`: MAST_unit#138.
- RAM-disk behaviour of the solver backends: the comment in `solving.py`, and the night of
  2026-08-04.
- Settle floor ~5 s: `wait_until_settled` with `poll=1.0s`, `stable_samples=2` and a 3 s
  grace, as recorded in `mount_stability_design.md` §6.5.
- Detector geometry: `common/asi.py` — `ASI_294MM_WIDTH = 8288`, `ASI_294MM_HEIGHT = 5644`.
- PyPI absence of the Thorlabs SDK: queried 2026-08-29.

~~**Nothing here has been implemented, and no part of it has been run against a mount, a
fibre or a camera.**~~ **Superseded 2026-09-02.** Sections 1-16 were implemented on the
`flux-metering` branches (`MAST_unit#205`, `MAST_common#97`) and run four times on mast02
(`Z:\MAST\mast02\2026-09-01\FluxMetering\0001`-`0004`). The runs were mechanical shakedowns
with `skip_acquisition: true` in a closed enclosure, so the optics half is still untested:
run `0004` reports `dx=0.75, dy=0.75` at `confidence: 0.0` with `low_confidence: true`,
which is the correlation correctly finding nothing in a starless frame. See section 17.

---

## 17. `spiral_correlate_steps` — correlating any two steps of a finished run

### 17.1 What it is, and why the run's own result is not enough

A run correlates exactly one pair: the reference frame against the arg-max frame (section
3.1), once, at the end. There is no way to ask *"what shift is there between step 3 and step
7?"* without re-running the whole spiral — which cannot be done at all for a run already on
disk, since the sky has moved.

`spiral_correlate_steps` takes two step numbers from one completed run and reports the
`dx, dy` between their imager frames, writing the answer beside the run's own products.

**Decided 2026-09-02, and each decision narrows it:**

| | |
|---|---|
| Both steps come from **one sequence** | so the run's own parameters are the only ones in play |
| **No overrides, no experiments** | the original run's parameters are used verbatim |
| An **aborted or incomplete run is refused** | a `CanonicalResponse` error, not a best-effort answer |

The deliverable is `dx, dy` between two steps. Nothing else.

### 17.2 Parameters, and why there are no dropdowns

Requested: OpenAPI dropdowns for date, sequence and the two step numbers, populated from the
shared area. **This is not achievable in FastAPI/Swagger, and a half-working version would be
worse than none.** Recorded here so it is not re-proposed:

1. A dropdown comes from an **`Enum`-typed** parameter, and enum members are fixed when the
   module is *imported*. Flux metering creates a new sequence every run, so the list is
   stale from the first run after service start — wrong precisely when it is being used.
2. Building the enum at import **couples process startup to the share being reachable**.
   `Filer` deliberately degrades to `local.root` when the share is down; an import-time enum
   has no such recovery and would bake an empty list in for the process's lifetime.
3. **Cascading is impossible.** Sequence depends on date; steps depend on sequence. OpenAPI
   has no dependent-enum concept, so three independent dropdowns would confidently offer
   combinations that do not exist. That is worse than a text box, because it looks
   authoritative.
4. FastAPI caches `app.openapi_schema` after first generation, so per-request regeneration
   needs cache-busting, and a schema mutated at request time is out of reach of the contract
   tests' static analysis.

There is no enum-dropdown precedent anywhere in the unit's API today.

**Proposed instead — not yet confirmed, and worth confirming before implementation:** two
discovery endpoints returning live data, which can carry what a dropdown never could.

```
GET  .../flux_metering/runs                        -> dates and sequence numbers on the share
GET  .../flux_metering/runs/{date}/{seq}/steps     -> per step: index, cell, ring,
                                                      offset_arcsec, flux, imager_frame
PUT  .../flux_metering/spiral_correlate_steps      -> date, seq, step_a, step_b
```

Listing steps *with their flux and cell* is the point: nobody wants to pick "step 7" from a
list of integers — they want to see that step 7 was the arg-max at cell (0,1). Defaulting
`date` and `seq` to the most recent run makes the common case genuinely "two step numbers",
which is what was asked for.

### 17.3 The prerequisite: record the values the run actually used

**This is a change to existing code and it must land before, or with, the new endpoint.**

Everything the correlation needs is already persisted — `usable_fraction` in `params`,
`fiber_x/fiber_y/fiber_source` in `result`, `reference_frame` at the top, and each step's
`cell`, `ring`, `offset_arcsec` and `imager_frame` in `steps[]` — with two exceptions, and
both are read from **live state** today:

| value | read from | why that breaks on re-correlation |
|---|---|---|
| `pixel_scale_at_bin1` | the live config (`session.py::_commanded_offset_px`) | the config may have changed since; it was `0.0` in the DB under MAST_unit#138, and `5a66745` has since constrained it |
| dec, for the `cos(dec)` RA factor | `self.unit.mount.status().dec_j2000_degs` (`session.py::_dec_degrees`) | **whatever the mount is pointing at right now** — an hour later, an unrelated part of the sky |

For the original run both are correct by construction. For a re-correlation neither is.

This matters more than it looks, because `commanded_offset_px` is **the** check on whether a
correlation means anything (section 9.1) — it is what showed run `0004` to be noise:
`[0.0, 1.91]` commanded against `[0.75, 0.75]` measured. Recomputing it from today's mount
position yields a plausible number that means nothing, which is the exact failure mode
section 5's `MIN_CONFIDENCE` history warns about.

**So `_finish` records the pixel scale and the dec it used, in the same document.** Cheap
now; impossible to reconstruct later.

**Runs already on the share (`0001`-`0004`) do not carry them.** They are not refused — they
are not aborted, merely older — but their `commanded_offset_px` is reported as `null` with a
stated reason, following the existing rule of *no check at all beats a check that always
reads zero*.

### 17.4 Refusal, and what counts as incomplete

A `CanonicalResponse` error, naming which condition failed:

- no `result.json` in the run folder
- `terminal_state` absent or `aborted` — an aborted run's steps may be inconsistent with its
  own parameters
- either step index outside `steps[]`
- a step carrying no `imager_frame`, or a frame file that is not on the share

Deliberately **not** a fallback to live configuration. That was considered and rejected with
the "no experiments" decision: a re-correlation is either faithful to the run or it is
refused.

### 17.5 The correlation itself

Reuse the primitives, as section 10 already argues. `_correlate` in `session.py` is 90% of
this and merely happens to hardcode reference-vs-arg-max; extract its core to a function
over two frames plus geometry, and let the session call it too. `measure_shift`,
`margins_from_fraction`, `max_reliable_shift` and `MIN_CONFIDENCE` are unchanged.

Two generalisations fall out of taking an arbitrary pair:

- **`expect_no_motion` when the two steps share a cell**, generalising the present
  `best.cell == (0, 0)` test. Otherwise a legitimate null measurement is flagged as
  fixed-pattern capture.
- **`commanded_offset_px` is the *difference* between the two steps' commanded offsets**,
  not one step's. That difference against the measured `dx, dy` is the whole diagnostic
  value of the endpoint.

Each step already records the single representative `imager_frame` the correlation should
read (`session.py:375`, section 5.6), so a step number is unambiguous and the multi-frame
reduction needs no exposing.

### 17.6 The product

`correlate-<step_a>-<step_b>.json`, five digits each to sort with the frames, written
**beside `result.json` in the same run folder**.

Written **directly to the share, not through `MoveGuardian` and not via the ram disk**
(contrast section 8.1): the inputs are already share-resident and the run is finished, so
there is no mover to race and nothing to protect against. Re-running a pair overwrites, and
the document records its own `created_at` and inputs so a stale copy is recognisable.

Contents: `dx`, `dy`, `confidence`, `at_origin`, `low_confidence`, `magnitude_px`,
`max_reliable_shift_px`, `beyond_limit`; both steps' `index`, `cell`, `ring`,
`offset_arcsec` and `imager_frame`; `commanded_offset_px` for the pair; the
`usable_fraction`, `fiber_x/y`, pixel scale and dec used, each with its source; and the
run's `date`, `seq` and `hostname`.

### 17.7 Contract placement

`PUT`, because it writes a file — invariant 5, state-changing routes answer PUT.
`@endpoint(tier=Tier.OPERATION)` with **no `completion=`**: it is synchronous and raises no
activity flag, so there is nothing for a caller to wait on. Bare return; the envelope is
applied at registration. Registered with the `add_api_route` helper.

It touches no hardware and reads only the share, so it must **not** be guarded on any
component being operational — it is expected to be used on a unit that is idle, or the
morning after.

### 17.8 Verification

- a synthetic run folder in `tests/fakes/`: two frames with a known injected shift, and a
  `result.json` carrying the geometry — the measured `dx, dy` recovers the injection
- **`test_a_run_without_recorded_geometry_reports_a_null_commanded_offset`** — the
  `0001`-`0004` case; asserts `null` and a stated reason, never a number
- **`test_an_aborted_run_is_refused`** and one test per refusal condition in 17.4, each
  asserting the error names the condition
- **`test_two_steps_in_the_same_cell_expect_no_motion`** — pins the generalisation
- `commanded_offset_px` is the difference of the two offsets, with `cos(dec)` applied to the
  RA axis only
- the output file name contains both step numbers and lands beside `result.json`

### 17.9 Open

- **The discovery endpoints of 17.2 need confirming** before implementation.
- **Reference-vs-step is not covered.** The parameters are two *step* numbers, and the
  reference frame is not a step. A run correlates reference-vs-arg-max only, so
  "reference against step 3" remains unavailable. A sentinel step index would cover it if
  it turns out to be wanted.
- **Cross-run correlation** — two full `(date, seq, step)` triples — is explicitly out of
  scope per the same-sequence decision, but the parameterisation stays open to it.
