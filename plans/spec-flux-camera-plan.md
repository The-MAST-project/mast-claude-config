# The flux camera on the spectrograph's API

*Plan for MAST_spec#129: serve the Thorlabs Zelux flux camera (CS165MU, sn 36555) from the
spec service on mast-ns-spec, as one of its components, instead of the standalone
`flux_meter_service`. Written 2026-11-16.*

**Status: plan, 2026-11-16. No code changed.** Checked against MAST_spec `master`,
MAST_common `master` and flux-meter-orchestrator `main` @ `586e51b`, all as of 2026-11-16.
Line numbers are at those commits.

---

## 1. Where things stand

- The camera is plugged into mast-ns-spec by USB and served by `flux_meter_service` (about
  600 lines, in The-MAST-project/flux-meter-orchestrator), started by hand on port 8003. It
  is outside this service's API: no lifecycle verbs, no status, no tier, no plan ownership.
  It opens the first camera the SDK discovers.
- Its frames go back to the caller as raw `.npy` bytes (`POST /expose`), or are written by
  the service itself straight to the share (`POST /expose_and_save`).
- Its callers are the orchestrator's three runs:
  - **save-spirals** (`save_spirals.py`): a spiral of cells; at each, the unit's `/expose`
    takes imager frames while flux frames run back to back; flux frames are paired with
    imager frames by time overlap afterwards (`best_overlap`).
  - **fiber focus** (`fiber_focus.py`): flux frames at a series of FCU focus positions.
  - **max-flux** (`run.py`): an adaptive spiral whose ring rule decides from each step's
    flux. **On hold and not in use; out of scope here** (section 8).
- MAST_unit's in-tree camera copy goes with MAST_unit#407 / MAST_unit#408.

## 2. Decisions

1. **Frames are products, filed the established way.** A flux frame is written to the spec
   machine's RAM area, protected by `MoveGuardian`, and handed to the mover
   (`Filer().move_ram_to_shared`), as the GreatEyes and Newton frames are. No frame
   travels in an HTTP response.
2. **The caller learns where its frames are from a `latest` record.** `/flux/expose` starts
   a series and answers once the record is replaced, as `/unit/expose` does.
   `SpecStatus.latest.flux` (a `LatestBase`) carries `local_products_path`,
   `shared_products_path` and one entry per frame (name, `DATE-OBS`, exposure, error).
3. **The caller needs to know only that the series ended.** It never waits for the mover.
   The orchestrator keeps each series' record and collects every file from the share at
   the end of the run (section 7).
4. **Headers come from MAST_common's one writer** (`fits_headers.py`: `standard_fits_cards`,
   `apply_cards`), per the frame-contract plan (`spec-frame-contract-plan.md`): the
   project-standard cards plus the camera's own and the caller's (section 4).
5. **The flux camera has a stop on the fiber (slit) Zaber stage.** Exposing requires the
   stage to be at it; spectrograph acquisitions refuse while the camera holds the stage
   (section 5).
6. **The camera is a `Component` held by `Spec`, outside `components_dict`.** So
   `operational`, `why_not_operational`, `detected`, `connected` and `powerdown` never
   depend on it, and a dead flux camera cannot block a HighSpec or DeepSpec acquisition.
   It is the first component outside the dict (`stages` and `wheels` are inside it,
   `spec.py:122-123`), so the rest is wired by hand (section 3).
7. **`/spec/abort` does not reach it.** `/spec/abort` is the plan client's abort path
   (`spec.py:783-786`); a spectrograph plan's abort must not end a unit's flux run. The
   camera's own `/flux/abort` stops its series and releases the stage.
8. **Configuration follows the `enabled` pattern** (`HighspecConfig.camera_enabled`,
   `GreateyesConfig.enabled`), not an optional section: the component and its routes
   always exist, and refuse with a reason while disabled. The database document can follow
   the code.
9. **Plan ownership: no exemption.** Dormant today: only MAST-control sets a plan owner.
   Whether a flux run carries a plan token is MAST_control#52's question.

## 3. MAST_spec

Branch `eli/spec-flux-camera`, paired with the same name in MAST_common.

**The SDK.**

- **Licensing gate first.** MAST_spec is public, and this would be the first public
  redistribution of Thorlabs' TSI SDK. Read its licence before any SDK file is committed
  and record the outcome in `VENDOR.md`'s Licensing section, as
  `cameras/greateyes/sdk/VENDOR.md` does. Removing a pushed DLL means rewriting history.
- If redistribution is allowed: `cameras/thorlabs/sdk/` with `thorlabs_tsi_sdk` and the
  64-bit DLLs, a `VENDOR.md` with each file's sha256, `.gitattributes` binary / `-text`
  rules, and a `ruff.toml` `extend-exclude` entry. `cameras/thorlabs/__init__.py` puts the
  package on `sys.path` and the DLLs on `os.add_dll_directory`, as
  `cameras/andor/__init__.py` does for the Andor SDK.
