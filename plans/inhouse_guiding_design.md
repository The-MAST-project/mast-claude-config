# In-House Guiding — Retiring PHD2

*Design document. Companion to `calibration_orchestration.md` and the on-sky
harness plans. This describes replacing PHD2 with in-house guiding on each MAST
unit: why, the target architecture, what to port from PHD2 versus drop, and a
staged migration with config-switch fallback. Code references are to `MAST_unit`
branch `calibration` at time of writing.*

---

## 1. Context and motivation

PHD2 currently wears **four hats** on each unit, all through one class —
`PHD2Connector` in `src/phd2/phd2.py`, a singleton that implements **both**
`GuiderInterface` and `ImagerInterface`:

1. **Guider** — `guide` / `stop_capture` / `get_settling` JSON-RPC; the
   `GuideStep`, `SettleBegin/Settling/SettleDone`, `StarLost`, `StartGuiding`
   event stream.
2. **Imager** — via a **custom PHD2 fork**. `capture_single_frame` with
   `gain`/`binning`/`path`/`save`, `set_limit_frame`, and the
   `SingleFrameComplete` event are **not stock PHD2**. We carry a fork-maintenance
   burden purely to take pictures.
3. **Cooler controller** — `get_cooler_status` / `get_ccd_temperature` /
   `set_cooler_state`; FITS temperature stamping in `src/phd2/fits_header.py`.
4. **Seeing-telemetry source** — `science/sky_quality.py`
   (`SeeingQualityWhilePHD2Guiding`) is fed *only* from `GuideStep` events.

The four motivations for replacing it, each verified against the code:

- **Camera ownership.** PHD2 monopolizes the ZWO USB camera. This forces the
  disconnect/reconnect **handover dance** in `unit.py:827-841` (so a non-PHD2
  imager can share the sensor), forces the custom fork for imaging, and
  constrains anything beyond PHD2's RPC. The clearest symptom: today's guiding
  *validation* (`phd2.py:432-534`) must **stop guiding** to grab a solve frame,
  and on an out-of-tolerance result it only logs `"WHAT TO DO?"` and does nothing.
- **Per-task settings.** PHD2's binning/bpp are fixed by the profile name and a
  mismatched request is **refused** (`phd2.py:1345`). `ZWOImager` (`src/zwo.py`)
  re-applies ROI / binning / gain / format on **every** `start_exposure`, so a
  full-frame acquisition and a small guide ROI can use different settings for
  free — the point of owning the camera.
- **Keep PHD2's knowledge, not its process.** Hysteresis and lowpass guide
  algorithms, min-move dead-band, star SNR/saturation rejection, lost-star
  thresholds, settling criteria — all portable as small pure-Python policies
  (§4). None of that needs a separate 24/7 process.
- **A better mount interface.** PHD2 corrects via ASCOM pulse guiding. PWI4
  exposes `mount_offset` in **sky coordinates** (ra/dec arcsec), which — as §2
  establishes — is a strict superset of what PulseGuide does, and eliminates
  PHD2's direction-calibration dance entirely.

**Core decisions (fixed):** a **hybrid** guider — a fast centroid loop on guide
star(s) in a small ROI, plus a periodic plate-solve as independent drift
validation; **full retirement of PHD2, staged**, with `guider.method` /
`imager.imager_type` config switches as instant fallback; the **ZWO imager** as
the camera backend; **dithering is a non-goal** (the fiber feeds the
spectrograph; the existing `dither()` RPC is never called by any flow).

## 2. PulseGuide vs mount_offset — the research finding

Before committing to `mount_offset` we verified how PlaneWave's ASCOM driver
actually guides (read-only inspection of the installed `PWI4_ASCOM.dll` /
`PWI4.exe` strings, `PWI4.cfg`, the ASCOM driver logs, plus PW documentation and
the open-phd-guiding list):

- **PulseGuide does not use the HTTP API.** It travels over a **private TCP
  command channel** (port **9220** on this install), not `mount/offset`. The
  HTTP API has **no** pulse-guide endpoint at all.
