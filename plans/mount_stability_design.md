# Mount Stability Monitoring — Design Notes and Site Wind Climatology

*Design document for a proposed `MountStabilityMonitor`, owned by `Mount`, plus the
research that motivates it. Nothing here is implemented yet. Written 2026-08-26.*

**Status: campaign implemented (skeleton, uncommitted); monitor still unbuilt.** The
measurements in §2 are real and reusable regardless. §5 records design decisions reached
in discussion. §6 lists what had to be measured before writing code — **§6.1 and §6.3 are
now answered** (2026-08-28), and the answers changed the design in three places. §8
records what was actually built and where it departs from §5–§6.

Read §8 before §5 if you are picking this up: the monitor described in §5 does not exist,
but the campaign that feeds it does.

---

## 1. Motivation

Wind buffets the OTA and the servo loop resists it. That resistance is measurable, and it
is measurable **per unit and per pointing** — which a site anemometer is not.

MAST already has a wind response: `safety_get_sensor("wind-speed")`
(`common/safety.py`) reads the site anemometer through the safety service at
`10.23.1.25:8001` and returns `(value, is_safe, reasons_for_not_safe)`. That drives a
site-wide safe/unsafe decision.

The gap: **one anemometer cannot say what an individual OTA is feeling.** Two units at
different azimuths take very different torque from the same gust, and units shadow each
other. A site-wide threshold must be conservative enough for the worst-pointed unit, which
costs observing time on all the others. Per-unit, pointing-aware response is the payoff.

Note the name is deliberately *stability*, not *wind*. Servo error also rises from
imbalance, a cable snag, ice, or a failing bearing. A general "is this mount tracking
well" monitor is both more useful and more defensible than a wind detector, and it should
not hard-code wind assumptions.

---

## 2. Site wind climatology — measured

Source: `sensors.davis` in the **PostgreSQL** database `last_operational` on
`10.23.1.25` (user `ocs`). This is the **on-site** Davis weather station. The sibling
table `sensors.ims232` is an Israel Meteorological Service feed from ~2 km away and is
**not** representative of what the OTAs feel — use it only for gross weather.

- 5,336,265 rows, **60 s cadence**, live.
- Columns: `wind_speed`, `wind_direction`, `temp_out`, `humidity_out`, `pressure_out`,
  `rain`, `solar_radiation`, `tstamp`.
- Analysis below covers **2024-01-01 → 2026-08-26**, ~1.27M readings over ~800 nights,
  excluding epoch-zero rows and one 410 outlier.

### 2.1 Calibrations and filters that had to be derived

**`tstamp` is UTC.** Mean `solar_radiation` peaks at hour 09; solar noon at Neot Smadar
(~35.0°E) is 09:40 UTC. Local = UTC+3 (IDT) / UTC+2 (IST) — use
`tstamp at time zone 'UTC' at time zone 'Asia/Jerusalem'` so DST is handled.

**`wind_speed` is in km/h** — the unit MAST works in, so every figure in this document is
km/h and no conversion is needed when consuming the column.

It is quantised in 1.6 steps (3.2, 4.8, 6.4, 8.0, 9.7, 11.3, 12.9 …), which is 1 mph =
1.609 km/h. The Davis protocol confirms why: the LOOP packet's Wind Speed field (offset 14)
is *"a byte unsigned value in **mph**"*, so the station reports integer mph and something in
the ingest multiplies by 1.609 before storing. The stored column is km/h; the step size is
the mph origin showing through. It means the true resolution is ~1.6 km/h, so a threshold of
16 km/h and one of 17 km/h select exactly the same readings — **place thresholds on step
values, not between them.**

**`wind_direction` needs two filters, or it is garbage.**

- **Valid range is 1–360, and `0` means NO DATA — not North.** The LOOP packet's Wind
  Direction field (offset 16, 2 bytes) is documented as *"a two byte unsigned value from 1
  to 360 degrees. (0° is no wind data, 90° is East, 180° is South, 270° is West and 360° is
  north)"*. So filter **`wind_direction between 1 and 360`**. An earlier revision of this
  document said `between 0 and 360`, which would silently count no-data rows as North; the
  observed minimum in `sensors.davis` is 3.0, so no zeros are present and the results in
  §2.5 are unaffected — but the filter as written was wrong and would bite whoever copied it.
- **Direction is meaningless when the speed is zero** — 134,956 such rows in the study
  period. Filter `wind_speed > 0` for any direction analysis, or the rose is dragged
  toward whatever the vane rests at.

**The 32767 sentinel is ours, not Davis's.** The protocol documents no dashed value for wind
direction — `0` covers it — and the dashed value for the other two-byte fields is 255. Wind
speed is a *one-byte* field and cannot produce 32767 either. 32767 is `0x7FFF`, the classic
invalid fill for a signed 16-bit field, so it is being introduced by whatever writes
`sensors.davis` — presumably storing direction as int16 and filling when it has nothing.
Worth knowing because it is a property of the ingest and could change if the logger does,
whereas the `0` = no-data rule is fixed by the protocol.

Resolution is ~1°. **Meteorological convention is still assumed** — 246° meaning wind *from*
the WSW. Searching all 60 pages of the Vantage Serial Protocol Reference (Rev 2.6.1) for
"coming from", "blowing", "from which" and "direction the wind" returns **nothing**: the
document defines the compass mapping and never states the convention. The meteorological
reading is a very safe assumption — it is the universal standard, it is what every
Davis-consuming project assumes, and a vane physically points into the wind — but *it is not
confirmed by Davis documentation.* If it were "toward", every bearing flips 180° and every
broadside calculation in §5 inverts, silently. **The definitive check is physical**: on a
windy evening compare the reported bearing against which way the vane points, or against the
known prevailing SW–WSW flow with a handheld compass.

### 2.2 The diurnal curve

Wind by local hour, **km/h**:

| local | p50 | p75 | p90 | |
|---|---|---|---|---|
| 14:00–20:00 | **12.9** | 17.7 | 22.5 | peak |
| 21:00 | 11.3 | 16.1 | 20.9 | decline begins |
| 22:00 | 9.7 | 14.5 | 19.3 | |
| 23:00 | 8.0 | 12.9 | 17.7 | |
| 00:00 | 6.4 | 11.3 | 16.1 | |
| 01:00 | 4.8 | 9.7 | 14.5 | |
| 03:00–06:00 | **3.2** | 6.4 | 11.3 | true calm |

**Two corrections to the working assumption ("wind after sundown, calms 10–11 PM"):**

1. **Wind does not start after sundown.** It peaks in the *afternoon*, 14:00–20:00, and
   simply continues through sunset. It is blowing hardest before dark.
2. **22:00 is the start of the decline, not the end.** It is a ~7-hour ramp from peak at
   20:00 to minimum at 03:00. At 22:00 the median is still ~75% of the evening peak.

### 2.3 How often it is still up

Percentage of nights whose hourly mean exceeds a threshold, **km/h**, with the worst hourly
mean ever recorded in that hour:

| local | ≥15 | ≥20 | ≥25 | worst |
|---|---|---|---|---|
| 19:00 | 43.8% | 13.3% | 2.3% | 29.4 |
| 20:00 | 42.3% | 16.9% | 1.3% | 30.8 |
| 21:00 | 37.3% | 8.1% | 0.7% | 29.9 |
| 22:00 | 25.6% | 2.6% | 0.1% | 27.1 |
| 23:00 | 16.3% | 2.1% | 0.3% | 26.0 |
| 00:00 | 11.0% | 2.3% | 0.0% | 24.7 |
| 01:00 | 8.5% | 2.1% | 0.0% | 24.9 |
| 02:00 | 7.4% | 2.5% | 0.3% | 30.5 |
| 03:00 | 5.9% | 1.8% | 0.3% | 26.2 |

"Still high at later hours" is real: **~1 night in 4 is at or above 15 km/h at 22:00, 1 in 6
at 23:00, and ~1 in 17 is still there at 03:00.**

**But the right-hand columns are the important ones.** Across ~800 nights the hourly mean
**never once reached 31 km/h**, and ≥25 km/h occurs on well under 3% of night-hours. This is
not a violently windy site — it is a persistently *breezy* one. The disturbance to design
for is **chronic low-level buffeting, not rare storms**, which argues for a sensitive
continuous metric rather than a trip threshold.

Note the ≥20 column does not decay to nothing the way ≥15 does — it sits around 2% from
midnight to dawn. The nights that stay windy stay *properly* windy, which is consistent
with §2.4.

### 2.4 The actionable finding — 21:00 predicts the night

Taking **15 km/h** as the "windy" line (§2.3 shows it is where the population actually
splits):

| state at 21:00 | nights | ≥15 km/h at 23:00 | at 01:00 | at 03:00 |
|---|---|---|---|---|
| calm (<15 km/h) | 498 | 5.2% | 3.8% | 3.0% |
| **windy (≥15 km/h)** | 297 | **35.0%** | **16.5%** | **10.8%** |

A windy 21:00 makes a windy 01:00 **~4× more likely**, and still ~3.5× more likely at
03:00. That is schedulable: by 21:00 you already know which kind of night it is, and can
bias target selection (altitude, azimuth relative to wind) or exposure length for the whole
night instead of reacting gust by gust.

The converse is the stronger half: **calm at 21:00 → ~96% chance of a calm night.** On most
nights you can stop worrying early — and 63% of nights are in that bucket.

### 2.5 Direction — the site has a preferred axis, and it is steadiest at night

Percentage of time and speed by 16-point sector (calm rows and the sentinel excluded):

| sector | % time | mean km/h | p90 km/h |
|---|---|---|---|
| **WSW** | **20.1%** | 12.3 | 20.9 |
| **SW** | **16.7%** | 10.0 | 17.7 |
| **W** | **16.1%** | 13.5 | 20.9 |
| SSW | 10.4% | 8.7 | 17.7 |
| S | 9.7% | 9.2 | 19.3 |
| SSE | 7.7% | 8.1 | 17.7 |
| SE | 5.0% | 8.0 | 16.1 |
| WNW | 3.6% | 11.3 | 19.3 |
| ESE | 2.2% | 8.0 | 16.1 |
| ENE | 1.8% | 12.4 | **24.1** |
| E | 1.4% | 8.9 | 17.7 |
| NE | 1.3% | 12.1 | **25.7** |
| NW / N / NNE / NNW | ~1% each | 6.6–8.5 | 12.9–16.1 |

**53% of the time the wind is SW–WSW–W, and those are also the fastest sectors.** Widen to
the southern-through-western quadrant and it is **73%**. The northern sectors together are
~7% and mostly weak.

**Worth a footnote: NE and ENE are rare (1.3%, 1.8%) but carry the highest p90 of any
sector — 25.7 and 24.1 km/h, against 20.9 for the prevailing W/WSW.** Uncommon, but when it
blows from there it blows hardest, so those are the events most likely to surprise an
operator whose intuition was built on the SW norm.

