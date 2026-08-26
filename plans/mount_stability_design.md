# Mount Stability Monitoring — Design Notes and Site Wind Climatology

*Design document for a proposed `MountStabilityMonitor`, owned by `Mount`, plus the
research that motivates it. Nothing here is implemented yet. Written 2026-08-26.*

**Status: research complete, design agreed, not built.** The measurements in §2 are real
and reusable regardless of whether the monitor is built. §5 records design decisions
reached in discussion; §6 lists what must be measured before writing code.

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

### 2.1 Two calibrations that had to be derived

**`tstamp` is UTC.** Mean `solar_radiation` peaks at hour 09; solar noon at Neot Smadar
(~35.0°E) is 09:40 UTC. Local = UTC+3 (IDT) / UTC+2 (IST) — use
`tstamp at time zone 'UTC' at time zone 'Asia/Jerusalem'` so DST is handled.

**`wind_speed` is km/h, quantised to 1 mph steps.** Values step by 1.6 (3.2, 4.8, 6.4,
8.0, 9.7, 11.3, 12.9 …) and 1 mph = 1.609 km/h, so the Davis is configured in mph and
stored as km/h. *Inferred from the quantisation, not from documentation — confirm at the
Davis console before hard-coding any threshold.*

### 2.2 The diurnal curve

Median wind by local hour, in mph:

| local | p50 | p75 | p90 | |
|---|---|---|---|---|
| 14:00–20:00 | **8** | 11 | 14 | peak |
| 21:00 | 7 | 10 | 13 | decline begins |
| 22:00 | 6 | 9 | 12 | |
| 23:00 | 5 | 8 | 11 | |
| 00:00 | 4 | 7 | 10 | |
| 01:00 | 3 | 6 | 9 | |
| 03:00–06:00 | **2** | 4 | 7 | true calm |

**Two corrections to the working assumption ("wind after sundown, calms 10–11 PM"):**

1. **Wind does not start after sundown.** It peaks in the *afternoon*, 14:00–20:00, and
   simply continues through sunset. It is blowing hardest before dark.
2. **22:00 is the start of the decline, not the end.** It is a ~7-hour ramp from peak at
   20:00 to minimum at 03:00. At 22:00 the median is still ~75% of the evening peak.

### 2.3 How often it is still up

Percentage of nights whose hourly mean exceeds a threshold:

| local | >10 mph | >15 mph | >20 mph |
|---|---|---|---|
| 20:00 | 36.3% | 2.3% | 0.0% |
| 21:00 | 31.6% | 1.1% | 0.0% |
| 22:00 | 18.4% | 0.3% | 0.0% |
| 23:00 | 10.4% | 0.4% | 0.0% |
| 00:00 | 7.9% | 0.6% | 0.0% |
| 03:00 | 5.4% | 0.5% | 0.0% |

"Still high at later hours" is real: **~1 night in 5 is above 10 mph at 22:00, 1 in 10 at
23:00, and ~1 in 20 never really calms.**

**But the third column is the important one.** In ~800 nights the hourly mean **never once
exceeded 20 mph**, and exceeded 15 mph on well under 1% of hours. This is not a violently
windy site — it is a persistently *breezy* one. The disturbance to design for is **chronic
low-level buffeting, not rare storms**, which argues for a sensitive continuous metric
rather than a trip threshold.

### 2.4 The actionable finding — 21:00 predicts the night

| state at 21:00 | nights | >10 mph at 23:00 | at 01:00 | at 03:00 |
|---|---|---|---|---|
| calm | 543 | 3.7% | 2.8% | 2.8% |
| **windy (>10 mph)** | 251 | **25.1%** | **11.6%** | **11.2%** |

A windy 21:00 makes a windy 01:00 **~4× more likely**, and the elevated risk stays flat to
03:00 rather than decaying. That is schedulable: by 21:00 you already know which kind of
night it is, and can bias target selection (altitude, azimuth relative to wind) or exposure
length for the whole night instead of reacting gust by gust.

The converse is the stronger half: **calm at 21:00 → ~97% chance of a calm night.** On most
nights you can stop worrying early.

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
silently rots. Bin by altitude at minimum — low elevation means more sail area and a
different gravity torque, so a single global baseline false-positives on every low target.

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
| Target selection — avoid low altitude and broadside-to-wind | scheduler | needs §2.4 + a pointing model |
| Safety threshold → park/close | real time | today, blunt |
| Servo tuning (AutoTuner, or PWTools) | permanent, offline | §4 |

**Guiding is the under-used one in this framing.** It is already a calibrated,
arcsecond-domain, closed-loop wind rejector running during every acquisition, and its
correction history is a *third* wind signal that is already in the logs.

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

### 6.2 Interference — only then

What matters is not the poller's throughput but whether it degrades PWI4's service to
`mount.ontimer`, guiding and slew acceptance. Run a **victim** — a 2 s `/status` loop
mimicking `ontimer`, recording its latency distribution — while a load loop ramps
1 → 2 → 5 → 10 → 20 Hz. Watch the victim's **tail**, not its median. Measure with both
`urllib` (as vendored) and a persistent `httpx.Client` so the connection-setup share of any
knee is known.

Run on a unit whose mount is tracking but **not doing science** — engineering time. Note
mast02 is not suitable: port 8220 there serves an HTML page, so PWI4 is not running.

### 6.3 The offline characterisation

High-rate direct-drive telemetry via PWTools gives the true disturbance spectrum and, via
its current-noise statistics, the measurement noise floor — without which an elevated σ
cannot be attributed to wind rather than to the current sense. **This calibrates the online
detector**, and a windy night that cannot be observed on is exactly when to run it.

### 6.4 Open questions

- **Safety sensor cadence and history.** `SensorModel.readings` is a *list* and the code
  takes `readings[-1]`. If the service retains depth, nights already observed can be joined
  retrospectively instead of polling and storing. How far back, and how often does it
  update? A 1-minute anemometer against seconds-scale gusts bounds what correlation is
  establishable. (The Davis table itself is 60 s — see §2.)
- **What threshold does the safety system already use** for `is_safe` on wind-speed? That
  is an existing, operationally-validated number and the natural anchor.
- **Confirm the mph/km-h units** at the Davis console (§2.1).
- **`/mount/configure` parameters** — ask PlaneWave.

---

## 7. Provenance

- Wind climatology: `sensors.davis`, PostgreSQL `last_operational` on `10.23.1.25`,
  2024-01-01 → 2026-08-26, ~1.27M readings / ~800 nights. Queried 2026-08-26.
- PWI4 API surface: [PWI4 CHANGELOG](https://planewave.com/files/software/PWI4/CHANGELOG.txt),
  the [2021 HTTP API PDF](https://www.indilib.org/media/kunena/attachments/7104/PlaneWavePWI4ProgrammingAPIviaHTTP2021-05-31.pdf),
  the [current reference client](https://planewave.com/files/software/PWI4/python/pwi4_client.py),
  and the vendored `unit/src/PlaneWave/pwi4_client.py`.
- PWTools: binary inspection of `C:\Users\mast\Downloads\PWTools-2024-09-17\` on mast02.
- Threshold-calibration precedent: `spiral_search_summary.md` §4,
  `focuser_calibration_summary.md`.

**Nothing in §5 has been implemented, and no part of this has been tested against a real
mount under wind.**