- **But it writes the same offset state.** Both pulse guides and hand-paddle
  jogs feed the mount kernel's `RaJogAndPulseGuideOffsetDegs` accumulator — the
  very `mount.offsets.ra_arcsec/dec_arcsec` accumulators `pwi4_client.py` reads.
  A pulse's net effect ≈ `guide_rate × duration` added to that accumulator.
- **The guide rate is fixed** at 0.5× sidereal (~7.5″/s) on L-series mounts and
  is not adjustable through the driver.
- **`mount_offset` is a strict superset:** arbitrary magnitude (no rate ×
  duration quantization), per-axis/transverse/path channels, gradual offsets
  with `gradual_offset_progress` telemetry, and rate offsets.

**Conclusion:** in-house `/mount/offset` guiding loses nothing — PulseGuide is
just a fixed-rate, duration-encoded way of writing offset accumulators we can
write directly. **Critical corollary: PHD2 pulse-guiding and our `mount_offset`
corrections sum into the same channels, so the two guiders must NEVER run
concurrently.** `AXIS_reset`/`AXIS_stop` clears offsets regardless of origin.

*(One item remains verifiable read-only: whether PWI4 ramps the offset during a
pulse or applies it as a step — pollable via `mount.offsets.ra_arcsec.total`
during a PHD2 calibration. It only affects how faithfully a timed-rate
correction would mimic PHD2, not the decision to use `mount_offset`.)*

## 3. Target architecture

A new unit-local package `src/mast_guider/`. Only two tiny touches reach the
`common` submodule (§7); everything else is MAST_unit code.

```
ZWOImager  (owns the camera; per-exposure ROI/bin/gain)
    │ image_array (in-memory; optional background FITS save every Nth frame)
    ▼
StarTracker  (pure analysis)  ── per-frame SNR/HFD ──► SkyQuality feed
    │ pixel error (dx, dy) + star health
    ▼
PixelToSky  (rotation from the latest solve's WCS)
    │ sky error (d_ra, d_dec arcsec)
    ▼
CorrectionPolicy  (hysteresis + min-move + clamp; pure, stateful)
    │ correction (arcsec)  or  None (inside the dead-band)
    ▼
MountCorrector  (PWI4 mount_offset + Mount.wait_until_settled)
```

**Components:**

- **`MastGuider`** (`guider.py`) — implements `GuiderInterface`
  (`start_guiding`/`stop_guiding`/`status`/`is_guiding`), singleton, owns
  `UnitActivities.Guiding` and its own `api_router` per the Component pattern.
  Runs the guide loop on one thread: `start_exposure` on the guide ROI →
  `wait_for_image_ready` → `image_array` → tracker → policy → corrector → repeat
  at `cadence_seconds`. Frames captured *during* a correction+settle window are
  discarded (no measurement while the mount moves).
- **Validation, interleaved in the same loop** — every `validation.interval`,
  the loop substitutes one full-frame (or large-ROI) exposure, hands it to the
  configured solver, and (a) refreshes the pixel→sky rotation from the solve
  WCS, (b) on out-of-tolerance either applies a drift correction via the
  existing `solve_and_correct` machinery or raises an alarm
  (`validation.action`). **No stop/resume dance** — we own the camera; guiding
  merely skips a centroid cycle for the solve. This replaces today's inert
  `"WHAT TO DO?"`.
- **`StarTracker`** (`star_tracker.py`) — pure ndarray-in, measurement-out.
  Reuses `calibration/analysis/hfd.py`: `_detect` for initial star selection,
  `half_flux_diameter` (flux-weighted centroid + HFD per stamp) as the
  per-frame centroid engine on a small box around the last position. Emits
  `(dx, dy, snr, hfd, peak_adu, mass)`. Alternative estimator for rich fields:
  whole-ROI correlation shift via `science/find_shift.py` /
  `cross_corellate.py`, pluggable behind the same interface. Worked out in §11.
