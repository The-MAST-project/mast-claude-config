# Fold-mirror guiding handover — exclusion region and bracketed SPEC insertion

> **Status: proposition, not on `main`.** Validated on sky on one unit and one night
> (mast01, 2026-09-02/03), and offered as a **stopgap alternative to the current
> acquisition ordering** until MAST-owned guiding replaces PHD2
> (`inhouse_guiding_design.md`). Since 2026-09-06 it has not been a merge candidate by
> default: adopting it is a decision for the team to take on purpose.
>
> **Where the code is:**
>
> | Repo | Branch | PR | Baseline |
> |---|---|---|---|
> | MAST_unit | `eli/exclude-region` @ `9e012ba` | MAST_unit#30 | `main` @ `f76987b` |
> | MAST_common | `eli/exclude-region` @ `91e6674` | MAST_common#13 | `master` @ `8fc6c3e` |
> | PHD2 | `eli/mastbuild5`, build `2.6.14dev1mastbuild5` | none | upstream `master` @ `a6c02722` |
>
> The PHD2 branch is **not hosted on GitHub**. Hosting a MAST fork is deliberately
> deferred, so §4 is the record of what the build changes: a contract precise enough
> to re-implement, with commit hashes as provenance only. The build is installed on
> mast01 (`PHDSubver dev1mastbuild5`). Merge order if adopted: MAST_common#13, then
> MAST_unit#30, then pin the build in provisioning's PHD2 provider.
>
> Plan and history: MAST_unit#19. Living document; revised 2026-10-11.

## Context

Each unit's FCU stage carries a 45° fold mirror on a linear track in the converging
beam (`stage_geometry_design.md`). At the **Sky** preset the mirror is parked toward
the edge of the guide field and occults only stars far from the optical center. At
**SPEC** it occults a band across the center of the field and feeds the target into
the fiber.

Guide-star selection and the mirror compete for the same pixels. PHD2 accepts a
candidate only if it is unsaturated, clears its SNR and mass minimums, and has an HFD
inside the configured window. MAST's strong coma smears the outer field, so the
candidates that pass cluster in the low-coma center, which is exactly the band the
mirror covers. Left alone, selection prefers the stars the mirror is certain to take
away.

There are only two naive orderings, and each costs something:

- **Mirror in, then guide.** The telescope tracks open-loop from the last acquisition
  correction through the stage travel, star selection, calibration and settling. Any
  slip in that interval is **frozen into the lock**: guiding holds the field where it
  drifted to, not where acquisition put the target on the fiber. Selection must also
  be kept off the mirror, which today means cropping the field.
- **Guide, then mirror in.** No unguided gap, but the star selected with the mirror out
  is very likely under the mirror once it is in, and stars in the corridor the mirror
  sweeps are occulted for the ~30 s of travel. The usual mitigation is a limit frame
  over the part of the sensor the mirror never occults, at any stage position. That
  avoids both losses, but at the price of every good star in the mirror's path that
  the mirror at SPEC would leave visible.

This design takes the second ordering and removes both of its costs.

## 1. Before and after

**Before** is `main` today (`f76987b`). Since f97acfc (2026-07-27) acquisition moves
the stage to SPEC itself, for both the automatic and the manual path, so that guiding
always starts at SPEC. **After** is the `eli/exclude-region` branch.

### Before — `main`: mirror in, then guide

```
acquire + solve at Sky ──► stage to SPEC ──► wait at-preset + 5 s
        │                                         │
        │◄───────────── open loop: tracking slip accumulates ───────────►│
                                                  ▼
                       start_guiding ──► PHD2 selects inside the limit frame
                                         (mode: derived — a crop to one side
                                          of the mirror) ──► calibrate ──► settle
                                                  ▼
                                    lock = wherever the field drifted to
```

- **Automatic path** (`handover_automatically_to_guider=True`): `start_guiding()` once
  the stage is at SPEC.
