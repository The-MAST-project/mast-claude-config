---
name: wiki-sweep
description: Check the MAST wiki against code changes. Before opening or updating a PR in any MAST repo, find the wiki pages the change affects and update them; with "all", audit every page against the latest code. Use before a PR, or when asked to "sweep/audit the wiki".
user-invocable: true
---

The [MAST wiki](https://github.com/The-MAST-project/MAST/wiki) holds the team's operational how-tos. Each page opens with an HTML comment listing its `triggers`, a map from repo name to git path globs:

```
<!--
triggers:
  MAST_unit.2024-12-12:
    - src/app.py
-->
```

## Setup

```bash
W=$(mktemp -d)
git clone --quiet https://github.com/The-MAST-project/MAST.wiki.git "$W/wiki"
```

## Before a PR (default)

In the code repo, with `<base>` the integration branch (`origin/main` or `origin/master`) and `<repo>` the GitHub repo name (e.g. `MAST_unit.2024-12-12`):

1. List the files the branch changes: `git diff --name-only <base>...HEAD`.
2. **Pages that point at you:** for each changed file, `git grep -h -o 'github.com/The-MAST-project/MAST/wiki/[A-Za-z0-9_.-]*' -- <file>`.
3. **Pages that cover you:** read the triggers block of each page (`head -40 "$W/wiki"/*.md`) and match the changed files against the globs listed under `<repo>`. Check a glob with `git ls-files -- ':(glob)<glob>'`.
4. For each affected page, read it next to the diff and fix whatever the change made wrong: commands, flags, paths, ports, defaults, behavior. If nothing on the page is affected, say so in the PR description instead of editing the page.
5. If the branch moved or renamed a covered file, update the trigger. If it added a how-to, put it on a page, add its files to the triggers, and leave a one-line pointer in the repo.
6. Push the wiki: `git -C "$W/wiki" add -A && git -C "$W/wiki" commit -m "<Page>: <what changed>" && git -C "$W/wiki" push`.

## Full audit (`/wiki-sweep all`)

For each page and each repo in its triggers, compare the page's last edit with the last commit to the covered files on the integration branch:

```bash
git -C "$W/wiki" log -1 --format=%cs -- <Page>.md
git -C <clone> log -1 --format='%cs %h %s' <base> -- ':(glob)<glob>' ...
```

If the code is newer, read `git -C <clone> log --since=<page date> <base> -- <globs>`, correct the page, and push. A glob that matches no file means the code moved; fix the trigger.

## Rules

- The wiki is public. No passwords, keys, share links or personal contacts.
- American English, task-oriented steps, no design rationale (that stays in the repo).
