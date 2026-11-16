# MASTrometry source selection — design

Nov 16, 2026 · Arie Blumenzweig

> **Status: plan only — not implemented; every number is from simulation (rev. 2026-11-16).**
> Nothing in `MAST_unit` changes until the survey (Test plan, Step 0) and the residual maps
> (Step 1) have been run on real frames. The flag `solving.source_selection` defaults to `off`.
>
> **Also read:** `inhouse_guiding_design.md` §11, which asks the same questions of the
> correlation-based guider: the rejects below are meant to choose its guide stars, and the
> penumbra width measured in Step 0 serves both. The simulation scripts are in the zip attached
> to the 2026-11-16 email "MASTrometry source selection — design for testing on real frames";
> they are not in a repo yet.

## Summary

MASTrometry should solve from a source list we extract and filter ourselves, measured with a **fixed-window centroid**, instead of letting astrometry.net extract sources from the image. The centroid method matters more than any single cut. In simulation, photutils' first-moment centroid (`x_centroid`) moves the solved fibre pointing by about 0.24″ between a faint-star field and a bright-star field. A fixed-window centroid cuts that to about 0.005″.

The filter then removes the sources that bias the fit while still being matched: stars in or near the fold-mirror shadow, saturated stars, blends, stars cut off by an edge, and hot pixels. Among the rest, it prefers stars inside the low-coma disk, keeping at least 30 when the field allows.

**Scope.** Both solve phases (`sky`, mirror retracted; `spec`, mirror in, fibre-centred ROI). Out of scope: replacing astrometry.net, and building new index files. Everything below is to be checked on real frames (see Test plan); the numbers come from simulation.

## How sources reach astrometry.net today

`MastrometryDotNet._solve_in` (`src/solvers/mastrometry.py`) crops to the phase ROI, block-averages 2×2 in numpy, writes a FITS file, and runs `solve-field` on the image. astrometry.net then finds the sources itself, so none of the unit's shadow, coma or saturation knowledge reaches the solver.

