# Code validation and CI — MAST guidelines

Cross-repo standards for linting, testing and continuous integration. Derived from the
work done on `MAST_common` and `MAST_unit` on 2026-08-09; **`MAST_spec`, `MAST_control`
and `MAST_gui` have none of this yet** and should follow it when they get it.

Everything here is written down because it was learned the expensive way. Where a rule
exists because something actually broke, the incident is named — those notes are the
reason the rule is worth keeping, and deleting them makes the rule look arbitrary.

---

## 1. The platform matrix

The fleet spans two production platforms, and a repo must be tested on the ones it
actually runs on:

| repo | platform(s) | CI runner(s) |
|---|---|---|
| `MAST_common` | **both** — imported by every service | `windows-latest` **and** `ubuntu-latest` |
| `MAST_unit` | Windows | `windows-latest` |
| `MAST_spec` | Windows | `windows-latest` |
| `MAST_control` | Linux | `ubuntu-latest` |
| `MAST_gui` | Linux | `ubuntu-latest` |

**Darwin is a development platform only.** `tests/conftest.py` in `MAST_common` and
`MAST_unit` shims `Filer` for it because `Filer.__init__` supports Windows and Linux
only. Do not build it in CI.

`MAST_common` is matrixed with `fail-fast: false`. A break on one platform only is
exactly what the matrix exists to catch, and cancelling the sibling job hides half the
answer.

Python is pinned to **3.12**, matching `target-version = "py312"` in `ruff.toml`. Keep
the two in step.

---

## 2. CI structure

Two jobs, never one.

```
jobs:
  test:   # matrix per the table above — blocking
  lint:   # ubuntu-latest, once — blocking
```

**Why separate:** if lint failures fail the test job, a red lint hides whether the suite
passed — and on `MAST_common` it hides *which platform* passed. The two answer different
questions and must be readable independently.

**Lint runs on Linux regardless of the repo's platform.** Ruff never imports the code, so
it needs neither Windows nor the dependency install — only `requirements-dev.txt`, which
pins the ruff version so CI and every workstation agree on what counts as a finding.

**`ruff format --check` runs before `ruff check`.** The format half is a single
`ruff format .` away; surfacing it first stops the cheap debt hiding behind the expensive
debt.

Add `concurrency: { group: ci-${{ github.ref }}, cancel-in-progress: true }` so a new
push supersedes an in-flight run.

### Lint is blocking

Both `ruff check` and `ruff format --check` fail the build. This was a deliberate
decision: an advisory step nobody reads is not a guardrail. Expect a repo to start red
and burn the debt down (§5).

### Branch protection

Still **off** in `MAST_common` and `MAST_unit` as of 2026-08-09, so a red PR can be
merged. Turn it on per repo once its workflow has proved green; a blocking job that
nothing requires is only a suggestion.

---

## 3. Making a repo installable by CI

Two problems block a naive `pytest` in CI, and both are silent.

### 3.1 There may be no way to install the repo

`MAST_common`'s `requirements-dev.txt` carries only `pytest` and `ruff`, and says —
correctly — that runtime dependencies come from each consuming project. That leaves CI
with nothing to install.

Fix: a **`requirements-ci.txt`** listing what is needed to *import and test the repo
standing alone*. It is explicitly **not** a runtime manifest.

- Pin to the versions the fleet is running, so a red build means *this repo* changed
  rather than a transitive dependency having moved.
- Use environment markers for platform-specific packages rather than a second file:
  ```
  pywin32==312; sys_platform == "win32"
  ```
  (`common/ascom.py` imports `pywintypes` and `win32com.client` unguarded, so it is
  Windows-only by construction.)

`MAST_unit` needed none of this: its `requirements.txt` already pins everything the
`common` import chain needs. Check before adding a file.

### 3.2 A green run can mean nothing

Test modules open with `pytest.importorskip(...)` so a developer missing a dependency
gets skips rather than a wall of collection errors. On CI that same behaviour is a trap:

