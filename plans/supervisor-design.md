# The MAST supervisor

> A Windows service (`mast-service`, session 0) that spawns an interactive supervisor
> (`mast-supervisor`, the autologon session). The supervisor shows a small GUI with a rolling
> log and a five-minute state heartbeat, waits for the network / RAM disk / share, reads the
> config DB, owns PWI4, PHD2 and ps3cli, and launches either VSCode or the unit/spec app
> according to `opmode`.
>
> **Status: plan only — not implemented; all design questions closed.**
> Depends on `claude/plans/opmode-design.md` stage 1. Code baseline: MAST_common `master`
> @ `5dfd263`, MAST_unit `main`, 2026-09-16.

## Context

Nothing supervises anything on a MAST machine today. `unit/src/app.py` starts PWI4 and ps3cli
one-shot via `ensure_process_is_running` and discards the result; `PHD2Connector.__init__`
starts phd2.exe with `WatchedProcess(no_restart=True)`, which disables the very watcher that
would restart it. **If any of the three dies, nothing notices and nothing restarts it** — and
in PHD2's case the unit keeps reporting the guider healthy, because `_read_forever` never
clears `_connected` ([phd2.py:864-874](../../unit/src/phd2/phd2.py#L864)).

Nor does anything wait for the machine's preconditions. The NSSM service starts on a
`SERVICE_DELAYED_AUTO_START` timer and hopes: no network check exists anywhere in the fleet,
the ImDisk RAM disk holding the astrometry indexes is checked only for directory existence
(the per-file check at [mastrometry.py:79-94](../../unit/src/solvers/mastrometry.py#L79) is
commented out behind a TODO), and the share probe is consulted lazily by the log handler
rather than waited on. `common/DECISIONS.md:74-79` records the shape of the resulting failure:
"nssm restarted a process that died before it could listen… the operator saw a running
service, an unanswered port, and a traceback they had to go find".

And there is nothing to look at. Every MAST program is a headless uvicorn service under NSSM.
An operator standing at a unit has no way to see what state it is in.

**The outcome:** one supervision chain, one place that knows why a machine is not observing,
and a window that says so.

## 1. The chain

| process | session | started by | supervises |
|---|---|---|---|
| `mast-service` | 0 | NSSM, auto | the supervisor |
| `mast-supervisor` | interactive | the service, `CreateProcessAsUser` | PWI4, PHD2, ps3cli, the app |
| the unit/spec app, or VSCode | interactive | the supervisor | — |

Three layers, each restarting exactly the one below it. NSSM's existing crash-restart settings
stay as the outermost backstop.

## 2. Where the code lives

**`common/supervisor/`, a package in MAST_common** — not a new repo. It must run on unit and
spec machines, both of which already have `<top>/common/` and the `mast.pth` that puts `<top>`
on `sys.path`; a new repo needs a clone, a `.pth` entry, CI and a provisioning entry, none of
which this plan could deliver. Every probe it needs is already in `common`.

```
common/supervisor/
  __main__.py     `python -m common.supervisor`  -> the interactive supervisor
  service.py      session-0 side: the NSSM application, owns the child watchdog  [Windows]
  session.py      the WTS / CreateProcessAsUser bridge, behind a replaceable API [Windows]
  supervisor.py   the phase machine
  resources.py    network / ramdisk+indexes / share probes
  probes.py       pwi4 / phd2 / ps3cli / app health callables — imports nothing from unit/
  managed.py      ManagedProcess: adopt-or-spawn, health loop, backoff, crash-loop cap
  launcher.py     build_launch(): the pure role+opmode -> LaunchSpec function
  locate.py       locate_vscode_exe(), locate_pwi4_exe()  — modelled on phd2_locate.py
  logsink.py      DequeHandler, rebind_daily_handler()
  gui_model.py    snapshots + the pure drain function — NO tkinter
  gui.py          the tkinter window                                            [tkinter]
common/config/supervisor.py
common/services/mast-service/install-mast-service.ps1
```

`__init__.py` holds a docstring and no imports; nothing elsewhere in `common` reaches into the
package. `win32*` lives only in `session.py`/`service.py`, `tkinter` only in `gui.py`, so the
Linux control host and the CI image import none of it.

Both processes are `python.exe`, which `find_process`'s image-name match cannot tell apart, so
each carries an explicit `--role` argument **and** a `Global\` named mutex — copy the shape of
`Filer._take_sweep_guard` ([filer.py:420-437](../../common/filer.py#L420)), which already
documents the session-0/session-1 scoping and `SeCreateGlobalPrivilege`.

## 3. The service

`common/services/mast-service/install-mast-service.ps1`, replacing
[unit/service/mast-service.ps1](../../unit/service/mast-service.ps1). Runs
`python.exe -m common.supervisor.service`, `AppDirectory=<top>`, keeping the existing
AppStdout/AppStderr rotation, `AppRestartDelay 5000` and the `sc.exe failure` triple.

**As LocalSystem — `ObjectName` omitted.** `WTSQueryUserToken` needs `SE_TCB_NAME` and
`CreateProcessAsUser` needs `SE_ASSIGNPRIMARYTOKEN_NAME`; LocalSystem holds both. Granting
`SeTcbPrivilege` to `.\mast` is security-equivalent with more moving parts. This also deletes
the installer's interactive password prompt, which is why it cannot run from provisioning
today. `unit/CLAUDE.md:45`'s `Path.home()` → `systemprofile` warning becomes obsolete in the
same change: the app now runs under the interactive `mast` token.

`$Top = Split-Path (Split-Path $PSScriptRoot)` rather than a hardcoded path — the current
`C:\Users\mast\PycharmProjects\MAST_unit.2024-12-12` is the actual bug in that file.

**The installer removes `mast-unit`.** Two services would mean two uvicorns on one port and two
owners of PWI4.

## 4. The session bridge

```
sid   = WTSGetActiveConsoleSessionId()      # 0xFFFFFFFF or 0 -> no interactive session
token = WTSQueryUserToken(sid)              # ERROR_NO_TOKEN  -> nobody logged on
dup   = DuplicateTokenEx(token, ..., TokenPrimary)
env   = CreateEnvironmentBlock(dup, bInherit=False)
si.lpDesktop = r"winsta0\default"
CreateProcessAsUser(dup, python, cmdline,
                    CREATE_NEW_CONSOLE | CREATE_UNICODE_ENVIRONMENT | CREATE_SUSPENDED, ...)
AssignProcessToJobObject(job, hProcess); ResumeThread(hThread)
```

Three silent failures, each worth a test:

- **`lpDesktop = r"winsta0\default"` is mandatory.** Without it the child starts on the
  service's invisible window station: the process runs, the window never appears, nothing
  errors. The single most likely thing to get wrong.
- **`CREATE_UNICODE_ENVIRONMENT` is mandatory** with a `CreateEnvironmentBlock` result.
- Hold `hProcess` — it is both the teardown handle and the death detector.

No interactive session is **not** an error: log once per state change, back off
(`_Backoff(1.0, cap 60.0)`, copied from [config/_watcher.py:57-62](../../common/config/_watcher.py#L57)),
retry. The watchdog is the same wait: `WaitForSingleObject(hProcess, 1000)` in a loop, so a
logoff/logon cycle needs no special case.

**Teardown is two mechanisms.** A named event `Global\mast-supervisor-stop` with an explicit
DACL (the service is LocalSystem, the supervisor is `mast`) for the graceful path; and a job
object with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_BREAKAWAY_OK` as the
backstop, so a `TerminateProcess` on the service cannot orphan the supervisor. The supervisor
spawns PWI4/PHD2/ps3cli/the app with `CREATE_BREAKAWAY_FROM_JOB`, so a hard service kill — and,
deliberately, a restart-to-apply (§7) — removes the supervisor and **leaves the telescope
applications running** — tearing those down
in order is the graceful path's job, not the kernel's.

**The service never probes `Z:` or `D:`, never builds a `Filer`, and never calls
`configure_logging()`.** Mapped drives are per-logon-session
(`claude/memory/reference_fleet_topology.md:21`), so session 0's answers are meaningless. It
logs to `C:\MAST\Logs\mast-service\` and stays off the share entirely. Every resource probe
lives in the supervisor, in the session the app will actually run in.

## 5. Phases and resources

```
STARTING → WAITING_FOR_RESOURCES → LOADING_CONFIG → SUPERVISING → LAUNCHING_APP → RUNNING
                                                                                → DEGRADED
```

| resource | probe | "available" means |
|---|---|---|
| network | `gethostbyname(controller_host.domain)`, then `create_connection((fqdn, mongo_port), 2s)` | both succeed |
| RAM disk + indexes | `is_windows_drive_mapped("D:")` → `is_accessible(index_dir, 2.0)` → every `index-5206-{00..46}.fits` present **and non-empty** | drive mapped, dir present; missing indexes are **amber, not fatal** |
| mast-share | `Filer().ensure_shared_root()` ([filer.py:143-181](../../common/filer.py#L143)) | it returns True |

Reuse the existing probes; do not write new ones. `is_accessible`
([filer.py:40-54](../../common/filer.py#L40)) runs `os.path.isdir` on a daemon thread with a
join timeout, which is the only thing standing between the supervisor and a hung SMB mount.

The network probe is defined as "can reach the config DB" deliberately, so a passing probe
followed by a failing `Config()` is impossible by construction. **Reject ICMP** — `pythonping`
is installed but unlisted and unused, and raw ICMP needs administrator, which the supervisor is
not. Say so in the module docstring so it is not re-litigated.

The index check is the one the solver has commented out. Move it here — it is a resource
precondition, not a solver concern — and delete `mastrometry.py:79-95` rather than reviving it.
A zero-length file is what a half-finished copy leaves behind, and `exists()` is happy with it.

**No resource is hard-required.** Each has a wait budget (default 300 s); when it expires the
supervisor proceeds degraded and keeps probing — *decided*. `Config` has a boot cache, `Filer`
falls back to `C:/MAST/`, and a unit with no indexes can still point, expose and guide. One
missing mount must not cost a whole night. The GUI shows amber; the night happens.

Config load: `Config()` failures are logged and retried on backoff, never fatal.
`Config().degraded` is acceptable and shown verbatim. `machine_role == "control"` refuses
loudly and idles — that host is Linux and will never run this.

## 6. Process supervision

**Write `common/supervisor/managed.py`; do not fix `WatchedProcess`.** Its only caller passes
`no_restart=True`, so the watcher, `restart_event` and `reconnect()` are already dead code; its
kill-first at [process.py:230-232](../../common/process.py#L230) is exactly what must go; it has
no health concept, only liveness; and its two real bugs (`stream.read_line`, and logging via the
module logger) prove the path has never run.

**Adopt, never kill.** If a matching process already exists, record its pid and supervise it.
Killing a PWI4 holding a connected, tracking mount because a supervisor restarted is
destructive — and adoption is what makes the staged rollout in §11 safe. `find_process` has no
owner/session filter, so add `find_processes(..., session_id=)` and `process_session_id()` to
`common/process.py`; adopt only same-session matches, and kill a different-session orphan
**once**, at startup.

Spawn with an argv **list** and `shell=False` — `process.py`'s `cmd.split()` is broken for
`C:\Program Files (x86)\…`, which is the whole reason the current code passes `shell=True` and
quotes by hand. No `CREATE_NO_WINDOW`: PWI4 and PHD2 are GUI applications.

| process | health probe | interval |
|---|---|---|
| PWI4 | `GET 127.0.0.1:8220/status`; parse `key=value`; assert it answered, `pwi4.version >= MINIMUM_PWI4_VERSION`, and `mirrorcover.overall_state_name` present | 10 s |
| PHD2 | TCP `127.0.0.1:4400`, one `get_app_state` JSON-RPC line, assert a known state | 15 s |
| ps3cli | TCP connect `127.0.0.1:8998`, close | 30 s |
| app | `GET /mast/api/v1/<role>/status` → 200 with a `value` key | 15 s |

**Do not call `pwi4_client.PWI4().status()`** — `PWI4Status.__init__` does
`self.raw["pwi4.version"]` unguarded ([pwi4_client.py:464](../../unit/src/PlaneWave/pwi4_client.py#L464)),
so anything else answering 200 on 8220 raises `KeyError` and kills the probe thread. The three
assertions above are `covers.pwi4_is_viable()` re-expressed without the client; move
`MINIMUM_PWI4_VERSION` into `common/const.py` and have `covers.py` import it from there.
Likewise do not import `unit.phd2` — a 30-line one-shot JSON-RPC in `probes.py`, socket closed
each time.

Failure handling: `unhealthy_threshold` (3) consecutive failures → terminate, grace, kill,
respawn; `_Backoff(5.0, cap 120.0)` between restarts; more than 5 restarts in 600 s →
`CRASH_LOOPED`, stop, red on the GUI, one ERROR naming the last exit code, and a "retry now"
button. A PWI4 that exits immediately because the mount is unplugged must not be restarted
eight thousand times a night.

**A PHD2 restart does not restart the app** — *decided*. The supervisor restarts PHD2 and
reports it; the app will keep reporting a dead guider healthy until MAST_unit clears
`_connected` on socket loss and revives `reconnect()`. That fix is therefore a **prerequisite,
not a follow-up** (§12), because until it lands a PHD2 restart leaves the unit silently wrong.

Which processes run is config-driven, not role-hardcoded: defaulted to pwi4/phd2/ps3cli in
`units.common` and `{}` in `specs`.

## 7. The GUI

The Tk mainloop owns the main thread; workers start first. `--no-gui` blocks on a stop event
instead, and a `TclError` falls back to headless with a log line. **The supervisor must never
die because its window could not open.**

One `ttk` window, min 900×600.

**Menu bar: Actions | About | Help.** `About` gives version, `<top>`, hostname, role, config
generation and a copy-diagnostics button; `Help` points at `docs/supervision.md` and the log
folder.

**Header labels**, the two an operator acts on given their own line and large type:

```
In maintenance:  false
Opmode:          controlled
```

plus hostname · role · phase · uptime · `opstate` · config generation, with `Config().degraded_reason`
verbatim when present.

Then a resources table; a processes table with per-row restart buttons; and a rolling log pane
filling the rest — `ScrolledText`, monospace, per-level colour tags, a level filter, and an
autoscroll toggle that pins to the tail so an operator can scroll back without fighting it.

**No Quit button.** The supervisor's lifetime belongs to the service; intercept
`WM_DELETE_WINDOW` and iconify, logging how to actually stop it.

Logging crosses threads on a bounded deque:

```python
class DequeHandler(logging.Handler):        # logging.Handler — NEVER logging.StreamHandler
    def emit(self, record):
        self.records.append((record.levelno, self.format(record)))   # format on the producer
```

`root.after(100, drain)` pops at most 200 per tick so a log storm cannot freeze the UI, trims
the widget to 2000 lines, and re-arms. `deque.append`/`popleft` are atomic under the GIL, so no
lock — with the precedents (`notifications.py:154`, `stopping.py:42`) named in the docstring.

**The `StreamHandler` trap:** `init_log` adds its Rich console handler only
`if not [h for h in handlers if isinstance(h, logging.StreamHandler)]`
([mast_logging.py:345](../../common/mast_logging.py#L345)). A `DequeHandler` subclassing
`StreamHandler` would silently suppress the console for the whole process. Subclass bare
`logging.Handler`, and make it a one-line test. Do not fix the `isinstance` check here — that
module reaches every consumer on the machine; file it separately.

Three rules in the module docstring: no worker thread touches a widget; everything crosses on
the deque or on snapshots published by whole-reference assignment; tables are redrawn from a
snapshot, never from live state.

### The Actions menu — the two operator verbs

```
Actions ─ Maintenance mode ─ activate / deactivate
        └ Opmode           ─ automatic / controlled
```

Each item opens a **confirmation modal naming the exact effect**, in the operator's terms, before
anything is written:

> *Put mast07 into maintenance?*
> mast07 will be added to site `ns`'s maintenance list in the configuration database. The
> controller will stop allocating plans to this unit. **Nothing on this machine stops** — PWI4,
> PHD2 and the unit app keep running. The supervisor will then restart (about 10 seconds).

> *Change opmode to `automatic`?*
> mast07's `opmode` becomes `automatic` in the configuration database. The supervisor will
> restart and open VSCode on `mast-unit.code-workspace` instead of running the unit app. **The
> running unit app will be stopped.**

Both actions are **write, then restart the supervisor** — *decided*. Not "tell the running
supervisor to stop and start the app": the startup path already computes what a mode means
(read config → resolve `opmode` → decide launcher → launch), so re-running it is the transition,
and there is one implementation of that decision rather than two that drift. It converges rather
than transitions, so a half-applied state — new opmode, stale process table — is unreachable.
And it needs no new IPC or new code path at all: the supervisor exits with a distinguished code
and the service's `WaitForSingleObject` watchdog (§4) respawns it against the current session —
the same path every crash recovery uses, and therefore the best-exercised one in the design.

**Two shutdown flavours, and the distinction is load-bearing.**

| | stops PWI4 / PHD2 / ps3cli | stops the app |
|---|---|---|
| service stopping (`Global\mast-supervisor-stop`) | yes, in order | yes |
| restart-to-apply (menu action) | **no — left running, re-adopted on the way back up** | only if the new mode requires it |

Adoption (§6) is what makes restart-to-apply cheap: the supervisor re-adopts the PWI4 it left
behind instead of killing and respawning it, and `CREATE_BREAKAWAY_FROM_JOB` keeps the job
object from taking them down with it. Without that property "just restart the supervisor" would
bounce the mount software to change a label, and the whole idiom would be wrong. The exit code
carries which flavour it is; nothing else needs to know.

Restart-to-apply is the idiom for changes that alter **what the supervisor launches**. It is not
for everything: a probe interval or a log level is read live or picked up at the next restart —
bouncing the stack to change a number would be absurd, and would teach operators to fear the
menu.

**Maintenance mode needs a config write path that does not exist.**
[`ConfigSource.write_unit_delta`](../../common/config/_source.py#L118) is the *only* write in the
config layer and it is `units`-only; there is no `set_site`, no `update_site`, and nothing ever
writes the `sites` collection. Add a sibling — and make it an atomic `$addToSet` / `$pull` on
`units_in_maintenance`, **not** a read-modify-write of the whole list, or two operators toggling
two units at once will silently drop one. Mirror `set_unit`'s degraded refusal
(`config/__init__.py:787-793`): while `Config().degraded` both menu items are disabled with a
tooltip saying why, because a write that cannot reach Mongo must not look like it worked.

Apply `Site.normalize_unit_specifier` ([config/site.py:79](../../common/config/site.py#L79)) to
the name before writing, so the entry matches what `common/parsers.py:95` compares against.

**Opmode writes through `set_unit`**, which persists only the delta from `units.common`
(`config/__init__.py:814-827`) — so setting a unit to `controlled` is exactly a one-key delta.
Note the corollary: setting a unit *back* to the value `units.common` already holds writes
nothing and the unit inherits it again, which is correct but means the DB will not always show
an explicit per-unit value. The label reads the effective value from `resolve_opmode()`, so it
is right either way.

**Two things these writes bypass, both worth stating in the modal or the docs.** They do not go
through `UserCapabilities` — the supervisor has no logged-in user and no capability check, so
anyone at the physical machine can make them; that is a deliberate consequence of it being a
console at the telescope. And **activating maintenance changes nothing on this machine today**:
`units_in_maintenance` has exactly two readers, both in
[common/parsers.py:95-109](../../common/parsers.py#L95), which skip the unit when parsing a plan's
unit specifier. The unit itself has never known it is in maintenance. Surfacing it here is the
first time it is visible where the hardware is — and if it should also stand the unit down, that
is a behaviour change to specify, not one to assume.

### The heartbeat — periodic state, to the window and the file

Every `heartbeat_interval_seconds` (default **300**) the supervisor logs its own state and every
monitored resource and process. This is not decoration: §5 says transitions log once rather than
per poll, which means a quiet log is ambiguous — "nothing changed" and "the supervisor died at
21:00" look identical. **The heartbeat is the only thing that distinguishes them**, and it is
what someone reads the morning after to answer "why did unit 7 not observe" without opening
anything else.

One `logger.info()` call reaches both destinations, because the window's `DequeHandler` and the
`DailyFileHandler` are both on the root logger. No second plumbing.

**One record, not ten.** Emit a single multi-line message so the formatter prefixes it once and
the block stays together; `boxed_info` (`common/utils.py`) is the existing house idiom for
exactly this and app.py already uses it for its startup banner.

```
supervisor heartbeat  up 4:12:06  phase=RUNNING
  role=unit  opmode=controlled  opstate=running  maintenance=false  config gen=418
  resources  network=ok  ramdisk=ok (47 indexes)  share=ok
  processes  pwi4=healthy pid=5120 r=0    phd2=healthy pid=7332 r=1
             ps3cli=healthy pid=8044 r=0  app=healthy pid=9160 r=0
```

**ASCII only** — no box drawing, no arrows, no degree signs. `common/CLAUDE.md` records that the
daily file's consumers are not the console's: a U+2033 in a log message was silently dropped
from the file on mast00 while the console showed it (MAST_common#63). A heartbeat is precisely
the record that must survive to the morning.

**The level tracks the worst thing in it** — INFO when everything is green, WARNING when any
resource is degraded or a process unhealthy, ERROR when anything is `CRASH_LOOPED`. That makes
`grep ERROR` over a night's file find the bad nights, which a fixed-INFO heartbeat cannot.

**Emit one immediately on entering each phase**, then on the interval, so the log carries a state
block right after startup rather than up to five minutes later.

Run it from the existing supervisor loop as another due-timestamp, not a new thread — that loop
already holds the data and publishes the snapshots. (`RepeatTimer`, `common/utils.py:31-60`, is
the fleet's periodic idiom and would also work; one fewer thread wins.) Render from a published
snapshot, never from live state, for the same reason the tables do.

At 300 s this is 288 records a night — a few thousand lines in the daily file, which the existing
Cygwin logrotate already handles.

## 8. Launching the app

`<top> = Path(common.__file__).resolve().parents[1]` — the same derivation `mast.pth` uses, and
the one that cannot go stale. Interpreter is `sys.executable` (the supervisor is already
launched with the venv python). **Do not set `PYTHONPATH`**; `mast.pth` already does it.

| role | entry | cwd |
|---|---|---|
| unit | `<top>/unit/src/app.py` | `<top>/unit/src` |
| spec | `<top>/spec/src/app.py` | `<top>/spec/src` |

The `cwd` is mandatory: `app.py`'s `from unit import Unit` needs `src/` as the import root.

Environment starts from `os.environ` — which in the supervisor *is* the interactive session's
block, already carrying `PS3CLI_DIR`, `PS3CLI_CATALOG`, `PHD2_EXE` and the user's `PATH`. Then
`PYTHONUNBUFFERED=1`, and **delete `http_proxy`/`https_proxy`** — that deletion currently lives
in `start_supporting_processes()` ([app.py:57-60](../../unit/src/app.py#L57)) and must not be
lost with it. `MAST_OPMODE` is passed through **only if the supervisor's own environment had
it**; never inject the resolved DB value, or a DB value would masquerade as an env override and
invert the opmode plan's precedence.

**`opmode` — one field, two readers** (*decided*):

- **`controlled`** → the supervisor launches the app, which comes up in standby awaiting the
  control machine. Restart on process exit or on the status endpoint not answering — **never**
  because `operational` is false; that is health, and the opmode plan puts health in
  `operational`/`why_not_operational`.
- **`automatic`** → the supervisor launches **VSCode** on `<top>/mast-<role>.code-workspace`
  (which already exists on this machine) and does not supervise it: `Code.exe` forks and exits,
  and an operator legitimately closes the editor. The row reads `launched (not supervised)` with
  a relaunch button. The app is started by the developer pressing F5; the supervisor still runs
  the status probe read-only so the GUI shows the app once it appears.
- **`tested`** → CI only; the supervisor is not involved.

`build_launch(role, opmode, top, conf, env) -> LaunchSpec` is a pure function. That is what
makes all of §8 unit-testable.

## 9. Changes to MAST_unit

1. **Delete `start_supporting_processes()`** ([app.py:44-108](../../unit/src/app.py#L44)) and
   its call at `:294`.
2. **Remove the phd2.exe spawn from `PHD2Connector.__init__`**
   ([phd2.py:376-399](../../unit/src/phd2/phd2.py#L376)) — the `WatchedProcess`, the
   `time.sleep(3)`, and `phd2_locate.py`. Replace the fixed sleep with a bounded readiness wait.
3. **Clear `_connected` on socket loss and revive `reconnect()`** — promoted to a prerequisite
   by §6's decision.
4. `MINIMUM_PWI4_VERSION` moves to `common/const.py`.
5. Delete `unit/service/`, `common/services/mast-unit/`.

**Tests that break, all named:** `test_phd2_init_reports_its_cause.py:86-94` and `:139-144`;
`test_limit_frame_guiding.py:61`. The process-launch guards in both conftests **stay** — their
rationale ("app.py calls `ensure_process_is_running` at module level") is what changes.

**Docs that go stale:** `unit/CLAUDE.md:45` (LocalSystem/`Path.home()`), `unit/README.md:27`,
and `unit/DECISIONS.md:1246` ("ps3cli health is a startup-time probe, not a supervised
process"), which this supersedes and whose new entry must say so.

**The developer path** — *decided*: `python -m common.supervisor --gui --no-service --no-app`
is the supported dev entry point, giving production topology minus the service; the developer
then runs `python app.py`. No fallback spawning in the app: two owners of a process makes "who
started this" unanswerable from a log. Pair it with self-explaining errors — *"PWI4 is not
answering on 127.0.0.1:8220 — is mast-service running? see docs/supervision.md"* — which is the
cheapest part of this migration and the part that pays back daily.

## 10. Configuration

New `common/config/supervisor.py`, added as `supervisor: SupervisorConfig = SupervisorConfig()`
to `UnitConfig` and `SpecsConfig`. **Every field defaulted** — `get_unit()` merges
`units.common` with the per-unit doc, and a required field absent from `common` raises for every
unit in the fleet at once.

Sections: `processes: dict[str, ManagedProcessConfig]` (enabled, exe, args, port, intervals,
thresholds, crash-loop window), `resources` (wait budget, probe intervals, `index_dir`,
`index_series`, `index_count`), `app` (package_dir, entry, grace, restart), `vscode` (exe,
workspace), `gui` (buffer sizes, drain interval, level), `heartbeat_interval_seconds` (300),
`stop_grace_seconds`. Observe
`common/CLAUDE.md:216` — one `json_schema_extra` entry per line, tooltips never wrapped.

Ports `8220`/`4400`/`8998` move to `common/const.py` and the supervisor config defaults to them;
rewiring `pwi4_client`/`phd2`/`ps3cli_client` to import them is a **follow-up**, not this change
— making them configurable in the supervisor alone would let the supervisor and the app disagree
about where PHD2 is, which is worse than a constant.

Nothing new in `C:\WIS\config.toml`. Resist adding a `MAST_TOP` env var.

## 11. Verification

The architectural rule that makes a GUI + service + supervision program testable: **every phase
is a pure function of injected probes, an injected clock and a snapshot.** No module reaches for
`Config()`, `Filer()`, `win32*` or `tkinter` at import time.

New files in `common/tests/`, house style (subclassed fakes, `object.__new__(Config)`, no Mongo,
no hardware): `test_supervisor_resources.py` (all up → ready; one down → waiting, then degraded
after the budget, **and it proceeds**; a raising probe is "down" and never propagates;
transitions log once, not per poll), `test_supervisor_index_check.py` (`tmp_path` with 47 files;
one missing; one zero-length), `test_supervisor_managed_process.py` (**the critical one**: a
same-session match → zero spawns *and zero kills*; another-session match → killed once then
spawn; threshold → exactly one restart; backoff caps; crash-loop stops),
`test_supervisor_probes.py` (a `TCPServer`/`http.server` on an ephemeral port — not an external
process, so the conftest guard does not fire; PWI4 **unhealthy on a 200 that is not PWI4**),
`test_supervisor_logsink.py` (bounded; formats in `emit`; `assert not
isinstance(DequeHandler(), logging.StreamHandler)`), `test_supervisor_gui_model.py` (the drain
against a `FakeText` — zero tkinter, runs on Linux CI),
`test_supervisor_launch_plan.py` (`build_launch` per role × opmode; no `http_proxy`;
`MAST_OPMODE` only when inherited), `test_supervisor_session_bridge.py` (faked `Win32SessionApi`:
no console session → no spawn; `ERROR_NO_TOKEN` → no spawn; happy path asserts
`lpDesktop == r"winsta0\default"` **and** `CREATE_UNICODE_ENVIRONMENT` — those two assertions are
the point of the file), `test_supervisor_child_watchdog.py`.

`test_supervisor_heartbeat.py` renders a heartbeat from a fixed snapshot: the block is one
logging record and not ten; it is pure ASCII (`text.isascii()` — the MAST_common#63 guard);
the level is INFO when all green, WARNING with a degraded resource, ERROR with a crash-looped
process; and a phase change emits one immediately rather than waiting for the interval.

`test_supervisor_actions.py` covers the two operator verbs against a fake config source: activate
→ exactly one `$addToSet` with the normalized name and no read-modify-write; deactivate → one
`$pull`; both refuse while `degraded` and neither writes; an opmode change writes the one-key
delta; and each returns the restart request rather than calling `sys.exit` itself, so the
decision is testable apart from the exit.

Add `win32process.CreateProcess`/`CreateProcessAsUser` to the denied set in both conftests — the
guard has a second door now.

**Manual acceptance on mast00** (nothing above covers these): `sc start mast-service` → a window
appears in the interactive session within 30 s; `sc stop` → it goes, with no orphan;
`taskkill /f` the service → the supervisor dies with it (the job object); log off and back on →
it reappears in the new session; kill PWI4 by hand → back within ~15 s and the GUI says so;
reboot → everything comes up with no keystroke.

## 12. Prerequisites — both blocking

**Autologon does not exist.** I checked mast00: `AutoAdminLogon` is unset, no `DefaultUserName`,
no `DefaultPassword`; the current `mast` console session was logged on by hand at 10:21. The
entire design assumes an interactive session on every unit — **without it the supervisor never
starts and the machine is worse off than today.** Who owns configuring it (presumably
MAST_provisioning, which is a sparse checkout here) is unresolved. Recommend Sysinternals
`Autologon.exe`, which stores the password as an LSA secret rather than plaintext in
`HKLM\…\Winlogon\DefaultPassword`. Screen lock and screensaver must also be disabled by policy,
or the GUI exists where nobody can see it.

**The PHD2 `_connected` fix** (§9.3), promoted from follow-up to prerequisite by the decision
that a PHD2 restart must not restart the app.

## 13. Changing `opmode` while running

**Through the supervisor's own Actions menu: write the DB, then restart** (§7) — *decided*.

**Changed elsewhere — by the GUI, by the control machine, by hand in Mongo — the supervisor
reports and does not act.** It registers a `Config` change callback on `units`, and when the
effective `opmode` no longer matches the one it launched under, the header label shows both
(`Opmode: controlled (DB now says automatic)`) and the Actions menu gains an **Apply** item that
performs the same restart. The reasoning is the one the menu's confirmation modal makes
explicit: switching `controlled`→`automatic` stops a running unit app, possibly mid-exposure.
That is a physical event, and a physical event should not be the silent consequence of someone
saving a form in a browser. An operator — or the same person, a second later, clicking Apply —
decides when.

The cost is that a remote `opmode` change does not take effect remotely. That is the intended
trade, and it is consistent with the rest of the design: the supervisor is a console at the
telescope, not a remote-control surface.

## 14. What this does NOT do

- **No control-machine logic.** The supervisor runs the machine it is on; the `startup`/
  `shutdown`/`powerdown` orchestration across the fleet is the opmode plan's supervisor loop,
  and still unbuilt.
- **No enclosure, AC or power switching.**
- **Does not make PWI4 stateful-recoverable.** After a PWI4 restart the mount connection is
  lost; reconnecting runs `mount_enable()` and is a hardware verb owned by the unit's lifecycle,
  not by a supervisor. It is reported, not acted on.
- **Does not mount the ImDisk or copy the indexes.** Nothing in either repo does; that stays
  with provisioning. The supervisor only checks and reports.

## 15. Staging

| stage | repo | contents |
|---|---|---|
| 0 | common | `common/opmode.py` (the merged opmode plan, stage 1) — prerequisite |
| 1 | common | `config/supervisor.py`; `const.py` ports + `MINIMUM_PWI4_VERSION`; `find_processes`/`process_session_id`; `init_log` gains `file_leaf`; **a `sites` write path** (`$addToSet`/`$pull` on `units_in_maintenance`) beside `write_unit_delta` |
| 2 | common | resources, probes, managed, launcher, locate, logsink, gui_model + every test. `--dry-run` prints the resolved plan and exits |
| 3 | common | gui (incl. the Actions menu and its modals), supervisor, `__main__`. **Run a night on mast00** as `--gui --no-service --no-app`, supervising PWI4/PHD2/ps3cli while `mast-unit` still runs the app — adoption is what makes two owners safe, and this is the highest-value de-risking step |
| 4 | prov. | autologon; nssm at a managed path; write `<top>/mast-<role>.code-workspace` |
| 5 | common | session, service, installer. Install on mast00 with `mast-unit` stopped but installed — rollback is `sc stop mast-service; sc start mast-unit` |
| 6 | unit | the §9 deletions and the PHD2 fix; **only now is `mast-unit` removed** |
| 7 | spec | mirror stage 6 |
| 8 | common | delete `WatchedProcess`, `log_stream`, `kill_process_by_name`, and (after a cross-repo grep) `ensure_process_is_running` |

`init_log` gaining `file_leaf` in stage 1 is the fix for the log collision: without it the
supervisor would write `mast-unit-log.txt`, the same file the app appends to, from a second
process over SMB, with no PID in the format to tell them apart.

## Provenance

Written 2026-09-16 against MAST_common `master` @ `5dfd263` and the MAST_unit clone beside it.
Requirement stated by Arie in session, in two rounds — the supervision chain first, then the
window's menu bar, labels and the two operator verbs. Ten decisions ratified: one `opmode` field
with two readers; the supervisor owns PWI4, PHD2 and ps3cli and `mast-unit` is replaced by
`mast-service`; `CreateProcessAsUser` from a LocalSystem service; a separate
`mast-supervisor-log.txt`; resources degrade-and-proceed rather than block; a PHD2 restart
reports rather than restarting the app; the supervisor is the developer entry point; no fallback
spawning in `app.py`; the Actions menu writes the DB and restarts the supervisor behind a
confirmation modal; an `opmode` changed elsewhere is reported with an Apply item rather than
acted on; and a five-minute heartbeat logs full state to both the window and the file, because
transition-only logging cannot distinguish a quiet night from a dead supervisor.

MAST_spec, MAST_control and MAST_provisioning could not be consulted — provisioning is a sparse
checkout here (top-level files plus `tools/`), so `server/providers/mast/provide-mast.ps1`, the
script that installs the deployed service, was not readable. The supervision decision record
cited at `retire-pwshutter-and-ascom-covers.md:250`
(`docs/decisions/2026-08-12-one-nssm-service-supervises-an-interactive-monitor.md`) **does not
exist** — not on disk and not in that repo's index. It is a dangling reference, and this plan is
the first written supervision design in MAST.
