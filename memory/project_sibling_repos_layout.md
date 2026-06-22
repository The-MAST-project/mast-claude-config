---
name: project_sibling_repos_layout
description: "MAST_control / MAST_gui / MAST_spec clones on Desktop/MAST — real code branches, Windows checkout quirk, broken submodule pins"
metadata: 
  node_type: memory
  type: project
  originSessionId: d865c83f-3f1b-45a8-9948-83cb59268f99
---

Cloned MAST_control, MAST_gui, MAST_spec (+ mast-claude-config) into `Desktop\MAST` (2026-06-21) alongside MAST_common + MAST_unit so cross-repo impact of the config change is visible. All import `common.config`.

Non-obvious gotchas (pre-existing, not ours):
- **MAST_control**: default branch `main` is an EMPTY stub (README only). Real code is on **`master`** (~95 files). gh reports default=main, which is misleading.
- **MAST_gui**: latest is `main`. Repo contains path `<app>/templatetags/dynamic_urls.py` — `<`/`>` are illegal on Windows, so checkout aborts with "invalid path". Worked around with sparse-checkout excluding `/<app>/` + `core.protectNTFS=false` + skip-worktree. That file can never exist on Windows.
- **MAST_spec**: latest is `master`. Its pinned `common` submodule commit `edaf2bc…` does NOT exist on The-MAST-project/MAST_common (lost in history rewrite). Also has an unmapped `dlipower` gitlink. `dlipower` not populated.
- All three: `common/` was populated by a direct standalone clone of MAST_common @ `eli/configuration-file` (NOT via submodule update, since pins are stale/missing). So each parent repo shows `common` as a modified gitlink — expected/harmless. After editing common, push then re-pull in each to resync.

Submodule layout: common is `./common/` in control/gui/spec, `./src/common/` in unit. See [[project_configuration_file_branch]] and [[project_mast_common_base_master]].
