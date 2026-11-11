# mastpipe in the MAST system -- an initial sketch

*How spectrograph products get reduced by mastpipe without anyone running it by hand: what
triggers a reduction, where it runs, how it is throttled during observing hours, and where
its outputs land on the share. A sketch for discussion, not a design: §6 is longer than §3
on purpose.*

**Status: sketch, 2026-11-11. Nothing built.** Companion to
[`spec-frame-contract-plan.md`](spec-frame-contract-plan.md), which makes the frames
reducible; this one makes the reduction happen. Checked against MAST_control `master` @
`cb4012d`, MAST_common `master` @ `1f7d7ff`, MAST_spec `master` @ `f0eaae4`, mastpipe `main`
@ `2cce25f`.

---

## 1. The shape, in broad strokes

mast-ns-control listens to the notifications mast-ns-spec already sends, and as spectrograph
products become available it calls mastpipe on them, **in a new process** per reduction.
Eventually those reductions are throttled during observing hours. Everything a plan produces
-- unit products, spectrograph frames, and now mastpipe's reductions -- is bundled close
together on the share, so it is easy to find.

This replaces the earlier proposal (the 2026-11-03 mastpipe review): a timer on
mast-ns-control running `mastpipe quicklook` once per night folder. The two are compared in
§5.1.

## 2. What already exists

**The notification path is built.** MAST_spec sends `AssignmentNotification`s to control
(MAST_common `models/assignments.py:142`, sent through `Notifier().assignment_notification`):

| When | Sent from | Carries |
|---|---|---|
| An assignment's acquisition folder is created | `highspec.py:638` (HighSpec), `deepspec.py:554` (DeepSpec) | `state="in-progress"`, `shared_top` (the folder, relative to the producer's share root), `shared_subpath` (`highspec` / `deepspec`) |
| The spectrograph is done with the plan | `spec.py:670` | `state="completed"` or `"failed"`, `stage=PlanStage.Spec`, errors; no folder |

An **aborted** plan gets no closing notification (`spec.py:665-668` returns when the
spectrograph no longer owns the plan), and a notification can be resent when its
acknowledgement is lost.

**Control already acts on them.** `Controller._handle_assignment_notification`
(`control/controller.py:1055`) links the producer's folder into the plan's products folder,
and on the spectrograph's `completed` / `failed` ends the plan.

**Control already has a hook on every plan ending.** `PlanExecution._terminate`
(`control/execution.py:296-315`) records the outcome, copies the plan TOML into the products
folder, and calls `on_terminated`, wired to `Controller._execution_ended`
(`controller.py:968`, `:1023`). It runs on every path: the spectrograph's notification, an
abort, a lost quorum, and control's own backstops when no notification comes (`spec-done`,
`spec-silent`, `execution.py:619-627`). By then the spectrograph folder is already linked
under `Spec/<instrument>/`.

**Each spectrograph folder says when it is finished and whose it is.** `plan_id` is written
when the folder is created, before the first frame (`highspec.py:651-657`,
MAST_common `models/plans.py:51-83`), so the folder names its plan wherever it is found.
`latest.json` (MAST_common `models/latest.py:31`, `:96`) is written when the series ends and
carries the number of frames saved.

**The plan products folder is the bundle.** MAST_common `PlanProducts`
(`models/plans.py:87`) is `plans/products/PLAN_<ulid>/<UTC start>/<Stage>/<producer>/`,
holding relative symlinks to where each producer's products landed on the share.
`PlanStage` (`models/plans.py:36`) is documented as the stages *whose products an execution
links*, and is also the type of `AssignmentNotification.stage`, which MAST_unit and MAST_spec
send.