- **Extraction.** The built-in image2xy fits a Gaussian to the 3×3 patch around each peak ([Lang et al. 2010](https://arxiv.org/abs/0910.2233)), so its positions follow the peak, not the first moment.
- **Ordering and uniformity.** Sources are resorted by brightness, `removelines` drops sources along rows or columns, and `--uniformize` (default 10) thins them to a spatially even subset.
- **Verification.** Stars are checked brightest first. An unmatched source counts as a distractor under a uniform term, so stray detections weaken a match but rarely break it. `--pixel-error` defaults to 1 px, which is 2 full-resolution px after binning ([solve-field man page](https://www.mankier.com/1/solve-field)).
- **Tweak.** SIP is fitted to the matched stars, order 2 by default. `mastrometry.py` keeps tweak on deliberately (see `solvers/CLAUDE.md`).

The unit already computes what a filter needs: `extract_sources` (photutils), `detect_mirror_shadow` → `ShadowModel`, and the optical-centre calibration with `low_coma_radius`.

## Findings: what degrades the solution

Damage comes from sources whose error is **systematic and small enough to still be matched** (about 1–4 px). Pure noise averages down, and wildly wrong sources are discarded as distractors. Numbers below are from simulation: ray-traced uncorrected f/3 parabola, Moffat 2″ seeing, 0.2616″/px, sky-limited noise, and an ordinary least-squares SIP fit. Model details are under Assumptions.

### 1. Coma and the centroid method

Coma pulls the centroid outward from the chief ray. A parabola's geometric coma centroid offset is C = θ/(16N²), about 0.7% of the field radius: 7 px at r = 1000 px and 35 px in the corner. A purely linear offset would be absorbed by plate scale. The problem is that the offset each estimator *measures* depends on the star.

Radial centroid offset from the chief ray, in px, for a faint star (SNR ≈ 15–45) and a bright one (SNR ≈ 500–4000):

| Field radius | First moment (photutils `x_centroid`) | Fixed window (`sep.winpos`, σ = FWHM/2.355) | Peak (image2xy-like, bin 2) |
| --- | --- | --- | --- |
| 1000 px | 5.5 → 6.9 | 4.9 → 4.9 | 4.0 → 4.0 |
| 2000 px | 6.5 → 13.9 | 6.7 → 6.6 | 5.7 → 4.7 |
| 3000 px | 6.6 → 20.8 | 7.2 → 7.4 | 6.6 → 5.1 |
| 4000 px | 11.1 → 27.6 | 7.3 → 9.4 | 5.6 → 5.1 |

The first moment has a magnitude equation of up to 17 px. The fixed window is flux-independent out to about r = 3000 px. photutils' `x_centroid_win` is **not** equivalent: it sizes its window from each source, so coma'd stars get larger windows (9.6 → 10.0 px at r = 2000, 14.6 → 18.3 px at r = 4000).

Effect on the solved fibre position, spec ROI of 4800 × 3200 px around the fibre, 60 stars, SIP order 2:

| Centroid | Scatter, whole ROI | Scatter, inside r < 1500 px | Shift between a faint and a bright field |
| --- | --- | --- | --- |
| First moment | 0.11″ | 0.04″ | 0.24″ |
| Fixed window | 0.07″ | 0.025″ | 0.005″ |
| Peak | 0.10″ | 0.06″ | 0.02″ |

The constant offset at the fibre itself does not matter. Flux metering defines `fiber_x/y` in measured-centroid space, so it absorbs that offset, as long as the same centroid method is used there and here. Per-source ellipticity is a poor coma indicator: noise alone gave e ≈ 0.2 for faint stars on axis. **Select by distance from the calibrated optical centre, not by measured ellipticity.**

### 2. Fold-mirror shadow

A star near the band sees only part of the f/3 cone. Blocking part of the pupil moves the centroid only when the image is also defocused or coma'd. The sign flips with the sign of the focus error, so the shift cannot be corrected and the star must be dropped.

| Case | Pupil blocked | Centroid shift |
| --- | --- | --- |
| Edge, in focus, on axis | up to 50% | < 0.05 px |
| Edge, 4 px defocus blur radius | 5% / 20% / 50% | 0.2 / 0.7 / 1.7 px |
| Edge, 10 px defocus blur radius | 5% / 20% / 50% | 0.6 / 1.9 / 4.5 px |
| Narrow occluder, 8–15% deep, blur radius 4 px | up to 15% | ≤ 0.6 px within r = 800 px; up to 1.4 px at r = 2000 px |

The sky step at the band edge, left over after the 50 px background mesh, adds only 0.1–0.3 px for a fixed-window centroid. It reaches about 1 px only for SNR 20 stars next to a 50%-deep edge. So a shift of several pixels points to a deep shadow combined with a focus error. Stars seen *through* the mirror in the umbra are likely displaced far more, if their light passes through the substrate.

These stars cluster near the fibre, where they hurt most. Five stars shifted 3 px moved the fibre pointing by 0.13″. A 3σ clip removed that, but at 10 such stars the clip stopped catching them (0.21″).

### 3. Other harmful sources

- **Saturated stars.** They have a flat top, and with coma the flat top sits off-centre. Precise astrometry rejects saturated reference stars outright ([Sahlmann et al. 2014](https://arxiv.org/pdf/1403.4619)).
- **Hot pixels, dust and amp glow.** `imaging/frame_shift.py` documents these on MAST frames. They are tiny, sharp sources with no catalogue match.
- **Blends and close pairs.** The centroid of a blend lies between the stars, and Gaia may resolve the pair.
- **Stars cut off by an edge** of the frame or ROI. The window is clipped, so the centroid moves inward.
- **Faint stars, SNR < ~15.** They add noise without bias, and some are noise peaks. Fixed-window scatter on axis is 0.26 px at SNR 13 and 0.09 px at SNR 45.
- **High proper motion.** The 5200 indexes are built from Gaia DR2, epoch J2015.5. A star moving 100 mas/yr has drifted 1.1″ since then. These are rare and clipping handles them.

### 4. How many stars

Noise-only error at the fibre (median) is 0.057″ with 8 stars, 0.041″ with 15, 0.032″ with 30, 0.019″ with 60 and 0.010″ with 250. The 90th percentile with 8 stars is 0.22″. SIP order 2 fits 6 terms per axis, so below about 20 matched stars use order 1.

## Design: selection pipeline

One pass per frame, at full resolution and before any binning, producing a ranked xylist plus a per-source record of why each source was kept or dropped.

1. **Background and detection.** Same as `extract_sources`: 50 px mesh, 3×3 filter, 2σ detection, 5 px minimum, on the phase ROI (`sky` ROI or the fibre-centred guiding ROI). Keep the deblending flag and the per-source segment.
2. **Measure each source.**
    - Fixed-window centroid: `sep.winpos` with σ_w = FWHM_seeing / 2.355, where FWHM_seeing is the median FWHM of stars inside the low-coma disk. One σ_w for the whole frame.
    - Flux and its error, SNR, peak value, area, and FWHM.
    - Distance r from the calibrated optical centre.
    - Shadow deficit at the source, d_shadow: read `ShadowModel.profile` at the source's coordinate across the band, s = −(x − cx) sin a + (y − cy) cos a. This is the fraction of the pupil blocked there.
    - Distance to the nearest comparable neighbour, and to the nearest ROI edge.
3. **Hard rejects.** A source is dropped if any of these holds:
    - **Shadow:** d_shadow > `max_shadow_deficit` (5%). This takes out the umbra, its leak-through ghosts and the inner penumbra. If the shadow is present but `ShadowModel` failed, drop the whole band rectangle.
    - **Saturated:** peak ≥ `sat_frac` × full scale.
    - **Too small or too sharp** (hot pixel, cosmic ray): FWHM < 0.5 × FWHM_seeing, or area < `min_area`.
    - **Blended:** deblend flag set, or a neighbour within `min_sep` whose flux is more than 10% of this source's.
    - **Truncated:** within `edge_margin` of the ROI edge, or the window's pixels touch the mask.
    - **Too faint:** SNR < `min_snr`.
    - **Bad centroid:** `winpos` flag set, or the window centroid moved more than 0.5 FWHM from the detection centroid.
4. **Rank the survivors** by expected positional error, σ² = σ_noise² + σ_coma(r)².
    - σ_noise ≈ 1.1 σ_psf / SNR (the fixed-window scatter in simulation).
    - σ_coma(r) = 0 inside `low_coma_radius`, then grows as (r − R)² / R² × `coma_px`.
5. **Select.**
    - Start with the survivors inside R = `low_coma_radius`, or the geometric low-coma disk when that is unset.
    - While fewer than `n_target` are selected, widen R in steps of 25%, up to the whole ROI.
    - Apply a grid quota (4 × 3 cells, at most `n_max`/12 per cell) so no corner dominates.
    - Cap at `n_max`, taking the lowest σ first.
6. **Decide the fit order.** Fewer than 8 selected: fail the frame with reason `too_few_sources` rather than solve from a poor list. Fewer than 20: `--tweak-order 1`. Otherwise the default of 2.
7. **Hand over to the solver.**
    - Write a FITS binary table with columns X, Y and FLUX.
    - Sort by FLUX, descending, so quads are built from the brightest good stars.
    - Convert coordinates into the binned, cropped grid with `pixel_grid` (`orig_fits → (orig_fits + (f−1)/2)/f`), so the existing coordinate surface and CRPIX handling are unchanged.
    - Run `solve-field` on the xylist with `--width`/`--height` of the binned ROI, `--uniformize 0` (we already spread the stars), and the same scale, RA/Dec, CRPIX and tweak flags as today.
8. **Fallback.** If the xylist solve fails, solve the image as today and record `selection: fallback` in the result, so the two paths can be compared.

## Parameters

Starting values, to be tuned on real frames. They belong in unit config, next to the acquisition ROIs.

| Parameter | Start value | Why |
| --- | --- | --- |
| `max_shadow_deficit` | 0.05 | 5% blocked gives 0.2–0.6 px at 4–10 px blur |
| `sat_frac` | 0.8 of full scale | margin for CMOS non-linearity near full well |
| `min_area` | 5 px | same as detection |
| `min_sep` | 3 × FWHM_seeing (≈ 23 px) | window radius plus PSF wings |
| `edge_margin` | 3 × σ_w + 5 px (≈ 15 px) | keeps the window inside the ROI |
| `min_snr` | 15 (relax to 10 when short of stars) | ≈ 0.25 px scatter at SNR 15 |
| `n_target` | 30 | 0.03″ noise-only error at the fibre |
| `n_max` | 150 | more adds little and slows verification |
| `coma_px` | 2 px | windowed bias variation seen at r ≈ 3000 px |
| grid quota | 4 × 3 cells | even coverage of the ROI |
| `--tweak-order` | 2; 1 when < 20 stars | 6 terms per axis need well over 6 stars |

## Integration into MAST_unit

- **New module `src/solvers/source_selection.py`.** It holds `select_sources(image, phase_roi, shadow: ShadowModel | None, optical_center, low_coma_radius, params) -> Selection`. `Selection` carries the kept sources (x, y, flux, σ) and every rejected source with its reason. The function is pure, with no unit or camera access, so it can be tested on saved FITS files.
- **Detection is shared with `calibration/analysis/optical_center.extract_sources`.** Add the window centroid and flags there, or call it and add them after. Do not use its `x_centroid` for astrometry.
- **Add `sep` to `requirements.txt`** for `winpos` and its flags. The alternative is a 30-line fixed-window centroid in numpy.
- **`MastrometryDotNet._solve_in`.** After crop and before binning, call `select_sources`. Write the xylist through `pixel_grid`, and pass the xylist instead of the downsampled image. Keep writing the downsampled image too: it is the fallback input and keeps `--new-fits` working.
- **Shadow input.** `spec` phase: run `detect_mirror_shadow` on the frame, or take the stored centre line for the current stage position. `sky` phase: none, because the mirror is retracted.
- **Result.** Add `selection` to `SolvingResult`: counts per reject reason, the number kept, R used, the fit order, and the xylist path. Log it in place of the current "FUTURE: image quality check" box.
- **Behind a flag.** `solving.source_selection: off | shadow_only | full`, default `off` until the test plan passes.
- **Fragile-surface rules apply** (`solvers/CLAUDE.md`). Run `solvers/tests/` by hand on a unit with the indexes, and add a test that the xylist path and the image path agree on a clean frame.

Feeding full-resolution positions without binning would remove the coordinate surface altogether. That reopens the decision recorded in `COORDINATE_SURFACE.md`, so it is listed as an open question rather than designed in.

## Test plan on real images

The goal is to measure the per-source errors directly, then confirm that the filtered list gives a steadier fibre pointing than today's image solve.

**Data set.** Take several nights on one unit, at least 20 fields per phase:

- `sky` frames with the mirror retracted, and `spec` frames with it in.
- A focus sweep of about ± 2 blur radii around best focus, with the mirror in.
- Pairs of frames of the same field with the mirror retracted and inserted.
- A dense field and a sparse field.
- Saved PHD2 guide frames from guiding runs.

**Step 0: survey the selection on frames already on the share (no new observing).**
Run the selection half of the pipeline (steps 1–3 of the design: detection, the measurements
and the hard rejects), then one survey solve of the filtered list, on `spec` and `sky` frames
that are already on the operational share, and record what it does. It is read-only on the
frames and does not touch a running unit. Two questions, and a picture per frame:

- **Is the extraction consistent?**
  - *Same image, run several times.* The result should be identical. Any difference is a bug
    (an ordering or tie-break dependence, a thread race, a parameter that is not pinned), and
    it has to be found before anything is compared across frames.
  - *Consecutive frames of one field,* which is the real test. Match the sources between
    frames and record, per source, how often it is detected, how far its position moves, and
    how often it is rejected and for which reason. A star that passes in one frame and fails in
    the next is a poor guide star, whatever its own numbers say.
- **How wide does the exclusion around the shadow have to be?** For a few different images,
  sweep the exclusion half-width across the band and record, for each width, the number of
  stars kept and the scatter of the kept stars' residuals (against the solve's own WCS, or
  against Gaia where Step 1 is done). Choose the narrowest width beyond which the residuals no
  longer depend on the distance across the band `s`. Repeat on frames at different focus, since
  the shift is predicted to change sign with focus. This sets `max_shadow_deficit` and the pad
  of the exclusion region, for this design and for the guide-star selection alike.

Also tabulate, per frame: the number of sources detected, rejected by each reason, and kept; and
how many of the kept sources fall inside `low_coma_radius` and inside the guiding ROI.

**The picture.** For every frame the survey writes an annotated image, so that a person can see
what the filter did and what the solver made of it:

- **The frame**, stretched (asinh or zscale) and shown whole, plus a zoomed crop around the
  fibre and the shadow band.
- **The mirror shadow, masked.** `ShadowModel.masks()` gives the umbra and the penumbra, which are
  drawn as two different tints over the frame, with the band's centreline
  (`centerline_endpoints()`). For the width sweep, the tested half-widths are drawn as parallel
  lines across the band and labelled. A frame where `ShadowModel.present` is false (or where the
  detection failed) is marked as such, not drawn without a band silently.
- **Two sets of ticks, in two colours** (also different shapes, so that they can be told apart
  without colour):
  1. **The filtered list**: the stars that survived the hard rejects and the selection, which
     is what is fed to the solver as the xylist.
  2. **The stars the solver used**: the field stars astrometry.net matched to its index
     (the `--corr` correspondences file, final matches after the tweak).
  A star in both sets was fed and used; one only in the first was fed and not matched (a
  distractor to the solver); one only in the second can occur only in the fallback image solve,
  where astrometry.net chose its own sources. The caption states the counts, the solver's
  match count and residual RMS, the fit order, and the frame's name and phase.
- **An optional third layer, off by default: the rejected stars,** drawn in a third colour and
  shape and labelled by the first reject reason (shadow, saturated, hot pixel, blended,
  truncated, faint, bad centroid). It shows directly which problem stars the exclusion width is
  catching, and which it lets through. Rejected stars near the band are the ones to read when
  choosing the penumbra width.
- It is a PNG saved beside the survey's table for that frame, so a set of frames can be paged
  through quickly, one picture each.

*What this needs that the unit does not have today.* `MastrometryDotNet` runs `solve-field` with
`--corr none`, `--rdls none` and `--match none`, so it keeps nothing about which stars matched.
The survey solve therefore calls `solve-field` itself (a standalone script, or a survey-only
option on the wrapper), with the same flags as `_solve_in` except `--corr <path>`, and leaves
the production path as it is. Coordinates in the correspondences file are on the solved
frame's binned and cropped grid, so they are put back onto the full-resolution frame with the
inverse of `pixel_grid` (`orig = f·binned − (f−1)/2`, plus the crop origin) before they are
drawn. `solve-field` and the index files are on the units, not necessarily where the frames are
read from, so the solve step runs where they are (not checked which machines have them).

*Where the frames are.* Each acquisition keeps its frames under its phase folder
(`.../Acquisitions/seq=...,target=.../<phase>/`, as `plotting.py` reads them). From the
`MAST_unit` change that solves twice on FCU v2 (MAST_unit#405) an acquisition holds a
`spec-mirror-out` and a `spec-mirror-in` folder, which are exactly the mirror-retracted and
mirror-inserted pairs of the same field that the data set above asks for. Acquisitions made
before that change have a single `spec` folder.

**Step 1: residual maps (the truth test).** Solve each frame with a loose, conservative selection. Project Gaia DR3 stars (propagated to the observation epoch) through the WCS, match them, and plot residuals against:

- **r from the optical centre, split by flux**, for each centroid method. Expect a magnitude equation for the first moment and none for the fixed window.
- **Distance across the shadow band (s), split by focus offset**, from the focus sweep. This sets `max_shadow_deficit` and tests whether the shift flips sign with focus.
- **Peak / full scale.** This sets `sat_frac`.
- **Nearest-neighbour distance**, which sets `min_sep`, and **SNR**, which sets `min_snr`.

**Step 2: A/B on the solve.** Solve every frame both ways: today's image solve, and the xylist solve with `full` selection. Compare:

- The fibre-pixel RA/Dec, its spread across repeated frames of one field, and the shift between dense and sparse fields.
- The solve success rate and solve time.
- The match count and the residual RMS reported by `solve-field`.
- On the `spec` path: the offset between the solved fibre position and the flux-metering maximum.

**Pass criteria (proposed).**

- [ ] The fibre-pixel spread on repeated frames drops by at least 30% against the image solve.
- [ ] The dense-vs-sparse shift is < 0.05″.
- [ ] The success rate is not lower than today's.
- [ ] With the mirror in, no star kept by the shadow cut has a residual above 1 px that correlates with s.
- [ ] Solve time stays under today's 30 s CPU limit.

The simulation scripts reproduce every number in this doc and can be pointed at the real-frame catalogues: `psf.py`, `sim_coma.py`, `sim_shadow.py`, `sim_skystep.py`, `sim_wcs.py`, `sim_wcs2.py`. They are not in a repo yet.

## Assumptions and open questions

**Simulation assumptions**

- **Optics.** An uncorrected paraboloid, as the code describes it: 61 cm, f/3, third-order coma only. If MAST has a corrector, the coma numbers shrink, but the centroid-method argument still holds.
- **Seeing and pixels.** A Moffat PSF (β = 3), 2″ FWHM, at 0.2616″/px.
- **Noise.** Sky-limited Gaussian noise at 1 per pixel; fluxes from 300 to 100,000 counts.
- **Fit.** An ordinary least-squares polynomial (SIP-like), with 3σ clipping where stated. astrometry.net's tweak may weight or reject sources differently.
- **Shadow geometry.** The real shadow geometry and depth are unknown. Synthetic tests use 15% and the `mirror_shadow.py` notes mention about 8%. An opaque edge and a narrow strip bracket the possibilities, so treat the penumbra numbers as bounds, not predictions.
- **Optical centre and fibre.** The optical centre was placed 400 px from the fibre as a placeholder. Use each unit's calibrated values.

**Open questions**

- What is the real shadow depth with the mirror in, and does the shift near the band follow focus as predicted?
- Does the mirror substrate pass any light? If it does, the umbra ghosts are displaced, which the 5% cut already excludes.
- Should we eventually feed full-resolution positions and drop the 2×2 binning (see `COORDINATE_SURFACE.md`)?
- Should `--pixel-error` tighten from 1 to 0.5 binned px once only clean centroids are passed?

**References**

- [Lang et al. 2010, Astrometry.net: blind astrometric calibration](https://arxiv.org/abs/0910.2233): verification model, distractors, image2xy centroids.
- [solve-field man page](https://www.mankier.com/1/solve-field): `--pixel-error`, sort and column options.
- [SExtractor windowed positions](https://sextractor.readthedocs.io/en/latest/PositionWin.html): windowed centroids come close to the noise limit for isolated stars.
- [Zacharias et al., URAT astrometric requirements](https://arxiv.org/pdf/astro-ph/0606193): coma produces a magnitude equation.
- [Sahlmann et al. 2014](https://arxiv.org/pdf/1403.4619): rejecting saturated reference stars.
- [Mendez et al., Cramér–Rao bound for astrometry](https://arxiv.org/abs/1407.3753): centroid precision against SNR.
- [Gaia DR2 astrometric solution](https://www.aanda.org/articles/aa/full_html/2018/08/aa32727-18/aa32727-18.html): reference epoch J2015.5.
