# Spectrograph frame contract -- action items and open questions

*Plan for folding every open FITS-header ask on the spectrograph into one epic,
`epic:spec-frame-contract`: every spectrograph frame describes itself, written by the one
FITS header writer in MAST_common that every MAST frame producer shares, under one card list agreed once with its two readers -- Yahel at the
bench (calibration and tuning frames) and mastpipe at night (unattended quick-look).*

**Status: proposal, 2026-11-11. Nothing filed, nothing labeled, no code changed.** Checked
against MAST_spec `master` @ `f0eaae4`, MAST_common `master` @ `1f7d7ff`, mastpipe `main` @
`2cce25f`. Line numbers below are at those commits.

---

## 1. Why one package

Today the asks arrive piecemeal and partly contradict each other. MAST_spec#121 proposes
card names mastpipe does not read, and the cards mastpipe does read (`GRATING`, `LAMP`, an
arc frame type, a UTC start time) have no ticket. As one package, the two camera
writers (the Newton's, and greateyes', which runs once per DeepSpec band) are touched once,
under one failure rule and one review, and no card is renamed after it ships.

The mastpipe side is ready for a first real night; most blockers are on the MAST side. The
exception is the frame-type vocabulary: mastpipe's `vocab.py:32` hard-codes the four
`FrameType` values and its fleet CI asserts they match MAST_common
(`tests/fleet/test_vocab_matches_common.py`), so a new `FrameType` value needs a paired
mastpipe change (C4).

