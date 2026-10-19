---
name: Operational how-tos live in the MAST wiki
description: How-tos go in the public MAST wiki, code points at them, and a change to code a page covers updates that page in the same piece of work
type: feedback
---

Operational how-tos (reaching systems, running a unit, observing, calibration, provisioning, deploying, recovery) live in the **[MAST wiki](https://github.com/The-MAST-project/MAST/wiki)**, not in repo READMEs. Design rationale and developer guides stay in each repo's `CLAUDE.md` / `docs/`.

**Why:** how-tos scattered across READMEs and old per-repo wikis rotted unseen. Nobody reads the code or sweeps the docs by hand, so a page stays true only if the agent changing the code updates it.

**How to apply:**
- Each wiki page opens with an HTML comment holding `triggers:`, a map from repo name to git path globs naming the code the page describes. Code points back with the page URL in a comment (`# How-to: https://github.com/The-MAST-project/MAST/wiki/<Page>`).
- **When you change a file that carries a wiki pointer, or that a page's triggers cover, re-check that page against your change and edit it, in the same piece of work.** Run `/wiki-sweep` before opening the PR.
- When you write a new how-to, write it in the wiki, add the files it depends on to its `triggers`, and leave a pointer in the repo instead of the text. When you move or rename a covered file, update the trigger.
- The wiki is **public**: no passwords, keys, share links or personal contacts, even where a repo carries them.
- Edit it as a git repo: `git clone https://github.com/The-MAST-project/MAST.wiki.git`.