- **Manual path** (`False`): acquisition ends **at SPEC** with the mount tracking. The
  operator fine-tunes the pointing with external tools, then calls `/start_guiding`.
- `StartGuiding` only starts guiding. There is no handover thread and no `PreGuiding`
  state.

### After — `eli/exclude-region`: guide, then insert under a pause

```
acquire + solve at Sky ──► stage stays at Sky
                                   ▼
guide(): set_exclude_region(shadow band)  ──► deselect_star ──► guide RPC
         (or reset it, mode: off)              (force a fresh selection)
                                   ▼
PHD2 selects anywhere except the shadow band ──► calibrate ──► settle
                                   ▼
              [lock nudge onto the target — optional, off by default]
                                   ▼
set_paused(full) ──► stage to SPEC ──► at-preset ──► set_paused(false)
   (lock, star and calibration survive the pause)        ▼
                                          drift over the travel is pulled
                                          back to the lock on resume
                                                  ▼
                              ready for exposure (UnitActivities.Guiding)

stage fault or timeout ──► guiding STAYS PAUSED, mirror out, error logged
```

### What changes

| | Before (`main`) | After (branch) |
|---|---|---|
| Stage when guiding starts | SPEC | Sky; the guider inserts the mirror |
| Where stars are selected | inside the limit-frame crop, one side of the mirror | the whole guided field minus the measured SPEC shadow band. Stars the mirror occults at Sky cannot be selected either, though they would be visible at SPEC; they lie far from the optical center, so little is lost |
| Unguided interval | last acquisition correction → settle, through the stage travel | the stage travel only (~27 s measured), bracketed by a pause |
| Drift during that interval | frozen into the lock | corrected back to the lock on resume |
| Ready for exposure | guiding started | stage at SPEC **and** guiding resumed; no settle gate after resume |
| Stage fault | acquisition abandoned before guiding | guiding left paused, mirror out, failure logged; `/resume_guiding` is the way out |
| Manual `/start_guiding` on fcu_v2 | guides at whatever stage position it finds (SPEC after acquisition) | also runs the bracketed insertion, gated by `phd2.handover.auto_insert` |
| Stage travel in the timeline | before guiding starts | after settle; serialized in both, so no net cost against `main` (the ≈ 30 s cost in the 2026-07-06 decision was against the older concurrent overlap) |
| PHD2 build | any with `set_limit_frame` | `2.6.14dev1mastbuild4` or later for the region; `mastbuild5` for lock validity's background test |
| A unit with no new config | — | `exclude_region` `off`, `lock_nudge` off, `auto_insert` on: it **guides at Sky with no exclusion, then inserts**. The ordering changes even without config, and the region must be measured and enabled per unit before that ordering is safe |

## 2. Key decisions

Each decision is tagged **[carries over]** if it applies to any guider, including the
in-house one in `inhouse_guiding_design.md`, or **[PHD2]** if it exists only because
the guider is PHD2.

**D1. Guide first, then insert the mirror. [carries over]** Of the two orderings, only
guide-first can avoid freezing tracking slip into the lock. Its costs (star loss under
the mirror and in its corridor) are removable (D2, D5). The costs of mirror-first are
not.

**D2. Exclude at selection, not at capture. [carries over, mechanism PHD2]** The limit
frame is a sensor readout crop. The camera reads one rectangle, so "everything except
a band" is impossible at capture. The failure being prevented is a *selection* failure,
so the exclusion belongs where stars are selected. That also makes it camera-agnostic,
where the limit frame is ZWO-only.

**D3. Select as if the mirror were already in. [carries over]** The excluded rectangle
is the mirror's parked shadow at SPEC plus a pad, so every star chosen with the mirror
out is still visible once it is in.

**D4. Filter candidates as they enter the ranked list. [PHD2]** Peaks inside the region
are rejected before they can take one of `AutoFind`'s TOP_N slots or take part in the
too-close-pair test. Rejecting later would let the bright central target push usable
stars out of the list.