| Item | Source | Status | In the package? |
|---|---|---|---|
| MAST_spec#121 instrument state in every header (stages, lamps, wheels, shutters) | Yahel | open, `epic:standalone` | yes, re-scoped to tier 1 (§3) |
| MAST_spec#122 `OBJECT` and `NOTES` on every frame | Yahel | open, `epic:standalone` | yes, as written |
| Arc frame type: MAST_common `FrameType` is light / bias / dark / flat only (`spec.py:31`) | mastpipe review | no ticket | yes |
| UTC start time on the Newton | mastpipe review | no ticket | yes |
| `INSTRUME` missing from manual and autofocus HighSpec frames (only the assignment path writes it, `highspec.py:698`) | mastpipe review | no ticket | yes |
| Plan-driven HighSpec exposures ignore the plan: `exposure_duration=999` (`highspec.py:667`), `apply_settings` commented out (`highspec.py:628`) | `/vet` of the mastpipe integration plan | no ticket | yes, as a frame-correctness child |
| MAST_spec#98 DeepSpec cameras have no gain control | site | open | no -- a camera fix; the applied gain becomes a later card |
| Weather / local-coordinate cards for telluric correction (discussion #14) | Arie | discussion | no -- later tier |

## 2. The mechanism

Every header ask becomes one of two inputs to the same write: **values the caller supplies**
(`OBJECT`, `NOTES`, frame type) and **a snapshot of the instrument** (stages, lamps). Both
meet at the exposure-start path each camera already has. The shutter mode is not part of the
snapshot: each camera picks it per exposure (`newton.py:120-145` `_shutter_mode_for`,
`greateyes.py:781-788`), so `SHUTTER` comes from the camera (Q2).

**The writer lives in MAST_common (team decision, 2026-11-11).** One centralized writer that
any FITS producer -- a unit's imagers or the spectrograph -- relies on to write the
appropriate headers truthfully and reliably. MAST_spec supplies its cards; it does not keep a
header writer of its own.

What exists today, and what has to change to get there:

- **MAST_common `fits_headers.py`** (MAST_common#225, merged 2026-11-04): `standard_fits_cards()`,
  `apply_cards(header, cards)` for an in-memory header, `stamp_fits_file(path, cards)` for a
  file another program wrote; `Card = (value, comment)` in a `dict`. `MACHROLE` already
  allows `spec`. MAST_spec does not call it yet.
- **MAST_spec `cameras/headers.py`**: `update_header(path, cards, remove=...)` with
  `Card = (keyword, value, comment)` in a `list`, used by the Newton (`newton.py:19`,
  `:1322`), with its own tests (`tests/test_headers.py`). MAST_spec#121's implementation notes
  target it.
- **A third, inline writer** in `highspec.py:691-699` (`PROGRAM`, `INSTRUME`).

To be the one writer, `fits_headers` needs what the Newton path relies on: a path-based
write with a `remove=` for Andor's stale cards (`TEMP` / `UNSTTEMP`), and a failure mode the
caller can see (`stamp_fits_file` swallows failures today). Then `cameras/headers.py` and
the inline block are retired, and there is one `Card` shape. That is child C0.

**One failure rule, made common:** a stage that is `None` or reads NaN, an axis error, or an
unknown lamp state drops that card with a warning and never stops the exposure.
Caller-supplied text is validated at the endpoint (422) and on the settings models, because a
refused card today kills the greateyes readout thread and partly writes the Newton header.

## 3. Tier 1: what the first night needs

17 new or changed cards, each with a named reader or (`TIMESYS`) stating a convention. #121
proposes about 21; tier 1 covers about 13 of them and about 8 wait (§4).

| Group | Cards | Reader | Conflict with today / with #121, and the fix |
|---|---|---|---|
| Identity | `INSTRUME` on every path, autofocus included | mastpipe | HighSpec writes it on the assignment path only |
| Frame type | `IMAGETYP` gains `arc` (and possibly `background`) | mastpipe | `FrameType` has no arc; mastpipe resolves `light` by content today; `FrameType.FLAT` already exists, but the plan-driven path cannot ask for any frame type (C5) |
| Time | UTC `DATE-OBS` + `TIMESYS='UTC'` on the Newton | mastpipe (`DATE-OBS`); `TIMESYS` has no reader yet, it states the convention | Andor's `DATE` / `FRAME` come from the mast-ns-spec Windows clock, zone unknown; DeepSpec already writes UTC `T_*` |
| Reduction keys | `GRATING` (`Mg` / `Halpha` / `Ca`) | mastpipe | #121 calls it `GRATPRE`; the value is already MAST_common's `HighspecPresets` name (`config/stage.py:9`), so only the name changes. Keep `GRATPOS` / `GRATOFF` |
| | `LAMP` (one card) | mastpipe | #121 has one TBD card per lamp. Value set is open -- see Q3a |
| | `SHUTTER` (`closed` / `open` / `auto`) | mastpipe | #121 has a TBD per-camera name |
| Stages | `SLITPOS` / `SLITPRE` / `SLITOFF` on both instruments; `GRATPOS` / `GRATOFF`, `SFOCPOS` / `SFOCPRE` / `SFOCOFF` on HighSpec | Yahel | none; mastpipe ignores them harmlessly |
| Caller-supplied | `OBJECT`, `NOTES` | Yahel, mastpipe (`OBJECT`) | none |

## 4. Later, each when its reader appears

- Per-unit `OBJ01`...`OBJ20` and the participating units, from MAST_control (multi-unit
  nights). mastpipe already reads them (`targets: {per_unit: "OBJ{nn}"}`).
- Shutter open/close transfer times, Uniblitz controller power, the two filter wheels'
  current filter.
- A stage-moved-during-exposure warning card (logging it is enough for now).
- The QHY600 `FOCUSPOS` rename (camera out of use).
- Applied gain, once MAST_spec#98 lands; `ARCKIND` for the full-arc campaign with the
  portable calibration unit.
- Weather, ambient and local-coordinate cards for telluric correction (discussion #14), once
  a pipeline consumer asks.

## 5. Action items

### 5.1 Structural, before any code

- [ ] **A1. Get the decisions in §6 (Q1-Q8) from Arie.** Q1 and Q2 shape everything else.
- [ ] **A2. Add `epic:spec-frame-contract` to the epic register** (structural lane first),
  then create the label in MAST_spec, MAST_common and MAST_control. mastpipe joins only if
  Na'ama adds the label there.
- [ ] **A3. Re-label MAST_spec#121 and MAST_spec#122** from `epic:standalone` to
  `epic:spec-frame-contract` (Q1).
- [ ] **A4. File the umbrella** in MAST_spec: *Epic: spectrograph frame contract*. Done when
  a real HighSpec night is reduced unattended on mast-ns-control with no manifest.

### 5.2 Children

| # | Repo | Ticket | Milestone |
|---|---|---|---|
| C0 | MAST_common (+ MAST_spec, MAST_unit) | New: make `fits_headers` the one FITS header writer -- a path-based write with `remove=` and a visible failure, one `Card` shape; then retire MAST_spec's `cameras/headers.py` and the inline `highspec.py` writer. Follow-up issue in each consumer repo | M0 |
| C1 | MAST_spec | New: agree the tier-1 card list in one Discussion, commit it as a contract document in MAST_spec, and export one real header as a text fixture for mastpipe's tests | M0 |
| C2 | MAST_spec | MAST_spec#121, re-scoped to tier 1: names aligned (`GRATING`, `LAMP`, `SHUTTER`), the tier-2 cards moved to a later section, instrument cards built by `Spec` (Q2) and written through the C0 writer | M1 |
| C3 | MAST_common + MAST_spec | MAST_spec#122 unchanged; its open question 1 (per-unit targets) moves to C6 | M1 |
| C4 | MAST_common + MAST_spec + mastpipe | New: frame identity and time -- `FrameType.ARC` (Q4), `INSTRUME` on every path, UTC `DATE-OBS` / `TIMESYS` from the Python clock at `start_exposure` | M1 |
| C5 | MAST_spec | New: plan-driven HighSpec exposures ignore the plan (`exposure_duration=999`, `apply_settings` commented out) | before any plan-driven night |
| C6 | MAST_control | Later: per-unit targets and participating units (`OBJnn`); the quick-look timer on mast-ns-control | M2 and later |

C3 and C4 share MAST_common changes to the exposure settings and `FrameType`, so they go on
**same-named branches** in both repos and CI pairs them. C4 also needs a same-named mastpipe
branch updating `FRAME_TYPES` in `vocab.py` (and its docstring, which calls arc and background
pipeline-only), or every mastpipe PR fails the fleet job once C4 merges. Each MAST_common signature change
gets a follow-up issue in each consumer repo (closing keywords do not cross repos).

### 5.3 Verification, before C4 writes any time card

- [ ] **A5. The clock check (Q5):** take one Newton frame with a known UTC time from the spec
  log and compare it with the header's `DATE` / `FRAME`. This settles how to read legacy
  Andor stamps; it does not block a new `DATE-OBS`, which can come from Python's
  `datetime.now(datetime.UTC)` at `start_exposure` as greateyes' `ExposureTiming` already
  does (`greateyes.py:176-201`).
- [ ] **A6. Check `DATE` precedence against mastpipe:** `standard_fits_cards()` writes `DATE`
  as the UTC *header-write* time and `apply_cards` overwrites existing keys, while mastpipe
  reads its start time from `DATE-OBS`, then `FRAME`, then `DATE` (`header_map.yaml:28`,
  `reference: start`). On today's Newton frames there is no `DATE-OBS`, and it is `FRAME`,
  ahead of `DATE` in that list, that protects the start time from an overwritten `DATE`
  (`header_map.yaml:12-15`). DeepSpec already writes `DATE-OBS` but as the *mid*-exposure
  time, and `MJD-OBS` as an ISO string (`greateyes.py:1161-1170`). C1 should pin what
  `DATE-OBS` means on both instruments.

## 6. Open questions

### For Arie -- eight calls settle the package; Q1 and Q2 simplify it

1. **One epic** instead of two standalone tickets plus loose asks: re-label #121 and #122?
2. **One snapshot owner:** `Spec` builds the stage and lamp cards rather than each camera
   reading the stages itself, while each camera keeps writing `SHUTTER`, the mode it chose
   for that exposure? For DeepSpec, is the snapshot taken once in the coordinator before the
   four band threads fan out (`deepspec.py:434`), rather than four concurrent reads of the
   shared stage controller and power switch, each delaying its band's shutter? Whether the
   Zaber library tolerates concurrent reads is unverified.
3. **The tier-1 card list and its names**, in particular `GRATING`, `LAMP` and `SHUTTER` in
   place of #121's `GRATPRE` and per-lamp cards.
   - **Q3a. `LAMP` values.** The review proposed `off` / `ThAr` / `qTh` / `ThAr+qTh` and
     said mastpipe maps `qTh` to flat. mastpipe `main` does not: `lamp_state` is lower-cased
     with no map (`header_map.yaml:53`), and the classification rules match only `off`,
     `thar` and `flat` (`header_map.yaml:76-78`), so a `qth` or `thar+qth` frame stays
     provisional `light` and is resolved by content, never recognized as a flat by its
     header. Either MAST_spec writes `flat` for the quartz lamp, or mastpipe adds a map
     (`qth: flat`) and a rule for both lamps on -- which side moves, and what is a both-on
     frame?
4. **`FrameType.ARC` in MAST_common**, and does `BACKGROUND` (lamp off, shutter open) join
   it? mastpipe's `exposure_type` map already accepts `background`.
5. **The clock on mast-ns-spec:** is it on UTC and NTP-synchronized? A5 settles how to
   read Andor's legacy `FRAME` / `DATE`.
6. **Frame type on the plan-driven path.** `HighspecSettings.camera` is a
   `NewtonSettingsConfig` with no frame-type field, and `highspec.py:666-669` builds the
   exposure settings with the default `light`, so `FrameType.ARC` alone changes nothing on the
   unattended path the umbrella is judged by. The assignment already says whether the lamp is
   on (`SpectrographModel.calibration.lamp_on`, `models/spectrographs.py:24`, applied in
   `Spec._run_assignment`, `spec.py:697-702`). Derive `IMAGETYP` from that, or plumb a
   frame type through `NewtonSettingsConfig`?
7. **`TELESCOP` on spectrograph frames.** DeepSpec writes `TELESCOP = 'WAO-MAST'`
   (`greateyes.py:1062`); MAST_common's identity cards set it to the hostname and
   `apply_cards` overwrites, so every DeepSpec frame would silently change to
   `mast-ns-spec`. For a spectrograph fed by many telescopes, what should `TELESCOP` say?
   C1 settles it before the identity cards are applied.
8. **Autofocus frames:** mark them (an `IMAGETYP` or `OBJECT` value) or leave mastpipe to skip
   the `Autofocus/` folder by path?

### For the astronomers, not for Arie

- Arc cadence.
- The physical slit order, before any multi-unit night.
- EM-amplifier gain and read noise.

## Provenance

Drafted from the 2026-11-10 working doc *Spectrograph frame contract: one package for the
FITS header asks*, re-checked against the three repos at the commits above, and vetted by a
fresh-eyes review against the code. New in this plan, not in the doc: the MAST_common writer
(§2, C0), mastpipe's paired change in C4, Q2's shutter and DeepSpec points, Q3a, Q6, Q7 and
A6.