#### The evening wind is the *steadiest* of the day

Vector-mean bearing by local hour, with **R** = resultant length (1.0 = perfectly steady
direction, 0 = uniformly scattered):

| local | mean bearing | R | mean km/h |
|---|---|---|---|
| 19:00 | 237° WSW | **0.76** | 13.4 |
| 20:00 | 233° SW | **0.79** | 13.4 |
| 21:00 | 233° SW | **0.78** | 12.4 |
| 22:00 | 234° SW | 0.77 | 11.1 |
| 23:00 | 232° SW | 0.74 | 9.7 |
| 00:00 | 228° SW | 0.73 | 8.7 |
| 03:00 | 207° SSW | 0.69 | 7.1 |
| 05:00 | 198° SSW | 0.67 | 6.3 |
| 10:00–13:00 | 225–230° SW | **0.48–0.51** | 10.1–11.6 |

**The evening — exactly when observing starts — has both near-peak speed and the tightest
direction of the whole day.** Midday is the most variable. That matters because it makes
"avoid pointing broadside to the wind" a *usable* rule in the observing window: the bearing
is not wandering.

It also rotates slowly and smoothly overnight — 237° at 19:00 backing to ~198° by 05:00 —
so a bearing taken at 21:00 stays good for hours. That pairs with §2.4: at 21:00 you can
know both the speed regime *and* a direction that will hold.

---

## 3. What PWI4 exposes

### 3.1 Readable — `/status`, per axis (`mount.axis0` = RA, `axis1` = Dec)

```
is_enabled              rms_error_arcsec           dist_to_target_arcsec
servo_error_arcsec      position_degs              position_timestamp
min_mech_position_degs  max_mech_position_degs     target_mech_position_degs
max_velocity_degs_per_sec    setpoint_velocity_degs_per_sec
measured_velocity_degs_per_sec    acceleration_degs_per_sec_sqr
measured_current_amps
```

**`measured_current_amps` is the best primary signal.** Wind is a *torque disturbance*, and
current is proportional to motor torque — it measures the disturbance itself rather than
the servo's failure to reject it. That matters because a stiff, well-tuned loop **hides**
wind in the error signal: moderate gust, error barely moves, current spikes. Keying on
error alone under-detects exactly the conditions where the mount is working hardest.

Use the **rolling standard deviation, not the mean** — mean current tracks altitude and
balance and changes across the sky with no wind at all.

`servo_error_arcsec` is the right **secondary**: it is already in arcsec, directly
comparable to seeing and to guide error, so it says when the wind is *costing data* rather
than merely being present.

### 3.2 Two traps

- **`mount.model.rms_error_arcsec` is not a tracking error.** It is the pointing *model's*
  fit residual (5.43″ per `spiral_search_summary.md`), static between model builds. One
  character from `mount.axisN.rms_error_arcsec`, which is the live servo error.
- **`rms_error_arcsec` is pre-smoothed by PWI4** over a window we do not control — fine for
  slow trending, actively wrong for gust detection, since it averages away the signal.

### 3.3 Not writable — there is no servo-parameter API

Only four things can be set over HTTP: `/mount/set_slew_time_constant` (4.0.9 b4),
`/mount/set_axis0_wrap_range_min` (4.0.13), per-axis `/mount/enable|disable`, and
`/mount/configure` (**4.1.9 b20 — parameters undocumented anywhere reachable**; a question
for PlaneWave). Plus the `/mount/model/*` family.

**No endpoint exists for servo gains, PID terms, current limits, encoder configuration, or
axis tuning.** Those live in config files on the PWI4 host (`LMount.cfg` —
*"options for overriding Axis0 positive/negative limits"*, 4.0.7 b2; `PW1000_custom.cfg`),
edited by hand, applied on restart.

**Consequence: there is no parametric response to wind.** Counter-action during observing
can only be operational (§5.6).

### 3.4 Version gap

The vendored `unit/src/PlaneWave/pwi4_client.py` is **~4.0.13-era**; current PWI4 is
**4.1.9 beta 25**. Missing: `/mount/configure`, the `axis` parameter on find-home,
`/fans/*`, `/heaters/set`, the model artificial-offset endpoints.

It also uses **`urllib.urlopen` per request** — a new TCP connection every call. Invisible
at 2 s, most of the cost at 10 Hz. A high-rate poller must use a persistent `httpx.Client`.

---

## 4. PWTools — the offline path to the axis controllers

Installed on mast02 at `C:\Users\mast\Downloads\PWTools-2024-09-17\PWTools.exe`
(Start Menu shortcut present). A **separate download**, not part of PWI4.

Its DLLs identify the hardware: `ElmoMotionControlComponents.GMAS.MMCLibDotNET.dll`,
`ElmoMotionControlComponents.Common.EASComponents.dll`, `PWLibMaestro.dll`, plus
`dfuprog.exe` (firmware), `ZedGraph` (plotting), `csmatio` (MATLAB I/O), `PXPLib`
(pointing models).

**The axis controllers are Elmo Motion Control Gold drives behind a Gold Maestro** — which
is why the PWI4 changelog refers to "EtherCAT mounts". The Elmo library exposes what PWI4
does not:

```
GetParameter / SetParameter          GetIntParameter / SetIntParameter
GetParameters / SetParametersArray   GetBoolParameter / SetBoolParameter
GetParameterGroup                    MMC_PARAMETER_LIST_ENUM
GetActualTorque  GetActualPosition  GetActualVelocity  GetAxisError  SetOpMode
```

PWTools' own UI strings show its purpose: `AxisSettingsForm`,
`limitsAndProtectionsToolStripMenuItem`, `currentNoiseStatsToolStripMenuItem`,
`currentAndOutputVsPositionToolStripMenuItem`, `EncoderCompareDataset`, `PlotLoadedPlants`,
`gainOrPhaseMargin_ValueChanged`, `rebootMaestroControllerToolStripMenuItem`. Plant
identification plus gain/phase margin is **system identification and loop shaping**.

**Cautions.** It writes drive parameters and can flash firmware. It almost certainly cannot
share the drives with PWI4 (one EtherCAT master), so PWI4 must be stopped — which rules out
live monitoring during observing. And the API is *Elmo's*, documented by Elmo, not by
PlaneWave; using it is outside what PlaneWave supports.

**If servo tuning is the goal, start with AutoTuner** — inside PWI4, documented, supported,
and built to tune the direct drives to your payload. PWTools is the engineering tool
underneath it.

*Binaries were inspected only. PWTools was not run.*

---

## 5. Proposed design — `unit/src/mount_stability.py`

### 5.1 Ownership and shape

Owned by **`Mount`** — it is mount telemetry, `Mount` already holds `self.pw`, and
`MountStatus` is the natural place to surface it for the GUI. Its own module so `mount.py`
(~1200 lines) does not grow. Polls on its own thread (`RepeatTimer`, `common/utils.py`)
with its own timeout: a slow PWI4 must never block a caller asking for the verdict.

**Inject the status source** as a callable rather than reaching for `self.unit.mount.pw`
internally — that is what makes it testable against synthetic traces, including replaying a
recorded windy night. `tests/test_spiral_search.py` shows the pattern working well.

### 5.2 Interface — arcseconds, not a boolean

```python
monitor.tracking_rms_arcsec     # per axis and combined, over the window
monitor.window_seconds
monitor.has_data / monitor.sample_age / monitor.samples_excluded
monitor.why_not_stable -> list[str]   # mirrors ComponentStatus.why_not_operational
monitor.stable                        # convenience over a configured threshold
```

A bare boolean discards what consumers differ on: a 3 s spiral frame barely cares, a 300 s
spectrum cares enormously. Expose the magnitude; keep `stable` as the default-threshold
convenience.

### 5.3 Ship it as an observer before a gate

**Phase 1 measures, logs and exposes; nothing consumes `stable` for control.**

This is not caution for its own sake. The repo has been bitten **twice** by a threshold
calibrated on one population and applied to another — `MIN_CONFIDENCE` (calibrated on
acquisition pairs scoring ~0.14, applied to spiral pairs scoring ~0.98) and
`max_best_hfd_px=12` (set from the single-frame HFD scale, applied to the cross-matched
one). `spiral_search_summary.md` §4 calls it *"two instances of one failure mode in two
campaigns"* and notes nothing in the test suite catches it. A `stable` that aborts
acquisitions on an uncalibrated threshold would be the third.

Let it run against the wind sensor for a few weeks; set the threshold from data; **then**
let it gate.

### 5.4 Four correctness requirements

**Exclude motion.** During a slew, offset, spiral step or focus move, servo error and
current are large and unrelated to stability. Without exclusion **every acquisition would
read "unstable" immediately after its own goto**. Use `MountActivities.Slewing` and the
`SettleMode` guards, drop samples during motion plus a settle margin, and expose
`samples_excluded` so a window that is mostly slew cannot report a confident number from
four samples.

**Hysteresis and dwell.** A bare threshold on a noisy signal chatters; gating an
acquisition on it gives start/abort/start. Separate enter and exit thresholds plus a
minimum dwell. Cheap now, painful to retrofit once callers depend on the timing.

**Fail open, and make "unknown" visible.** When PWI4 is unreachable, the monitor just
started, or the mount is disconnected: fail-open (`True`) risks missing wind; fail-closed
(`False`) means a bug in a brand-new subsystem stops the observatory. For something
uncalibrated, **require positive evidence of instability** and surface "I do not know"
through `has_data`/`sample_age` rather than folding it into the boolean. A gate that
silently says True for "no idea" is one nobody will trust.

**Learn the floor, not the average.** If the baseline is learned during a windy week it
learns wind as normal and never fires again. Learn the **low quantile** of σ per altitude
bin — wind only ever *adds* disturbance, so the bottom of the distribution is the calm
baseline regardless of the weather during learning. Make it **continuous, not one-shot**:
balance changes with instrument swaps, bearings age, tuning drifts, and a frozen baseline
silently rots.

**Bin by (altitude, |azimuth − wind bearing|), not altitude alone.** Altitude matters
because low elevation means more sail area and a different gravity torque, so a single
global baseline false-positives on every low target. But §2.5 supplies the other half:
`wind_direction` makes the OTA's angle to the wind computable, and that is expected to
explain much of the remaining variance. An OTA pointing downwind at 60° is in a different
regime from one broadside at 30°, and an altitude-only baseline blurs the two together.

The evening steadiness result (R ≈ 0.78 at 20:00–21:00) is what makes this bin usable
rather than noise: during the observing window the bearing is tight enough that the angle
is meaningful for hours at a time.

### 5.5 Persistence — no new database

**Do not write telemetry into the config DB.** It is what `Config()` cross-checks at
startup and every service needs to boot; coupling observing-time writes to it buys a new
way to fail to start.

Two tiers, both on existing machinery:

- **Live decision: in-memory ring buffer.** Nothing persisted; the rolling window is all
  `stable` needs.