- **`CorrectionPolicy`** (`correction_policy.py`) — the PHD2 port (§4); pure,
  `update(error_arcsec) -> RaDec | None`.
- **`MountCorrector`** (`mount_corrector.py`) — thin adapter over `Mount` /
  `PWI4.mount_offset` + `Mount.wait_until_settled(SettleMode.OFFSET_STEP)`.
  Isolates the discrete-vs-rate choice (§5) so it can change without touching
  the loop.
- **`PixelToSky`** — the CD matrix from a plate solve gives rotation + parity +
  scale, cached at guide start and refreshed on each validation solve. This is
  what makes PHD2's **direction-calibration dance unnecessary**: we read the
  orientation from the WCS instead of learning it by pulsing.
- **`SettleMonitor`** — PHD2-style "settled = guide error < `settle.pixels` for
  `settle.seconds`, else `settle.timeout`". Drives `status()` and the **FCU-v2
  stage-to-SPEC handoff** (today buried in PHD2's `StartGuiding` handler — it
  moves to `MastGuider` on first-settle).

**Where each PHD2 hat lands:**

| Hat | Replacement |
|---|---|
| Guiding | `MastGuider` (this design) |
| Imaging | `ZWOImager` — already `ImagerInterface`-complete bar a few stubs (Stage 0) |
| Cooler | `ZWOImager` (on/off/power/temp; needs a config-driven set-point setter) + `stamp_cooling` generalized out of `src/phd2/` |
| Seeing telemetry | guide loop feeds `(snr, hfd)` per frame into `science/sky_quality.py`, which already consumes an externally-measured `hfd_pixels` |

## 4. Port from PHD2 vs drop

**PORT** (as pure policies):

- **Hysteresis guide algorithm** per axis:
  `correction = aggr × ((1−hyst)·error + hyst·weighted_history)`.
  Defaults ≈ aggressiveness 0.7, hysteresis 0.1 for both axes in v1.
- **Lowpass2** as the optional Dec algorithm (slope-fit over history) — a v2
  config option.
- **MinMove dead-band** — suppress corrections below threshold. Wire it to the
  **dead config** `guiding.min_ra/dec_correction_arcsec`, which is read into
  `unit.py:145-146` and **never applied anywhere today**.
- **Max-correction clamp** — cap any single correction (PHD2's
  MaxRaDuration/MaxDecDuration analog, in arcsec); protects the fiber from a bad
  centroid.
- **Star selection / rejection** — brightest star that is: non-saturated
  (peak < `saturation_adu`), SNR ≥ `min_snr` (PHD2 default 3.0), not within N px
  of the ROI edge, not a hot pixel (HFD > ~1.5 px), and **outside the fiber
  exclusion zone** (SpecRoi geometry from `Guider.make_guiding_settings`,
  `guiding.py:99`).
- **Lost-star detection** — SNR below threshold *or* star **mass change** beyond
  `mass_change_threshold` (PHD2 default 0.5) between frames; mass-change catches
  clouds / fiber occlusion that SNR alone misses. **v1: stop + report**; **v2:
  auto-reacquire.**
- **Settling** — the pixels / time / timeout triplet consumed before spec
  exposures.

**DROP:**

- **Direction calibration** — sky-coordinate offsets + the WCS make it moot.
- **Dithering** — never called; spectroscopy feeds fibers.
- **Multi-camera, ST-4 / on-camera guiding, dark libraries** —
  `hfd._bg_subtract` + the hot-pixel HFD guard suffice for v1.
- **Backlash compensation initially** — PWI4 direct-drive mounts should have
  negligible backlash, and the min-move dead-band prevents Dec direction-hunting
  anyway. Revisit only if on-sky Dec oscillation appears (§9).
- **Multi-star guiding** — a v2+ SNR improvement, not v1.

## 5. Correction strategy

**Default: discrete `mount_offset(ra_add_arcsec=…, dec_add_arcsec=…)` steps** —
the `ApproachMode.DISCRETE_STEP` pattern already proven in
`solve_and_correct` (`solving.py`):