- If not: the SDK is a machine prerequisite installed by provisioning, like Thorlabs' USB
  kernel driver, which cannot be vendored either way.

**The component**, `cameras/thorlabs/zelux.py`:

- The service's `thorcam.py` (226 lines), ported to `common.mast_logging`, opening the
  camera by `conf.serial_number`. A lock serializes camera calls.
- `Component(FluxCameraActivities)`; `startup` opens the camera, `shutdown` closes it,
  `abort` stops a series between frames (a triggered exposure cannot be interrupted) and
  releases the stage.
- **`status` reads only cached values** (model, serial, saturation level, last settings,
  enabled, the reason it is not operational) and never takes the lock. Otherwise
  `/spec/status` would stall for the length of every flux exposure, and MAST-control and
  the GUI poll it.
- `conf` is a property over `Config().get_specs().flux_camera`. `serial_number` names the
  device opened, so it is listed with its reason among the restart-only fields in
  `tests/test_config_is_live.py`.

**The series**, `PUT /flux/expose`:

- Parameters: `exposure_seconds`, `gain`, `black_level`, `repeats`, `subfolder`, and the
  caller's cards (section 4). Settings come with every call; there is no separate
  `configure`.
- Refused with the reason while disabled, while the camera is not at its stage stop, or
  while a series is running.
- Replaces `latest.flux` before answering, raises `FluxCameraActivities.Exposing`, and runs
  the series on a thread. Each frame: arm, trigger, wait, write the FITS under
  `MoveGuardian().protect`, hand it to the mover, append its entry to the record. A failed
  frame is recorded and the series goes on. The record is written as `latest.json` into the
  folder when the series ends.
- Completion is the `Exposing` flag, declared on the route.

**Routes**, in a new `flux` area with an `OPERATOR_AREAS` entry in `app.py`:

- `register_component_endpoints`: `startup`, `shutdown`, `abort`, `status`. The status
  replaces the old `/info`.
- `PUT expose`; `PUT stop`, which ends a series after its current frame and leaves the
  stage where it is; `PUT engage`, `PUT release` (section 5).

**Wiring in `spec.py` and `app.py`**:

- `Spec.__init__` builds it, outside `components_dict`.
- Startup inside `_startup_worker` (`spec.py:218-228`), isolated from the others' failures.
  Not inline from `lifespan`: an SDK open that hangs would block uvicorn (MAST_spec#87).
- Shutdown called explicitly. `SpecStatus(**ret)` drops keys it does not know, so
  `flux_camera` is set on the status explicitly.
- `app.include_router` for its router.

**Tests and CI.** CI here is lint-only and never checks out MAST_common, and importing the
app commands hardware (MAST_spec#77).

- Component tests against a fake SDK that import `cameras/thorlabs/zelux.py` alone, never
  `app.py`.
- The config-live entries.
- A pytest job in CI that checks out the paired MAST_common branch, starting with the
  AST-only `test_config_is_live.py` and the new tests. Until it exists, the tests run by hand
  in a task venv against the paired common worktree.

**Docs:** README, DECISIONS, CLAUDE.md.

## 4. FITS headers

Written by MAST_common's `fits_headers.py` (`standard_fits_cards()` + `apply_cards()` on
the in-memory header before the write), plus:

| Card | Value |
|---|---|
| `DATE-OBS` | UTC, taken just before the trigger |
| `DATE-END` | UTC, taken when the frame arrives |
| `EXPTIME` | seconds, as set |
| `GAIN`, `BLKLEVEL` | as set |
| `SATLEVEL` | the camera's saturation level |
| `INSTRUME` | the camera model |
| `CAMSN` | its serial number |
| `PIXSIZE` | microns |
| caller's cards | e.g. the unit, the run, the ring and cell, through the caller-supplied values input the frame-contract plan defines |

`DATE-OBS` / `DATE-END` bracket the exposure on mast-ns-spec's clock; they are not the
exposure's own start and end (section 9). The exact card list is settled in the PR, against
the frame-contract plan's vocabulary.

## 5. The stage stop

The flux camera sits at a stop on the fiber (slit) Zaber stage.

- **MAST_common:** a `flux` preset name. `FiberStageConfig.presets` only accepts
  `StagePresetNames` (`config/stage.py:9-11`).
- **Config DB:** the stop's position in the specs document's `stage.fiber.presets`. **Its
  value is not known yet**; it is measured on site.
- **MAST_spec:**
  - `PUT /flux/engage` moves the fiber stage to `flux` and records the preset it left.
    `PUT /flux/release` returns it there. `/flux/abort` releases too.
  - `/flux/expose` refuses unless the stage is at `flux`.
  - While engaged, `Spec.acquire`, the assignment path and the HighSpec paths refuse with
    the reason. All of them move the same stage today (`spec.py:430`, `:463`, `:706`,
    `highspec.py:232`), so without the refusal a spectrograph acquisition would take the
    stage off the camera mid-run.
- **Orchestrator:** `engage` at the start of a run, `release` in its `finally`, as it already
  does for the FCU mirror.

## 6. MAST_common

Same branch name, built on `master` after MAST_common#233 merges (both touch
`activities.py`, `models/statuses.py`, `paths.py` and the path tests).

