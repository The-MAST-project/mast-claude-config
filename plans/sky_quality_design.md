# Consolidated sky quality — design & methodology

*MAST unit · a flow-independent sky-quality layer, fed parasitically by existing
flows, writing a nightly per-beam record — planned shared module (promoted from
`src/focus_on_star/sky_quality.py`) + a nightly JSONL log (patterned on
`src/mast_guider/guide_log.py`)*

This note documents the design for a **single, flow-independent sky-quality layer**
on a MAST unit: one measurement kernel, one per-unit owner, one durable nightly
record, fed opportunistically by the flows that already take solved frames. It
consolidates three sky-quality paths that measure overlapping-but-different things
today.

> **Status (read first):** this is a **design**, not yet implemented, and it is
> deliberately **phased**. Phase 1 (the kernel, the sample schema, the nightly
> log, one parasitic feed, an ephemeral status gauge) is self-contained and ships
> value on its own. The **abort-on-conditions policy** and the **site sweeper** are
> named here as later phases but are **not specified** — do not build them from this
> note. An authoritative **site-wide** sky survey (a dedicated SQM / all-sky camera)
> is **explicitly out of scope**: a unit measures only its own pencil beam, and only
> while active. See [§10](#10-the-site-layer-out-of-scope-here) and
> [§11](#11-deferred--out-of-scope).

---

## 1. Purpose & scope

Three places gather sky-quality data today, each shaped by its flow and each
owning its own schema and status field:

| Source flow | Producer | What it measures | Status owner |
|---|---|---|---|
| PHD2 guiding | `GuidingSkyQuality` (`src/science/sky_quality.py`), fed by PHD2 guide **events** | **Relative**: PHD2's own HFD / SNR / StarMass, transparency vs the session's first minute | `guider.sky_quality_while_guiding` |
| `focus_on_star` | `measure()` (`src/focus_on_star/sky_quality.py`) on a **solved frame** | **Absolute**: FWHM/HFD in arcsec, zero-point vs Gaia DR3, airmass, background | `focus_on_star.sky_quality` |
| mast guiding | source-selection seeing estimate + guide scatter | measured, but wired into **neither** — a gap | — |

The status/model layer is already partly unified: `FullUnitStatus.latest.sky_quality`
is a `LatestSkyQuality` wrapper over `while_guiding` + `measured`
(`common/models/latest.py`), assembled by `Unit._latest_sky_quality()`. The
fragmentation is one layer down — **two different measurement kernels, a third flow
feeding nothing, and no durable history.** This design unifies the producers under
the existing status contract and adds the record.

**Goal.** A per-unit, flow-independent sky-quality layer that (a) produces **one
calibrated reading** from any solved frame, (b) appends readings to a **durable
nightly record** in the unit's night folder, (c) exposes a **small ephemeral
summary** in `/unit/status`, and (d) carries enough **context** on every reading to
support later per-product provenance, cross-unit corroboration, and a per-unit
baseline.

**Non-goals (this design).** The abort decision, active (non-parasitic) probing,
and any site-wide survey. See [§11](#11-deferred--out-of-scope).

---

## 2. Principles

These are the decisions the rest of the document rests on.

1. **One kernel, calibrated.** The common currency is the **absolute** reading
   (arcsec seeing, zero-point per second, airmass recorded) — the only thing
   comparable across units, nights, and (later) sites. Relative per-session metrics
   (PHD2 HFD, guide SNR) survive only as session-local annotations, never as the
   cross-unit currency.

2. **Parasitic, never active.** Readings come from frames the flows **already
   solve** — acquisition solves, the mast guider's §3.3 validation solve, a focus
   frame. The layer **takes no exposures of its own.** This matches the physical
   truth that a unit's data only pertains to its allocated task.

3. **A unit measures a pencil beam, while active.** A reading describes the sky
   **along this unit's line of sight, at this moment, through this unit's optics.**
   It is not an all-sky datum, and there are **no readings while the unit is idle**
   (no task → no frames). This gap is accepted, not papered over.

4. **A single beam confounds sky, instrument, and star.** A transparency drop can
   be local cloud, this unit's dew/defocus, or a bad star. The layer **records the
   effect and the context; it does not attribute the cause.** Attribution is a
   cross-unit / dedicated-instrument job, out of scope here.

5. **The record is durable; the status is ephemeral.** The nightly JSONL is the
   history for analysis. `/unit/status` carries only a short rolling summary that
   newer readings overwrite.

6. **The layer can never fail the flow it rides.** A reading is a by-product of a
   guide cycle or an acquisition. Measuring it, locking the log, or writing it must
   **never stall or fail** the host operation — on any error or contention, drop the
   reading and continue. (Same contract as `Notifier`: a notification can never fail
   the operation it announces.)

---

## 3. The reading — `SkyQualitySample`

One record per solved frame. The schema is the contract between the kernel, the
log, the status summary, and every later consumer, so it is the **primary
deliverable** of Phase 1. It has three parts.

**Measured** (from the frame + its solve — these are most of
`LatestMeasuredSkyQuality` today):
- `fwhm_arcsec`, `hfd_arcsec`, `hfd_over_fwhm` — delivered image size (seeing +
  optics).
- `zero_point_mag` = `G + 2.5·log10(counts/s)`, median over matched unsaturated
  Gaia stars; `zero_point_spread_mag` (MAD→σ); `zero_point_stars`.
- `background_adu` — median of the measured region, bias included (no sky-brightness
  conversion until a bias level is configured).
- `catalog_stars`, `detected_stars`, `matched_stars` — detection/match census (a
  cheap transparency and crowding signal).

**Context** (deterministic — computed from the pointing + ephemeris, free from the
IERS/astropy stack the unit already runs). **Kept on every reading even though the
abort policy is deferred** — the per-product provenance, the corroboration, and the
baseline all need it; only the *decision logic* waits.
- `observed_at` (ISO UTC, mid-exposure), `exposure_seconds`, `binning`,
  `plate_scale_arcsec`.
- `ra_deg`, `dec_deg`, `altitude_degs`, `airmass`.
- `moon_separation_degs`, `moon_phase`, `sun_altitude_degs` (twilight).
- `rotation_degs`, `mirrored` (from the match — orientation sanity).

**Provenance** (so a later consumer can weight, compare, and exclude):
- `source_flow` — `acquisition` | `guiding` | `focus_on_star`.
- `phase` — `sky` | `spec-mirror-out` | `spec-mirror-in` (the fold-mirror shadow is
  in the frame during the spec phases; a consumer must know, or a reading's
  background/counts are polluted by the instrument, not the sky).
- `plan_id`, `frame_path` (the FITS this reading came from).

> `LatestMeasuredSkyQuality` (`common/models/latest.py`) is already ~80% of the
> measured + context fields. `SkyQualitySample` is that model generalized to any
> solved frame and extended with the ephemeris context and the provenance.

---

## 4. The measurement kernel

A **pure** function: `image + SolvingSolution (+ exposure, pointing, catalog) →
SkyQualitySample`. No hardware, no flow state, no I/O beyond the catalog read.

This already mostly exists as `src/focus_on_star/sky_quality.py` — `match_field`
(detected stars → Gaia DR3), `zero_point` (flux vs catalog mag / exposure /
airmass), `airmass`, `measure`. The work is to **promote it out of
`focus_on_star/`** into a shared home (e.g. `src/science/`, beside the guiding
aggregator), generalize the input from "a focus frame at the fibre" to "any solved
frame", and emit a `SkyQualitySample` rather than the focus-specific `Measurement`.

It reuses, rather than re-implements, the unit's existing measurement pieces: the
FWHM/HFD estimator (`src/imaging/hfd.py`), the source detection and the pixel-free
seeing estimate (`src/solvers/source_selection.py`), and the solve geometry
(`SolvingSolution`). Nothing new is invented at the pixel level; the kernel
composes what the solve and selection already produce into one calibrated record.

---

## 5. The nightly log

**Format.** Nightly, append-only **JSONL**, one `SkyQualitySample` per line,
flushed per line so it is followable live and survives a crash mid-night. Patterned
directly on `src/mast_guider/guide_log.py` (nightly JSONL, per-line flush,
stdlib-only reader so a viewer needs no imaging stack) — **reuse that writer**, do
not fork a second one.

**Per night, not per session.** Unlike the guide log (per guiding session), the
sky-quality log is **one file per observing night**, appended across every flow and
every session, with the idle gaps left as gaps. The observing night turns at
**12:00 UTC** (the unit's existing night label), which is when a new file opens.

**Location & shipping.** Written **local, on the unit's RAM disk**, in the night
folder — **not** straight to the share. Units are Windows; SMB file-lock semantics
are unreliable and network append is slow and risky. Ship (copy) to the share on a
cadence and at night-end, exactly like the guide log; the local file keeps
accumulating.

**Exclusive, best-effort write access.** The writer holds an **exclusive** handle
on the local nightly file, defending it against a second writer (a supervisor, a
manual tool, a crash-restart with a stale handle) and against a concurrent reader
tearing a line. The lock is **best-effort and non-blocking** (principle 6): if it
cannot be taken immediately, the reading is **dropped**, never waited on — a missing
reading is cheaper than a stalled guide cycle. The lock is per nightly file and is
re-acquired at the 12:00 UTC turnover.

**Torn-line tolerance.** Readers — the live follower and the site sweeper copying
from the share — must skip a torn trailing line (a write interrupted by a crash).
`read_guide_log` already does this; the sky-quality reader inherits it.

---

## 6. Ephemeral status

`/unit/status` carries a **short, rolling, time-based window summary** — not the
single latest raw reading (one reading is too noisy to act on) and not the history
(that is the log's job). The in-memory state is a small ring of recent samples
producing medians + MAD over the last *N* minutes; newer readings overwrite older
ones. This is precisely the `SkyQualityWindow` / `GuidingSkyQuality` windowing logic
that already exists (`src/science/sky_quality.py`) — **reuse it, but feed it
normalized `SkyQualitySample`s** rather than PHD2 events.

The window is **time-based, not sample-count-based**, because the feed cadence is
wildly uneven (see §7). No consumer may assume a uniform rate.

The existing `LatestSkyQuality` status wrapper stays as the **external contract**;
its producers are unified underneath it, so consumers need not change.

---

## 7. Feeds (parasitic)

A unit's owner receives samples; it does not pull. Each feed is a flow that already
has a solved frame calling `unit.sky_quality.record(sample)`:

- **`focus_on_star`** — already produces `measured`; becomes one `record()` call.
- **Acquisition** — every sky / spec-phase solve frame is a free sample, phase-tagged.
- **mast guiding** — the **§3.3 validation solve** already captures and solves a
  **full frame every ~60 s** during guiding (`VALIDATION_INTERVAL_SECONDS`). Solve
  once, use it for **both** pointing validation **and** sky quality. This single feed
  fills the mast-flow gap and gives a continuous guiding-time absolute series at
  **zero extra exposure cost**.
- **PHD2 guiding** — keep `GuidingSkyQuality` as the **relative** annotation (it has
  no solve). An *absolute* reading during PHD2 guiding would need full-frame solves
  (cf. issue #283) and is not required here; if PHD2 is being retired in favour of
  the mast guider, do not invest in generalizing its event path.

**Cadence is uneven and flow-dependent** — a burst during acquisition, ~1/min while
mast-guiding, one at focus, nothing while idle — and §5/§6 are built to tolerate it.

---

## 8. Ownership

A per-unit **owner** component (a sibling of `flux_metering`), flow-agnostic:
- receives `SkyQualitySample`s via `record()`,
- holds the ephemeral window (→ status, §6),
- owns the nightly JSONL writer (→ log, §5).

This collapses today's two separate owners (`guider.sky_quality_while_guiding` +
`focus_on_star.sky_quality`) into **one owner and one record**, read live from
config per the unit's configuration conventions.

---

## 9. Session health — "how is this guiding session doing?"

A **per-session consumer** of the guide log (the `mast_guider` nightly guiding JSONL)
**joined with this layer's absolute SQM series** (§3). It answers a question neither
source answers alone: *is the loop performing — and if not, is it the loop or the sky?*
That join is the reason it is specified here rather than in the guider: the SQM reading
is what keeps the verdict honest.

**Do not collapse it to one scalar.** A session has a quality **vector**; a single
number hides exactly the thing worth knowing. A session can hold tight residual while
spending half its time star-lost (looks great, isn't guiding), or run mediocre residual
that is in fact **excellent for the sky it had**.

**Three guider sub-scores**, all from fields the guide-log cycle already carries
(`decision`, `error_arcsec`, `scatter_px`, `n_used`) — orthogonal by construction
(output / duty-cycle / input):

1. **Tracking** — the residual, robustly. Per-axis (RA/Dec) and total **median and
   p90/p95 |error|**, *not* mean RMS alone (RMS is dominated by the settle phase and by
   outliers). Scored against a **budget** — a fraction of the seeing disk / fibre, or a
   fixed arcsec target: `tracking = clamp(1 − p90/budget)`.
2. **Availability** — is the loop actually closing. Duty cycle from `decision`:
   `applied + deadband` (good measurement, loop in control) vs `held_scatter` vs
   `star_lost`, plus the **longest continuous star-lost gap** (ten scattered losses is
   fine; one 90-second blackout is not). A 40%-star-lost session is not-guiding,
   however tight its measured frames.
3. **Input quality** — rolling `n_used` and `scatter_px`. Falling star count / rising
   scatter is the early warning; it leads tracking degradation by several cycles.

**Temporal shape:**
- **Two windows** — a trailing ~60–120 s EMA for "how is it doing *now*" (a status
  tile, reusing the §6 windowing), and a whole-session aggregate for the post-mortem
  (a session-end `event` record).
- **Trend** — the sign of the rolling-residual derivative. "Recovering from acquisition
  settle" and "started tight, falling apart" have identical instantaneous RMS and
  opposite meaning.
- **Exclude the settle phase** from the steady-state score (detect steady-state: error
  below threshold for N cycles), else every session looks bad for its first 20 cycles.
  Report **time-to-settle** separately — it is its own useful number.

**Conditioning on sky — why this lives here.** The SQM is what turns "mediocre" into
either *the loop is failing* or *the loop is doing all the sky allows*. Two tiers:

- **Regime label (Phase 1-ready).** When availability drops, check the SQM window (§6):
  if SQM collapsed concurrently, annotate the low score **"sky-limited"** rather than
  charging it to the guider — clouds and a broken loop otherwise produce the same grade,
  and the operator's response (wait vs. go chase pointing/periodic-error) is opposite.
  This is a pure join of the guide log against this layer's samples; it needs nothing
  beyond Phase 1.
- **Expectation residual (Phase 3, the sweeper).** The honest measure is the residual of
  tracking / `n_used` **against what this SQM permits**, learned over nights by the §10
  sweeper's per-unit baseline. "As tight as the sky allows" then scores well at
  absolute-mediocre residual, and tight residual under great sky that *should* have been
  tighter scores poorly.

**Headline last.** Once the vector exists, a single grade is a weighted roll-up (e.g.
`0.5·tracking + 0.3·availability + 0.2·input`), gated to "sky-limited" when the SQM
explains the loss — displayed **only with the three sub-scores and the sky regime beside
it**, never the grade alone, which was the entire point.

**Shape.** A pure reader over the guiding JSONL (stdlib, the `read_guide_log` pattern)
→ a `SessionHealth` struct: testable off a unit, surfaced as a status tile, a
session-end `event` record, and a `mast-guide-scope` header row.

---

## 10. The site layer (out of scope here)

A unit's log is a **labeled pencil-beam time series**, gathered only while the unit
was active on its task. The **authoritative** site sky quality comes from a
**dedicated resource — an SQM or an all-sky camera — which is a separate instrument,
not an aggregation of unit beams.** The unit layer does **not** try to synthesize an
all-sky map from sparse, confounded beams.

A later **offline site sweeper** (in `MAST_control`, reading every unit's nightly
JSONL from the share, batch, never on any real-time path) then has three well-posed,
humble jobs:
1. **Per-product provenance** — attach each unit's beam quality to the products it
   took (a spectrum through thin cloud is flagged by the zero-point drop at that
   moment). *This stands on its own and needs no site layer at all — it is the
   independent value of Phase 1.*
2. **Corroboration** against the dedicated instrument — a beam reading "cloud" while
   the all-sky reads "clear" flags **that unit**, not the sky.
3. **Per-unit baseline** — the clear-night zero-point reference against which
   transparency/extinction are later reckoned (as `LatestMeasuredSkyQuality` already
   anticipates).

The sweeper and the dedicated instrument are **not specified here.**

---

## 11. Deferred / out of scope

- **Abort-on-conditions policy.** The unit could abort its own job locally on bad
  readings (low latency, good for not wasting exposure time), but a
  context-normalized "worse than expected at this airmass / moon" model is a real
  atmospheric-modelling project. Deferred entirely. When taken up: keep it to a
  simple absolute trigger first (transparency dropped > X mag over Y minutes, or
  FWHM above a ceiling for N consecutive readings), and it **must** emit its
  evidence (the readings) into status + log so the orchestrator does not reassign
  the unit straight back into the same cloud. The **context fields of §3 are
  retained now** precisely so this is buildable later without a schema change.
- **Active / idle-time probing.** Strictly parasitic (principle 2). The log goes
  blind while the unit is idle; inverting "abort when bad" into "resume when good"
  is the **orchestrator's** problem (it can command a probe frame), not this layer's.
- **The site-wide survey** — the dedicated SQM / all-sky camera (§10).
- **The site sweeper** itself (§10).

---

## 12. Phasing

- **Phase 1 — plumbing (self-contained, ships value).** Promote the frame+solve
  kernel to a shared module (§4); define `SkyQualitySample` (§3); the per-unit owner
  (§8); the best-effort exclusively-locked, torn-line-tolerant nightly JSONL writer
  on the guide-log pattern (§5); wire **one** feed (the §3.3 validation solve is the
  highest-value, lowest-cost); the ephemeral window in status (§6). No policy, no
  decisions.
- **Phase 2 — local decision.** The simple abort trigger (§11) and its evidence
  contract with the scheduler. The **session-health measure** (§9) — at least its
  Phase-1-ready regime-labelled form — is a natural consumer to add here.
- **Phase 3 — site.** The offline sweeper (§10), against the dedicated instrument,
  which also supplies the expectation baseline the session-health residual (§9) needs.

Phase 1 delivers a durable per-beam, per-product sky-quality record and a status
gauge with **no dependence** on Phases 2–3 or on the dedicated instrument.

---

## 13. Open questions

- **Which single feed for Phase 1?** The §3.3 validation solve is the recommendation
  (continuous, free, already full-frame and solved). Confirm before building.
- **Relative metrics — keep or drop?** Whether PHD2's per-session HFD/SNR survive as
  annotations, or everything collapses to the absolute tier. Tied to whether PHD2
  guiding is being retired.
- **Window length *N* for the status summary**, and whether it is configurable.
- **Ship cadence** of the local nightly file to the share (continuous tail vs
  periodic copy vs night-end only), given the log is night-long rather than
  session-scoped.
