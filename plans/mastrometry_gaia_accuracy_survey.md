# MASTrometry accuracy against Gaia (`original` vs `selective`)

Nov 22, 2026 · Arie Blumenzweig

> **Status: an offline pilot is done (24 mast02 acquisition frames, 2026-11-22); the on-sky survey is not started.**
> Companion to `mastrometry_source_selection_design.md` (the stages compared) and
> `MAST_unit/docs/mastrometry_stages.md` (the earlier offline results). `shadowed` is not part of this comparison.

## Question

Does `solving.source_selection.mode = selective` put the solved position at the fibre closer to the truth than
`original`? **Only the fibre and its close neighbourhood matter** (decided 2026-11-22): accuracy over the whole frame is
not a goal, and `selective` is a first-order fit, so it is expected to be worse far from the fibre. The measurement
is for the **acquisition phase**, where the fold mirror is out of the frame and star positions near the fibre can be
measured. With the mirror in, the target on the fibre is always inside the mirror's shadow (see
`inhouse_guiding_design.md` 11.4), which is a different measurement.

## Ground truth and its limit

The reference is a Gaia DR3 star's catalog position, with proper motion applied to the observation epoch. The image
position of the star is measured by a centroid estimator, so the error is *WCS(star's centroid) minus Gaia*. Two
estimators give different positions for the same star:

- **Fixed-window** (`winpos`: a Gaussian-weighted centroid with one fixed width, about the seeing). It follows the
  core of the star and does not depend on brightness. It is also what `selective` fits with.
- **First moment** (the intensity-weighted mean over the detected pixels). It includes the wings and a coma tail, and its
  size depends on the star's brightness.

Near the fibre on mast02 they differ by about 0.3 arcsec, along +Dec. That is as large as the difference between the
modes. **So a star's centroid is not an absolute truth for the fibre**: the fibre collects the light in its aperture,
and which estimator describes that is not known. The on-sky test below is what settles it.

## The pilot (done)

**Method.** For each of 24 mast02 acquisition frames (the first `spec` frame of each production acquisition,
2026-11-17 and 11-18, 5 s, fibre pixel (4050, 2439)):

1. Solve with the real `MastrometryDotNet` on mast08, in `original` and `selective`
   (`tools/source_survey.py --via-solver`). Each mode leaves a solved FITS (SIP WCS on the 2x2-binned grid) and a
   `.corr` file listing the stars its fit used.
2. Take the clean stars (`kept` or `spare`) from the selection pass. Drop every star within 1.5 binned pixels of a star either fit used, so
   no mode is scored on a star it fitted (**held-out stars**).
3. Match them to Gaia DR3 (catsHTM on control, G to 18, proper motion from 2016.0 to the exposure start), on the mean of
   the two WCS positions so neither mode is favoured. A match needs exactly one Gaia star within 4 arcsec, the
   nearest within 2.5 arcsec, and G of 16.5 or brighter.
4. The error is WCS sky position minus Gaia, in arcsec east and north. The metric is the **median error vector of
   the held-out stars within a given distance of the fibre pixel**: a systematic offset.

**Results, offset in arcsec (median vector's length), stars pooled over 19 to 20 frames, standard error about 0.02:**

| Distance from fibre | Stars | `original`, fixed-window | `selective`, fixed-window | `original`, first moment | `selective`, first moment |
| --- | --- | --- | --- | --- | --- |
| 0-300 px | 126 | 0.52 (0.00 E, +0.52 N) | 0.17 (-0.11, +0.13) | 0.83 | 0.46 |
| 300-500 px | 232 | 0.49 | 0.18 | 0.79 | 0.49 |
| 500-800 px | 369 | 0.46 | 0.16 | 0.66 | 0.36 |
| 800-1200 px | 811 | 0.35 | 0.01 | 0.53 | 0.19 |
| 1200-1800 px | 2,163 | 0.10 | 0.09 | 0.25 | 0.07 |

- Per frame, stars within 600 px of the fibre: `selective` is closer to Gaia in 18 of 19 frames (fixed-window) and
  20 of 20 (first moment). The one tie is frame 04. The median per-frame offset is 0.50 against 0.19 arcsec
  (fixed-window) and 0.81 against 0.44 (first moment).
- **The gap, about 0.35 arcsec in favour of `selective`, holds with both estimators.** The absolute offsets do not.
- Both modes sit north of Gaia (almost no east-west offset). `original`'s 0.52 arcsec is almost exactly one binned
  pixel (0.523 arcsec); coincidence or a pixel-origin convention is **not** established.
- Whole frame, for the record: the median per-star error ties (0.45 against 0.46 arcsec), and `selective`'s 90th
  percentile is twice as bad (1.47 against 0.74), as expected of a first-order fit. Frames 04 to 06 are clearly
  worse for `selective` there; the cause is not traced.

**What the pilot does not show**
- It is star positions against Gaia, not the fibre.
- The `selective` fit and the fixed-window scoring use the same centroid, so a centroid bias cancels for `selective`
  and not for `original`. The first-moment run only partly answers this.
- The 24 frames come from about 10 fields, so the standard errors, which treat stars as independent, are optimistic.
- Frames 19 to 22 have few stars (6 to 26 held out). One frame (the 2 s one) did not solve.
- One unit, mast02. **mast01 cannot be scored this way from its traverse frames**: those are mirror-in `spec` frames,
  with the shadow over the fibre, and none of their 15 to 22 clean stars lies within 2,000 px of it. Its
  acquisition-phase frames (mirror out) would have to be used.
- The pilot's scripts are scratch files, not in a repo; the output is on control
  (`~/claude-scratch/oc/gaia-pilot/{acq,m01}`) and mast08 (`C:\MAST\scratch\survey\gaia-pilot`), which are not
  durable places.

## The on-sky survey (next)

The one measurement that resolves the estimator question: put a Gaia star on the fibre and measure how its light
couples, against where the solved WCS says the fibre is.

1. **Targets.** 15 to 20 isolated Gaia stars, G about 8 to 11 (below the saturation margin), low proper motion, no
   neighbour within 30 arcsec, spread over altitude, azimuth and star density.
2. **Frames.** For each target, the acquisition-phase frame (mirror out) solved in both modes, then the star
   positioned on the fibre by a small grid of mount offsets about the solved position. The throughput through the
   fibre (the spectrograph's flux, or the guider's) against offset gives where the fibre's response peaks, to compare
   with each mode's WCS-predicted position.
3. **Both modes on the same frames**, offline, so only the solver differs.
4. **Decision criterion, set before looking.** `selective` becomes the default if its offset at the fibre (the
   median vector within 500 px, with the fibre-response position as the truth) is smaller than `original`'s by at
   least two standard errors on every unit tested, **with both centroid estimators**. Otherwise it stays opt-in, and the
   units where it loses are examined first.

## Harness

A standalone `tools/gaia_accuracy_survey.py` in MAST_unit. The pilot's analysis becomes its `analyse` step first,
since it needs no telescope time:

- `analyse`: the pilot's held-out scoring, with the centroid estimator chosen by a flag and per-star output.
- `plan`: choose targets for a unit and a night from the Gaia catalog.
- `acquire`: on the unit, slew, offset, expose, and save frames with a sidecar of target, offset and time.

## Open

- **Units and nights.** Not chosen. mast02 is the best documented for acquisition frames; mast01 would need its
  acquisition-phase frames.
- **Which estimator describes the fibre?** Only the on-sky test decides.
- **mast02 frames 04 to 06**, where `selective` is clearly worse, and the **one-pixel offset of `original`**.
- **Epoch.** The pilot used the exposure start, not mid-exposure; negligible at 5 s.
