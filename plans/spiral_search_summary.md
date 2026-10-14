# Spiral Search — Commissioning Summary

*Companion to MAST_unit PR #117 (the implementation).  This document is the
**commissioning summary**: what the spiral frame-shift measurement is for, what it was
measured to do on sky on the night of 2026-08-13 at Neot Smadar (unit **mast00**), and --
at least as importantly -- what it was **not** measured to do.*

**Scope warning, up front:** one night, one field, one declination, one unit.  Every number
below is a single-night measurement.  The `cos(dec)` result in particular is derived from a
single pointing, and the drift's *cause* is unresolved.

---

## 1. Motivation

The spiral search steps the mount through a spiral while the operator watches for the target
to reach the fibre.  `measure_shift` answers a different question from "did we find it": it
reports **how far the sky actually moved** between the reference frame and the final one, in
pixels, so an operator can tell a real acquisition from a mount that did not go where it was
told.

The measurement is a plain (not phase-normalised) cross-correlation of two background-
subtracted crops, `skimage.registration.phase_cross_correlation(..., normalization=None)`.
Phase normalisation whitens the spectrum and amplifies fixed-pattern detector content, which
is precisely the failure mode here; using the plain correlation is the primary defence
against it, not `confidence` or `at_origin`.

## 2. Sessions

All on a Cygnus field (20h58m +41d16m), 3 s exposures, binning 1, `Spirals/NNNN` on the
share.

| session | steps | window | elapsed | shift | notes |
|---|---|---|---|---|---|
| 0001 | 1" x 3 | 1406x958 | 438 s | 18.1 px | operator-paced; **6 min idle** between reference and first step |
| 0002 | 10" x 2 | full frame | 70 s | 46.2 px | 101 stars |
| 0003 | -- | -- | -- | -- | left open by hand; **silently aborted** when 0004 started |
| 0004 | 10" x 5 | full frame | 109 s | 27.2 px | intermediates saved; over-determined fit |
| 0005 | 10" x 5 | 1406x958 | 96 s | 28.0 px | **folding mirror in the beam** |

**Ground truth throughout is star-matched, not the correlation's own output**: `DAOStarFinder`
detections cross-matched between the two frames, then a least-squares similarity fit
(rotation + translation) evaluated at the crop centre.  This is independent of the
correlation and is what every accuracy claim below is measured against.

## 3. Measured performance

### Accuracy -- the solid result

| session | window | shift | **error vs star truth** | confidence |
|---|---|---|---|---|
| 0002 | full frame | 46 px | **0.42 px** | 0.9894 |
| 0004 | full frame | 27 px | 0.82 px | 0.9803 |
| 0005 | **mirror in** | 28 px | **0.46 px** | 0.9539 |
| 0001 | 1406x958 | 18 px | 1.3 px | 0.9819 |

Sub-pixel on every well-populated field.  0001 is the outlier and the reason is understood:
67 stars against 0002's 101, and its measurement was dominated by drift over the idle gap
rather than by the commanded 1".

### At the operational scale (1" steps = 3.8 px)

**Better, not worse.**  Real sub-2 px pairs -- the zero-motion legs, where only drift moved
the sky -- measured to **0.14 px** and **0.32 px**, at or below the star-fit's own ~0.3 px
standard error.  A controlled sweep on real frames (two frames with independent noise,
registered together then displaced by a known amount) recovered imposed shifts of 0.5, 1, 2,
3.8 and 8 px **exactly**.

The error floor *shrinks* as the shift shrinks: the frames overlap more completely, so there
is less differential field motion to disagree about.  An earlier prediction that the floor
would be constant -- making 1" relatively worse -- was wrong.

### The folding mirror does not matter

Its shadow is visible in the raw data as a broad ~10% depression around column 3600, absent
from clear-beam frames.  It never reaches the correlation: `_bg_subtract`'s 64-px background
model absorbs it, exactly as `frame_shift.py`'s module note argued from a *simulated* band.
The claim now holds on real frames.

The zero-shift ("fixed-pattern") confidence **fell** rather than rose -- 0.0675 with the
mirror, against 0.033 and 0.112 clear-beam at comparable shifts -- and the separation between
the correct answer and the zero-shift answer was unchanged (0.886 vs 0.880).  A prediction
that the shadow would raise that floor and make an `at_origin` tolerance mandatory was
wrong.

## 4. The confidence metric goes blind at operational scale -- IMPORTANT

`_confidence` is a Pearson correlation between the frames after the measured shift is undone.
It answers *"do these frames match at the shift I found"*, not *"is the shift right"*.

The gap between the correct answer and the zero-shift answer collapses with shift magnitude:

| true shift | conf at answer | conf at zero-shift | **separation** |
|---|---|---|---|
| 0.78 px | 0.9830 | 0.9786 | **0.0044** |
| 1.86 px | 0.9934 | 0.9793 | **0.0141** |
| 30.06 px | 0.9734 | 0.0330 | 0.9404 |
| 45.76 px | 0.9925 | 0.1123 | 0.8802 |

**So at 1" steps you get an accurate number that its own quality metric cannot confirm.**
The reason is physical, not a coding error: these frames carry saturated stars whose profiles
are tens of pixels wide, so at a small misalignment the bright stars still overlap and the
correlation stays high.  Small shifts are the spiral's normal operating point, which is
exactly where the metric is weakest.

Two consequences:

- `MIN_CONFIDENCE = 0.10` provides no protection there.  The **zero-shift answer clears it in
  every session measured** -- 0.1022, 0.1390, and **0.7366** at a 16.7 px shift, which would
  read as a confident, healthy measurement.
- `at_origin` is the only remaining guard, and it is `shift_x == 0.0 and shift_y == 0.0` --
  exact float equality on a value quantised to 0.01 px by `upsample_factor=100`.  A
  fixed-pattern peak at (0.01, 0.00) passes both checks.

### This is the same mistake as the two-HFD-scales error -- see `focuser_calibration_summary.md`

`MIN_CONFIDENCE` was calibrated against star-matched truth on **18 acquisition pairs**, where
correct answers score as low as 0.144.  It is applied **only** to spiral pairs, where correct
answers score ~0.98.  A threshold referenced to the wrong population, exactly as
`max_best_hfd_px=12` was set from the single-frame HFD scale and applied to the cross-matched
one, where it would have rejected the correct solution.

**Two instances of one failure mode in two campaigns.**  The general lesson: when a threshold
is calibrated on one population and applied to another, the number is meaningless even when
the code is right, and nothing in the test suite will say so.