- **Persisted: downsampled aggregates.** One row per 10–60 s — median, robust σ, n,
  excluded count, alt, az, activity mask. At 60 s that is ~660 rows/night/unit.
- **Raw high-rate only during explicit campaigns**, behind a flag, for a few nights.

Sizing for raw: 5 Hz × 2 axes ≈ 24 MB/night/unit as CSV, ~500 MB/night across 20 units —
fine for a campaign, not as a standing cost.

**Revised by §6.1.** PWI4 actually serves ~44 Hz, not the 5 Hz assumed above, so raw is
**~200 MB/night/unit**. For the two dedicated units over ten nights that is ~4 GB in
total, which is still nothing — and §8 records raw rather than summary statistics for a
reason the original sizing could not have known: at 44 Hz a dwell resolves the
disturbance *spectrum*, and a σ cannot be un-computed back into one.

Write through `Filer` / `PathMaker` / `MoveGuardian.protect`, the same path spirals and
acquisitions use, so products land on the share beside the night's other output with no new
infrastructure and no new failure mode. Keep a stable flat schema and ingesting into a
database later is an afternoon; starting with a database and discovering you wanted
different columns is not.

### 5.6 What "countering wind" can actually mean

There is **no API to change servo parameters while PWI4 owns the drives** (§3.3). Available
levers:

| lever | when | availability |
|---|---|---|
| **Guiding** — PHD2 corrections already reject low-frequency wind error; aggressiveness and guide exposure are tunable | real time | **today** |
| Exposure length — shorter subs under wind | per plan | today |
| Target selection — avoid low altitude and broadside-to-wind | scheduler | **expressible now** — see below |
| Safety threshold → park/close | real time | today, blunt |
| Servo tuning (AutoTuner, or PWTools) | permanent, offline | §4 |

**Guiding is the under-used one in this framing.** It is already a calibrated,
arcsecond-domain, closed-loop wind rejector running during every acquisition, and its
correction history is a *third* wind signal that is already in the logs.

**Target selection stopped being hypothetical once direction was examined.** §2.4 gives a
speed regime knowable at 21:00; §2.5 gives a bearing that is both strongly preferred
(53% SW–WSW–W) and at its steadiest in the same window (R ≈ 0.78). Together they make a
constraint like *"on a windy night prefer targets within ±X° of the wind axis, and
de-prioritise low-elevation broadside pointings"* a concrete scheduler rule rather than an
aspiration — decided once at 21:00 rather than reacted to gust by gust.

X is unknown and must come from the servo measurement: that is one of the things the
observer phase (§5.3) exists to establish.

---

## 6. Measure before building

### 6.1 The useful poll rate — do this first, it constrains everything

`/status` is a **snapshot at request time**, so polling faster than PWI4 refreshes its own
telemetry returns the same drive sample twice — 10 Hz of rows, 4 Hz of information, and
duplicate "samples" that make σ artificially small.

**Test:** poll hard for 30 s and count *distinct* `mount.axisN.position_timestamp` values
per second. That is PWI4's real update rate and the hard ceiling on anything the monitor
can see. If it is 4 Hz there is no point testing 20 Hz, and the window-length question is
settled by it. Costs a minute, read-only.

#### Answered, 2026-08-28 on mast02: **~44 Hz**

