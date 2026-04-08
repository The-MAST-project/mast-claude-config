---
name: wip-commit
description: Stage all changed files, write a descriptive commit message, and push to remote
user-invocable: true
---

The MAST projects that can be committed are:
- `/home/mast/PycharmProjects/MAST_gui`
- `/home/mast/PycharmProjects/MAST_control`
- `/home/mast/PycharmProjects/MAST_spec`
- `/home/mast/PycharmProjects/MAST_unit.2024-12-12`

Determine which project(s) have uncommitted changes by running `git status` on each in parallel.
Work on all projects that have changes, one at a time.

For each project with changes, follow these steps exactly:

1. Run `git -C <project> status`, `git -C <project> diff --stat`, and `git -C <project> log --oneline -5` in parallel to see what changed and the commit style.

2. Stage all modified tracked files (do NOT use `git add .` or `git add -A` — add each file by name, skipping submodules and any .env / secrets files). Use `git -C <project> add <file> ...`.

3. Also stage any untracked files that are clearly part of the work (new templates, new Python files, etc.), by name.

4. Write a commit message that:
   - Starts with a short summary line (≤72 chars) describing *what and why*
   - Uses a blank line then bullet points for non-obvious details if needed
   - Ends with: `Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>`
   - Passes the message via a HEREDOC to avoid shell quoting issues

5. Commit: `git -C <project> commit -m "$(cat <<'EOF' ... EOF)"`

6. Push: `git -C <project> push`

7. Report the short commit SHA and push result.
</content>
</invoke>