- Guide corrections are sub-arcsec; measured settle for offset steps is a few
  seconds, and small steps settle fastest.
- It is **idempotent and stateless** — a rate-based correction that fails to stop
  (crash, timeout) leaves the mount drifting; a discrete step cannot.
- The research (§2) settles the design question: a PulseGuide is just a quantized
  write to the same accumulator, so nothing is lost by writing discrete offsets
  directly.

Two config knobs make it tunable without touching the loop:

- `correction.settle_mode: wait | blank_frames` — either
  `Mount.wait_until_settled(SettleMode.OFFSET_STEP)`, or (cheaper at short
  cadence) discard the next 1–2 frames as a time-based blank. The `blank_frames`
  mode **cannot deadlock**, which matters given the wind finding below.
- Settle tolerances must be **wind-realistic and sourced from `unit_conf`**.
  Measured `dist_to_target` gusts to **5.9″**, so `wait_until_settled`'s 0.5″
  default is unsatisfiable in wind (calibration already uses 10″). Closing
  `mount.py`'s existing "source tolerances from `unit_conf`" TODO is a Stage-0
  item.

Dead-band and clamp apply in PHD2 order: MinMove (revived
`min_*_correction_arcsec`) **after** hysteresis filtering, then clamp to
`max_correction_arcsec`.

## 6. Staged migration

**Key constraint:** one physical camera means the imager and guider switches
**cannot be mixed across backends**. `imager=zwo + guider=phd2` is the
contention configuration — the handover dance *is* the symptom of exactly that
coupling. So the coherent states are the two whole stacks —
`{imager=phd2, guider=phd2}` (today, with the fork) and
`{imager=zwo, guider=solving|mast}` — and each unit flips **both switches
atomically**. Fallback = flip both back + a unit restart (config is cached at
startup, so fallback is minutes, documented per stage).

- **Stage 0 — gap closing** (no behaviour change, merges behind existing config):
  `zwo.py` — implement `start_exposure_series`/`end_exposure_series`,
  `capture()`, `powerdown()`; add a **config-driven cooler set-point** (replace
  the hardcoded −5 °C/+10 °C); **preallocate one persistent frame buffer** reused
  across exposures (the commented-out `del self._image_array` is a memory-churn
  risk at guide cadence). `solving_guider.py` — move the cadence sleep **inside**
  the while loop (it free-runs today), implement `status()`, fix the parent
  activity, give the exposure series a purpose. `mount.py` — source
  `wait_until_settled` tolerances from `unit_conf`. Generalize `stamp_cooling`
  out of `src/phd2/`.
  **Exit:** new unit tests green; the existing PHD2 stack is untouched on-sky.
- **Stage 1 — ZWO-owned stack baseline** (`imager=zwo, guider=solving`): flip one
  unit to the already-legal `zwo + solving` stack. Proves ZWO camera ownership
  end-to-end (acquisition, autofocus, guiding frames, FITS pipeline) and **kills
  the handover dance** in that configuration, before any new guiding code exists.
  Make the handover dance in `unit.py:827-841` conditional on
  `imager_type == phd2`. The (slow, solve-per-correction) `SolvingGuider` is the
  interim guider and the permanent post-PHD2 fallback.
  **Exit:** N nights of acquisition → guiding → spec handoff, drift within
  `guiding.tolerance`, no USB resets, complete FITS headers; PHD2 fallback
  verified once deliberately.
- **Stage 2 — MastGuider** (`guider.method=mast`): the new `src/mast_guider/`
  package. `common` gains `GuiderTypes.Mast = "mast"` and optional-with-defaults
  `GuidingConfig` algorithm/star/settle/validation fields (§7). Star-loss **v1:
  stop + report**.
  **Exit:** guiding RMS ≤ the PHD2-era baseline over M nights on one unit; settle
  → spec handoff works; a deliberate star-loss (cap the cover) stops cleanly with
  an alarm; `SolvingGuider` fallback verified.
