---
name: wip-commit
description: Commit the work this session did, by name, with a descriptive message, and push it
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

2. Stage only the files that belong to the change being committed (see `memory/feedback_no_unprompted_git_writes.md`: do exactly the scope named). Do NOT use `git add .` or `git add -A`; add each file by name, skipping any .env / secrets files. Run `git -C <project> diff -- <file>` on each first: a hunk this session did not write belongs to another session, so leave that file out, or stage only this session's hunks with `git apply --cached` of a filtered patch. Use `git -C <project> add <file> ...`.

3. Also stage any untracked files that are clearly part of the same work (new templates, new Python files, etc.), by name. A dirty file that belongs to different work is left out and reported, not committed.

4. Write a commit message that:
   - Starts with a short summary line (≤72 chars) describing *what and why*
   - Uses a blank line then bullet points for non-obvious details if needed
   - Ends with a `Co-Authored-By:` trailer naming the model that actually wrote the commit, in the form the running harness gives. Don't hard-code a model version.
   - Passes the message via a HEREDOC to avoid shell quoting issues

5. Commit: `git -C <project> commit -m "$(cat <<'EOF' ... EOF)"`

6. Push: `git -C <project> push`. If the current branch is the repo's integration branch (`main` or `master`), stop and ask before pushing: a direct push skips review.

7. Report the short commit SHA, the push result, and any dirty files left out of the commit.