- `activities.py`: `FluxCameraActivities` (`Exposing`, `StartingUp`, `ShuttingDown`).
  `Component.__init__` requires one.
- `config`: `FluxCameraConfig` (`enabled`, `serial_number`, default exposure, gain and black
  level); `SpecsConfig.flux_camera`; the `flux` stage preset name.
- `models`: `FluxCameraStatus` and `SpecStatus.flux_camera`; `LatestFluxExposure` (reusing
  `LatestExposureFrame` for its frames) and `LatestSpecRecords.flux`.
- `paths.py`: `PathMaker.make_flux_camera_folder(subfolder)`, under
  `<night>/flux-meter/` on the RAM area, so the share path keeps the folder the service
  writes today (an interface). Added by hand to both path tests' lists.
- DECISIONS.

## 7. The orchestrator

flux-meter-orchestrator, its own PR, after the spec side is deployed.

1. **First, move what it imports from the service package into `flux_orchestrator`**:
   `Settings`, `CameraInfo`, `observing_night` (`run.py:29-30`, `save_spirals.py:36`,
   `fiber_focus.py:34`, `app.py:43`, `flux_client.py:12`, the tests). Deleting the package
   before that breaks the orchestrator at import.
2. `flux_client`: start a series, wait until `latest.flux` has ended (or `Exposing` drops),
   keep the record. Errors arrive in the `CanonicalResponse` envelope, not as HTTP status
   codes. Camera facts come from `/flux/status`.
3. **save-spirals:** a flux series per cell, ended with `/flux/stop` when the unit's
   series at that cell ends. The records are kept per cell; at the end of the run the files
   are collected from the share with `read_arriving` and moved into the run folder, as the
   imager frames are today, so the layout Param reads does not change. The pairing by
   overlap runs on the records' windows.
4. **fiber focus:** a flux series per focus position, collected the same way at the end.
5. Its own FITS writing (`_write_flux_frame`) goes.
6. `engage` / `release` around every run.
7. A share demoted during a run shows at collection: the record's `shared_products_path` is
   null for that series, and the run reports which frames stayed on the local fallback.

## 8. Out of scope: the max-flux run

`run.py`'s walk decides from each step's flux (`RingRule`), and its correlation needs the
arg-max step, so it needs each frame during the run. It is on hold and not in use. Until it
is revisited it is disabled in the orchestrator with a message saying why, rather than left
to fail against a service that no longer exists. Whether it then reads frames during the
run or becomes a fixed spiral analysed afterwards is decided then.

## 9. Open issue: exposure timing across the two cameras

Pairing a flux frame with an imager frame relies on three imprecise times, and this plan
improves none of them:

- **The imager** (ZWO through PHD2): `DATE-OBS` is stamped just before the driver call, in
  the unit's clock; USB and driver latency are unmeasured. While PHD2 is guiding it saves
  the guide frame it already has, so the window can predate the request
  (`LatestExposureFrame`'s docstring). Fiber focus guides throughout.
- **The flux camera:** only a bracket, from before the trigger to the frame's arrival.
- **The two hosts' clocks:** the offset is estimated from each `/expose` round trip,
  milliseconds at best.

Ways to fix it, strongest first: a hardware trigger from the guide camera to the flux camera
(the Zelux's trigger input is to be checked against its datasheet, and the guide camera's
trigger or strobe output against its model); the Zelux's per-frame timestamps from the SDK,
anchored once per series (narrows the flux side only); or comparing per-cell medians, which
needs no precise timing. Left open; to be decided by how precise the pairing must be.

## 10. Deploy and retire

1. MAST_common, then MAST_spec, merged; the specs document gains `flux_camera` (enabled,
   serial 36555) and the `flux` stop. Both need MongoDB on mast-ns-control.
2. On mast-ns-spec: stop `flux_meter_service` first (one process can hold the SDK), then
   restart the spec service.
3. Daytime check, camera capped: `status`; `engage` moves the stage to the stop; a short
   series; the frames reach the share with their headers; `latest.flux` reports them;
   `release` returns the stage; a spectrograph acquisition is refused while engaged.
4. The orchestrator PR; save-spirals and fiber focus on sky, by the unit test guidebook.
5. Then: delete `flux_meter_service` and its docs from flux-meter-orchestrator; close
   MAST_spec#129.
6. Callers of the old port 8003 left behind: MAST_unit's `eli/flux-night` and
   `eli/remote-flux-meter` branches (`src/flux_metering/remote.py`). Delete them, or note
   it on MAST_unit#407.

## 11. Open questions

- The `flux` stop's position on the fiber stage (section 5).
- Thorlabs' SDK licence: vendored, or a provisioned prerequisite (section 3).
- The exposure-timing issue (section 9).
- The max-flux run's future (section 8).