- **Stage 3 — full parity:** feed `sky_quality` from the guide loop (rename
  `SeeingQualityWhilePHD2Guiding`); activate validation **drift correction**
  (`validation.action=correct`); star-loss **v2: auto-reacquire**; move the
  FCU-v2 handoff and validation-timer ownership fully out of `src/phd2/phd2.py`.
  Roll out to remaining units one at a time with the Stage 1+2 checklist.
- **Stage 4 — decommission:** remove PHD2 from configs; delete the handover dance;
  retire `src/phd2/`; remove `GuiderTypes.Phd2` / `ImagerTypes.Phd2` from
  `common` (4-repo sync); stop maintaining the custom PHD2 fork.

## 7. Config and interfaces

**`common` (submodule — keep minimal, all new fields optional with defaults):**

- `interfaces/guiding.py`: `GuiderTypes.Mast = "mast"`. `GuiderInterface` is
  already sufficient.
- `config/unit.py` `GuidingConfig` additions (nested models with defaults):
  `algorithm` (ra/dec aggressiveness + hysteresis, `max_correction_arcsec`,
  `settle_mode`), `star` (`min_snr`, `saturation_adu`, `mass_change_threshold`,
  `search_box_pixels`, `estimator`), `settle` (`pixels`, `seconds`, `timeout`),
  `validation` (`interval_seconds`, `action`, `full_frame`). The existing
  `min_*_correction_arcsec`, `tolerance`, `cadence_seconds`, `rois`,
  `exposure/binning/gain` are reused. **Nothing else** in `common`.

Config lives in MongoDB (`common` entry + per-unit deltas); a switch needs a unit
restart. **Development on the `mast_guiding` branch** of MAST_unit, with a
matching `mast_guiding` branch of MAST_common for the two submodule touches —
independent of the `calibration` branch, merging on its own on-sky evidence.

## 8. Testing strategy

Follows the `calibration` test patterns (pure pytest, synthetic data, no
hardware):

- **`test_correction_policy.py`** — step/ramp/noise error sequences → assert
  hysteresis convergence, dead-band suppression, clamping, no overshoot on sign
  reversal. Property: output magnitude never exceeds the clamp.
- **`test_star_tracker.py`** — synthetic Gaussian stars on noise with programmed
  drift → centroid tracks within tolerance; saturation / low-SNR / hot-pixel
  rejection; mass-change loss detection fires at the ported thresholds.
- **`test_pixel_to_sky.py`** — real solved WCS headers at several
  rotations/parities → known pixel offsets map to known ra/dec arcsec.
- **Replay harness** — a fixture directory of saved guide-ROI FITS series (the
  background-save path yields these for free) run through tracker+policy offline;
  the regression harness for tuning.
- **Mock-mount closed-loop test** — `MountCorrector` against a fake PWI4 that
  integrates offsets into simulated drift → whole-loop convergence without
  hardware.
- **On-sky commissioning checklist per stage** — patterned after the
  `on-sky-*-harness.md` docs; each stage's exit criteria as an executable
  checklist with recorded metrics (RMS, settle times, USB error counts, solve
  latencies).

## 9. Risks and mitigations

- **USB stability under continuous ROI streaming** at guide cadence: persistent
  preallocated buffer (Stage 0), explicit USB-bandwidth setting, a watchdog that
  detects a stalled `wait_for_image_ready` and reconnects the camera, error
  counters in status.
- **Single-camera contention** — MAST units use the *same* camera for
  acquisition and guiding; the fiber feeds the spectrograph, so during spec
  integration the camera is free to guide (the operating model). Validation
  full-frames pause centroid guiding for exposure+solve; mitigate with short
  validation exposures, the RAM-disk-indexed solver (~few s), and suppressing
  *corrections* (not measurements) during the gap. If solve latency exceeds
  budget, fall back to large-ROI (not full-frame) validation.
- **Wind vs settle** — 5.9″ gusts make 0.5″ settle unsatisfiable; guide-loop
  settle must use wind-realistic tolerances from config, or the `blank_frames`
  mode which cannot deadlock.
