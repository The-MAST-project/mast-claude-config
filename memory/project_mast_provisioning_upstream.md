---
name: project-mast-provisioning-upstream
description: "MAST_provisioning has an upstream fork on The-MAST-project; origin is the user's elibrody-weizmann fork. Eli's branch (eli/vm-provisioning) carries a vast autonomous-provisioning rewrite not yet on either main."
metadata: 
  node_type: memory
  type: project
  originSessionId: 9b368948-8580-4b69-97ac-d112171ea733
---

`C:\Users\labcomp2\Desktop\MAST\MAST_provisioning` is a fork of
`github.com/The-MAST-project/MAST_provisioning`. The user's fork lives at
`github.com/elibrody-weizmann/MAST_provisioning` (the `origin` remote). An
`upstream` remote was added on 2026-05-24 pointing at the The-MAST-project
repo.

**Why:** Upstream occasionally adds providers (e.g. the 2026-05 monitoring +
windows_exporter + fix-perf-counters drop, astrometry.tgz, imdisk image
filename). Our working branch `eli/vm-provisioning` carries a much larger
autonomous-provisioning + VM-test rewrite (see [[project-mongodb-setup]] and
the Phase 1/2 entries in DECISIONS.md). Direct `git diff HEAD..upstream/main`
looks huge (~15k deleted lines) because of files *we added*, not files
upstream removed; use `git diff f9ee7ed..upstream/main` (the merge-base) to
see what upstream actually changed.

**How to apply:** When the user says "fetch latest from MAST_provisioning",
they mean `git fetch upstream` (the The-MAST-project remote), not the
elibrody-weizmann fork. When merging, expect that any upstream "new provider"
may overlap with parallel work we've already staged on eli/vm-provisioning -
collapse them into a single methodology-aligned provider (using
`server/lib/mast-log.ps1` + `Get-MastLogSessionDir`) rather than carrying
both copies. The Phase 2 work also expects providers to be ASCII-only and
PS 5.1-compatible per CLAUDE.md.
