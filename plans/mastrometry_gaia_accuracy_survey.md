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

## Ground truth and the estimator

The reference is a Gaia DR3 star's catalog position, with proper motion applied to the observation epoch. The image
position of the star is measured by a centroid estimator, so the error is *WCS(star's centroid) minus Gaia*.

**Decided 2026-11-22: the estimator is the fixed window** (`winpos`: a Gaussian-weighted centroid with one fixed width,
about the seeing), to match astrometry.net's own extractor as closely as possible. It follows the core of the star,
does not depend on brightness, and is what `selective` fits with.

astrometry.net's `image2xy` fits a Gaussian to a small patch around each peak, so it also follows the core. Measured on
3,599 stars that `original`'s fit used (24 mast02 frames, paired to our clean stars within 4 px), its positions differ
from the fixed-window ones by 0.00 arcsec overall and by **0.10 arcsec south within 1000 px of the fibre**, with a
frame-to-frame scatter of 0.04 to 0.05 arcsec.

So the estimator is *not* what makes `original` differ from `selective`. About 0.1 arcsec of `original`'s offset is the
0.1 arcsec between its extractor and the fixed window; the rest is the fit. What the fibre actually responds to
(the core, or the light-weighted centre) is still not known, and the on-sky test below is what settles it.

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

| Distance from fibre | Stars | `original` | `selective` |
| --- | --- | --- | --- |
| 0-300 px | 126 | 0.52 (0.00 E, +0.52 N) | 0.17 (-0.11, +0.13) |
| 300-500 px | 232 | 0.49 | 0.18 |
| 500-800 px | 369 | 0.46 | 0.16 |
| 800-1200 px | 811 | 0.35 | 0.01 |
| 1200-1800 px | 2,163 | 0.10 | 0.09 |

- Per frame, stars within 600 px of the fibre: `selective` is closer to Gaia in 18 of 19 frames; the one tie is frame
  04. The median per-frame offset is 0.50 arcsec for `original` and 0.19 for `selective`.
- **The gap near the fibre is about 0.35 arcsec in favour of `selective`.** About 0.1 arcsec of `original`'s
  0.52 arcsec is the mismatch between its extractor and the fixed-window scoring, leaving a gap of about 0.25 arcsec
  (0.42 against 0.17) that is the fits themselves: the SIP order, and 267 stars against 22.
- Both modes sit north of Gaia (almost no east-west offset). `original`'s 0.52 arcsec is almost exactly one binned
  pixel (0.523 arcsec); coincidence or a pixel-origin convention is **not** established.
- Whole frame, for the record: the median per-star error ties (0.45 against 0.46 arcsec), and `selective`'s 90th
  percentile is twice as bad (1.47 against 0.74), as expected of a first-order fit. Frames 04 to 06 are clearly
  worse for `selective` there; the cause is not traced.

**What the pilot does not show**
- It is star positions against Gaia, not the fibre.
- The `selective` fit and the fixed-window scoring use the same centroid. For `original` the mismatch is small and
  measured (about 0.1 arcsec near the fibre, above), so this advantage to `selective` is bounded by it.
- The 24 frames come from about 10 fields, so the standard errors, which treat stars as independent, are optimistic.
- Frames 19 to 22 have few stars (6 to 26 held out). One frame (the 2 s one) did not solve.
- One unit, mast02. **mast01 cannot be scored this way from its traverse frames**: those are mirror-in `spec` frames,
  with the shadow over the fibre, and none of their 15 to 22 clean stars lies within 2,000 px of it. Its
  acquisition-phase frames (mirror out) would have to be used.
- The pilot's scripts are scratch files, not in a repo; the output is on control
  (`~/claude-scratch/oc/gaia-pilot/{acq,m01}`) and mast08 (`C:\MAST\scratch\survey\gaia-pilot`), which are not
  durable places.

## The on-sky survey (next)

The harness picks about 20 Gaia stars, runs a mastrometry acquisition on each with `selective` sources, and compares
the resulting pointing with the star's Gaia coordinates. The same run in `original` gives the comparison.

1. **Targets (`plan`).** 15 to 20 isolated Gaia stars, G about 8 to 11 (below the saturation margin), low proper
   motion, no neighbour within 30 arcsec, spread over altitude, azimuth and star density. Coordinates are the Gaia
   position with proper motion applied to the observation epoch.
2. **Acquisition (`acquire`).** For each target, on the unit: slew to the star, then run a normal mastrometry
   acquisition with the mode under test (`selective`, and `original` as the baseline). Save the frames and a sidecar
   with the target, mode, time and the pointing the acquisition ended with.
3. **Comparison (`analyse`).** The resulting pointing (where the solved WCS puts the fibre pixel, and the acquisition's
   final correction) against the target's Gaia coordinates, in arcsec east and north, per target and mode.
4. **Decision criterion, set before looking.** `selective` becomes the default if its pointing error is smaller than
   `original`'s by at least two standard errors (over targets, not stars) on every unit tested. Otherwise it stays
   opt-in, and the units where it loses are examined first.

## Harness

A standalone `tools/gaia_accuracy_survey.py` in MAST_unit. The pilot's analysis becomes its `analyse` step first,
since it needs no telescope time:

- `analyse` (**built 2026-11-22**, `tools/gaia_accuracy_survey.py`, with its tests): the pilot's held-out scoring,
  with the fixed-window centroid, per-star output, standard errors over frames as well as stars. It reproduced the pilot's numbers exactly. It reads the layout `tools/source_survey.py
  --via-solver` leaves, which is on a branch that is not merged yet, and it needs the Gaia catalog share.
- `plan`: choose targets for a unit and a night from the Gaia catalog.
- `acquire`: on the unit, slew to each target, run the acquisition in the mode under test, and save the frames with a sidecar of target, mode, time and resulting pointing.

## Open

- **Units and nights.** Not chosen. mast02 is the best documented for acquisition frames; mast01 would need its
  acquisition-phase frames.
- **Which estimator describes the fibre?** The fixed window is chosen to match astrometry.net, not because it
  describes the fibre; only the on-sky test decides that.
- **mast02 frames 04 to 06**, where `selective` is clearly worse, and the **one-pixel offset of `original`**.
- **Epoch.** The pilot used the exposure start, not mid-exposure; negligible at 5 s.