| measurement | result |
|---|---|
| HTTP throughput, persistent `httpx.Client` | 613 Hz, 18381 polls, 0 failures |
| distinct `axis0/axis1.position_timestamp` | **43.4 Hz**, steady at 42–45 every second |
| gap between distinct samples | p50 16 ms, p90 32 ms, max 47 ms |
| duplicate polls at 613 Hz | 93% |
| `mount.update_count` (PWI4's internal loop) | 69.9 Hz |
| `mount.update_duration_msec` | p50 0.07, p90 0.10, max 3.98 |

Three consequences:

- **Poll at ~45–50 Hz, not higher.** Above the refresh rate you collect duplicate samples,
  which is precisely the σ-deflating trap this section was written to avoid.
- **The dwell-length worry is void** — see the correction at the end of §6.5.
- **44 Hz buys a spectrum, not just an RMS.** Nyquist ~22 Hz makes structural resonance
  and the gust rolloff directly observable, which is a different question from "how big is
  σ" and one the design did not know it could ask. It is why §8 stores raw rows.

The drives deliver ~44 Hz while PWI4's own loop runs at ~70 Hz, so roughly two thirds of
its iterations carry a new drive sample.

Caveat on provenance: measured with axis0 parked on its soft limit and axis1 idle, so it
is the drive-to-PWI4 link rate rather than a tracking mount's. It is unlikely to differ,
but it has not been re-confirmed under tracking.

### 6.2 Interference — only then

What matters is not the poller's throughput but whether it degrades PWI4's service to
`mount.ontimer`, guiding and slew acceptance. Run a **victim** — a 2 s `/status` loop
mimicking `ontimer`, recording its latency distribution — while a load loop ramps
1 → 2 → 5 → 10 → 20 Hz. Watch the victim's **tail**, not its median. Measure with both
`urllib` (as vendored) and a persistent `httpx.Client` so the connection-setup share of any
knee is known.

Run on a unit whose mount is tracking but **not doing science** — engineering time.

~~Note mast02 is not suitable: port 8220 there serves an HTML page, so PWI4 is not
running.~~ **Wrong, and worth keeping as a cautionary note.** PWI4 4.1.6 runs on mast02
with the mount connected, and §6.1 was measured there. The HTML page was the **Weizmann
site proxy** answering 403: on these Windows machines `urllib.getproxies()` reads the
WinINET *registry* settings, so a client that trusts the environment routes even
`127.0.0.1:8220` through the proxy. It appears as no proxy variables in the environment,
and `curl` here does not do it — only Python HTTP clients that honour `trust_env`.

`common/api.py` already passes `trust_env=False` for exactly this reason, so production
code was never affected; only ad-hoc probes are. **Any tool written against PWI4 must set
`trust_env=False`** or it will conclude the mount software is absent.

### 6.3 The offline characterisation

High-rate direct-drive telemetry via PWTools gives the true disturbance spectrum and, via
its current-noise statistics, the measurement noise floor — without which an elevated σ
cannot be attributed to wind rather than to the current sense. **This calibrates the online
detector**, and a windy night that cannot be observed on is exactly when to run it.

#### Largely answered online, 2026-08-28 — the PWTools detour is now optional

Both justifications above turned out to be obtainable from PWI4 itself. A 30 s trace at
40 Hz on mast02, mount stationary:

| | axis0 (RA/az) | axis1 (Dec/alt) |
|---|---|---|
| position spread over 30 s | 0.081″ | 0.137″ |
| σ(`servo_error_arcsec`) | **0.0039″** | **0.0167″** |
| σ(`measured_current_amps`) | **0.0046 A** | **0.0055 A** |
| mean current | −0.007 A | −0.738 A |

**The servo error is pure encoder quantisation.** On both axes `servo_error` spans exactly
±½ of the position peak-to-peak (±0.0405″, ±0.0686″) and the two spreads agree to the last
digit — ±1 encoder count of dither, no mechanics in the trace at all. Which is what makes
it the noise floor:

- σ(servo_error) sits **25–170× below** the 0.4–0.7″ RMS guiding recorded in §6.5. Servo
  error has ample dynamic range as a stability metric.
- σ(current) ~0.005 A is the floor for the primary signal: **wind-driven σ(current) above
  ~0.006 A is real.**
- A rolling σ(servo_error) below ~0.04″ is meaningless — under one encoder count.

Two caveats. It is measured at **zero velocity**, so it excludes the torque ripple and
cogging a tracking axis adds — treat it as a *lower bound* on the floor. And whether
mast02's axes were mechanically locked at the time is unresolved; axis1 carrying 0.74 A of
holding current suggests a motor bearing the gravity load rather than a clamp taking it,
but the telemetry cannot separate the two without commanding motion.

PWTools remains the only route to a true disturbance *spectrum* under load and to the
drive-side current-noise statistics. It is no longer on the critical path.

### 6.4 Open questions

- **Safety sensor cadence and history.** `SensorModel.readings` is a *list* and the code
  takes `readings[-1]`. If the service retains depth, nights already observed can be joined
  retrospectively instead of polling and storing. How far back, and how often does it
  update? A 1-minute anemometer against seconds-scale gusts bounds what correlation is
  establishable. (The Davis table itself is 60 s — see §2.)
- **What threshold does the safety system already use** for `is_safe` on wind-speed? That
  is an existing, operationally-validated number and the natural anchor.
- **Confirm `wind_direction` is "from", not "toward"** (§2.1). *Checked against the Davis
  Vantage Serial Protocol Reference Rev 2.6.1 and it is not documented there* — the protocol
  gives the compass mapping and never states the convention. Everything in §2.5 and the
  broadside binning in §5.4 inverts if it is the other way, and nothing in the data would
  reveal the mistake. **Resolve it physically**: watch the vane on a windy evening, or take a
  handheld compass bearing against the prevailing SW–WSW flow.
- **Where does 32767 come from?** (§2.1) Not from Davis — it is introduced by whatever writes
  `sensors.davis`. Worth knowing which component, since the sentinel could change with the
  logger while the protocol's `0` = no-data rule cannot.
- **Does the bearing at the mast represent the bearing at each OTA?** Local topography and
  shadowing by neighbouring units mean it may not. This is the same gap the per-unit servo
  measurement exists to fill, and comparing per-unit σ against the mast bearing is how it
  gets answered.
- **`/mount/configure` parameters** — ask PlaneWave.

### 6.5 The calibration campaign — a dedicated alt/az mesh

#### Why a mesh, and not more log-mining

**Log-mining was tried and is closed.** Two candidate signals already in the logs were
examined on 2026-08-27 and neither has the coverage:

- **Settle durations** (`wait_until_settled`) — 166 paired events on mast02 over 9 nights.
  Floor-limited at ~5 s by `poll=1.0s` × `stable_samples=2` plus the 3 s grace, so it can
  only resolve disturbances large enough to add whole poll intervals, and 5.11/5.12/5.12 s
  across three calm hours is the instrument reading zero rather than a measurement. Worse,
  the events cluster at 03:00–05:00 — the *calmest* hours — because that is when
  acquisitions ran. There are no `slew`-mode settles logged at all.
- **PHD2 guide logs** — mast02 had one usable session (261 frames, 2026-06-24) in a 1.4 km/h
  mean wind: a clean calm baseline and nothing else. mast00 had three sessions, 287 usable
  frames, fetched over SSH.

The mast00 result is the instructive one. Binned by wind it *looked* like a strong effect —
total RMS 0.50″ (0–5 km/h), **3.05″ (5–10)**, 0.67″ (10–15), 0.62″ (15+) — non-monotonic,
with the worst guiding in the second-calmest bin. Decomposed by session it evaporates:

| session | n | RA RMS | Dec RMS | median SNR | wind mean/max km/h |
|---|---|---|---|---|---|
| 2026-07-20 | 34 | 0.46″ | 0.73″ | 74.6 | 13.1 / 17.7 |
| **2026-08-04** | 135 | **1.21″** | **2.69″** | 126.2 | 6.4 / 11.3 |
| 2026-08-17 | 118 | 0.42″ | 0.47″ | 54.3 | 13.3 / **24.1** |

One session supplied 135 of 287 frames, all in the 5–10 bin. The "wind bins" were session
bins. And the direction is backwards: the **windiest** session, gusting to 24.1 km/h — near
the top of the whole site distribution — guided at 0.42″/0.47″, as well as calm. 08-04's
median SNR was the *highest* of the three, so it was not a faint-star problem; something
mechanical or configuration-side that night, not wind.

**The lesson generalises: opportunistic data is dominated by between-session variation** —
focus, star choice, guide parameters, whatever went wrong on one night — not by wind. What
is needed is *within-session* variation, wind changing while everything else is held fixed.
Only a deliberate campaign provides that.

Two numbers worth keeping as the baseline any stability metric must beat: mast00 guided at
**0.4–0.7″ RMS** on two of three nights including one gusting to 24 km/h; mast02 at
0.9″/0.8″ on a dead-calm night.

#### Design

**Dedicate one or two units.** Two, chosen for *contrasting exposure* — an edge unit and a
sheltered one. Running the identical mesh on both under identical wind is the only way to
answer §6.4's question about whether the mast bearing represents what each OTA feels, and
how much neighbouring units shadow each other.

**Mesh in alt/az, command in RA/Dec.** Alt/az is where the physics lives — wind arrives on a
bearing, gravity torque follows altitude. But `goto_alt_az` **stops tracking** (mount.py:
*"an alt/az target is a fixed direction… sidereal tracking would drag the mount straight off
it"*), and a stationary mount is not the servo state being characterised. So convert each
cell to RA/Dec at visit time and use `goto_ra_dec_j2000`.

Drift during a 90 s dwell is negligible against the cell size (computed for Neot Smadar,
30.053°N):

| cell | dAlt | dAz |
|---|---|---|
| any alt, az 90/270 | ±0.33° | +0.19° |
| alt 30, az 180 | −0.00° | +0.38° |
| alt 75, az 180 | −0.00° | **+1.40°** |

Azimuth drift diverges toward the zenith, which is an independent reason to cap at 75°.
**Bin on the alt/az read back from `/status`, not the requested cell**, and drift stops
mattering at all.

**Trimmed mesh: 40 cells.** alt {15, 30, 45, 65} × az every 36° (10). Trimmed from 60 to pay
for the split dwell below — the contrast is worth more than the resolution.

- **alt 15** is the mount floor (`MIN_ALTITUDE_DEGREES = 15.0`) and where the effect should
  be largest. Keep it even though science rarely goes there: it tells you where the
  operational floor *should* be.
- **alt 65** is the control. Keep it — without the contrast you cannot show the effect is
  real.
- **10 azimuths** still resolves broadside from downwind. Since the covariate is
  `|az − wind bearing|` and the bearing is steady within a night (§2.5, R ≈ 0.78), each pass
  samples the relative-angle range twice, and nights with different bearings fill in the
  intermediate angles for free.

**Split dwell — the most valuable part of the design:**

```
slew → settle
  60 s  UNGUIDED  → clean disturbance      (servo current / error only)
  20 s  star acquire + PHD2 settle
  60 s  GUIDED    → operational residual   (PHD2 arcsec + servo)
```

Guiding is not merely extra data — with PHD2 active the mount is commanded by an **outer
loop**, so `measured_current_amps` and `servo_error_arcsec` then contain guide pulses, which
are themselves a response to wind. Guided-only measurement conflates the disturbance with
the reaction to it.

**The difference between the halves is the answer to "how do we counter wind"**: how much of
the disturbance guiding actually removes, per pointing, per wind speed. Neither half alone
gives it. The unguided half also needs no star, so it still runs on cloudy nights.

**PHD2 self-labels each cell.** Every `Guiding Begins at` block records `Alt`, `Az`, `RA`,
`Dec`, `Hour angle`, `HFD` and the lock position, so a cell's guide session ties itself to
its pointing with no cross-correlation and no risk of mis-joining. `start_guiding()` /
`stop_guiding()` already exist in `guiding.py`; this is plumbing, not research.

**Traverse order.** Two conflicting wants — randomised order to decorrelate pointing from
hour, spatial order to avoid burning the night in slews. Get both by keeping a fixed spatial
order and **rotating the start offset each pass** (`pass k starts at cell (k·7) mod 40`).
Slews stay between neighbouring cells; each cell is visited at a different hour every pass.
A cyclic Latin square, one line of code.

**Do not** sweep az 0→360 at one altitude then the next: azimuth would advance monotonically
with the hour and the evening wind decay (§2.2) would be attributed to azimuth — exactly the
confound the campaign exists to remove.

#### Budget

| | |
|---|---|
| cells | 40 (alt 15/30/45/65 × az every 36°) |
| dwell | 60 s unguided + 20 s acquire + 60 s guided ≈ 3.5 min with slew |
| pass | ~2.3 h → **~4 passes/night** |
| visits/night | ~160 |
| per cell over 10 nights | ~40 |

Stratifying those 40 by wind speed leaves ~13 per cell per bin, which is thin — an argument
for taking **every** cloudy and moonlit night for the servo-only tier rather than waiting
only for windy ones.

**Superseded — the pilot must be a SUBSET of the full mesh.** As specified below it shares
exactly one altitude (65) and two azimuths (0, 180) with the full mesh, so every pilot
night would be excluded from the final dataset or, worse, silently pooled across two mesh
definitions — the same failure mode as `MIN_CONFIDENCE` and `max_best_hfd_px`, wearing a
third hat. §8 uses **alt {15, 65} × az every 72° = 10 cells**, all of which are full-mesh
cells, so pilot nights contribute real data.

**Pilot first, 2–3 nights: alt {20, 40, 65} × az every 45° = 24 cells.** Its purpose is not
the baseline. It answers: does σ respond to pointing at all, how large is the effect, does
slew exclusion work, does the rig survive a night unattended, and does PHD2 tolerate the
start/stop cycling. If σ does not move measurably between alt 20 broadside and alt 65
downwind on a windy night, the full campaign is not worth running — and three nights is a
cheap way to find that out instead of forty.

**Use the 21:00 predictor to choose nights** (§2.4): windy at 21:00 → run the mesh, the
informative case; calm → back to science, or a short mesh to top up the calm floor that
§5.4 needs anyway. That concentrates effort where the signal is instead of spending three
nights in four measuring calm.

#### Risks, in order of what could sink it

1. **PHD2 calibration reuse across the sky.** PHD2 calibrates at one declination and scales
   by dec compensation. The mesh sweeps everywhere; if PHD2 decides to recalibrate at some
   cells it costs *minutes* each and the campaign is dead. mast00's header shows
   `Cal Dec = 0.0, Last Cal Issue = None`, so a stored calibration is being reused — verify
   it survives a full mesh before committing, and consider pinning "auto restore
   calibration".
2. **Low-altitude cells will fail guiding most often, and they are the cells that matter
   most.** mast02's logs are full of `Star lost - low SNR` / `low mass`; extinction and
   seeing near the horizon anti-correlate star acquisition with the strongest wind signal.
   Budget for cells that yield servo data and no guide data, and never let a failed star
   abort the dwell.
3. **~160 guide start/stop cycles a night** is far outside PHD2's normal usage, and
   `phd2.py` already carries `# hack! workaround bug where PHD2 sends a GuideStep after
   stop`. Soak-test the cycling alone for a night before trusting a campaign to it.
4. **Cable wrap.** A mesh that repeatedly sweeps azimuth will hit the axis0 wrap limit and
   spend the night unwrapping. `min/max_mech_position_degs` are in `/status`; plan the
   traversal to stay within one wrap.
5. **Guide star nuisance variables.** SNR, StarMass and HFD vary per cell and per night and
   will confound any comparison if ignored — a "worse" cell may simply have had a fainter
   star. All three are in the guide-log rows. They are free; capture them.

#### Dwell length depends on §6.1

90 s per half assumes a poll rate that delivers enough *independent* samples. Wind is
autocorrelated on a 1–10 s gust timescale, so consecutive `/status` reads are not
independent however fast you poll. At ~2 s decorrelation, ~50 effective samples needs ~100 s.

**If §6.1 finds PWI4 refreshes at ~1 Hz, the dwell must grow to ~300 s and the cell count
must fall accordingly.** Measure the poll rate before fixing the mesh size — the gust
timescale itself is best measured by the offline PWTools run (§6.3), which is another reason
that characterisation belongs before the campaign rather than after.

**Resolved: it is 44 Hz, so this worry is void.** Sampling is nowhere near the constraint;
gust autocorrelation is, exactly as the good case above predicted. The 40-cell mesh at
60 + 60 s dwells stands as designed, and §8 implements it unchanged.

---

## 7. Provenance

- Wind climatology: `sensors.davis`, PostgreSQL `last_operational` on `10.23.1.25`,
  2024-01-01 → 2026-08-26, ~1.27M readings / ~800 nights. Speed queried 2026-08-26,
  direction 2026-08-27. Direction statistics use 1,261,236 rows after excluding the
  32767 sentinel and calm rows, and are computed as **vector** means (mean of sin/cos)
  rather than scalar averages of bearings, which would be meaningless across 0°/360°.
- PWI4 API surface: [PWI4 CHANGELOG](https://planewave.com/files/software/PWI4/CHANGELOG.txt),
  the [2021 HTTP API PDF](https://www.indilib.org/media/kunena/attachments/7104/PlaneWavePWI4ProgrammingAPIviaHTTP2021-05-31.pdf),
  the [current reference client](https://planewave.com/files/software/PWI4/python/pwi4_client.py),
  and the vendored `unit/src/PlaneWave/pwi4_client.py`.
- PWTools: binary inspection of `C:\Users\mast\Downloads\PWTools-2024-09-17\` on mast02.
- Threshold-calibration precedent: `spiral_search_summary.md` §4,
  `focuser_calibration_summary.md`.
- Log-mining results (§6.5): `Z:/MAST/mast02/*/mast-unit-log.txt` (166 paired settle events,
  9 nights) and PHD2 guide logs from `C:/Users/mast/Documents/PHD2/` on mast02 (local) and
  on **mast00** (fetched over SSH/SFTP — the `c$` admin share and WinRM are both blocked;
  mast00's `MAST` share is rooted at `C:\MAST` and does not contain them). Analysed
  2026-08-27.
- Pointing-drift figures: computed with astropy for the `ns` site location as recorded in
  the config DB — 30.05301°N, 35.04080°E, 400 m.
- Davis field semantics (§2.1): *Vantage Pro, Vantage Pro2 and Vantage Vue Serial
  Communication Reference Manual*, **Rev 2.6.1** (2013-03-29), LOOP packet table, p.22 —
  Wind Speed at offset 14, Wind Direction at offset 16. Read 2026-08-27 from
  `davisinstruments.com/support/vantage-pro-pro2-and-vue-communications-reference/`.
  The from/toward convention is **absent** from that document; do not cite it as the source
  for that assumption.

- §6.1 poll rate and §6.3 noise floor: measured on **mast02** 2026-08-28, PWI4 4.1.6,
  mount connected and stationary with axis0 parked on its `max_mech_position_degs` soft
  limit. Persistent `httpx.Client(trust_env=False)` against `127.0.0.1:8220/status`.
- Per-cell declinations (§8): `sin δ = sin a · sin φ + cos a · cos φ · cos A` at
  φ = 30.05301°, the site latitude in the config DB.

**Nothing in §5 has been implemented.** The MONITOR does not exist. The campaign of §6.5
does — see §8 — but no part of it has been run against a real mount under wind.

---

## 8. What was built (2026-08-28)

Branch `mount-stability-campaign` in both `MAST_common` and `MAST_unit`, **uncommitted**.
A skeleton: the structure and all the non-hardware logic are real and exercised, the
hardware sequencing is wired to existing APIs but has never driven a mount.

### 8.1 Files

| repo | file | what |
|---|---|---|
| `common` | `activities.py` | `UnitActivities.StabilityCampaigning`, appended at the end of the enum |
| `common` | `paths.py` | `PathMaker.make_stability_folder()` |
| `unit` | `src/stability_campaign.py` | new — mesh, slot clock, descriptor, sampler, session |
| `unit` | `src/guiding.py` | `Guider.wait_for_settle()`, `Guider.calibration_state()` |
| `unit` | `src/unit.py` | `self.stability`, three endpoints |

### 8.2 Endpoints — on the UNIT router, not the mount's

`start_stability_campaign(pilot: bool)`, `stop_stability_campaign`,
`stability_campaign_status`.

§5.1 puts the *monitor* on `Mount` and that still holds. The *campaign* is a different
animal: its dwell drives the mount, the imager and PHD2, and `Mount` has no business
reaching into the guider. `SpiralSearch` is Unit-owned for the same reason, and supplied
the session/watchdog shape reused here.

`status` is not a nicety — the campaign runs unattended for hours, and start/stop alone
would leave no way to see what it is doing. It reports the current visit and cell, phase,
visits attempted/completed/skipped, cells that yielded no guide star, and per-cell
coverage.

Starting is **idempotent** (a retrying client must not spawn a second walker on one
mount) and **refuses while the unit is acquiring, guiding, focusing or solving** — the
mesh owns the mount for the night.

### 8.3 The mesh — and the cell that had to move

Full: **alt {15, 30, 45, 65} × az every 36°, offset by 18° = 40 cells**, `MESH_VERSION`
stamped into every product. Pilot: **alt {15, 65} × az every 72° = 10 cells**, a strict
subset (verified).

The 18° offset is not cosmetic. A cell's declination has **no time term** —
`sin δ = sin a · sin φ + cos a · cos φ · cos A` — so each cell guides at the same
declination on every visit, forever. Along the due-north column that reduces to
`δ = 90° − |alt − φ|`, and with φ = 30.053° the mesh's `alt 30` row landed **0.05° from
the celestial pole**:

| | before offset | after |
|---|---|---|
| worst cell | alt 30, az 0 → **δ 89.9°**, RA rate 1081× | alt 30, az 18 → δ 74.4°, 3.7× |
| δ range | −44.9° … 89.9° | −41.7° … 74.4° |
| cells with \|δ\| > 80° | 1, unguidable | **0** |

PHD2 scales the RA guide rate by 1/cos δ, so that cell could never be guided — by
geometry, not by calibration. The cell is mechanically ordinary, so unguided dwells were
fine; what was lost was the **guided-minus-unguided difference**, the headline result,
across the whole northern column and missing non-randomly. The offset costs nothing: the
azimuth origin is arbitrary when the covariate is `|az − wind bearing|`.

Two cells remain awkward — `alt 30, az 18` and `az 342` at δ 74.4°, RA rate 3.7×. Expect
them to be the flakiest for guiding. That is now a known hole rather than a surprise.

**The fixed-δ property is also good news.** Any declination-dependent guiding systematic
is a constant per-cell offset, so it cancels in the "excess over that unit's own per-cell
calm floor" comparison §8.7 relies on — provided calibration does not *change* mid-campaign,
which is what §8.6 exists to detect.

### 8.4 Lockstep — the reason for two units, and it does not happen by itself

The cell is a function of a **campaign-wide slot clock**, not of a stored position:

```
visit      = floor((now - epoch) / SLOT_SECONDS)       SLOT_SECONDS = 210
cell_index = (visit * 7) mod 40
```

Both units compute the same cell at the same moment, so **every cell yields a
simultaneous pair** — one instant, one bearing, one speed, two OTAs, with the difference
attributable to shadowing and topography rather than modelled away afterwards. §6.5 asks
for "the identical mesh on both **under identical wind**"; two units each walking from
their own checkpoint satisfy the first half and not the second, drifting apart within an
hour into unit A at 20:00 against unit B at 23:00.

The epoch lives at `<share>/MAST/Stability/<night>/campaign.json`, **above** the
per-machine product roots, because it is the one genuinely cross-unit piece of state. The
first unit to start writes it; the second adopts it. Share unreachable → the unit runs with
its own epoch and records `standalone: true`, so the analysis knows that run cannot be
paired instead of having to guess. A mesh-version mismatch between the two is refused
outright.

**Costs ~40 visits/cell rather than ~80 pooled**, and that is the right trade: pooled
visits across two different mounts are confounded by mount identity anyway (§8.7).

**Stride 7 is coprime with both 40 and 10**, so one pass covers every cell exactly once and
each cell lands on a different hour on successive passes (verified). This preserves §6.5's
rotation requirement, which a plain resume-where-you-stopped walk would have destroyed: at
~4 passes over 40 cells a night, such a walk lands back on cell 0 every evening and every
cell keeps its time-of-night slot forever.

**Resume is the same mechanism** — a restarted unit computes the current slot. There is no
checkpoint file to desync from the products.

### 8.5 Products

`PathMaker.make_stability_folder()` → `<ram>/<observing-night>/Stability/<NNNN>`, which the
mover lands at `<share>/<hostname>/<observing-night>/Stability/<NNNN>`.

Three corrections to the obvious spelling of that path, all load-bearing:

- **No hostname join.** `Filer().shared.root` is *already* `Z:/MAST/<hostname>/` on
  Windows; joining `gethostname()` yields `Z:/MAST/mast02/mast02/…`.
- **Observing night, not calendar date.** A campaign runs dusk to dawn and would otherwise
  split its own products at 02:00 local, mid-mesh, under two names that give no hint they
  belong together.
- **RAM disk first, then `move_ram_to_shared` under `MoveGuardian`** — the pattern every
  other product maker uses. A 44 Hz writer is exactly the case it exists for; writing
  straight to a network share would largely defeat the guardian's purpose.

`<NNNN>` comes from the existing `PathMaker.make_seq()`. One folder per **cell visit**
(`visit=NNNNN,cell=NN,alt=..,az=..`) holding `unguided.csv`, `guided.csv`, `meta.json` —
per-cell rather than per-night so a crash costs one cell, and so coverage is derivable by
listing.

**Coverage is derived, never stored.** `coverage_from_products()` counts completed visits
per cell from the products themselves. A separate counter file is one more thing that can
disagree with the evidence.

Rows carry both PWI4's `position_timestamp` and a host UTC stamp, so the offline join
against `sensors.davis` can be *checked* rather than assumed — a few minutes of NTP drift
would misattribute wind to the wrong cell and nothing downstream would reveal it.

### 8.6 Guiding

**Settle, not a fixed wait.** `Guider.wait_for_settle()` polls PHD2's real settle protocol
(`check_settling()` → `SettleBegin`/`Settling`/`SettleDone`). `guide()` primes the settle
state before issuing its RPC, so there is no start-up race, and nothing else in the tree
calls `check_settling()` — which matters, because it consumes the done-transition when it
reports it.

It returns *what happened*, not a bool: **time-to-settle is itself a measurement** of how
hard the star was to hold at that pointing, a covariate of the same kind as SNR and HFD.
Verified across settle / PHD2-gave-up / no-SettleDone / stopped / not-settling / no-settle-
protocol.

**The wait is bounded by the slot**, not just by a constant:
`min(45 s, seconds_left_in_slot − 60 s guided dwell)`. Past ~155 s into a slot the budget
goes negative and the cell **forfeits its guided half but keeps the unguided data**, rather
than overrunning and costing the pair its next cell too.

**A failed star never aborts the dwell.** Low-altitude cells fail guiding most often and
matter most (§6.5 risk #2); a design that drops them keeps only the easy half of the mesh.

**Calibration is recorded twice** — in full at run start, and compactly at every visit
*after* the guide attempt. Camera rotation invalidates calibration, and a recalibration
part-way through puts a step in the guided residuals that reads exactly like a change in
wind or exposure; with two units being compared against each other, "did either recalibrate,
and when" has to be answerable from the products. A start-of-run snapshot alone cannot show
it. **Operational decision: a PHD2 calibration run on each unit before the campaign starts.**

Note the slot clock adds a wrinkle to §6.5 risk #1: a mid-mesh recalibration takes minutes,
longer than a 210 s slot, so it does not merely cost time — the unit misses slots and the
pair loses those cells. It self-heals (the walker rejoins at the current slot) but the cells
are gone. Pin "auto restore calibration".

### 8.7 Analysis constraints this design bakes in

- **Compare excess over each unit's own per-cell calm floor, not raw σ.** With n = 2 units
  you cannot separate "A is more exposed" from "A's mount is in worse shape" — the mounts
  cannot be swapped between locations. This makes calm nights a *requirement*, not a
  consolation prize; §2.4 says 63% of nights are calm at 21:00, so they are abundant.
- **Wind joins offline** against `sensors.davis` on timestamp. No live wind path was added
  to the unit: `safety_get_sensor` gives speed only, and direction is needed. Davis is
  quantised to 60 s and 1.6 km/h, so it labels the *regime*; within-dwell gustiness is only
  measurable from the mount's own telemetry.
- **Raw rows, not summary σ** — see the §5.5 revision.

### 8.8 Not done

- **No tests.** The mesh, rotation, lockstep, settle and slot-budget logic were exercised
  ad hoc and all pass; none of it is in the test suite.
- **The wrap check is a guard, not a predictor.** It refuses a cell when axis0 is already
  within 10° of a limit, but a cell's exact mech position is only known after the RA/Dec
  transform. §6.5 risk #4 is live: mast02 was found parked on `max_mech_position_degs`
  with a target 378° away on 2026-08-28.
- **PHD2 start/stop cycling is untested at campaign rate.** ~160 cycles/night is far
  outside normal use and `phd2.py` already carries a workaround for a `GuideStep` arriving
  after stop. Soak-test it for a night before trusting a campaign to it. This was never
  about the settle wait; it is about the cycling.
- **Unresolved and physical: is `wind_direction` "from" or "toward"?** (§6.4) Everything in
  §2.5 and the broadside binning in §5.4 inverts if it is the other way, and nothing in the
  data would ever reveal it. A person is attending the campaign — this is five minutes with
  a compass on a windy evening and it should happen on night one, before the mesh data
  accumulates under an unverified assumption.
- **Verify NTP on both units** before night one, and record each unit's clock offset in the
  run metadata (§8.5).
- If the camera really was rotated, anything else derived from camera orientation — optical
  centre, fibre position used by acquisition — is equally stale. Outside this campaign's
  scope, worth a glance while calibrating.

---

## 9. Operator procedure

For the person on site. Everything here is driven from each unit's **OpenAPI page** (the
service's `/docs`) — open one browser tab per unit and keep both up all night. The three
endpoints are under the **"Mount stability campaign"** tag:
`start_stability_campaign`, `stop_stability_campaign`, `stability_campaign_status`.

**The campaign takes both units for the whole night.** They cannot run plans or
acquisitions while it walks the mesh, and it will refuse to start if either is busy.

### 9.1 Once, before the first night

| # | Check | Why it matters |
|---|---|---|
| 1 | **Run a PHD2 calibration on each unit.** | The cameras may have been rotated; a stale calibration silently inflates the guided residuals, which is the half of the measurement guiding exists to provide. |
| 2 | **Pin PHD2's "auto restore calibration".** | Stops PHD2 recalibrating mid-mesh. A recalibration takes minutes — longer than one 210 s slot — so it costs cells, not just time. |
| 3 | **Confirm the clocks.** Both units NTP-synced and agreeing with each other. | The wind data is joined to the telemetry by timestamp, offline. A few minutes of drift attributes a cell's data to the wrong wind and **nothing downstream reveals it.** |
| 4 | **Check `Z:` is mapped on both units.** | Without the share the units cannot share an epoch and will not be in lockstep — see `standalone` in 9.3. |
| 5 | **On a windy evening, settle the wind-vane question.** Watch which way the vane points, or take a handheld compass bearing against the prevailing SW–WSW flow, and write down what you see. | The Davis manual never states whether `wind_direction` is the direction the wind comes *from* or goes *toward*. If it is "toward", every bearing in §2.5 flips 180° and every broadside result inverts — and no amount of data would show the mistake. Five minutes, and it invalidates the whole analysis if skipped. |

### 9.2 Every night, before starting

1. **Unwrap axis0 if it is near a limit.** Check `min/max_mech_position_degs` against
   `position_degs` on each unit. The mesh sweeps azimuth all night and will find a limit
   that is already close; mast02 was found parked on its limit on 2026-08-28. Cells are
   skipped rather than forced, so a wrapped mount quietly does nothing all night.
2. **Mount ready**: unparked, tracking, covers open, focus done.
3. **Safety system reporting normally**, and check the forecast — rain ends the night.
4. **Decide pilot or full**, and use the **same choice on both units**. The second unit
   will be *refused* if its mesh does not match the first's. That refusal is deliberate,
   not a bug.
   - First 2–3 nights: **pilot** (10 cells).
   - After that: **full** (40 cells).
5. **Prefer a windy night.** §2.4: if it is at or above ~15 km/h at 21:00, this is an
   informative night — run the mesh. If it is calm, run it anyway when you can; the calm
   floor per cell is a requirement of the analysis, not filler.

### 9.3 Starting — and the one check that matters

Call `start_stability_campaign` on **both units, within a few minutes of each other**.
Order does not matter: whichever starts first creates the night's shared epoch, the second
adopts it.

Then call `stability_campaign_status` on both and confirm:

| Field | Expect | If not |
|---|---|---|
| `active` | `true` | Read `last_error`. |
| `standalone` | **`false` on both** | **Stop, fix the share, restart.** `true` means that unit invented its own epoch and is *not* paired with the other — the night's main result is lost even though data still accumulates. |
| `epoch_utc` | **identical on both units** | They are not in the same campaign. Stop both and restart. |
| `mesh_version` | identical on both | As above. |
| `cell` | **the same cell on both**, when read at the same moment | If they differ, they are not in lockstep. |

That last row is the whole point of running two units: the same cell, at the same instant,
on two OTAs. If it does not hold, the night measures half of what it should.

### 9.4 Through the night

Refresh `stability_campaign_status` occasionally. Normal looks like:

- `visits_completed` climbing by about **17 per hour** (one cell per 210 s slot).
- `phase` cycling `unguided` → `acquire` → `guided` → `idle`.
- `guide_failures` accumulating **mostly at low altitude**. This is expected and is not a
  fault — those cells still produce good unguided data.
- `coverage` filling in broadly evenly across cell indices.

Worth acting on:

| Symptom | Likely cause | Do |
|---|---|---|
| `cells_skipped` climbing steadily | axis0 near its wrap limit | Stop, unwrap, restart. |
| `guide_failures` high **at all altitudes** | calibration, focus, or cloud | Check PHD2; consider stopping and recalibrating. |
| `visits_completed` not advancing | walker stuck or mount fault | Read `last_error`; stop and restart. |
| The two units drift onto different cells | one lost slots to a long recalibration | It self-corrects at the next slot. If it persists, stop both and restart. |
| `standalone` became relevant (share dropped) | network/share | Data still lands locally; the pairing for that run is lost. |

Also note in the log book anything the software cannot see: cloud, dome/enclosure state,
wind you can feel, anyone touching the units. Those notes are what rescue an anomalous
night from being discarded.

### 9.5 Stopping

Call `stop_stability_campaign` on both units.

- It finishes the sample it is inside, then stops — expect up to about a minute.
- A cell counts only once **both** its dwells are written, so stopping mid-dwell discards
  that visit rather than contributing a short one. That is intended.
- **The mount parks on the way out.** Do not assume it is still tracking afterwards.
- Confirm `active: false` on both before leaving.

Stop for rain, an unsafe reading from the safety system, or a mount fault. Wind is *not* a
reason to stop — a windy night is the one you came for.

If a unit will not stop, the walker also gives up on its own after 14 hours, and it parks
by the same path. Restarting the unit's service is the blunt fallback; the products already
written are unaffected, since each cell is complete on disk before the next begins.

### 9.6 Where the data goes

`Z:\MAST\<hostname>\<observing-night>\Stability\<NNNN>\` — one folder per run, one
subfolder per cell visit, each holding `unguided.csv`, `guided.csv` and `meta.json`, with
`campaign.json` at the run root.

The `<observing-night>` label turns at **12:00 UTC**, so a whole night stays in one folder
and carries the same date as that night's logs. Expect roughly **200 MB per unit per
night**. Nothing needs copying by hand — the files move to the share as they are written.

---

## 10. The ongoing monitor — design, and what measuring a slew changed about it

§5 proposed a continuous stability monitor and it was never built; §8 built the *campaign*
instead. This section is the design for the other half — a gauge that runs on every unit all
the time — together with the hardware measurements taken on **2026-09-02** to settle the
numbers §5 left open.

It is written as a design, not as built code. **Nothing in §10 exists yet.**

### 10.1 What it is

`MountStatus.stability`: a **0–100 % gauge**, 100 % = steadiest, derived from the rolling
standard deviation of each axis's `measured_current_amps`, with the raw numbers reported
beside it and a per-night CSV of window aggregates accumulating so the scale can eventually
be set from data rather than chosen.

**Observer only. No gate, and deliberately no `stable` boolean** — which is where this
departs from §5.2. §5.3 already names the two occasions this repo has been bitten by a
threshold calibrated on one population and applied to another (`MIN_CONFIDENCE`,
`max_best_hfd_px`). A boolean in the status model is an invitation to gate on it, and the
threshold that would make it meaningful is precisely the number that is still unmeasured.
Expose the magnitude; let a later, evidence-backed decision add the gate.

### 10.2 The measurements — two runs on mast02, 2026-09-02

Both runs commanded gotos through the unit's own `PUT /mount/goto_ra_dec_j2000`, returned
to the identical J2000 coordinate, and sampled PWI4 `/status` at 25 Hz with de-duplication
on `axis0.position_timestamp` (~24.5 Hz of distinct samples, consistent with §6.1's 44 Hz
server-side refresh).

| run | move | samples | span |
|---|---|---|---|
| 1 | 5° in dec, out and back, plus a ±30″ `dec_add_arcsec` offset pair | 6076 | 251 s |
| 2 | 3° in dec, out and back, 180 s of post-slew tail each way | 10728 | 432 s |

**Floors (MAD-scaled σ of current, calm, tracking, enclosure closed):**

| | axis0 | axis1 |
|---|---|---|
| run 1 baseline | 0.00581 A | 0.00639 A |
| run 2 baseline | 0.00611 A | 0.00747 A |

The floor is therefore **reproducible to roughly ±15 % between runs twenty minutes apart**.
That is the variability a learned floor has to absorb, and it is small enough that a p10
over two nights is a sound estimator. Compare §6's earlier figures — 0.0046/0.0055 A
stationary (2026-08-28) and 0.0067/0.0060 A tracking — and the whole family sits in
0.0046–0.0075 A. The quantisation step is 1e-05 A, so σ is 300–750× the step: **the bottom
of the gauge is real signal, not the encoder.**

### 10.3 Three questions the slew was run to answer

#### Q1 — the upper anchor: *not* answered, and the slew disqualified itself as the source

The intent was to replace the one invented constant with a measured ceiling. That was the
wrong instrument, for a reason only visible after running it: **slews are excluded from the
gauge**, so slew current cannot anchor a scale the slew never enters.

What the slew does supply is the **contamination magnitude**, which is what justifies the
contiguity rule in §10.5:

| during `is_slewing` (run 1, 5° in dec) | axis0 | axis1 |
|---|---|---|
| σ of current | 0.0776 A = **13× floor** | 0.8416 A = **132× floor** |
| peak \|I\| | 0.895 A | 6.014 A |

And it supplies a **lower bound on the mapping's zero point**: a perfectly healthy mount,
merely settling after its own goto, reaches ratio ≈ **2.3** (§10.4). So `R` — the ratio that
maps to 0 % — must be comfortably above that, or routine post-acquisition settling would
display as total instability. `R` in the 5–20 band is the defensible starting range; the
number itself still has to come from windy tracking data, which a closed enclosure on a calm
evening cannot produce. **`PROVISIONAL_ZERO_PERCENT_RATIO` stays provisional**, and §10.7
says what replaces it.

#### Q2 — the settle margin: 5 s was wrong by an order of magnitude, and the right answer is not a margin

Run 1 first showed axis1 σ still at 1.3–2.7× the floor a full 60 s after `is_slewing`
cleared. Run 2, with proper exclusion and a 180 s tail, resolves it:

| 30 s window ending N seconds after the last excluded sample | slew out | slew back |
|---|---|---|
| +30 s | 1.08 / **1.24** | 0.90 / **2.28** |
| +45 s | 1.08 / 0.90 | 0.91 / **1.57** |
| +60 s | 1.10 / 0.90 | 0.85 / **1.28** |

(ratio0 / ratio1, against that run's own baseline floor.)

Two findings:

- **The outbound slew settled immediately** — the first fully contiguous window was already
  within noise. **The return took ~60 s.** The asymmetry is the hysteresis of §10.6, not
  noise.
- **Contiguity already buys 30 s for free.** A 30 s window containing no excluded sample
  cannot begin until 30 s after the last excluded one. So the design does not need a settle
  *margin* in the usual sense; it needs **one additional discarded window** after any
  exclusion, which covers the reversal case and costs 30 s of blankness the operator can see
  in `state`.

Replace §5.4's "drop samples during motion plus a settle margin" with: **clear the window on
any excluded sample, then discard the first window that would otherwise complete.**

#### Q3 — signal ordering: `setpoint_velocity` does not lead, and it does not need to

Run 2, both slews, seconds since start (`^` rising, `v` falling):

```
pwi4 is_slewing        32.45^  37.02v    232.49^  237.09v
axis1 setpoint>1e-3    32.50^  36.56v    232.53^  236.66v
flag Slewing(4)        33.73^  37.97v    234.02^  238.02v
flag Moving(128)       34.53^  38.81v    234.84^  238.78v
```

`setpoint_velocity` **lags `is_slewing` by 0.05 s — one sample.** It does not lead. But the
question mattered only for `mount_offset()`, which raises no flag and has no `is_slewing` to
race against, and there setpoint moved **0.08 s after the command was issued**. Both cases
are covered; the residual race is one sample wide and contiguity absorbs it.

**The flag ordering result is an artefact, and the artefact is the useful part.**
`MountActivities.Slewing` appears to lag `is_slewing` by ~1.3 s and to clear ~0.9 s late.
It does not: [`mount.py`](../../unit/src/mount.py) calls `start_activity(Slewing)` *before*
`pw.mount_goto_ra_dec_j2000`. The lag is entirely the measurement path — `/unit/mount/status`
takes **0.70 s** to answer (and `/unit/status` takes **5.85 s**, which is why run 1's mask
column came back empty: a 3 s client timeout against a 5.85 s endpoint failed all 76 attempts
it managed in 250 s).

The design consequence is concrete: **the monitor must read activity flags in-process via
`self.mount.is_active(...)`, never over HTTP.** Through HTTP the flag is ~1.5 s stale, which
is 15 samples at 10 Hz.

`Moving(128)` trails `Slewing` by a further ~0.8 s in both directions — the `is_moving`
rms-error test lagging, exactly as its definition implies.

### 10.4 The three layers, so the invented number is isolated

**Layer 1 — measurement.** Rolling σ per axis, reported verbatim with `n`, `n_excluded`,
`window_seconds`, `sample_hz`, `sample_age`. Nothing invented.

**Layer 2 — ratio to a learned floor.** `ratio_axisN = σ_axisN / floor_axisN`.
Dimensionless, ≈1 when calm: *this axis is working N× harder than its own quietest observed
state.* **Normalise per axis before combining** — the two axes have different floors and
different loads, so combining σ first lets the structurally noisier axis dominate for
reasons of scale rather than disturbance. Report both, and `ratio = max(...)`.

**Layer 3 — the percentage, the only invented thing.**

```
percent = 100 * (1 - log(clamp(ratio, 1, R)) / log(R))
```

Linear in log-ratio: 100 % at ratio 1, 0 % at `R`, bounded by construction. **Linear rather
than a logistic** (sky_quality's shape) because a logistic has a knee, and placing a knee
asserts where "good" becomes "bad" — the precise thing that is unmeasured.

`R` = `PROVISIONAL_ZERO_PERCENT_RATIO` carries a `#:` provenance block in the
`MIN_CONFIDENCE` style recording: the floors of §10.2, the ratio ≈2.3 healthy-settling lower
bound, that **no reading under wind has ever been taken**, that a wrong value compresses or
saturates a display and gates nothing, and that p95 of `ratio` from the campaign's windy
nights replaces it. A `MAPPING_VERSION` rides on the status and every log row so any stored
percentage can be re-derived — the `MESH_VERSION` lesson from §8.

**Insufficient data is `percent = None`, never `0.0`.** This is the explicit fix for
[`sky_quality.py:112`](../../unit/src/science/sky_quality.py#L112), which sets
`score_0_to_100 = 0.0` during warm-up. To be fair to it, `quality_state = WarmingUp` sits on
the next line, so the discriminator does exist — but the *score field itself* reads as
"terrible" to anything that plots it, and a nested object that is present-with-`None` says
the same thing without needing the reader to know about a second field.

### 10.5 Exclusion — what a sample must not be

The predicate returns a **reason string or `None`**, so exclusions are counted by cause.

**Do not exclude on `Mount.is_moving` / `MountActivities.Moving`.** It is
`axis0.rms_error_arcsec > 3.0 or axis1.rms_error_arcsec > 1.0` — a tracking-*quality* test
mimicking PWI4's GUI. Measured in wind on 2026-07-21, **tracking on target with
`is_slewing=False`**, axis0 rms ran 1.36–3.81″ and axis1 1.00–6.40″, making `is_moving` true
in **6 of 7 samples**. Excluding on it discards precisely the windy samples the gauge exists
to measure. This gets a loud comment and a named regression test.

Exclude on, in this order:

| test | evidence |
|---|---|
| PWI4 `mount.is_slewing` | direct |
| `Slewing\|Parking\|FindingHome\|Dancing\|Aborting\|StartingUp\|ShuttingDown`, read **in-process** | §10.3 Q3 |
| not tracking | a stationary mount is a different regime; admitting it lets a stationary floor reinforce itself |
| axis0 `setpoint_velocity` departing from sidereal, or axis1 from 0, by **> 1e-3 °/s** | §10.5 below |
| the window's first completed window after any of the above | §10.3 Q2 |

#### Discriminate on `setpoint_velocity`, not on `dist_to_target`

`dist_to_target` is the second instance of the `is_moving` trap:

| | calm (2026-09-02) | windy (2026-07-21) |
|---|---|---|
| \|dist_to_target\| | median 0.03″, max 0.14″ | **0.06–5.89″**, tracking on target |

A `dist_to_target > 0.5″` test — `wait_until_settled`'s default tolerance — passes in calm
and **excludes most windy samples**. The 2026-07-21 note says it directly: *"following
distance itself gusts to ~5.9″, so `wait_until_settled`'s 0.5″ default tolerance is unusable
here."* Log `dist_to_target`; use it at most as a very loose sanity bound at tens of
arcseconds, never at 0.5″.

`setpoint_velocity` has the opposite character because it is **commanded intent, not
response** — wind perturbs the measurement and never the setpoint.

#### The threshold, measured — and a correction to the margin originally claimed

Over 3643 calm tracking samples:

- axis1 `|setpoint_velocity|` reaches **7.6e-05 °/s**, p99 5.7e-05, and is **nonzero in 1331
  of 3643 samples**. It is *not* identically zero while tracking, so a threshold at 1e-4 —
  the obvious choice — sits only 1.3× above observed noise.
- axis0 setpoint spans 0.004140–0.004241 °/s around a sidereal 0.004178, a spread of 1.0e-04.

**The threshold is 1e-3 °/s**: 13× above tracking jitter, and 60× below the quietest
departure any real move produced.

The margin claimed while planning — *"a slew runs to 20 °/s, ~4800× sidereal, so the
separation is unambiguous"* — **is wrong for the axis that was not commanded.** During a
5° dec slew, axis0 setpoint only departed to −0.053…+0.062 °/s, some 15× sidereal, because
axis0 was merely tracking through it. 1e-3 still catches that comfortably; the reasoning
behind it needed correcting.

#### The gradual-offset test covers almost nothing, and the offset kind that matters is the other one

Planned: exclude on `gradual_offset_progress` in flight, handling its **signed** convention
(`_gradual_ramp_complete` in `mount.py` already does, correctly: completion is
`|progress| >= 1.0`, since a negative offset ramps 0 → −1.0).

Measured: through both a +30″ and a −30″ `dec_add_arcsec`, **`gradual_offset_progress`
stayed pinned at 1.000 and never dipped.** That is correct behaviour, not a bug — it is
`SettleMode.OFFSET_STEP`, and only `OFFSET_GRADUAL` moves the progress field.

This matters because **the offsets the code actually issues are mostly `OFFSET_STEP`**:
spiral search (`spiral_search.py`) and exposure-series offsets (`unit.py`) both use discrete
`add_arcsec` and `wait_until_settled(SettleMode.OFFSET_STEP)`. So the gradual-progress test
would have excluded almost nothing in practice.

`setpoint_velocity` caught it: **61 of 602 samples above 1e-3, first at +0.08 s, last at
+5.94 s** — a 30″ offset takes about 6 s of commanded motion. Keep the gradual-progress test
for the `OFFSET_GRADUAL` path, but it is a supplement; **`setpoint_velocity` is the
load-bearing discriminator**, and there is no `MountActivities.Offsetting` to fall back on.

#### Window contiguity, not sample dropping

**Clear the window on any excluded sample**, so a window is always a contiguous run. This
keeps `n` honest, stops two pointings' samples being stitched into one σ, and means a
partially contaminated window is *discarded* rather than reported. Given contamination of
13–132× floor (§10.3 Q1), the property worth having is that contamination costs a window of
blankness and can never produce a wrong number.

The gauge therefore goes blank for one to two windows after every acquisition slew. That is
the correct answer and satisfies §5.4's "make unknown visible".

### 10.6 The statistic, the window, and a hysteresis nobody was looking for

**MAD-scaled σ (`1.4826 × MAD`) primary, plain `pstdev` alongside.** Both estimate the same
quantity; the robust one is not hostage to a single unexcluded micro-offset, which inflates
the plain estimate quadratically. Reuse `median_absolute_deviation` from
[`sky_quality.py:15`](../../unit/src/science/sky_quality.py#L15), moved to `common/` now it
has two consumers. Subtracting the window median also absorbs slow gravity-load drift.

**The 30 s window is not arbitrary, and run 2 shows why a longer one is worse.** Computing σ
over a whole 180 s phase versus over 30 s windows inside it:

| phase | axis | σ over the whole phase | rolling 30 s windows |
|---|---|---|---|
| `settle_out` | axis0 | 0.01281 A (ratio **2.10**) | ratio 1.08–1.12 |
| `settle_back` | axis1 | 0.04585 A (ratio **6.14**) | ratio 0.86–1.57 |

The long-span figures are inflated by **slow drift, not jitter**. A σ taken over minutes
measures the drift; a σ taken over 30 s measures the disturbance the gauge is about. Do not
lengthen the window to get more samples.

**An unplanned finding: axis1 current is hysteretic in approach direction.** At the *same*
mechanical position, axis1 mean current was:

| | axis1 mech | mean current |
|---|---|---|
| run 1, before the excursion | 48.8551° | **−1.8640 A** |
| run 1, after returning | 48.8537° | **−0.7481 A** |
| run 2, before | 48.8512° | −0.9625 A |
| run 2, after returning | 48.8492° | −0.7834 A |

A spread of about **1.1 A at one position**, depending on how it was approached. Two
consequences:

- It is direct evidence for the design's choice of **σ and never the mean** — a mean-based
  gauge would read wildly differently at the same pointing for no disturbance reason.
- The learned floor is **not purely a property of the mount**; it carries some dependence on
  approach history. A p10 over ~2 nights averages across approaches, which is the right
  shape, but the effect belongs in the log and in the constant's provenance.

It also explains the settle asymmetry of §10.3 Q2: the direction-reversing return is the one
that took 60 s.

### 10.7 The floor

Push each completed window's σ into a `deque(maxlen≈2400)` (~2 nights); the floor is the
**p10, not the minimum** — the minimum is the noisiest order statistic and one dropout would
define it forever. Require ~1 hour of windows before using it; until then use the §10.2
measurements as a bootstrap and report `floor_source="bootstrap"`.

Note the direction of that bootstrap error: the **tracking floor sits above the stationary
floor** (stationary excludes torque ripple and cogging), so a stationary bootstrap makes the
gauge read **pessimistically**. That must be visible in the status, not merely described as
"provisional".

Persist as a `MountStabilityCalibration` in `common/config/calibration.py` — a learned floor
is a calibration, not telemetry, so it belongs with the machine-written records that already
carry provenance, and it gets `matches()` for free. The gate is load-bearing: **a floor
learned at a different `window_seconds`, `sample_hz` or statistic is not the same
statistic**, and silently reusing one would be `MIN_CONFIDENCE` a third time.

Write **once after the first hour and on stop — never per window.** §5.5 forbids coupling
observing-time writes to the config DB, and the write must be wrapped so a `ConfigError`
never reaches the monitor thread.

**Open, and it decides whether even that is allowed:** whether `Config.set_unit` bumps a
generation that `common/config/_watcher.py` propagates to running components. If it does,
hourly floor writes are wrong and persistence must be shutdown-only.

### 10.8 Shape of the implementation

| file | | contents |
|---|---|---|
| `unit/src/PlaneWave/fast_status.py` | new | `Pwi4StatusPoller` — persistent `httpx.Client(trust_env=False)`, field-restricted `key=value` parse, dedupe on `axis0.position_timestamp` |
| `unit/src/mount_stability.py` | new | exclusion predicate, window, statistic, floor learner, mapping, CSV writer, monitor |
| `common/models/statuses.py` | edit | `MountStabilityStatus`; `MountStatus.stability` |
| `common/config/mount.py` | edit | `MountStabilityConfig`, all defaulted (no DB migration) |
| `common/config/calibration.py` | edit | `MountStabilityCalibration` + `matches()` |
| `common/paths.py` | edit | `make_stability_monitor_folder()` |
| `unit/src/mount.py` | edit | construct the monitor; pass `stability=` in `status()` |
| `unit/tests/test_mount_stability.py` | new | §10.9 |

**The poller.** The vendored `pwi4_client.py` uses `urllib.urlopen` — a fresh TCP connection
per call, fine at 2 s, wrong at 10 Hz. `TelemetrySampler` in §8's `stability_campaign.py`
already solves this; extract **only the poller** to `fast_status.py` on `main` and let the
campaign delegate to it. `trust_env=False` is load-bearing and must survive with its comment:
WinINET *registry* proxy settings otherwise route even `127.0.0.1` through the site proxy,
which answers 403. Take the field tuple as a constructor argument so campaign and monitor
cannot drift into a shared constant. Derive the URL from `Mount.pw.host`/`.port`.

**Not `RepeatTimer` at 10 Hz.** `common/utils.py` is `while not self.finished.wait(interval)`,
so the period is `interval + function duration` and drifts — invisible at 2 s, not at 0.1 s.
Use a daemon thread with a monotonic-deadline loop. (Both measurement scripts did exactly
this and held 24.5 Hz against a 25 Hz request with zero dropped polls, which is the shape
being recommended.)

**Status.** `MountStabilityStatus` nested as `MountStatus.stability`, carrying `state`,
`percent`, `ratio` (+ per axis), σ per axis, servo-error σ, floor per axis, `floor_source`,
`calibrated`, `mapping_version`, window/rate, `n_samples`, `samples_excluded`,
`excluded_reason`, `sample_age_seconds`, `latest_update`. **100 % = most stable**, documented
and tested, because the phrase is ambiguous.

The nested object is `None` only when the monitor was never constructed; when it exists
without data it is **present** with `state="Unknown"` and `percent=None`, so a GUI can tell
"no such capability" from "no data yet".

`unit/tests/test_status_fields_are_populated.py` statically requires every `MountStatus`
field to be passed **by keyword** at the construction site, so `Mount.status()` must
literally read `stability=self.stability.status() if self.stability else None`. **That
snapshot read must never touch the network** — `/unit/mount/status` already costs 0.70 s
(§10.3 Q3) and must not also inherit the monitor's PWI4 latency.

**Log.** One row per completed window to
`<share>/<hostname>/<observing-night>/Stability/monitor/` via
`make_stability_monitor_folder()` — named distinctly from §8's `make_stability_folder` to
avoid a collision, but a deliberate sibling so both land in one tree. ~1200 rows/night.
Columns: timestamps, n, excluded + reasons, σ (both estimators) and mean per axis,
servo-error σ, setpoint velocity, alt/az, max `dist_to_target`, `is_tracking`, activity mask,
floors, `floor_source`, ratio, percent, `mapping_version`, rate/window/statistic. Plus a
per-night `meta.json` recording that `activities_mask` **may contain `Moving` on windy nights
and that this is logged, never excluded on** — so an analyst months later does not filter on
it.

**Rotate every 30 minutes and on the 12:00 UTC rollover.** Do *not* hold
`MoveGuardian().protect()` open all night: `protect()` claims the folder until
`release_folder()` reaps it after `_RELEASE_TIMEOUT_SEC = 600`, so an eight-hour claim would
block `Filer.move` on that folder for the night. §8's campaign escapes this only because its
dwell is 60 s. Rotation also caps crash loss at one file.

Raw per-sample CSV stays behind a flag, default **off** — §8 already exists to capture raw at
full rate.

**Robustness.** The monitor swallows every exception, counts consecutive failures, and
disables itself with one log line past a threshold. A new 10 Hz thread must not be able to
take down the mount component.

### 10.9 Verification

Against a synthetic injected poller (the `test_spiral_search.py` pattern):

- the exclusion table: `is_slewing`; each activity bit; not tracking; setpoint above and
  below 1e-3; `gradual_offset_progress = -0.4` → excluded (pins the signed-progress
  convention); `offsets` absent → not excluded, no crash
- **`test_a_high_rms_error_does_not_exclude_a_windy_sample`** — `rms_error_arcsec = 9.0`,
  tracking, `is_slewing=False` → **not excluded**; the docstring carries the 6-of-7 evidence
- **`test_a_discrete_offset_is_excluded_by_setpoint_velocity_alone`** — the run-1 case:
  `gradual_offset_progress` pinned at 1.0 throughout, setpoint above 1e-3 → excluded
- **`test_insufficient_data_is_none_not_zero`** — names the `sky_quality` wart it prevents
- statistic: a synthetic trace of known σ; one outlier moves `pstdev` a lot and MAD little
- contiguity: one excluded sample mid-window clears it, `percent` returns to `None`, and the
  next window to complete is also discarded
- mapping: `percent(1)==100`, `percent(R)==0`, monotone, **bounded 0–100 for
  ratio ∈ {0, 0.5, 1, R, 10R, inf, nan}**
- **`test_the_floor_is_learned_from_the_calm_tail_not_the_average`** — 90 % windy windows,
  10 % calm; the floor lands on the calm value
- `matches()` rejects a floor stored at a different window/rate/statistic → falls back to
  bootstrap
- poller: canned `/status` text in `tests/fakes/`; field extraction, dedupe on a repeated
  timestamp, a raising callable counted as a dropped poll, and **no `httpx.Client`
  constructed when a callable is injected**

On hardware: `MountStatus.stability` populates within one window; `samples_excluded` rises
during a slew and the gauge **blanks rather than dipping**; the CSV appears on the share and
rotates; a calm reading sits near ratio 1 against the §10.2 floors.

### 10.10 Sequencing

0. Pure additions, no behaviour: move `median_absolute_deviation`; add the status model,
   config, calibration model, `PathMaker` method. Small PR — the piece most likely to
   conflict with §8's branch.
1. `fast_status.py` + tests, no caller yet; the campaign rebases onto it.
2. `mount_stability.py`, fully tested with an injected poller, not yet wired.
3. Wire into `Mount`; CSV writer with rotation.
4. Floor persistence — subject to the `_watcher` question in §10.7.
5. **Only once campaign data exists:** replace the provisional ratio, set `calibrated=True`.
   Turning the gauge into a gate is a separate decision needing its own evidence.

### 10.11 Deliberately out of scope

- **No gate, no `stable` boolean** — departs from §5.2, see §10.1.
- **No `is_moving` refactor.** Splitting it into `is_slewing` + `tracking_quality` was agreed
  on 2026-07-21 and deferred; §10 delivers only the *reading* half. The refactor also has to
  fix `autofocusing.py`, which by the same measurement stalls ps3cli autofocus in wind, and
  that touches an operational path. Its own PR.
- **No wind-bearing binning.** §5.4 wants `(altitude, |az − wind bearing|)`; v1 has one
  global floor with alt/az on every row so a binned floor is derivable offline. §5.4's
  binning is a requirement for a *gate*; this is an observer.
- **`sky_quality`'s warm-up `0.0`** is live today and is a one-line fix. Worth its own PR.

### 10.12 Still open

- **The 0 % anchor.** Needs windy tracking data. Until then `R` is a chosen number in the
  5–20 band with a lower bound of ~2.3 established by healthy settling.
- **Guiding.** PHD2 corrects continuously during an acquisition. If those corrections reach
  the mount as PWI4 offsets they will move `setpoint_velocity` constantly and the gauge will
  be permanently blank for most of the observing night — which would be fatal to the whole
  idea. If instead PHD2 drives the mount by another path, the corrections appear only in the
  axis telemetry and the gauge measures *residual after guiding*, a different but still
  meaningful quantity. **This was not measured and must be, before Stage 2.** It is the
  single largest unknown remaining in this design.
- **`Config.set_unit` and the config watcher** (§10.7).