**Control already knows when it is night.** MAST_common `Site.observing_window()`
(`config/site.py:97`) computes tonight's dusk-to-dawn window from the site's sun limits, and
`Scheduler.make_immediate_batch` (`control/scheduling.py:45-60`) already uses it.
(Control's own `control/safety.py` is a stub, and the safety service does not answer from
mast-ns-control, MAST_common#68.)

**mastpipe has most of what a per-product trigger needs:**

- A CLI, `mastpipe quicklook NIGHT_DIR --out OUT --instrument ... [--library LIB]`
  (`pipeline/commands.py:55`).
- **Idempotence by input, per `--out`:** a science product whose key (input checksum,
  configuration hash, reference, drift-arc checksums) is already under `OUT/spec` is skipped
  (DECISIONS 2026-10-30; `group.py:164`, `science.py:309-310`).
- **Atomic writes** for products, QA and the library index (`io/atomic.py`).
- **A calibration library shared across runs** (`--library`), whose index is re-read and
  written under a lock (`pipeline/callib.py:97`, `:125`). Drift-arc fits are not stored
  there; they stay in the run's memory.

What it does not have yet, for a subprocess caller:

- **No machine-readable result.** `quicklook` prints human-readable counts
  (`commands.py:112-122`) and returns 2 both when one frame failed and when the whole run
  could not start; a library lock timeout or a bad `index.json` escapes as a traceback with
  exit 1 (`runner.py:318`, outside the per-group handling). Control needs something like a
  `--summary-json` and distinct exit codes -- a mastpipe change (Q9).
- **Logging to stderr.** The full INFO log goes to stderr as well as to
  `OUT/logs/quicklook_<YYYYmmddTHHMMSS>.log` (`runner.py:150-157`), so the caller must drain
  or redirect both pipes. The log name has one-second resolution and is opened in append
  mode, so two runs into one `--out` in the same second share a log.

## 3. Proposed flow

1. **Trigger on the plan's end.** The spectrograph's `completed` notification is what
   normally ends a science plan; control turns every ending into one call to
   `_execution_ended`. Queueing the reduction there, rather than in the notification handler,
   covers aborted plans and lost notifications too (their frames are on the share all the
   same), and gives one place to dedupe a resent notification. The job carries the
   instrument, the spectrograph folder(s) linked under `Spec/`, and the plan's products folder.
2. **Wait for the share.** The plan can end before its frames are on the share: products
   reach it after the RAM-to-share move, which control's linker already treats as the normal
   order (`controller.py:1062`, `:1100`). The job waits for `latest.json` in the folder on the
   share, then for as many FITS files as it says were saved -- the mover does not guarantee
   the order of files. `plan_id` is no use here: it is there before the first frame.
3. **Run.** A job runner in MAST_control starts `mastpipe quicklook` as a **separate process**
   (`asyncio.create_subprocess_exec`), never in control's own process: a reduction must not
   be able to stall or crash control, and control must be able to kill one. Its stdout and
   stderr go to a file, not a pipe.
   - input: the spectrograph folder on the share;
   - `--out`: the plan's reduction folder (§4);
   - `--library`: one calibration library on the share (§4).
4. **Record.** The job's exit code, its summary and its log path go into the plan's events.
   Those events come after `_terminate` has copied the plan TOML into the products folder
   (`execution.py:307-309`), so the copy is refreshed when the job ends. A failed reduction
   never fails the plan: the plan is over by then.
5. **Throttle.** Jobs go through a queue whose concurrency limit depends on whether it is
   inside `Site.observing_window()` (§5.2).

## 4. Bundling on the share

The goal: open one plan folder and find its raw frames, its unit products and its reductions.

```
plans/products/PLAN_<ulid>/<UTC start>/
    PLAN_<ulid>.toml              <- copied by _terminate, refreshed after the job
    Autofocus/<unit>/...          -> links, as today
    Acquisition/<unit>/...        -> links, as today
    Spec/highspec/<acquisition>   -> link, as today
    reduction/mastpipe/           <- new: mastpipe's --out, written in place
        spec/ qa/ calib/ logs/quicklook_<stamp>.log
        job.json                  <- control's record: mastpipe version, command, exit, times
```

- **A sibling folder, not a fourth `PlanStage`.** `PlanStage` means "linked from a
  producer", and it is a shared notification type: a new member is one any producer could
  claim, and needs paired branches across MAST_common, MAST_unit and MAST_spec. Reductions
  are written in place by control, which runs where the share is a local disk.
- **One calibration library for the site**, e.g. `mastpipe/calib/<instrument>/` at the share
  root. Masters and reference solutions outlive any one plan. But see §5.1 on master age and
  §5.2 on who may write to it.
- **Frames taken outside a plan** -- operator exposures under `Exposures/seq=NNNN`, the
  bench, and today *all* calibration frames -- have no plan folder and send no notification.
  They need a home too (Q5).

## 5. Choices

### 5.1 Per-plan runs vs. a nightly sweep

| | Per plan (this sketch) | Nightly timer (2026-11-03 proposal) |
|---|---|---|
| Latency | minutes after the plan | next morning |
| Night context | one plan's frames; masters must come from the library | the whole night: biases, darks, flats and drift arcs are all in the folder |
| Concurrency | several runs at once | one run |
| Bundling | output lands in the plan's folder | output is per night, but each folder's `plan_id` routes it to its plan |

The cost of per-plan runs is **night context**, and today it is a hard one:

- **Masters.** `quicklook` stacks masters from the frames it is given, or takes them from the
  library; with neither it fails the group with "no bias frames in the night and no bias
  master in the library" (`masters.py:164-165`). No plan takes calibration frames: a plan
  fails without units (`execution.py:132-133`) and its spectrograph phase starts only once
  units are guiding (`execution.py:230-243`). Calibrations come from operator exposures,
  which nothing feeds to the library. So until something does, every per-plan run fails.
- **Drift arcs** are never stored in the library; a per-plan run pairs only the arcs in its
  own folder.
- **Master age.** `CalibLibrary.find` takes the nearest master in time with no upper bound
  (`callib.py:206-242`). Once a site library exists, a per-plan run will flat-field with a
  months-old flat without a word, except in its provenance. A per-plan design that leans on
  the library needs a maximum age, or QA that flags it (Q2).

A **hybrid** -- per-plan quick-looks during the night, a better pass in the morning -- only
improves the bundle if the morning pass works *per plan*: idempotence is per `--out`, so a
sweep into its own night folder would reduce everything again and leave the plan folders
with the worse reduction. The morning pass would first fill the library from the night's
calibrations, then re-run `quicklook` on each plan folder into that plan's own `--out`, where
products whose masters changed are reduced again.

### 5.2 Concurrency and throttling

Can several mastpipes run at once against different products? **Two processes on
mast-ns-control, into separate `--out` folders, mostly yes**: outputs never collide, the
library index is locked and atomically replaced, and products are written atomically.

What is **not** safe as it stands:

- **Two runs registering a master under the same name.** `CalibLibrary.add` names a master
  after its *first* frame's time and checksum (`callib.py:156`, `products.py:97-110`) and
  replaces any index entry with that path. Two runs whose bias sets share a first frame but
  differ in members -- an evening set and the whole night in the morning pass -- write the
  same file name: the later one replaces the earlier file and entry. Products made against
  the earlier master then carry a `masters_hash` that no longer matches, and are reduced
  again on the next run (Q1).
- **Stale lookups.** `find` reads the index as this process last loaded it
  (`callib.py:203`), so a run does not see a master another run added after it started. If
  that master was its only bias, the group fails (`masters.py:164-165`).
- **A hand reduction over SMB.** `locked()` is `fcntl.flock` on Linux and `msvcrt.locking`
  on Windows (`io/atomic.py:61`, `:65`). A Windows run over SMB takes a byte-range lock that
  Samba maps, at most, to POSIX record locks, which are independent of `flock` on Linux. So a
  workstation reduction and control's local job can both hold "the" lock and lose each
  other's index entries. Likely rather than tested; until it is, a hand reduction uses its
  own library.

**Throttling.** A queue in MAST_control whose concurrency limit is lower (or zero: queue
only) inside `Site.observing_window()`, and higher outside it. If the night limit only
defers jobs, the queue has to survive a control restart (Q7).

## 6. Open questions

1. **Shared-library safety (Na'ama, mastpipe):** should a master's name identify its member
   set rather than its first frame, so two runs never overwrite each other's master? And
   should the library refuse writers whose lock it cannot honor (SMB)?
2. **Night context:** where do masters come from for a per-plan run -- a calibration
   sequence that control runs and feeds to the library, operator calibrations swept into it,
   a carried-over library with a maximum master age -- and what does a run do when there is
   none: fail and re-queue, or wait?
3. **"On the share and settled":** is `latest.json` plus a frame count enough, or should the
   mover say when a folder is complete? And what is the job's timeout?
4. **The throttle:** is `Site.observing_window()` the right notion of observation hours, or
   "a plan is in progress", or the roof? Is the night limit 0 or 1?
5. **Frames outside a plan:** where do operator, bench and calibration frames get reduced,
   and where do their products land?
6. **Bundle layout:** `reduction/mastpipe/` as above, or somewhere else in the plan folder?
   Does `job.json` duplicate what the plan's events say?
7. **Job durability:** a queue in memory loses jobs on a control restart. Acceptable for a
   quick-look (the morning pass catches up), or does the queue persist?
8. **Where it runs:** mast-ns-control has the share as a local disk, which is why control
   owns the plan folder. Does it also have the CPU and memory for mastpipe during a night,
   next to MAST_control's own work?
9. **mastpipe's caller contract (Na'ama):** a `--summary-json` (or similar), exit codes that
   tell "some frames failed" from "the run failed", and run-level failures (lock timeout, a
   bad index) reported the same way as the rest.
10. **Packaging:** mastpipe in its own venv on mast-ns-control, called by path, so its
    dependencies never meet MAST_control's? Which version is deployed, and who upgrades it?
11. **DeepSpec:** mastpipe reduces HighSpec today; DeepSpec folders end plans the same way.
    Queue them and skip, or do not queue until mastpipe supports them?

## 7. Possible phasing

1. **By hand, against the layout.** Run `mastpipe quicklook` on one real plan's spectrograph
   folder into `reduction/mastpipe`, with a library filled by hand from that night's
   calibrations. Proves the layout and makes Q2 concrete (needs the frame contract's M1).
2. **One job at a time, no throttle.** Control queues a job from `_execution_ended`, waits
   for the share, runs mastpipe as a subprocess at concurrency 1, records the result.
   Needs Q9 on mastpipe's side and an answer to Q2.
3. **Throttle and concurrency.** The observing-window limit, and N > 1 once Q1 is settled.
4. **Morning pass, per plan,** if night-time runs leave products short of the night's
   calibration.

## Provenance

The broad strokes in §1 are a team direction, 2026-11-11. Everything else was drafted
2026-11-11 from the code at the commits above and the 2026-11-03 mastpipe review, and vetted
by a fresh-eyes review against the code; nothing here has been run.