The fix that survives at small shifts is to stop using a fixed constant: **compare each
measurement against its own zero-shift confidence**, computable from the same two frames.
The *gap* stays diagnostic where the absolute value does not, and it adapts to shift
magnitude, star brightness and the mirror shadow automatically.  (MAST_unit#139.)

## 5. The spiral does not move where you would think

**PWI4's `x_step_arcsec` is in RA coordinate arcsec, so sky motion is `x_step x cos(dec)`.**
The `y` (Dec) step is true arcsec.  At dec +41.16 a 10" x-step moves the field 7.44".

Evidence, from an over-determined fit of six legs (five commanded plus one zero-motion),
rank 6/6, per-leg residuals 1.0-2.9 px:

| | value |
|---|---|
| singular values of the fitted mount->image transform | 3.8604, 2.9289 px/arcsec |
| **ratio** | **0.7587** |
| `cos(dec = 41.157)` | **0.7529** |
| ratio a similarity transform would give | 1.0 |

Corroborated per-leg without any fitting (session 0002): the x-leg moved 7.44" for 10"
commanded (ratio 0.744), the y-leg 9.76" (0.976).  The two axes are **orthogonal to 0.36
degrees**, so this is a clean rotation, not skew or a bad fit.  The alt/az reading is
excluded: the mount was at alt 54.47, so `cos(alt) = 0.581`, nowhere near 0.744.

**Consequence:** the search pattern is not square on sky and its shape depends on
declination.  At +41 the x steps are 25% short; at +70 they would be 66% short.  Coverage
degrades silently toward the pole.  (MAST_unit#136.)

**Not established:** this is inferred from the mount's behaviour, not from PlaneWave's
documentation, and from a single declination.  Worth confirming against the PWI4 HTTP API
reference, since the same question applies to any other PWI4 offset taking an "x" in arcsec.

## 6. Drift bounds the session

**0.48 arcsec/min**, from the over-determined fit -- consistent with the ~0.53 arcsec/min
implied independently by session 0001's seven-minute baseline.

At 1" steps that is 2.1-3.4 px over a 70-110 s session, against a net commanded signal of
only 4-8 px.  **30-55% of the signal.**  Session 0001 spent six of its seven minutes idle
between the reference frame and the first step, and its measurement was consequently
dominated by drift rather than by the commanded 1".

The reference frame therefore has a **short shelf life**.  Measuring consecutive
intermediates instead of reference-to-final removes it: a 12 s leg accumulates 0.1 px.

### Cause unresolved

Decomposed into mount coordinates the drift is **+0.447"/min in RA and +0.142"/min in Dec --
95% RA**.  Polar misalignment is characteristically a *declination* drift (it is the whole
basis of the drift-alignment method), so the direction argues against it being dominant, even
though the magnitude fits: attributing all of it to polar error gives `rho ~ 1.8 arcmin`,
which is a plausible "not optimally aligned" value.

RA-dominant drift fits a tracking-rate error (0.447"/min is 0.05% of sidereal) or refraction
(at alt 54.5, `dR/dz ~ 1.5"/deg` and a rising target changes altitude ~0.2 deg/min, giving
~0.3"/min -- the same order, and not a mount defect at all).

**One pointing cannot separate these.**  Polar error's drift direction depends on hour angle
and declination.  The clean test is drift measured at three or four positions spread in HA
and Dec: polar error varies with position predictably, rate error stays constant in RA,
refraction scales with altitude.  Two frames per position and the star-matching above is
enough -- no spiral needed.

PWI4 reports `mount.geometry=1` (equatorial), model `DefaultModel.pxp`, 50 points enabled,
RMS 5.43".

## 7. The correlation window barely matters

Tested properly by re-measuring the **same saved frames** with only the window varying --
which holds sky, drift and ground truth fixed in a way no pair of on-sky sessions can:

| session | window | error vs truth | confidence | time |
|---|---|---|---|---|
| 0002 | margins 0 (full sensor) | 0.43 px | 0.9894 | 28 s |
| 0002 | `usable_fraction=0.66` | 0.47 px | 0.9933 | 13 s |
| 0004 | margins 0 | 0.82 px | 0.9803 | 27 s |
| 0004 | `usable_fraction=0.66` | 0.88 px | 0.9826 | 13 s |

**No measurable accuracy difference** -- the gaps are 0.04 and 0.06 px against a ground truth
with ~0.3 px standard error.  What is consistent: trimming **halves the runtime** (28 s ->
13 s) and slightly *raises* confidence, so the coma rationale for the default margins is real
and visible in match quality, it just does not reach the answer.  A 2.2x change in correlated
area moves the measured shift by 0.06 px, which is a useful robustness property in itself.

## 8. Known issues and gotchas

- **`guiding.rois[fcu_v2]` margins are 0** on mast00, with a valid centre.  A configured 0
  cannot be distinguished from a field nobody set, so the config branch of the precedence
  chain correlates the whole sensor -- costing ~15 s per measurement.  (MAST_unit#137.)
- **float32 overflow** in skimage's `_compute_error` at full-frame windows.  Harmless: it is
  confined to the `error` return, computed after the shift is final and discarded in favour
  of our own `confidence`.  Silenced at the call site rather than fixed by promoting to
  float64, which would double the working set on a 43-megapixel frame for a number we throw
  away.
- **`imager.pixel_scale_at_bin1` is 0.0** on mast00, and `autofocusing.py` consumes it.
  Measured on sky here as **0.2541 / 0.2621 arcsec/px** against the 0.2616 documented in
  `COORDINATE_SURFACE.md`.  (MAST_unit#138.)  The calibration package does *not* use it.
- **Starting a session silently aborts an open one.**  Session 0003 was left open by hand and
  0004's `spiral_new_path` closed it out with `aborted: true`, keeping its frames -- but the
  call returned success without mentioning it.  Worth a line in the response if two people
  might ever drive one unit.
- **Sparse fields remain the documented hard case.**  0001's 67 stars gave the worst result of
  the night.  The prior failure mode -- under ~30 matchable stars, 5 failures in 6 -- was not
  re-tested here.
- **A log message with a non-ASCII character was dropped from the log file** while the console
  showed it, because the daily file took the locale encoding (cp1252).  Fixed in
  MAST_common#63; the lost lines are visible in `Z:/MAST/mast00/2026-08-13/mast-unit-log.txt`
  as three `SpiralSearch.start` entries whose following "session open" line is simply absent.

## 9. What was NOT measured

- **Whether the spiral actually acquires a target.**  Everything here tests the *shift
  measurement*.  No session was run against a target that needed finding.
- **More than one declination.**  The `cos(dec)` result rests on a single pointing at +41.
- **The drift's cause.**  Needs several sky positions; see section 6.
- **A deeper mirror shadow.**  The shadow measured here is ~10% deep; the original simulation
  went to 60%.  If the mirror can sit deeper, that case is untested.
- **Sparse fields, deliberately.**  See above.
- **Any unit other than mast00.**

## 10. Provenance

Implementation: MAST_unit PR **#117**, branch `spiral-frame-shift`
(`src/spiral_search.py`, `src/imaging/frame_shift.py`).
Issues: **#136** (RA-arcsec x step), **#137** (zero margins), **#138** (pixel scale),
**#139** (MIN_CONFIDENCE calibrated for the wrong regime).
Products: `Z:/MAST/mast00/2026-08-13/Spirals/{0001,0002,0003,0004,0005}` -- frames and
`result.json` retained, so every number above can be re-derived offline.
On-sky commissioning 2026-08-13, mast00, Neot Smadar.

Related: `focuser_calibration_summary.md` (section 4 here shares its two-scales lesson).
