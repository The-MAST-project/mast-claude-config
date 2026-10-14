# Retiring PWShutter and the ASCOM covers driver

*Plan for moving `unit/src/covers.py` off ASCOM and onto PWI4's `mirrorcover` HTTP API,
and dropping `PWShutter.exe` from the unit's startup. The API was verified on hardware --
see MAST_unit#134 for the raw findings; this document is the implementation plan built on
them.*

**Status: proposed.** The capability is proven; the ordering, the state-mapping and one
safety question below are not yet decided.

---

## 1. Why

**The ASCOM path is broken on at least one machine.** MAST_unit#95: the
`CoverCalibrator` ProgID is unregistered, `win32com.client.Dispatch(self.conf.ascom_driver)`
throws at construction, and the component fails at startup. That is a per-machine driver
registration problem, and it recurs.

**`PWShutter.exe` is the awkward process in every supervision design.** `app.py` starts it
via `ensure_process_is_running`, it is referenced nowhere else in the codebase, and it has
**no probe channel of its own** -- no port, no status endpoint. Every other supervised
process can answer "are you working": PWI4 on :8220, ps3cli on :8998, PHD2's JSON-RPC
socket, the unit's own `/status`. PWShutter can only be name-matched. Its removal is what
lets supervision be health-based across the board rather than special-casing one process
(see MAST_provisioning's supervision decision record, 2026-08-12).

**PWI4 is already there.** Installed, running, connected to the hardware, with a client, a
status model and a health probe. Consolidating covers behind it puts mount, focuser,
rotator, M3 *and* covers on one interface.

**It works.** MAST_unit#134: PWI4 4.1.6 on mast00, 2026-08-12, three full open/close cycles
driven entirely over HTTP, with a sensor-backed state machine that settled within a tenth of
a second of the same timing each run.

## 2. What exists today

| | |
|---|---|
| `unit/src/covers.py` | `Covers(Component, SwitchedOutlet, AscomDispatcher)`, `win32com.client.Dispatch(self.conf.ascom_driver)`, every operation through `ascom_run(self, "...")` |
| `unit/src/app.py:76-83` | `ensure_process_is_running(name="PWShutter.exe", cmd=".../PlaneWave Interface 4/PWShutter.exe", shell=True)` |
| `common/config/covers.py` | `CoversConfig` has exactly one field: `ascom_driver: str` |
| `unit/src/PlaneWave/pwi4_client.py` | parses `site`, `mount`, `focuser`, `rotator`, `m3`, `autofocus` -- **zero** occurrences of `mirrorcover` |

The vendored client predates the feature: its newest annotations read "Added in 4.0.99
Beta 2", and the installed PWI4 is 4.1.6. `pw.status().mirrorcover` does not exist.

## 3. The state-value collision -- read this before writing any code

`CoversState` (`common/models/statuses.py`) is the **ASCOM** `CoverStatus` enum. PWI4's
`mirrorcover.overall_state` uses different integers **for the same range**:

| int | `CoversState` (ASCOM, today) | PWI4 `overall_state` |
|---|---|---|
| 0 | `NotPresent` | **`Open`** |
| 1 | `Closed` | `Closed` |
| 2 | `Moving` | `Opening` |
| 3 | **`Open`** | **`Closing`** |
| 4 | `Unknown` | *not observed* |
| 5 | `Error` | **`PartlyOpen`** |

**Only `1` means the same thing in both.** The rest are wrong, and two are dangerously so:

* `CoversState(0)` on a PWI4 value reports **`NotPresent` for covers that are open**.
* `CoversState(3)` reports **`Open` for covers that are actively closing.** `covers.py:203`
  is `if self.connected and self.state != CoversState.Open:` -- so a naive int hand-off makes
  a closing cover read as open, at exactly the moment that matters.
* `CoversState(5)` reports `Error` for `PartlyOpen`, which is PWI4's **normal** transitional
  state in both directions.

`CoversState(response.value)` in the current code is a direct int cast. Feeding PWI4's
integer into it silently produces wrong answers rather than raising.

**Therefore: no int passes from PWI4 into `CoversState` without going through an explicit,
tested mapping.** Write it as a dict keyed on PWI4's `overall_state_name`, not on the
integer -- names are self-documenting and PWI4's `4` is unobserved, so an integer table
would be guessing at one entry.

## 4. The client, and what "viable" means

Follow the focuser's shape -- a `Component` holding a PWI4 client, doing its work through
`self.pw.<call>()` and `self.pw.status()` -- with **one addition: gate every call on PWI4
being viable.**

**Hold a private `PWI4()`, as `Mount` and `Focuser` do.** Not for symmetry: construction
order forbids the alternative. `Unit.__init__` builds `Covers` at `unit.py:168` and assigns
`self.pw` at **171**, so `unit.pw` does not exist when `Covers.__init__` runs -- the same
reason `Mount` (166) and `Focuser` (170) construct their own. That pattern is a consequence
of ordering, not duplication to be tidied away.

It also costs nothing. `PWI4` holds `host`, `port` and a `PWI4HttpCommunicator` that holds
`host`, `port`, `timeout_seconds` -- no socket, no session, no pool. Every call is a fresh
`urlopen` against a URL built on the spot. Several instances are several copies of three
fields, contending over nothing.

**The instance and the gate are separate decisions.** What must be shared is the *answer* to
"is PWI4 viable", not the object that asks. A private client consulting a shared viability
property gets both.

**"Viable" is not `pw is not None`.** `PWI4()` never contacts the server -- it stores a host
and a port -- so `_try_init("pw", pwi4_client.PWI4)` essentially cannot fail, and `unit.pw`
would be non-`None` on a machine with no PWI4 installed at all. That check answers nothing.

Viability is **a `status()` that answered recently**, which is exactly what `app.py:57-75`
spends up to thirty seconds establishing:

```python
_pwi4_ok = False
...
pw = pwi4_client.PWI4(); pw.status(); _pwi4_ok = True
...
if not _pwi4_ok:
    logger.warning("PWI4 unavailable at startup - unit will start with mount unavailable")
```

`_pwi4_ok` is a module-local that **nothing ever reads again**. The viability property this
plan needs is what that local should have been; build it there rather than adding a third
mechanism beside a discarded one and an assumption.

**Where the gate surfaces:** the `Component` contract the covers already implement. An
unviable PWI4 makes `is_operational` false with `why_not_operational` saying so, rather than
raising. `Focuser` types its client non-optional and calls `self.pw.status()` unguarded, so a
`PWException` propagates to whichever caller asked -- merely unhelpful for a focuser, but for
covers it is the difference between "cannot report cover state" and an unhandled exception on
the path that closes the mirror.

**Deliberately out of scope:** moving `self.pw` above line 166 so `Mount`, `Focuser` and
`Covers` could all share `unit.pw`. It is a one-line move and probably right, but it changes
two working components to satisfy a tidiness argument, on a plan whose first principle is
backend swap rather than interface change. Follow-up, not prerequisite.

## 5. Work items, in dependency order

**1. Provisioning first.** PWI4 must be configured to use **"Mirror cover with Series5
controller"** or the `mirrorcover` section does not drive real hardware. That configuration
file is generated by MAST_provisioning, so it is a fleet-wide change and it must land, and be
verified on more than one unit, **before** any `covers.py` depends on it.

**2. ~~Extend `pwi4_client.py`~~ -- NOT NEEDED.** The plan assumed the vendored client had to
learn `mirrorcover`. It does not: `PWI4Status` keeps `self.raw`, the full key/value dict of
everything PWI4 returns, so `status().raw["mirrorcover.overall_state_name"]` works against the
client as shipped. The four commands go through `PWI4.request("/mirrorcover/<verb>")`. Wrappers
live in `covers.py` and the vendored PlaneWave code is untouched -- which is the better
outcome, since patching vendored code carries its own upgrade cost.

**3. Write the state mapping** (§3) with unit tests covering every PWI4 name, including
`PartlyOpen` in both directions, and a case asserting that an unmapped value raises rather
than defaulting. *Done: `_PWI4_STATE_NAMES` in `covers.py`. Unit tests still outstanding.*

**4. Swap the backend inside `covers.py`**, keeping the `Component` contract as-is:
`startup()`, `shutdown()`, `status()`, `is_operational`, the `CoverActivities` flags and the
existing endpoints. This should be a backend swap, not an interface change -- if the public
surface moves, that is a separate PR. *Done, and verified on mast00: open, close and status.*

This turned out to require a **MAST_common** change too, which the plan had not anticipated:
`CoverStatus` inherited `AscomStatus`, whose required `ascom: AscomDriverInfoModel` field
cannot be produced once there is no ASCOM driver. Nothing outside the model ever read it.

**5. Remove `PWShutter.exe` from `app.py`**, and from MAST_provisioning's service definitions
(a leftover `mast-pwshutter` service set to Automatic would contend for the device).
*Done in `app.py`; provisioning outstanding.*

**6. Retire the ASCOM path** -- the `AscomDispatcher` base, `ascom_run` calls, and
`CoversConfig.ascom_driver`, which becomes an empty model. Do this **last** and as its own
commit, so a revert restores a working ASCOM path without unpicking anything else.
*Outstanding: `covers.py` no longer imports any of it, but `CoversConfig.ascom_driver` still
exists and `AscomDispatcher`/`ascom_run` remain in use by the focuser and the imagers.*

## 6. What this does NOT fix

Three open issues touch covers and **none of them is resolved by a backend swap**. Fixing
them is independent work; the risk is assuming otherwise.

* **#133 -- `connected` never becomes true.** The setter is
  `try: ... if response.succeeded: self._connected = value; finally: self._connected = False`.
  The `finally` overwrites the success case unconditionally, so `connected` is always `False`
  and `shutdown()` therefore never closes the covers. **This is a live safety bug and it
  should be fixed on its own, before or independently of this plan** -- it leaves the mirror
  uncovered on every shutdown, today.
* **#132 -- service start opens the covers uncommanded**, and they stayed open for 54 hours.
  Backend-independent, and the more urgent of the two.
* **#124 -- removal of the deprecated `connect`/`disconnect` endpoints.** Covers genuinely
  need connect/disconnect semantics under PWI4 (§6), so check this does not collide.

## 7. Contract details that are easy to get wrong

**`/mirrorcover/stop` exists, and #134 does not list it.** Found by probing 4.1.6 after that
issue was written: it answers 200 with a status body, while `/mirrorcover/halt` and
`/mirrorcover/abort` both 404. So `abort()` keeps a real hardware halt rather than degrading
to clearing activity flags, which is what the plan originally assumed it would have to do.
The endpoint set is therefore five, not four: `connect`, `disconnect`, `open`, `close`,
`stop`.

The rest are from #134, all observed on hardware:

* **`PartlyOpen` contains `Open` as a substring.** Any completion check using `in`,
  `startswith`, or an unanchored regex reports success ~0.8 s early, **in both directions**,
  with the covers still moving. This already produced a confidently wrong "covers are open"
  during testing. Match terminal states exactly.
* **`overall_state` is meaningless without `is_connected`.** Disconnecting leaves the last
  value reported verbatim -- observed reporting `Closed` while `is_connected=false`, and
  reporting `Open` for physically closed covers before connecting. Read both fields or act on
  stale data.
* **Connect and disconnect are explicit calls**, not implicit in open/close. The covers must
  be connected before commanding or trusting state, and disconnected after.
* **Timings:** ~25 s per direction, reproducible.
  `Closing(3) @0.4s -> PartlyOpen(5) @24.7s -> Closed(1) @25.5s`. Any timeout should be set
  from this with margin, not guessed.

## 8. The safety question this plan raises, and does not answer

**Today the covers do not depend on PWI4. After this change they do.**

The covers protect the primary mirror. Moving them behind PWI4 means a PWI4 crash, hang, or
failed start takes the covers with it -- including the ability to *close* them. The current
ASCOM path fails independently, which is worse for reliability and better for blast radius.

This needs an answer before implementation, not after:

* What closes the covers if PWI4 is not answering? Is there a fallback path, or is the
  answer "a human on site"?
* `ensure_process_is_running` currently restarts PWShutter if it dies. What is the
  equivalent for a wedged PWI4 -- and note that a *silent but present* PWI4 must not be given
  a second instance, since two PWI4s contending for one mount is worse than one that is stuck.
* Does the enclosure/roof interlock assume covers can always be closed?

**Ownership contention** is the other open question. PWI4 and the ASCOM driver cannot both
own the device. On mast00 the conflict does not arise *because ASCOM is broken* (#95) --
which is very likely why PWI4 connected cleanly. On a unit where ASCOM works, ownership has
to be decided rather than discovered. Testing this on a healthy unit is a prerequisite, not
a formality.

## 9. Verification before it is called done

* Provisioning generates the Series5 configuration, verified on **two or more** units.
* The state mapping's unit tests pass, including `PartlyOpen` and the unmapped case.
* On hardware, on a unit where **ASCOM works**: three open/close cycles, asserting terminal
  states exactly, `is_connected` read alongside `overall_state`, and no early completion.
* `shutdown()` demonstrably closes the covers -- which requires #133 fixed, and is the
  behaviour that matters most.
* PWI4 restarted mid-cycle, to see what the failure looks like before it happens at night.
* A PWI4 version check: the API is gated on **>= 4.1.6**, and a unit running older PWI4 must
  degrade with a clear message rather than silently reporting `Open`.

## 10. Provenance

Findings and hardware verification: **MAST_unit#134** (PWI4 4.1.6, mast00, 2026-08-12).
Motivating failure: **#95**. Independent covers bugs: **#132**, **#133**. Endpoint surface:
**#124**. Supervision consequences: MAST_provisioning
`docs/decisions/2026-08-12-one-nssm-service-supervises-an-interactive-monitor.md`.
Code as of MAST_unit `main` @ c246093.
