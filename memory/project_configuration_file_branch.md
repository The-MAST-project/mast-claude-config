---
name: project_configuration_file_branch
description: eli/configuration-file branch in The-MAST-project (both repos) for moving hard-coded values from common/config/__init__.py into a .toml file
metadata: 
  node_type: memory
  type: project
  originSessionId: d865c83f-3f1b-45a8-9948-83cb59268f99
---

Task (started 2026-06-21): replace hard-coded values in MAST_common `config/__init__.py` with a `.toml` configuration file, consumed from MAST_unit. Work happens on branch **`eli/configuration-file`** based on the merged upstream code, pushed to **The-MAST-project** (NOT the elibrody-weizmann fork).

Branch exists in all three working copies, all tracking The-MAST-project:
- `Desktop\MAST\MAST_common` (standalone clone) — on `eli/configuration-file` @ `75215fe`, tracks `upstream/eli/configuration-file`.
- `MAST_unit.2024-12-12` — on `eli/configuration-file` @ `87a1a1a` (upstream/main, merge of vm-provisioning PR #13), tracks `upstream/eli/configuration-file`.
- `MAST_unit\src\common` (submodule) — on `eli/configuration-file` @ `75215fe`; its `origin` was repointed from the fork to `The-MAST-project/MAST_common` to match `.gitmodules`.

Gotcha: standalone MAST_common clone and the `src/common` submodule are two SEPARATE clones of the same branch — edits don't cross over. Edit MAST_common in one place, push, then sync the other (`git submodule update --remote`). MAST_unit picks up MAST_common changes only when its submodule gitlink is re-committed. See [[project_mast_common_base_master]] (MAST_common integration line is master, not main) and [[feedback_no_unprompted_git_writes]].
