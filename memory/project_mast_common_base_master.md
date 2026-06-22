---
name: project_mast_common_base_master
description: "MAST_common's mainline/PR base is master, NOT main"
metadata: 
  node_type: memory
  type: project
  originSessionId: adcb216f-dbad-478a-9f78-708d1f251ba1
---

For **MAST_common**, the integration branch / PR base is **`master`**, not `main`. The `eli/vm-provisioning` branch is based on `master` and merges `upstream/master` in; `upstream/main` has **no merge base** with it (diffing against `*/main` is meaningless/empty or fatal "no merge base"). Both `origin/main` and `origin/master` exist on the fork, but `main` is a red herring for this work.

Consequence when sizing a PR: diff against `upstream/master` (The-MAST-project), not origin/master. `origin/master` (the fork) lags `upstream/master`, so `origin/master...branch` is bloated with upstream's already-merged refactor (~23 files); `upstream/master...branch` shows the real new contribution (the vm-provisioning hardening: DECISIONS.md, config/__init__.py, dlipowerswitch.py, process.py, utils.py).

See [[project_mast_provisioning_upstream]] for the upstream/origin remote convention (upstream = The-MAST-project, origin = elibrody-weizmann fork). Per-repo base differs: **MAST_common = master**, but **MAST_unit.2024-12-12 = main** (its `eli/vm-provisioning` reconciles against `upstream/main`; `upstream/master` is the odd one there). So don't assume a single convention - check each repo's merge-base before sizing a PR or merging.