**D5. Bracket the stage travel with a full pause. [carries over]** The parked-shadow
exclusion does not cover the corridor the mirror sweeps. A full pause stops guide
exposures for the travel, and PHD2 keeps the selected star, the calibration and the
lock position across a pause. Open-loop drift over the travel is then a correction
toward the lock on resume, not a new lock.

**D6. No settle gate after resume. [carries over]** The pull-back after resume is a few
pixels and decays into the science integration. Stage-at-SPEC is the earliest moment
the shutter means anything anyway. The noted cost: a short exposure collects a larger
fraction of its light during the pull-back.

**D7. A failed insertion leaves guiding paused. [carries over]** Resuming with the
mirror part-way across would guide on a half-occulted field. The handover fails loudly,
ends `PreGuiding` without raising `Guiding`, and the operator recovers with
`/resume_guiding` (or `/stop_guiding`) rather than by restarting the service.

**D8. The handover thread commands the stage itself. [carries over]** A deliberate
semantic change: a manual `/start_guiding` on an fcu_v2 unit also gets the bracketed
insertion. Under the pre-f97acfc code it waited passively and stranded `PreGuiding` on
a 60 s timeout.

**D9. The region is runtime state in PHD2 and configuration in MAST. [PHD2]** PHD2
never persists the region in its profile: a stale exclusion silently suppressing guide
stars is worse than requiring the client to set it every session. MAST stores it per
unit in the config DB (`phd2.exclude_region`) and sets **or resets** it before every
guide, the same discipline as the limit frame.

**D10. Force a fresh selection after setting the region. [PHD2]** The region filters
only *auto*-selection. A star left selected by a previous session survives it, and the
guide RPC would lock on that star. Verified on the bench: without `deselect_star` the
lock landed inside the region, with it outside.

**D11. `off` is the default, and a rectangle under `off` is legal. [carries over]**
There is no derived fallback rectangle, so the feature must be off until a unit's shadow
is measured. The measurement tool writes the band as soon as it is measured and the
region is enabled later, so "measured but not enabled" must be expressible. `mode`
alone decides what is sent.

**D12. A stale rectangle refuses to guide. [carries over]** The rectangle is a derived
value of the per-unit `depth` and `pad_px` knobs, and records what it was derived from.
If a knob was hand-edited since, `guide()` raises rather than guiding against a
rectangle nobody measured.

