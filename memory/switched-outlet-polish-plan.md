---
name: switched-outlet-polish-plan
description: "PLANNED (after calibration works): polish SwitchedOutlet in MAST_common via its own PR -- ranked defect list from the 2026-07-21 review"
metadata: 
  node_type: memory
  type: project
  originSessionId: c5d5e86f-993e-44c3-905d-33897e044c39
  modified: 2026-07-21T16:12:00.154Z
---

Moved here from mast02 local project memory 2026-07-21 at Arie's request.

**Agreed 2026-07-21 (Arie):** after calibration is working, polish
`common/dlipowerswitch.py` (`SwitchedOutlet` + surroundings), as a **PR against
MAST_common `main`** on its own branch -- NOT riding the `calibration` branch
(dlipowerswitch is untouched there, and the blast radius is spec operations:
SpecOutlets drives ThAr lamps, chiller, shutters).

## Ranked findings (reviewed, not yet fixed; from code reading only -- no tests exist)

Real defects:
1. **Tri-state silently collapsed, biased toward "off".** `state ->
   TriStateBool` but `all([...])` maps unknown (None) to False. So `is_off()`
   is True when the truth is unknown, `power_status()` reports unpowered, and
   `power_off()` on an unknown-state outlet does NOTHING (thinks it is already
   off). TriStateBool exists to express unknown; the class erases it.
2. **`power_on_or_off` fails silently** -- switch not detected -> log + return;
   callers (component `startup()`) cannot tell "powered" from "no-op". Same
   failure shape as the covers-closed night.
3. **`_from_group` is dead** (accepted, never read) and `group()` resolves the
   power switch twice (member-0 resolution immediately overwritten).
4. **Hostname inconsistency:** `get_power_switch` falls back to full
   `socket.gethostname()` while the factory's None-path uses `.split(".")[0]`.
   Fix: pass None through and let the factory canonicalise.

Smells: group members may bind different switches than the group (SpecOutlets
member vs all-outlets lookup; reads via members, writes via group switch);
`is_on`/`is_off` not complements so `cycle()` on a mixed group never cycles the
already-on outlets; `transfer_attributes` docstring references nonexistent
`populate()` and promises methods `__dict__` doesn't carry;
`is_outlet_group`'s hasattr is dead; `__main__` block TOGGLES REAL HARDWARE
(mastw Outlet8 + Camera group) if the file is run.

## PR strategy (agreed direction)

- Branch from MAST_common `main`; merge AFTER the calibration branch merges.
- **Stage commits: mechanical first** (dead flag, double resolution, hasattr,
  doc drift, remove/guard the `__main__` footgun -- provably behaviour
  preserving), **behavioural second** (tri-state preservation; un-silencing
  power_on_or_off). The behavioural ones change semantics consumers may rely
  on -- e.g. dev machines with no power switch may depend on the silent no-op.
- **Characterisation tests first, in MAST_common itself** (mocked
  DliPowerSwitch), so all four consumers inherit them.
- **Call-site survey across MAST_control / MAST_spec / MAST_gui required
  before the behavioural commits** -- only MAST_unit is checked out on mast02.