> With nothing installed, **190 of `MAST_common`'s 201 tests skipped and the run
> reported SUCCESS**, having exercised 11.

Fix, both halves required:

1. **`tests/test_imports.py`** — imports the same modules **without** a guard, so an
   incomplete environment fails loudly. It must stay in step with the guards: a new
   module opening with `importorskip("common.x")` needs `common.x` added there.
2. **`pytest -ra`** — surfaces any skip that does occur, so an unexpected one is visible
   rather than silent.

---

## 4. Tests must not touch the real world

**The fleet runs its test suites on the machines that run the telescope.** A test that
starts a process does not pollute a sandbox; it starts PWI4, the shutter or the plate
solver against real hardware.

This is not hypothetical. `MAST_unit/src/app.py` calls `ensure_process_is_running` at
**module level** — its `if __name__ == "__main__"` is far below — so simply importing it
launches PWI4, PWShutter and ps3cli. Importing it during a lint clean-up did exactly that
on `mast00`, a live unit.

Every repo's `tests/conftest.py` must install a guard:

- **Replace the spawn entry points with functions that raise.** Nothing is started and
  then killed — no process is ever created. Cover `subprocess` (`Popen`, `run`, `call`,
  `check_call`, `check_output`), `os` (`system`, `popen`, `startfile`, `exec*`, `spawn*`)
  and `psutil.Popen`.
- **Block wholesale, not at the funnel.** Patching `common.process.ensure_process_is_running`
  alone would be slipped past by a direct `subprocess.Popen`.
- **Install it at conftest IMPORT time, not from a fixture.** Fixtures — even autouse
  session ones — first run with the first test, which is *after* collection, and
  collection imports every test module. A module importing an entry point at top level
  would spawn before any fixture could stop it.
- **Test the guard.** `tests/test_no_process_launch.py` captures `subprocess.Popen` while
  its own module is being imported and asserts it is already the guard — that is what
  pins the collection-time ordering. A tripwire nobody tests quietly stops working.
- Make the error name the call and the target, so whoever trips it can see what tried to
  start what.

If a test genuinely needs a subprocess, allow it explicitly in `conftest.py` rather than
removing the guard.

Note the scope honestly: on a CI runner these programs are not installed, so a spawn
would fail there anyway — just slowly and confusingly. **The case this exists for is the
fleet's own machines.**

The guard is a tripwire, not the fix. The fix is for entry points to start nothing on
import.

---

## 5. Burning down lint debt

A repo adopting blocking lint will start red. Work through it in stages, **each its own
commit** (this is already the convention stated in `ruff.toml`: mechanical fixes land
separately so real changes stay readable).

**Stage 1 — the formatter.** `ruff format .`. No behaviour change.

**Stage 2 — safe autofixes.** `ruff check --fix .`, then `ruff format .` again to absorb
the reflow. **Never `--unsafe-fixes` without reading each one.**

**Stage 3 — the judgement calls.** One rule at a time, with a policy (see §6).

### Verifying a stage

- **Compare lint counts against a real baseline.** Beware: copying files to a temp
  directory to lint "before" gives the wrong answer, because ruff resolves `ruff.toml`
  from the file's ancestors and the copy has none. Lint the HEAD content *inside the
  project tree* (`git show HEAD:x.py > src/_base_x.py`) or the numbers are meaningless.
- **Run the suite before and after.**
- **`ruff check --select F821`** is the safety net for narrowing an `except` clause or
  removing an import: a name used without a binding is exactly what a wrong narrowing
  produces. Run it on *every* repo touched, after committing.
- **Mutation-check new tests.** Reintroduce the bug and confirm the tests fail. A test
  that passes against both implementations is not a test.
- **Inspect every semantic-looking change** rather than trusting the rule name.
  `SIM117` collapsing nested `with` statements, for instance, must not reorder lock
  acquisition.

