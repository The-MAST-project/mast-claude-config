# Storage areas: the share by UNC, and fallbacks that follow the machine at run time

> **Status: PLAN (rewritten 2026-10-14), not implemented.** Supersedes the 2026-08-11
> "migrating the shared area from a mapped drive to UNC paths" draft, which this file
> replaces. Tracked as `MAST_common#26`.
>
> A unit has two storage areas that can fail while its long-running processes are up:
> the **RAM disk** (`D:`, ImDisk, can fill *or disappear*) and the **share**
> (`\\mast-ns-control\mast-share`, can become unreachable). Each gets a local-disk
> fallback, chosen **at the moment of use**, and a monitor that returns it to its primary
> once that is writable again. The share is reached by UNC instead of `Z:`. Products,
> logs and solver scratch all follow the current choice; whatever lands on a fallback is
> drained to the share later; anything lost with the RAM disk is reported.

## 1. Why

### 1.1 Accessibility is decided once, and the processes run for days

`Filer.__init__` ([filer.py:103-141](../../common/filer.py#L103)) picks every root when a
`Filer` is constructed: `shared` is `Z:/MAST/<hostname>/` if `Z:` is mapped, else
`C:/MAST/`; `ram` is `D:/MAST/` if `D:` is mapped, else `C:/MAST/`. The unit, the spec and
the supervisor run for days. The share comes and goes in between, and the RAM disk can
fill or vanish (§1.3). A choice made at construction is wrong for most of a process's life.

The log handler is the same: `init_log` passes `Filer().machine_log_root()` as the
handler's `base_dir` once ([mast_logging.py:399](../../common/mast_logging.py#L399)). A
process started while the share was down logs to `C:` until it exits; one whose share
drops later loses file logging until it returns (`_emit` returns when `_reopen` fails,
[mast_logging.py:190-200](../../common/mast_logging.py#L190)).

### 1.2 The silent fallbacks can collapse onto one folder, which deletes products

With neither `D:` nor `Z:` mapped, `local`, `ram` and `shared` are all `C:/MAST/`. The
startup relocation sweep then moves every folder under `C:/MAST/` onto itself, and
`_merge_into(src, src)` compares each file with itself, finds it "identical", and unlinks
it. **Verified on mast00, 2026-10-13**, on a scratch folder: `Filer().move(p, p)` deleted
`frame.fits` and kept only `seq.txt`. MAST_common#157 (skip paths not under the RAM root)
does not cover it: in this state they are under it.

### 1.3 The RAM disk can fill, and it can disappear

`D:` is an ImDisk RAM disk created at boot by the `\ImDisk Persistent Drive` scheduled
task (runs as `mast`, highest privileges):

```
imdisk -a -m D: -t vm -f "C:\MAST\Shared\MAST-15GB-indexes-5202+5203.img"
```

`-t vm -f` loads the image into memory; nothing is written back. The image holds the
astrometry indexes (`D:\mast-indexes\`) and an empty `D:\MAST\` — checked on mast00
2026-10-14: nothing under `D:\MAST\` predates the boot except the folder itself, so a
revival brings back no stale `seq.txt` or products. That property must be kept whenever
the image is rebuilt.

A scheduled task is not monitored or restarted the way a service is, so the disk can die
mid-run, and when it does **its contents are gone**, not merely unreachable. The
mast-supervisor waits for it before starting the unit, and revives it (§8). Leaving
products on the RAM disk while the share is down — the current deferral design — also
risks filling it during a long outage.

### 1.4 Path spellings disagree

Roots are stored forward-slashed (`D:/MAST/`); `PathMaker` returns `str(Path(...))`, which
is backslashed on Windows. Every prefix test or `.replace` between them silently does
nothing unless the caller converts first:

- [acquisition.py:128](../../unit/src/acquisition.py#L128) — `self.folder.replace(ram.root,
  shared.root)` never matches on Windows, so `plot_acquisition_corrections` is always
  given the RAM-disk folder (checked 2026-10-13). Same class as the 2026-07-22 loss of
  eight runs' frames.
- `Filer.change_top_to` ([filer.py:347](../../common/filer.py#L347)) needs a forward-slashed
  input, replaces every occurrence rather than the leading root, returns `None` silently,
  and on Linux raises `AttributeError` on the `None` RAM entry. Flux metering converts
  before calling it ([session.py:1303](../../unit/src/flux_metering/session.py#L1303)).

### 1.5 Today, a missing `D:` makes the startup sweep walk all of `C:/MAST/`

With `D:` unmapped, `ram` falls back to `C:/MAST/`, and `start_product_relocation_sweep`
([filer.py:427](../../common/filer.py#L427)) treats every folder there holding files as a
leftover product. On mast00 that is the RAM-disk image folder (`Shared/`), `iers-cache/`,
`config-db-cache/`, `Kepler/`, `Campaigns/` and scripts. With the share mapped they are
moved to it — including the image needed to revive `D:`; with the share unmapped too,
each is moved onto itself and loses its files (§1.2). A missing `D:` is exactly the state
an ImDisk task that failed at boot leaves; the supervisor waits for `D:` in `production`,
but a `development` start from VSCode does not. Stopgap in §12, item 0.

## 2. Findings on mast00 (2026-10-13/14)

| Question | Answer |
|---|---|
| Does UNC work from Python? | Yes. `os.path.isdir`, `pathlib`, `os.path.join`, `is_accessible`, create / rename / cross-volume `shutil.move` / delete in a probe folder of our own. |
| Does it need stored credentials? | No. `//10.23.1.181/...` and `//mast-ns-control.weizmann.ac.il/...` (new SMB sessions, not the `Z:` one) both work as the logged-on `mast`. mast00 is in `WORKGROUP`; `cmdkey` holds nothing for `mast-ns-control`. |
| Share name | `mast-share` (`net use`: `Z: \\mast-ns-control\mast-share`). |
| Who runs the unit? | User `mast`, interactive session 1 (VSCode). No NSSM services or MAST scheduled tasks on mast00. The supervisor design launches the apps in the autologon session too, so the 2026-08-11 draft's premise — a session-0 service cannot see `Z:` — no longer applies. UNC is now about robustness, not reachability. |
| `os.path.realpath("Z:/MAST/mast00/")` | `\\mast-ns-control\mast-share\MAST\mast00` — already UNC. But only while the share is reachable: otherwise it returns `Z:\...` unchanged. |
| Long paths | **`LongPathsEnabled = 0`.** Longest product path on the share: 238 chars as `Z:`, **263 as UNC** — over `MAX_PATH`. Blocker (§9). |
| `Z:` anywhere else? | Only `filer.py` in common and unit production code. Nothing in the config DB (`units`, `sites`, `services`, `specs` scanned for `Z:`, `mast-share`, UNC prefixes). |

## 3. Areas, roots and fallbacks

| Area | Primary (Windows) | Fallback | Fails by |
|---|---|---|---|
| `ram` | `D:/MAST/` | `C:/MAST/ram-fallback/` | filling (`ENOSPC`), or the ImDisk task dying |
| `share` | `//<controller_host>/mast-share/MAST/<hostname>/` | `C:/MAST/share-fallback/` | the share or the network becoming unreachable |
| `local` | `C:/MAST/` | — | (it is the fallback) |

`share_root` (`//<controller_host>/mast-share/MAST/`) is kept for the share-level probe
(§4.3). `machine` (the per-machine folder) is the `share` area.

**The two fallbacks are different folders, by rule.** If both were `C:/MAST/`, a RAM
product written to the RAM fallback while the share is down would be "moved" onto itself —
§1.2's deletion. `Filer.move` additionally refuses a move whose source and destination
resolve to the same path or one inside the other (§6.4).

**Linux** (control) is unchanged in behaviour: `ram` is `None`, and the share is the local
`/Storage/mast-share/MAST` that the control machine serves. It gets the new `Location` and
`to_top`, and no fallback state.

## 4. `Location`

### 4.1 One canonical root

`Location(root: str)` — one argument; a UNC root has no meaningful drive/prefix split, so
the two-part constructor goes. `__init__` canonicalises **as string work only**: forward
slashes, exactly one trailing slash. **No `realpath`**: it touches the file system (a hung
redirector would hang `Filer()`, and `common.utils` builds one at import), it drops the
trailing slash the prefix tests rely on, and its answer for `Z:` depends on whether the
share is up (§2). Comparisons against a root are case-insensitive on Windows.

### 4.2 Live checks

- `readable(timeout=2.0) -> bool` — the root is a directory, within the timeout.
- `writable(timeout=2.0) -> bool` — create and remove a probe folder in the root, within
  the timeout. Not `os.access`: on Windows it reads only the read-only attribute, not ACLs
  or share permissions. The probe name carries hostname and PID, so concurrent processes
  do not collide.

Both run on a short-lived thread, like `is_accessible` today, because SMB and a dying
ImDisk can block `isdir` / `open` indefinitely. Results are cached for a few seconds:
moves and sweeps ask per file.

### 4.3 Probing the share, not the machine's folder

A new or renamed machine's folder does not exist until something creates it
(`ensure_shared_root`, [filer.py:149](../../common/filer.py#L149)). So "is the share up"
probes `share_root`, as `machine_log_root` already does, and the machine's folder is
created on demand.

## 5. Area state: demote on failure, promote by a monitor

Process-wide state on `Filer` (class-level, like `_pending`: `Filer()` is constructed
everywhere): for each failable area, `PRIMARY` or `FALLBACK`.

- **Demotion is immediate, on any failed use.** A move, `mkdir`, open or write that fails
  against the primary with an `OSError` marks the area `FALLBACK` and is retried against
  the fallback. Waiting for the monitor would mean a minute of failures.
- **Promotion is the monitor's.** A daemon thread, once a minute, checks each demoted
  area's primary with `writable()` (create and remove a folder). On success the area
  returns to `PRIMARY`, and the drain (§6.3) is triggered.
- **Reported once per transition:** one WARNING on demotion (area, primary, fallback,
  cause), one INFO on promotion, plus the drain's summary. Not a line per file — the
  pattern `NotificationWorker` already uses.
- `Filer` never recreates `D:` or remounts anything. Recreating the RAM disk is the
  supervisor's (§8).

Each process runs its own monitor; the probes are cheap.

### 5.1 The client interface

Several clients write under the roots without going through `Filer.move`: the imager
backends saving FITS, the log handler, solver scratch, `PathMaker`. So:

| Method | For | Notes |
|---|---|---|
| `current_root(area) -> str` | anything that creates a folder or file under an area | Asked each time, never held: that is what makes a demotion stick. Cheap. Replaces subscriptions — nothing is notified of a change. |
| `report_failure(area, path, exc)` | a client whose write under an area failed | A **report**, not a command: `Filer` classifies the error. Area-level — `ENOSPC`, the root missing, the network path gone (`WinError` 53, 59, 64, 67, 1231), a probe timeout — demotes. Path-level — access denied on one file, a missing subfolder, a name in the way — does not: one bad file must not send every product to `C:`. |
| `check_now(area)` | a client with reason to think the primary is back | Runs the promotion probe at once instead of at the next minute; promotes only if it passes. |

**No client-driven promotion.** Only the probe (§5) promotes: a client cannot know the
area is healthy, and a wrong promotion costs a round of failed writes.

**The supervisor does not nudge the unit** after reviving `D:`: they are separate
processes, and the unit's monitor finds the disk within a minute (decided 2026-10-14). A
`PUT /storage/check` endpoint calling `check_now` is the upgrade if that minute ever
matters.

A manual hold (`hold_fallback(area, reason)` / `release(area)`, keeping an area on its
fallback through planned maintenance) is **not** planned; add it if planned maintenance
turns out to need it. Tests demote through `report_failure` with a real area-level error.

## 6. Moves

### 6.1 Choosing the destination at the moment of the move

`Filer.move` (not `MoveGuardian` — its job stays "never move what is being written")
creates the destination folder **as the accessibility test**: it is the real operation, so
it cannot disagree with a probe. Failure demotes `share` and the destination is rebuilt
under the share fallback.

**Spill immediately.** When the share is unreachable, products go to the share fallback
on `C:` rather than staying on the RAM disk, which could fill (decided 2026-10-14). Brief
outages therefore also touch `C:`; the drain returns them.

### 6.2 Atomic per file

Copy to `<dst>/.<name>.partial`, then rename onto `<dst>/<name>`, then remove the source.
A cross-volume `shutil.move` today copies under the final name, so a share dropping
mid-copy leaves a truncated file that the next attempt reads as a collision (reported,
source kept, junk left). With the rename the product appears whole or not at all.
`.partial` files are bookkeeping (`is_bookkeeping`) and are removed by the next attempt.

A whole acquisition is not made atomic: if the share fails half-way, the rest goes to the
fallback, and the existing merge (`_merge_into`) recombines the two halves on drain.

### 6.3 Draining the fallbacks

The sweeper drains, each pass: the RAM primary, the RAM fallback, and the share fallback.
`to_top` accepts the primary **and** the fallback as source roots of an area. On the share
area's promotion the share fallback is drained at once rather than at the next 30 s pass.
The relocation sweep at startup covers the same three.

**The legacy `C:/MAST/<YYYY-MM-DD>/` night folders are swept too** (decided 2026-10-14):
the folders the old construction-time fallback left whenever a process started with the
share unreachable. Only top-level folders whose name is a night label — never anything
else under `C:/MAST/` (`Shared/` with the RAM-disk image, `iers-cache/`,
`config-db-cache/`, `Kepler/`, `Campaigns/`, scripts). On mast00 (2026-10-14) there are
82; 81 hold only log files, and `2026-04-19` holds 21 product files under
`Acquisitions/`.

Their log files are renamed on the way, to the fallback name of §10
(`mast-<role>-log.fallback.txt`; `mast-STARTUP-log.txt` likewise): the share usually has
its own `mast-<role>-log.txt` for the same night, and the two differ, so moving them under
the same name would be a collision on every sweep.

### 6.4 Guards

- **Never onto itself.** `move` refuses when source and destination resolve to the same
  path, or one is inside the other — fixes §1.2 independently of the root layout.
- **`C:` never above 90% used** (decided 2026-10-14). A full system disk is worse than
  losing data: Windows itself degrades. At or above 90%, writes to either fallback are
  refused. Products stay where they are (on the RAM disk, while it lives), so they are
  lost only if the RAM disk fills or dies before the share returns; file logging stops
  while the console keeps every record. One ERROR when the ceiling is first hit, one INFO
  when usage drops below it. mast00 was at 92% on 2026-10-14 — 40 GB of unused RAM-disk
  images — and at 84% once they were removed; the fleet needs the same check (§12).
- **Bookkeeping stays put** (`seq.txt`, claims, `.partial`), as now.

## 7. The RAM disk dying

### 7.1 While it is gone

- **Producers mid-write fail**, with an `OSError` on a `D:` path. That is correct; the
  acquisition must fail cleanly (flags ended, folder released) so that the next one starts
  on the fallback. Folder creation therefore asks `Filer` for the area's *current* root
  each time — `PathMaker` stops defaulting to `Filer().ram.root` held from earlier
  ([paths.py:94, 131, 161, 174, 198](../../common/paths.py#L94)).
- **Losses are reported.** Today `_drain_pending` drops a queued move whose source no
  longer exists, silently ([filer.py:575](../../common/filer.py#L575)), and the folder
  reaper counts a vanished product as moved because it tests `os.path.exists`
  ([filer.py:1014](../../common/filer.py#L1014)). With the RAM area demoted, both log one
  ERROR listing the products lost with the disk.
- **Claims on the dead root are dropped**, not released one by one: their lock files went
  with the disk, and the open handles `MoveGuardian._folder_claims` keeps are stale.
- **Solver scratch** (`D:/MAST/tmp`, [astrometry_dot_net.py:172](../../unit/src/solvers/astrometry_dot_net.py#L172),
  [mastrometry.py:127](../../unit/src/solvers/mastrometry.py#L127)) follows the RAM area's
  current root. Its hard-coded `/cygdrive/d` becomes a conversion of the current root.
- **The astrometry indexes** live on the RAM disk and come back with it: the image holds
  them (§1.3). Until the supervisor has revived `D:`, solving fails; the unit reports
  *why* ("indexes missing on the RAM disk") rather than a generic solver error.

### 7.2 When it comes back, empty

- **Sequence numbers.** `PathMaker.make_seq` reads `seq.txt` in the RAM folder, else
  starts at 0 ([paths.py:25-41](../../common/paths.py#L25)). On a recreated RAM disk the
  next acquisition is `seq=0001` again — straight into folders already on the share.
  (`is_bookkeeping`'s docstring names this risk for a reboot; a mid-run restart makes it
  routine.) `make_seq` seeds from the **highest sequence present** in the same relative
  folder across the RAM primary, the RAM fallback, the share and the share fallback, and
  only then bumps.
- **Promotion means writable,** nothing more (§5). The unit does not restart; it follows
  the monitor.

## 8. The supervisor

- **Revives the RAM disk** when it disappears, since a scheduled task is not restarted by
  Windows: by running the task itself (`schtasks /run /tn "\ImDisk Persistent Drive"`),
  so the image is named in one place. The image brings the indexes back with it (§1.3).
  *Changes supervisor-design §14*, which says the supervisor "does not mount the ImDisk …
  only checks and reports" (decided 2026-10-14).
- **Does not tell the unit.** The unit's monitor finds the revived disk within a minute
  (§5.1).

### 8.1 `PUT /ramdisk/restart`: clients may ask for a revival

The supervisor serves `PUT /ramdisk/restart` (decided 2026-10-14). It runs in both
opmodes — under `development` it launches VSCode rather than the app, but it is up — so
the recovery below works in both.

**Restarting wipes `D:`.** A forced restart detaches the disk whatever holds it open and
reloads the image, so everything on the RAM disk not yet moved is gone. Every rule below
exists to make sure it happens only when that is already true.

**Who asks, and when.** `Filer`, when it classifies a failure on the `ram` area (§5.1) as
**the disk being gone**: the RAM root missing, the device not ready, the path not found
*on the root itself*. Never for:

- **a full disk** (`ENOSPC`). Full is cured by moving products off, not by wiping them —
  and a full RAM disk is most likely during a long share outage, exactly when it holds the
  most unmoved products. Full demotes the area (§5); it never asks for a restart;
- **a path-level error** (access denied on one file, a missing subfolder).

The request is sent from a background thread, never from the failing write: the area is
demoted at once regardless (§5), and the write is retried on the fallback.

**What the supervisor does.**

1. **Treats the request as a hint and checks for itself**, with the same writable probe
   (§4.2). If `D:` is writable it answers `409` with "D: is healthy" and does nothing — a
   client with a mistaken view cannot wipe a working disk.
2. **Detaches** (`imdisk -D -m D:`, forced) and **runs the task** (`schtasks /run /tn
   "\ImDisk Persistent Drive"`), so the image is still named only in the task (§1.3).
3. **One restart at a time.** Requests arriving during a restart — from the unit's
   `Filer`, a solver, or the spec's — join the one in progress and get its outcome.
4. **Backoff, and a limit.** Loading 15 GB into memory takes a while; a disk that dies
   again at once must not loop. After three failed or short-lived revivals within an hour
   the supervisor stops trying, raises it in its status, and leaves the units on their
   fallbacks.
5. **Also watches on its own.** It already checks the RAM disk as a resource (§8), so it
   revives without being asked; a client's request only shortens the wait.

**Responses:** `202` with the restart's state while it runs, `200` "restored" once `D:` is
writable again, `409` "healthy", `503` "giving up" once the limit is reached.

**The client's side.** A `SupervisorApi` in `common/api.py`, beside the other `BaseApi`
clients, so the spec's `Filer` behaves the same way. On "restored", `Filer` calls
`check_now("ram")` — acting on its own call's answer, which is not the supervisor nudging
it (§5.1). A supervisor that does not answer is logged once; the area stays on its
fallback, and the one-minute check finds the disk whenever it returns.

**Localhost only.** The endpoint wipes a disk, so the supervisor binds it to `127.0.0.1`;
nothing off the machine can call it.
- **Its resource wait probes the share by UNC**, replacing the `Z:` check, and keeps the
  RAM-disk check (supervisor-design §5, the `RAM disk + indexes` row).
- **Reports the event** in its status: "RAM disk lost 02:14, restored 02:15", so a gap in
  products is explained.

## 9. UNC and long paths

- `share_root` = `//<controller_host>/mast-share/MAST/`, with `controller_host` from
  `load_local_config()` — MongoDB-free, so `Filer` can use it at import. `mast-share` is
  a constant until a site needs otherwise.
- **Prerequisite: `LongPathsEnabled = 1`** on every Windows machine, set by
  MAST_provisioning (`HKLM\SYSTEM\CurrentControlSet\Control\FileSystem`). Python 3.12 is
  long-path aware once it is set. Not the `\\?\UNC\` prefix: it bypasses normalisation and
  sits badly with `pathlib`. Without the setting the longest existing products (263 chars)
  cannot be moved, and would be retried forever.
- `is_windows_drive_mapped` is retired for the share. It stays for `D:` only as the
  supervisor's precondition, if at all — the live checks (§4.2) answer the real question.

## 10. Logging

- `DailyFileHandler` asks `Filer` for the `share` area's current root **on every record**
  and reopens when it differs from the open file — cheap, a string comparison. Logs move
  to the fallback on demotion and back on promotion, instead of `base_dir` fixed at
  startup.
- **A write that fails** demotes the area through `Filer` and is retried on the fallback.
- **Re-entrancy guard.** `Filer` reporting the demotion would log back into the handler
  that is failing. The handler holds a guard; a transition reported from inside it goes to
  stderr, and is repeated to the file once it is writable.
- **Fallback files have their own name**: `<night>/mast-<role>-log.fallback.txt`. Two
  copies of `mast-unit-log.txt` for one night would differ, and draining them would be a
  collision reported on every sweep. The distinct name also shows the outage in a listing.

## 11. Open questions

1. **MAST_spec** builds the same `Filer` on `mast-ns-spec`; its use of the RAM disk, any
   `Z:` assumptions and its `C:` usage are not checked (not checked out here). MAST_spec#2
   is the same problem from that side.
2. **Reconnect cost.** The first UNC access after idle may pay a reconnect; the 2 s probe
   timeout may need to be longer for `writable()`.

Answered 2026-10-14: the `C:` ceiling is 90% used (§6.4); the RAM disk is revived from
its image, indexes included, by running the ImDisk task (§1.3, §8); legacy night folders
are swept (§6.3); the supervisor does not nudge the unit (§5.1).

## 12. Work items, in dependency order

0. **Stopgap, now, before any of the rest** — MAST_common: the `Filer` redirection in
   `tests/conftest.py` extended to every platform (§13); `Filer.move` refuses a move onto
   itself or into its own subtree (§1.2); and `start_product_relocation_sweep` does not run
   when `ram.root` is `local.root` (§1.5). MAST_unit: fix `acquisition.py:128` (§1.4).
   Overlaps MAST_common#157 in `move()`; agree the order with its author.
1. **MAST_provisioning** — `LongPathsEnabled = 1`; verify on mast00 first, then the fleet.
   **Fleet check** at the same time, per Windows machine: `C:` usage against the 90%
   ceiling, the ImDisk task's command line, and `C:\MAST\Shared\` holding only the image
   the task names.
2. **MAST_common: `Location`** — single canonical root; `readable()` / `writable()` with
   timeout and cache. Tests: canonicalisation (backslashes, missing or doubled slash,
   UNC), case-insensitive comparison on Windows, a probe that hangs.
3. **MAST_common: `to_top` / `locate`** — `to_top(area, path)` pure (separator-agnostic,
   leading root only, Linux-safe, raises when nothing matches, accepts primary and
   fallback); `locate(path)` finds a product on share, share fallback, RAM, RAM fallback.
   Replace `change_top_to` and `move_to` (no callers); fix `acquisition.py:128` and
   flux metering's `_frame_path` to use them.
4. **MAST_common: the self-move guard** in `Filer.move` (§6.4). Small, independent, and
   worth landing first given §1.2.
5. **MAST_common: area state + monitor** (§5), the client interface (§5.1), the UNC share
   root (§9), the two fallbacks (§3); `SupervisorApi` and the RAM-disk restart request,
   sent only when the disk is gone (§8.1).
6. **MAST_common: moves** — destination by `mkdir`, `.partial` + rename, drain of the
   fallbacks and the legacy night folders, the `C:` ceiling (§6).
7. **MAST_common: RAM loss** — loss reporting, claim dropping, `make_seq` seeding,
   `PathMaker` asking for the current root (§7).
8. **MAST_common: logging** (§10).
9. **MAST_unit** — solver scratch on the current RAM root; the "indexes missing" report;
   `acquisition.py:128` (if not already in 3).
10. **supervision** — UNC resource probe, reviving `D:` through the ImDisk task, the status
    line (§8); `PUT /ramdisk/restart` on localhost, with its own check, one restart at a
    time, and the backoff limit (§8.1); and supervisor-design §14 amended to match.

Every item lands with its tests at layers 1–3 of §13, green on both runners; the
`unit_storage` marker comes with item 2. Items 0 and 2–4 are useful on their own and carry no behaviour change for a healthy
machine.

## 13. Tests and CI

The GitHub runners have no RAM disk, no share and no supervisor, and the Linux runner has
no drive letters at all. The suites must pass there, while still proving the behaviour
that only a unit machine can show. Four layers:

**1. Nothing in a test reaches a real root.** Every area is built on temporary folders.
Today only MAST_unit's `conftest` redirects `Filer` on every platform; MAST_common's does
it on macOS only ([tests/conftest.py](../../common/tests/conftest.py)). So on the Windows
runner a bare `Filer()` gets `C:/MAST/` for both `ram` and `shared` — §1.2's collapse —
and on mast00 the suite touches the real `D:` and share. Common's redirection is extended
to every platform, as unit's already is, **before** any of this work lands. A test that
needs particular roots builds a `Filer` from explicit `Location`s rather than patching
attributes after construction, as several do today.

**2. Failures are simulated, never awaited.** Each failure §5–§8 reacts to has an
injectable cause on a temporary root:

| Failure | Simulated by |
|---|---|
| RAM disk gone | removing (or renaming away) the temporary RAM root |
| RAM disk full | the write raising `OSError(ENOSPC)` |
| share unreachable | the root removed, or the probe replaced by one raising a network `OSError` |
| share hung | the probe replaced by one that blocks; the timeout must fire |
| `C:` at the ceiling | the free-space reading replaced |
| supervisor | `SupervisorApi` replaced by a fake answering 200 / 202 / 409 / 503, or not at all |

The monitor's interval and the probe cache's lifetime are parameters, so a test promotes
in milliseconds rather than a minute. No test sleeps for a real interval.

**3. String logic is tested as strings, on every runner.** `Location`'s canonicalisation,
`to_top` and the night-folder name match are pure (§4.1), so the Windows and UNC
spellings are tested on the Linux runner too — `"D:\\MAST\\x"`, `"//host/share/MAST/"`,
doubled or missing slashes — with no file system involved.

**4. The real thing is marked, and skipped where it cannot run.** Tests that need a unit
machine's actual storage carry a marker, `unit_storage`, registered and handled like
`network` (`common/testing/network.py`): skipped in CI (`CI` / `GITHUB_ACTIONS` set)
without probing, and elsewhere skipped unless the real primary is writable — `D:` for the
RAM tests, the UNC share for the share tests — with the reason shown. They are
**non-destructive**: they write and remove a probe folder, move one file onto the share
and back, check a path over 260 characters when `LongPathsEnabled` is set. They never
remove `D:`, never call the restart endpoint, never block the share. (Note: SMB goes
through the Windows redirector, not Python sockets, so the network guard does not see a
UNC access; the marker, not the guard, is what keeps CI off the share.)

The destructive checks below stay manual, on mast00, with the operator present.

## 14. Verification on mast00

**Covered by the unit tests (§13), on every runner:** primary → fallback on a failed
`mkdir`, back on a successful probe; fallback drained on promotion; a move onto itself
refused; a `.partial` never visible under the final name; `make_seq` seeded across all
four roots; the log handler following the root and naming fallback files; the restart
request sent for "gone", never for "full", and acted on only for "restored".

**On mast00, with the operator present** (each touches a running unit):
  1. Share: block `mast-ns-control` with a firewall rule for a few minutes during an
     acquisition. Expect one WARNING, products and logs under `C:/MAST/share-fallback/`,
     one INFO on recovery, the fallback drained, nothing left behind, no collision.
  2. RAM disk: stop / remove the ImDisk drive between acquisitions. Expect the in-flight
     acquisition to fail cleanly, the loss reported, the next acquisition on
     `C:/MAST/ram-fallback/`, then promotion after the supervisor restores `D:`, and the
     next `seq` continuing from the share rather than restarting at `0001`.
  3. RAM-disk restart request: with `D:` removed, the unit's request revives it through
     the supervisor and the unit promotes on the answer, well inside a minute; with `D:`
     healthy, the same request gets `409` and `D:` is untouched; with `D:` merely full,
     no request is sent.
  4. Long paths: with `LongPathsEnabled = 1`, move a product whose UNC path exceeds 260
     characters.

## Related

- `MAST_common#26` — the issue this plan serves
- `MAST_common#52`, `#56` — the RAM → share lifecycle and cross-process claims this builds on
- `MAST_common#156` / PR #157 — moves that could never be dequeued; overlaps §6
- `MAST_spec#2` — remote connection to `Z:`, the same problem from the spec side
- `plans/supervisor-design.md` — §5 resource wait, §14 scope (changed by §8 here)

## Provenance

First drafted 2026-08-11 (UNC because a session-0 service cannot see `Z:`; service account
via NSSM). Rewritten 2026-10-14 with Arie, in session, after the mast00 findings in §2
showed the apps run in the interactive session. The design points are Arie's: the share by
UNC; `Location` with live readability / writability checks and a canonical root; the
destination chosen when a product is moved, by creating its folder, with a fallback to the
local disk; both the RAM disk and the share treated as failable, each with a local
fallback and a once-a-minute recovery check; the log location taken from `Filer` and
falling back when a write fails; and the RAM disk able to disappear, not only to fill,
since the ImDisk task is not restarted by Windows. Same day, answering §11: `C:` never above
90%, losing data rather than filling the system disk; the RAM disk revived from its image,
which carries the indexes; the legacy night folders swept like any fallback; a one-minute
promotion check with no supervisor-to-unit nudge; clients able to report failures but
not to promote; and the supervisor serving `PUT /ramdisk/restart`, in both opmodes, for
clients that find the RAM disk gone. Kept from review: path conversion stays
pure (`to_top`), with fallback chosen by the mover, not the converter; distinct fallback
folders; drain of the fallbacks; per-file atomicity; loss reporting and sequence seeding.
