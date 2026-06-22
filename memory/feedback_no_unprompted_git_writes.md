---
name: no-unprompted-git-writes
description: Never run git commit / push / rm / reset / rebase / lfs migrate / filter-repo / tag without an explicit user request in the current turn. Read-only git is fine.
metadata: 
  node_type: memory
  type: feedback
  originSessionId: fe8833d2-b3ef-4810-a6a4-90a94adf1586
---

Do not run history- or remote-mutating git operations unless the user has
specifically asked in the current request. Read-only (`git log`, `status`,
`diff`, `show`, `rev-parse`, `ls-files`, `lfs ls-files`, `lfs migrate info`,
`fetch`) is always fine. When asked to commit/push, do exactly the scope
named -- don't fold in unrelated dirty files, don't amend unnamed commits,
don't push to unnamed remotes.

**Why:** git history and remote state are the user's review surface.
Premature commits force them to undo or amend; premature pushes broadcast
in-progress work, trigger CI, or move shared refs collaborators see. The
cost is asymmetric -- doing it later when asked is cheap, undoing it
after the fact is expensive. Recorded after I pushed and committed
unprompted during the [[mast-provisioning-upstream]] LFS rewrite session
on 2026-05-28.

**How to apply:** When an edit looks "finished" and a commit feels like
the obvious next step, stop. Leave the working tree dirty, surface what
changed, and wait. Do not offer to commit "for tidiness". Codified in
the repo's `CLAUDE.md` under "Do not write to git unless explicitly asked".

**Do NOT infer push/commit authorization from the task description.** A task
like "resolve the conflicts so it can merge", "fix X", or "create PRs" does
NOT implicitly authorize the commit/push -- resolve/stage/prepare, show what's
ready, and wait for an explicit go-ahead to push. Reinforced 2026-06-22: I
merged upstream/master, resolved a config/__init__.py conflict, committed, and
pushed on the eli/configuration-file branch off "resolve conflicts for merge"
alone; user accepted that push but said do not perform git operations
autonomously. Explicit prior "proceed with the git operations" / "push the fix"
instructions DO authorize the named scope; absent that, ask first.
