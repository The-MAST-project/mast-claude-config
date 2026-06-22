---
name: feedback-decisions-md-append-only
description: "DECISIONS.md rules - when/what to add, date format, order, amend vs append, immutability after commit"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 677c5e40-c4b2-416e-909d-d4970ace897a
---

DECISIONS.md is a reverse-chronological log of architectural and design decisions. Rules:

**When to add:** architectural/design decisions (transfer mechanism, credential model, script decomposition, protocol choice, security posture, etc.). Do NOT add for debugging spikes, transient experiments, or bug fixes with no design intent.

**Format:** WHY / WHAT / IMPLICATIONS. Match existing entry style.

**Date:** Always generate with a system command -- `(Get-Date).ToString('yyyy-MM-dd')` in PowerShell or `date /t` in cmd. Never guess or hardcode.

**Order:** Prepend at the top (newest-first). Never append to the bottom.

**Amend vs. append:** If understanding of the decision evolves while the change is still staged (before the relevant git commit), edit the pending entry in place. Only append a new entry once the prior decision is committed.

**Immutability after commit:** Once committed, do not edit an entry -- even if later work supersedes it. A new entry at the top handles that.

**Why:** User corrected an edit to an older [2026-05-07] entry that updated a stale reference instead of leaving it as a historical record. User then expanded the rules to cover date generation, when to add entries, and the amend-vs-append distinction.

**How to apply:** Before touching DECISIONS.md, check whether there is an uncommitted pending entry for this task (amend if so) or whether this is a new committed change (prepend new entry). Always run the date command first.
