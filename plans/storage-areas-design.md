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

`D:` is an ImDisk RAM disk created by the `\ImDisk Persistent Drive` scheduled task. A
scheduled task is not monitored or restarted the way a service is, so the disk can die
mid-run, and when it does **its contents are gone**, not merely unreachable. The
mast-supervisor waits for it before starting the unit, and may restart the task (§8).
Leaving products on the RAM disk while the share is down — the current deferral design —
also risks filling it during a long outage.

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

The legacy `C:/MAST/` night folders that the old construction-time fallback left on some
machines are **not** swept automatically — they mix products with logs and are not
certainly products. Listed per machine and moved by hand (§11).

### 6.4 Guards

- **Never onto itself.** `move` refuses when source and destination resolve to the same
  path, or one is inside the other — fixes §1.2 independently of the root layout.
- **A free-space floor on `C:`.** A full system disk is worse than a full RAM disk. Below
  the floor, a spill is refused: the product stays where it is, and an ERROR names it.
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
- **The astrometry indexes** live on the RAM disk and are restored by provisioning / the
  supervisor, not by `Filer`. Until then solving fails; the unit reports *why* ("indexes
  missing on the RAM disk") rather than a generic solver error.

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

- **Restarts the ImDisk task** when the RAM disk disappears, since a scheduled task is not
  restarted by Windows. *Changes supervisor-design §14*, which says the supervisor "does
  not mount the ImDisk … only checks and reports" (decided 2026-10-14). Whether it also
  restores the indexes, or provisioning keeps that, is open (§11).
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

1. **The `C:` free-space floor** (§6.4): an absolute size, or a percentage?
2. **Indexes after a RAM-disk restart:** the supervisor restores them, or provisioning?
3. **Legacy `C:/MAST/` night folders** on machines where the old fallback was taken: list
   them per machine before moving anything; some are control's or local logs.
4. **MAST_spec** builds the same `Filer` on `mast-ns-spec`; its use of the RAM disk and
   any `Z:` assumptions are not checked (not checked out here). MAST_spec#2 is the same
   problem from that side.
5. **Reconnect cost.** The first UNC access after idle may pay a reconnect; the 2 s probe
   timeout may need to be longer for `writable()`.

## 12. Work items, in dependency order

1. **MAST_provisioning** — `LongPathsEnabled = 1`; verify on mast00 first, then the fleet.
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
5. **MAST_common: area state + monitor** (§5), the UNC share root (§9), the two fallbacks
   (§3).
6. **MAST_common: moves** — destination by `mkdir`, `.partial` + rename, drain of the
   fallbacks, the `C:` floor (§6).
7. **MAST_common: RAM loss** — loss reporting, claim dropping, `make_seq` seeding,
   `PathMaker` asking for the current root (§7).
8. **MAST_common: logging** (§10).
9. **MAST_unit** — solver scratch on the current RAM root; the "indexes missing" report;
   `acquisition.py:128` (if not already in 3).
10. **supervision** — UNC resource probe, ImDisk task restart, the status line (§8).

Items 2–4 are useful on their own and carry no behaviour change for a healthy machine.

## 13. Verification

- **Unit tests** against temp roots for every transition: primary → fallback on a failed
  `mkdir`, back on a successful probe; fallback drained on promotion; a move onto itself
  refused; a `.partial` never visible under the final name; `make_seq` seeded across all
  four roots; the log handler following the root and naming fallback files.
- **On mast00, with the operator present** (both touch a running unit):
  1. Share: block `mast-ns-control` with a firewall rule for a few minutes during an
     acquisition. Expect one WARNING, products and logs under `C:/MAST/share-fallback/`,
     one INFO on recovery, the fallback drained, nothing left behind, no collision.
  2. RAM disk: stop / remove the ImDisk drive between acquisitions. Expect the in-flight
     acquisition to fail cleanly, the loss reported, the next acquisition on
     `C:/MAST/ram-fallback/`, then promotion after the supervisor restores `D:`, and the
     next `seq` continuing from the share rather than restarting at `0001`.
  3. Long paths: with `LongPathsEnabled = 1`, move a product whose UNC path exceeds 260
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
since the ImDisk task is not restarted by Windows. Kept from review: path conversion stays
pure (`to_top`), with fallback chosen by the mover, not the converter; distinct fallback
folders; drain of the fallbacks; per-file atomicity; loss reporting and sequence seeding.