**D13. Send the rectangle verbatim. [PHD2]** It is a selection filter, not a readout
crop, so no camera alignment applies. `ImagerRoi` conditioning would only move it
(same reasoning as the limit frame, MAST_common#17).

**D14. Optionally nudge the lock onto the target before insertion. [carries over]**
Settle is the last moment the target is observable in the guide frame. The nudge
measures the target offset by solving, moves the lock with `set_lock_position`
(treated by PHD2 as a dither), and confirms over a few frames. It runs before the mirror
moves and never after: a mirror-induced apparent shift cannot be told from a pointing
change, and correcting an optical shift with the mount drives the target off the fiber.
Failure is never fatal to the handover. Off by default.

**D15. Insertion can be handed to the caller. [carries over]**
`phd2.handover.auto_insert: false` lets a measurement harness time the insertion
itself, or run a no-insertion control, without first undoing an automatic insertion.
It is a measurement mode, not an operating one: a unit left that way never reaches SPEC.

**D16. Judge whether the lock is a star at all; act on it only by a separate switch.
[carries over]** PHD2 reports how well the star holds the lock, not whether the lock is
on a star. The supervisor (`science/lock_validity.py`) combines a session-scale test
(this frame's mass against the running median) with a stateless test (peak over local
sky in sigma, and mass over peak·HFD²). It needs the background fields PHD2 did not
report (§4.3). Acting on a `NotAStar` verdict is `end_guiding_on_not_a_star`, default
off, so a night of reporting can be read against what happened before anything acts.

**D17. PHD2 build tags are `mastbuildN`. [PHD2]** `mastNN` always names a unit. The
build counter was renamed so the two cannot be confused.

## 3. The coordinate trap

The region is given in **unbinned full-sensor** coordinates. PHD2 reports star and lock
positions **inside the active limit-frame crop**. On 2026-09-02 the crop origin was
`x=520`, so comparing a reported star position against the configured rectangle made a
working exclusion look broken. The on-sky check was done by widening the band and
watching selection move to another star. Any tool that checks the exclusion must
translate by the crop origin and the binning first, as PHD2 does internally (§4.1).

## 4. PHD2 contract — build `2.6.14dev1mastbuild5`

Upstream `master` @ `a6c02722` plus four commits (provenance only):

| Commit | Change |
|---|---|
| `4297e950` | exclusion region and its event-server API (§4.1) |
| `0c66a91e` | draw the active region in the guider view (§4.2) |
| `63c5a7ec` | include `toupcam.dll` in the x64 installer — an upstream packaging bug, unrelated to this design, without which the x64 build does not launch |
| `c8d71417` | `PHDSUBVER` = `dev1mastbuild5` |
| `10484fe9` | `Peak`, `Background`, `BackgroundSigma` on `GuideStep` and `StarLost` (§4.3) |

`mastbuild4` (the earlier stack on PHD2's `eli/exclude-region`) carries §4.1 and §4.2
only.

### 4.1 Exclusion region

**Methods** (JSON-RPC on the event server):

| Method | Params | Result |
|---|---|---|
| `set_exclude_region` | `{"roi": [x, y, w, h]}` or `{"roi": null}` | `0` |
| `get_exclude_region` | none | `{"roi": [x, y, w, h]}`, or `{"roi": null}` when none is set |

**Semantics:**

- `roi` is **required**. `null` clears the region. Missing → `-32602 missing required
  param 'roi'`; malformed → `-32602 invalid ROI param`.
- Coordinates are **unbinned full-sensor pixels**, the same convention as
  `set_limit_frame`.
- **Refused while calibrating or guiding**: error `1`, *"Cannot set the exclude region
  while calibrating or guiding."* A client sets it before the guide RPC. A paused
  session counts as guiding.
- No guide camera → error `1`, *"no guide camera"*.
- **Runtime-only.** Never written to the profile. It survives across guide sessions
  within one PHD2 process and is lost on restart, which is why the client sets or
  resets it every session.
- **Affects auto-selection only**: the primary star and every MultiStar secondary, all
  of which go through `GuideStar::AutoFind`. Manual
  selection (clicking, `set_lock_position`) is intentionally not restricted, and an
  already-selected star is not dropped.
- **Filter point:** a candidate peak at image position `(x, y)` inside the region is
  skipped as it is considered for the TOP_N list, before the too-close-pair test.
- **Transform at selection time:** each edge is divided by the current binning, the
  far edges rounded **outward** so a partly covered pixel stays excluded, then offset
  by the limit-frame origin (in binned coordinates) when a limit frame is active. So the
  region composes with a limit frame: the crop keeps its bandwidth benefit and the
  region removes the shadow inside it.
- A region entirely outside the delivered image excludes nothing and is not an error.
- Older builds answer both methods with `-32601 method not found`. MAST treats that as
  success for a *reset* (no state to clear) and as a failure for a *set*.

### 4.2 Display

While a region is set, the guider view draws it as a red dashed, hatched rectangle in
image coordinates, transformed as in §4.1. A region silently suppressing selection
should never be invisible to someone at the screen.

### 4.3 Lock telemetry on `GuideStep` and `StarLost`

Three fields added to both events, measured in the annulus `Star::Find` already uses to
background-subtract the mass:

| Field | Type | Meaning |
|---|---|---|
| `Peak` | integer (ADU) | the star's peak pixel (`Star::PeakVal`, which existed but never left the debug log) |
| `Background` | number, 1 dp | mean local sky around the lock |
| `BackgroundSigma` | number, 2 dp | standard deviation of that sky |

Frames with no star report `0`. They answer the question the existing `StarMass`, `SNR`
and `HFD` cannot: whether the lock stands above the sky at all. A star-shaped centroid
on flat background has ordinary-looking mass and HFD; only its peak sitting at the
background gives it away.

### 4.4 Stock PHD2 behavior relied on

Not changed by the build, but load-bearing:

- `set_paused [true, "full"]` stops guide exposures; the selected star, calibration and
  lock position survive until `set_paused false`. A `Resumed` event follows.
- `deselect_star` clears the selection so the next guide RPC auto-selects.
- `set_lock_position {x, y, exact}` while guiding is reported to the algorithms as a
  dither and triggers no settle.

## 5. MAST_common contract — `PHD2Config`

| Section | Fields | Default |
|---|---|---|
| `exclude_region` | `mode: off \| fixed`; `x`, `y`, `width`, `height` (unbinned px); `depth`, `pad_px` (knobs); `derived_from_depth`, `derived_from_pad_px` (written by the measurement tool only); `stale_derivation()` | `off` |
| `handover` | `auto_insert` | `true` |
| `lock_nudge` | `enabled`, `max_offset_px` (7.0), `confirm_frames` (2), `confirm_px` (5.0), `confirm_timeout` (60 s) | off |
| `lock_validity` | `warmup_frames` (8), `scale_window_frames` (60), `artifact_mass_fraction` (0.05), `min_peak_sigma_over_background` (5.0), `min_mass_over_peak_hfd2` (0.35), `hysteresis_frames` (2), `require_background` (false), `end_guiding_on_not_a_star` (false) | report only |

`mode: fixed` requires a complete rectangle; `off` accepts one (D11). Every threshold
is read live, so a unit can be retuned from the config DB without a deployment. Absent
sections parse to the defaults, so existing documents are unchanged.

## 6. MAST_unit behavior

- **`guide()`** applies `exclude_region` before every guide RPC: under `fixed`, check
  `stale_derivation()` (raise if stale), `set_exclude_region(verbatim rect)`, then
  `deselect_star`; under `off`, `set_exclude_region(null)`.
- **Acquisition** leaves an fcu_v2 unit at Sky; fcu_v1 has no fold mirror and is at
  SPEC from the solve.
- **`StartGuiding`** calls `start_handover_if_configured()`: on fcu_v2 with
  `auto_insert` on, raise `PreGuiding` and run `do_fcu_v2_spec_handover` on a thread:
  wait for settle → nudge (if enabled) → `set_paused(full)` → stage to SPEC within 60 s →
  `set_paused(false)` → end `PreGuiding`, start `Guiding`. A failed settle ends
  `PreGuiding` without inserting. With `auto_insert` off, `PreGuiding` is not raised.
- **Endpoints:** `/pause_guiding` (default `full`), `/resume_guiding`, `/stop_guiding`
  (discards the lock, unlike pause, and leaves acquisition and tracking alone).
- **`unit.expose`** gains `start_tracking` and `stop_tracking` (both default `true`), so a
  frame can be taken under a pause without the mount stopping and the field walking off.
- **Lock validity** is fed from `GuideStep`; its assessment, including
  `worst_assessment`, is in `guider.backend.lock_validity` in the unit status.

The branch also carries fixes and enhancements unrelated to the ordering question. PR
MAST_unit#30 keeps that inventory; it is not repeated here.

## 7. Evidence

**On sky, mast01, night of 2026-09-02/03** (first end-to-end run):

- The bracketed handover completed: open-loop stage travel **26.78 s**, resume 0.3 s
  after arrival, guide star never lost.
- The exclusion is honored, shown by widening the band and watching selection move
  (§3).
- The fault path held: twice, a guide that failed to settle left guiding paused with
  the mirror out.

**Replay of 2026-09-08** (lock validity): 14 of 14 artifact frames caught, 0 false
alarms in 1087 sound frames.

**Bench:** PHD2 camera simulator end-to-end with the region honored; labcomp2 bench
suite for the handover's happy and fault paths (6/6). MAST_unit suite 726 passed at the
2026-10-01 rebase, against the paired MAST_common branch.

**Not shown:**

- One unit, one night. No star budget, no long integration, no science chain (mast01
  has no fiber registration).
- The **1–2 px drift over the travel** is neither confirmed nor contradicted: the
  post-resume excursion of 3.11 px sits inside that night's ambient scatter of
  0.7–3.7 px.
- The supervisor has **no on-sky demonstration**. It was deployed to mast01 on
  2026-09-14, but the roof stayed closed for the part of the night that would have
  exercised it.
- `capture_single_frame` during a full pause has never been observed on real PHD2.

## 8. Open questions

1. **The ordering.** `main` puts the mirror in first, deliberately, so guiding always
   starts at SPEC. This design puts it in last. One of the two has to win; a rebase
   must not settle it quietly. The concrete point of contact is the **manual tuning
   path**: under f97acfc the operator fine-tunes pointing with the stage at SPEC before
   starting guiding. Under this design acquisition ends at Sky and `/start_guiding`
   inserts the mirror, so either the tuning moves to after the insertion or the manual
   path keeps mirror-first.
2. **The limit frame.** If the exclusion region proves itself, the limit frame is likely
   to be retired along with the code that sets, restores and reads it. Every unit runs
   `limit_frame.mode: derived` today. Separately, `mastbuild5` ignores the inline
   `limit_frame` on `capture_single_frame` (MAST_unit#238).
3. **Acting on lock validity.** When, and on what evidence, `end_guiding_on_not_a_star`
   is turned on.
4. **The drift assumption** needs a night with a healthy guiding baseline and a long
   integration.
5. **Hosting the PHD2 changes** (§4) is deferred: until a MAST fork exists, the build
   exists as source on two machines and as the installer deployed to mast01.

## 9. Relation to in-house guiding

`inhouse_guiding_design.md` retires PHD2 and gives its `SettleMonitor` the
stage-to-SPEC handover. The decisions tagged **[carries over]** in §2 are written to
transfer: guide before insertion, select away from the parked shadow, pause over the
travel and correct back to the lock, never resume onto a half-occulted field, and judge
whether the lock is a star. With an in-house guider most of them become simpler: the
"pause" is not sending corrections while the stage moves, and the exclusion is a mask
in MAST's own star finder. §4 and the **[PHD2]** decisions retire with PHD2.

## 10. What this does not do

- It does not correct the mount for any shift the mirror itself introduces; it
  deliberately leaves such a shift alone (D14).
- It does not measure the shadow. The rectangle comes from the per-unit shadow
  measurement (`mirror_shadow` / `stage_geometry_design.md`), with its derivation record.
- It does not touch fcu_v1 units beyond the region itself.
- It does not change how settle is judged; `settle` being snapshotted is MAST_unit#214.

## Provenance

- MAST_unit#19 — the plan and its history.
- MAST_unit#30 and MAST_common#13 — the code, and each repo's `DECISIONS.md` entries
  of 2026-07-03, 2026-07-06, 2026-09-15 and 2026-10-04 on the branch.
- f97acfc on MAST_unit `main` — the mirror-first ordering this is weighed against.
- Notebook records (Eli's vault): *2026-07-03 PHD2 exclusion-region proposal*,
  *2026-09-02 mast01 fold-mirror exclusion region and bracketed handover session
  review*, *2026-09-14 mast01 deployment for the guide-supervisor run*, *MAST handover
  campaign lessons and tickets*.