- **Dec oscillation / backlash** — assumed negligible (direct drive); min-move
  is the first defense; port PHD2's resist-switch as a fast-follow if Dec hunts.
- **Telemetry gap** — sky-quality goes dark between Stage 2 and Stage 3 on a
  converted unit; bounded and acceptable, but stated so consumers aren't
  surprised.
- **Config-flip fallback needs a restart** — minutes, not seconds; documented.
- **`common` submodule sync** — the two small changes propagate to
  MAST_control/spec/gui per the established convention; scheduled with Stages 2
  and 4.
- **Save-thread churn** — a thread per FITS save at guide cadence; save only
  every Nth frame (or on anomaly) and reuse the save thread.

## 10. Open questions

1. **PulseGuide ramp shape** — step vs ramp during a pulse (§2); read-only
   verifiable, informs a timed-rate `MountCorrector` variant only.
2. **Guide-star geometry vs the fiber** — exclusion-zone radius around the
   SpecRoi; is a star *near* the fiber preferred (differential flexure) or is the
   field edge fine?
3. **Cadence and exposure targets** — 1 s vs 3 s loop; guide-ROI exposure vs star
   brightness at MAST fields.
4. **Seeing-telemetry consumers** — who reads sky-quality downstream (control?
   GUI?); affects the rename timing and payload compatibility.
5. **Mount backlash reality** on the deployed PlaneWave mounts — confirm the
   no-backlash assumption.
6. **Multi-star guiding** as v2 — in or out of the roadmap.

---

## 11. Guiding on a fixed star set chosen from the reference frame

*Added 2026-11-16 from a design discussion. Direction agreed; the estimator is not decided.
Companion to `mastrometry_source_selection_design.md`, whose rejects choose the stars.*

§3 designs `StarTracker` as a centroid tracker on one star and mentions correlation over the
whole ROI as an alternative. This section records the reasoning for tracking **several stars**
and what has to be measured before building it.

### 11.1 Direction

