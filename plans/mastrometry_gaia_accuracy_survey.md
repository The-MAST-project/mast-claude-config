# MASTrometry accuracy against Gaia (`original` vs `selective`)

Nov 22, 2026 · Arie Blumenzweig

> **Status: an offline pilot is done (24 mast02 acquisition frames, 2026-11-22). The survey harness is built (2026-11-23,
> MAST_unit PR #420, not merged) and has not yet run on a unit.**
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

The harness picks about 20 Gaia stars and runs one mastrometry acquisition on each, in whatever mode the unit is
configured for (there is no per-call override, and mast02 is on `original`: nothing in the configuration database sets
`source_selection`). The acquisition's last frame is then **re-solved offline in both modes**, and each mode's position of
the target star is compared with the star's Gaia coordinates. Only the solver differs between the modes, because they
are scored on the same frame; the acquisition itself ran in the unit's one mode. (Two acquisitions per star, one per
mode, were rejected: separate runs add seeing, altitude and slew noise that can swamp a difference of a few tenths of
an arcsec at 20 targets. Flipping the mode per target through the configuration was the alternative, and needs a
config write path.)

1. **Targets (`plan`).** 15 to 20 isolated Gaia stars, G 8 to 11 (below the saturation margin), a measured proper
   motion of at most 10 mas/yr, **no catalog star of any brightness down to G 18 within 30 arcsec**, spread over
   altitude (35 to 80 degrees) and azimuth (farthest-point sampling of 4 x 8 sky cells; star density is recorded, not
   enforced). Coordinates are Gaia's with proper motion applied to the planning time.
2. **Acquisition (`acquire`).** For each target, on the unit: `start_acquisition_and_guiding` with the Gaia position,
   unguided afterwards. A sidecar records the target, how the acquisition ended (each phase's last offset against
   tolerance), where its products are on the share, and the mount's own position. Resumable; a failing target is
   recorded and the run goes on.
3. **Both modes, offline (`solve`).** The last raw frame of the acquisition's mirror-out phase, solved in `original`
   and `selective` with `tools/source_survey.py --via-solver` (MAST_unit branch `solver-source-selection`, PR #421),
   with the pilot's selection parameters. This needs the astrometry.net indexes: run it on a unit or on mast08.
4. **Comparison (`pointing`).** The target star is the brightest source within 25 full-frame pixels of the fibre pixel,
   at its fixed-window centroid. Through each mode's solved WCS it gives a sky position; the error is that minus the
   star's Gaia position, east and north in arcsec. A mode whose fit used the target star is flagged: its error is not
   independent (`selective` fits only 22 to 30 stars). The report gives each mode's median vector and the paired
   difference over targets.
5. **Decision criterion, set before looking.** `selective` becomes the default if its error is smaller than
   `original`'s by at least two standard errors, paired over targets (not stars), on every unit tested. Otherwise it
   stays opt-in, and the units where it loses are examined first.

**What this measures.** The WCS error at the star the acquisition put on the fibre, i.e. the error at the fibre's
position, against Gaia and independently of either solver's own fit. It does not show what the fibre responds to
(the core, or the light-weighted centre): that stays open, below.

## Harness

A standalone `tools/gaia_accuracy_survey.py` in MAST_unit, one step per stage, all built 2026-11-22/23 with tests
(PR #420; none has run on a unit):

- `plan` -- the targets for a night, from the Gaia catalog share, into `targets.csv`.
- `acquire` -- one acquisition per target, with a sidecar.
- `solve` -- both modes on each target's last frame.
- `pointing` -- the target stars against Gaia, the criterion over targets, `pointing.csv`.
- `analyse` -- the pilot's held-out scoring over the whole frame, with the fixed-window centroid, per-star output,
  standard errors over frames as well as stars. It reproduced the pilot's numbers exactly. A cross-check on `pointing`,
  not part of the decision.

`solve` and `analyse` read and write the layout `tools/source_survey.py --via-solver` leaves, which is on a branch that
is not merged yet; `plan` and `analyse` need the Gaia catalog share (run on a unit or on mast-ns-control).

## Open

- **Units and nights.** Not chosen; the first run on a unit will also show whether the harness works end to end. mast02 is the best documented for acquisition frames; mast01 would need its
  acquisition-phase frames.
- **Which estimator describes the fibre?** The fixed window is chosen to match astrometry.net, not because it
  describes the fibre; only the on-sky test decides that.
- **mast02 frames 04 to 06**, where `selective` is clearly worse, and the **one-pixel offset of `original`**.
- **Saturation.** Whether a G 8 to 11 star saturates at 5 s, and how its centroid behaves, is unchecked.
- **Epoch.** The pilot used the exposure start, not mid-exposure; negligible at 5 s.