### The CRLF trap

`ruff format --check` on a CRLF working tree reports far more files than CI will see,
because `.gitattributes` (`* text=auto eol=lf`) normalises on checkout. Measure the real
number on LF-normalised copies. On `MAST_unit` the working tree said 44 files; CI saw 9.

---

## 6. Rule policies

### `BLE001` — blind `except Exception`

Three-way split, applied per site. **Never blanket-`noqa` the rule.**

1. **Narrow** where the raising surface is knowable:
   - file I/O → `OSError`; `shutil.move` → `(OSError, shutil.Error)`
   - a single httpx call → `httpx.HTTPError`
   - `json.loads` → `json.JSONDecodeError`
   - `response.json()` + a Pydantic model → **`ValueError`** (both `JSONDecodeError`
     and Pydantic's `ValidationError` derive from it)
   - `[x for x in xs if ...][0]` → `IndexError`
2. **`logger.exception(...)`** where the catch must stay broad but is discarding the
   traceback. Ruff exempts a blind catch whose handler calls `logging.exception`, so this
   clears the finding, changes no control flow, and restores the diagnostics. **This is
   the default for any handler that already logs.**
3. **`# noqa: BLE001 -- <reason>`** where catching everything is the design and
   `logger.exception` is unavailable (e.g. the handler records into an error list):
   vendor SDK boundaries (ZWO, Standa ximc, ASCOM/COM are ctypes and COM wrappers raising
   undocumented types), `exec()` of a profile file, a logging handler that must not raise
   into its caller, a thread that must outlive one failed item, optional integrations, and
   `__main__` demo helpers. **Always give the reason.**

Follow-on: converting to `logger.exception` raises **`TRY401`** if the message still
interpolates the exception — the traceback already carries it, so strip it. Watch for
pre-existing `logger.exception(ex)` calls that pass the exception *as* the message; give
them a real one and `raise` bare (which also clears `TRY201`).

**Why this rule earns its keep:** `mastrometry.cleanup()` was called with two arguments
for three parameters, raising `TypeError` on every solve *inside a thread*, where the
default excepthook writes to stderr. It went unseen for months and cost 1.1 GB of leaked
scratch plus every plate-solved FITS.

**Bugs this pass surfaced:** `fswatcher.run()` had `except Exception` around
`while True: time.sleep(5)` — nothing there raises `Exception`, and `KeyboardInterrupt`
derives from `BaseException`, so the handler had **never once fired**; the observer was
never stopped. Expect to find more of these.

### Datetimes — `DTZ005`, `DTZ011`

Two rules, split by intent:

- **Timestamps** — anything recorded, named, or correlated with observations →
  `datetime.now(datetime.UTC)`. Aware, UTC, always.
- **Durations, timeouts, elapsed** → **`time.monotonic()`**, not a datetime at all.
  A naive difference is wrong regardless of timezone: it moves under NTP steps, DST
  transitions and manual clock sets. An observatory running NTP will eventually measure a
  negative exposure.

Specific traps found in `MAST_common`:

- `isoformat_zulu(datetime.datetime.now())` appends `"Z"` to a **naive local** time. Every
  such value is local time labelled UTC — a 3-hour lie at Israel's offset. `time_stamp()`
  fed the `date=` field of eight status models this way.
- `Field(default=datetime.datetime.now())` in a Pydantic model is evaluated **once, at
  import**, so every instance carries the import moment. Use `default_factory`.
- `(now() - start).seconds` is the 0–86399 component, excluding days. A backwards clock
  step normalises to `days=-1, seconds=86399`, so a timeout loop runs for about a day.
  Use `.total_seconds()`, or better `time.monotonic()`.

### `RUF012` — mutable class attribute

**Read every one.** Wrapping a Pydantic model field in `ClassVar` silently removes it
from the model. It is absent from ruff's *safe* fix set for good reason; never batch it.

### `C901` — complexity

Restructuring `expose()`, `do_acquire()` or `solve()` is a refactor, not a clean-up, and
those are the hardware paths with the least test coverage. Prefer `# noqa: C901` with a
reason, or raise the threshold, until there is a contract suite to refactor against
(`MAST_unit#52`).

### `TRY002` — raising bare `Exception`

Wants a small exception hierarchy per repo. A genuine improvement, but it touches error
contracts broadly — treat it as a reviewed change, not as lint.

---

## 7. Cross-repo concerns

### `MAST_common` is consumed by four repos

A change here is a change everywhere. Two mechanisms are in play and the submodule is
being phased out:

- `MAST_unit` — **sibling clone** in the flat layout (`<top>/common/`, `<top>/unit/`),
  put on `sys.path` by the `mast.pth` MAST_provisioning writes into the venv. No
  submodule (`MAST_unit#94`).
- `MAST_control`, `MAST_spec`, `MAST_gui` — still submodules at `./common/`. See the
  TODO in `MAST_common/CLAUDE.md`; verify per project how `common` reaches `sys.path` at
  runtime before removing anything.

In CI, reproduce the layout the machines actually use. For `MAST_unit` that is two
checkouts side by side plus `PYTHONPATH: ${{ github.workspace }}` standing in for
`mast.pth` — which makes CI a standing check on that decision. Both repos are public, so
the default `GITHUB_TOKEN` covers the cross-repo checkout.

Keep **`known-first-party = ["common"]`** in every `ruff.toml`. It matters *more* once
`common` lives outside the repo, because ruff's path-based resolver cannot classify it at
all.

### Changing a shared signature needs a consumer follow-up

Adding an optional parameter keeps consumers compiling while silently changing their
behaviour. When `make_autofocus_folder`'s hardcoded `"highspec"` became a `subfolder`
parameter, `MAST_spec` kept building but its products would land in the wrong place until
its call site passed the name — filed as `MAST_spec#34`. **File the follow-up in the
consumer repo, and say what breaks in the interval.**

GitHub closing keywords **do not work across repositories**. A `MAST_common` commit
cannot close a `MAST_unit` issue; close it by hand.

### Path names are an interface

Product folder and file names are consumed by planning and the GUI. Renaming them —
including changing which day a product lands under — is a **cross-repo coordination**,
not a lint fix. Survey the consumers first.

Related standard: an **observing night** is anchored at **12:00 UTC** (the Julian Date
noon epoch, and what `SiteConfig.night_window` already uses). A night spans local
midnight, and at Israel's offset `00:00 UTC` falls at 02:00–03:00 local, so dating by
calendar day splits every night across two directories. Logs already do this
(`MAST_common#29`); products do not yet (`MAST_common#28`), so the two currently disagree.

---

## 8. Working habits that prevented (or caused) damage

- **Do not use `git checkout -- <file>` to undo a mutation test.** It restores from the
  index, so it *destroys* uncommitted work. Commit first, or copy the file aside. This
  cost a full re-do of `filer.py`.
- **Do not import entry points to check they still import.** `app.py` starts hardware at
  module level. A sweep that imports "every module under `src/`" will launch PWI4 on a
  live unit. Exclude entry points, or rely on the §4 guard.
- **Watch the shell's working directory.** It persists between commands; a `cd ../unit`
  at the end of one command silently makes the next command's "common" grep run in
  `unit`, which produced a confidently wrong "no results" answer.
- **Org-wide GitHub code search is not authoritative here.** It reported no `MAST_spec`
  caller for a function `MAST_spec` demonstrably calls, and 503s under load. Absence of
  results is not evidence of absence — check out the repo, or ask.
- **Behind the Weizmann proxy**, `git` and `gh` need `https_proxy`/`http_proxy`
  (`http://bcproxy.weizmann.ac.il:8080`). The Windows system proxy setting does not reach
  them.