- **Choose the guide stars once, from the reference frame, and track those.** The reference is
  the frame taken with the fold mirror at SPEC: on FCU v2 the solve of the `spec-mirror-in`
  phase (MAST_unit#405), whose frame is the one held as `unit.reference_image`. The mirror
  has to be in because a mirror-induced shift cannot be told from a pointing change (D14 of
  `fold-mirror-handover-design.md`).
- **Do not re-select every frame.** Seeing changes how many stars pass the SNR cut, so a
  re-selected set makes the estimate jump as stars enter and leave. A fixed set is weighted
  smoothly instead: a fading star counts less and a lost one drops out.

### 11.2 Why several stars, and why it is differential

- Guiding measures the **change** since a reference taken in the same optical configuration. A
  star's coma offset and centroid bias are the same in the reference and in every later frame,
  so they cancel. That is why the fixed-window-versus-first-moment result of the source-selection
  design matters for absolute astrometry and much less here, provided the **same estimator** is
  used on the reference and on every frame. What does not cancel is how the bias changes when
  seeing or focus changes; that is second-order.
- Many stars average the noise down: from the simulation, 0.057 arcsec with 8 stars against
  0.019 arcsec with 60 at the fibre.
- **The spread of the per-star displacements is a health signal.** With one star a cloud and a
  drift look alike. With 10 to 30 stars the scatter rises when clouds or seeing degrade the
  measurement, and the loop can stop correcting. It feeds `lock_validity` and `sky_quality`.

### 11.3 Clouds and seeing

| Condition | Effect | Handled by |
| --- | --- | --- |
| Uniform thin cloud | SNR falls, positions do not move | SNR weights |
| Patchy cloud | stars fade unevenly | a robust (weighted median or clipped) combination over per-star displacements |
| Bright, cloud-lit background | structure that a whole-frame correlation can lock onto | background removal, or per-star stamps instead of the frame |
| Seeing changes | peak broadens, not shifts; fewer stars pass SNR | a fixed star set, smooth weights |
| Seeing-induced image motion | real, correlated across the field | the loop follows it, at low bandwidth |

### 11.4 What to take from the source-selection design

- **Take:** the hard rejects, applied once to the reference to choose the set: shadow deficit,
  saturation, hot pixels, blends, edge truncation, SNR. A star that saturates when seeing
  improves, a blend whose separation changes with seeing, or a star near the shadow whose shift
  flips with focus is a bad guide star. Also the fibre exclusion zone (§4) and an edge margin,
  because the mount drifts and stars leave the box.
- **Skip:** ranking by `coma_px` and widening the radius to reach 30 stars. That is tuned to
  absolute astrometry. For guiding take whatever clean stars the ROI has.

### 11.5 Two forms of "correlation"

- **Whole-frame correlation** (what `science/cross_corellate.py` does, with
  `skimage.registration.phase_cross_correlation`): least code and no star list. It needs the
  shadow masked and the background removed, it weights bright stars, and a cloud hurts it most.
- **Per-star stamp matching against the reference stamps**, combined robustly: more code, and
  it gives the scatter diagnostic and the cloud robustness above. **Preferred;** not decided.

Both would sit behind the `StarTracker` interface. `cross_corellate.py` today is a script with
hard-coded paths, not a module.

### 11.6 Risks

1. **How many clean stars the guide ROI has.** It is small, centred on the fibre, and the shadow
   and the fibre exclusion cut into it. With only 3 to 5 usable stars the multi-star advantage
   mostly goes, and the scatter is not reliable. Measure this first (11.7).
2. **Rotation and scale over hours.** A fixed reference goes stale through differential
   refraction and flexure. Fit translation only at first and check the residual; re-reference from
   the validation solves of §3.
3. **Lever arm to the fibre.** The target is in the fibre, not at the guide stars. Rotation of
   the field acts on the offset between them. A translation-only fit ignores it.
4. **Frame cadence against star SNR.** The guide exposure has to be long enough for the chosen
   stars to be well above the noise; unmeasured (also open question 3).

### 11.7 First step: a survey on frames already on the share

Before any guider code, run the selection on frames that are already on the operational
share, with one survey solve of the filtered list per frame. This is Step 0 of the test plan in
`mastrometry_source_selection_design.md`; its two questions are the ones this section needs
answered:

- **Consistency.** The same image run several times (it should be identical; a difference is a
  bug), and consecutive frames of one field, matching sources between them. A star that passes in
  one frame and fails in the next is a poor guide star.
- **Penumbra width.** For several images, the exclusion half-width across the shadow band beyond
  which the kept stars' residuals stop depending on the distance across the band; repeated at
  different focus. That width is the exclusion of guide-star selection too.

It also answers risk 1: the number of stars kept per frame, and inside the guiding ROI.

The survey writes one annotated image per frame: the frame with the mirror shadow masked
(umbra and penumbra), and two sets of ticks in two colours, the filtered list that is fed to
the solver and the stars the solver actually matched (details in Step 0 of the other document).
The same picture shows which stars would make good guide stars and which the solver itself
distrusted. An optional layer shows the stars the hard rejects dropped, labelled by reason.

### 11.8 Open questions

1. Whole-frame correlation or per-star stamps (11.5).
2. The combination rule: weighted median, or a clipped weighted mean, and the weights.
3. Translation only, or translation plus rotation (11.6).
4. When to re-reference during a long guiding run.
5. What the loop does when too few stars remain, or the scatter is too high: hold corrections
   (this fits v1 "stop and report" of §4), and when to give up.

---

*Provenance: research and design 2026-07-21 (mast02). PulseGuide findings from
read-only inspection of the local PW ASCOM driver + PWI4, PW's HTTP API
document, the PWI4 CHANGELOG, and the open-phd-guiding list. Code references to
`MAST_unit` branch `calibration`.*

*§11 added 2026-11-16 from a design discussion of guiding on stars chosen from the reference frame; it draws on `mastrometry_source_selection_design.md` and `fold-mirror-handover-design.md`.*
