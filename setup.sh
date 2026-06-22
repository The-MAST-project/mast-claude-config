#!/usr/bin/env bash
# setup.sh — install MAST Claude Code skills and memories (Linux / macOS / Git-Bash)
set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_DIR="$HOME/.claude/skills"
PROJECTS_DIR="$HOME/.claude/projects"

# --- Determine the memory destination ----------------------------------------
# Memory lives under ~/.claude/projects/<slug>/memory, where <slug> is Claude
# Code's encoding of the project working-dir path (path separators and the
# drive ':' become '-'). The slug differs per machine, so it is NOT hardcoded:
#   /home/mast/PycharmProjects        -> -home-mast-PycharmProjects
#   C:\Users\you\Desktop\MAST         -> C--Users-you-Desktop-MAST
#
# Pass the project working-dir path (or the slug itself) as the first argument,
# or set MAST_PROJECT_DIR. With neither, the script auto-detects when exactly
# one project exists under ~/.claude/projects.
slugify() { printf '%s' "$1" | sed -e 's#[/\\:]#-#g'; }

arg="${1:-${MAST_PROJECT_DIR:-}}"
slug=""
if [ -n "$arg" ]; then
    if [ -d "$PROJECTS_DIR/$arg" ]; then
        slug="$arg"                 # already a slug
    else
        slug="$(slugify "$arg")"
    fi
fi

if [ -z "$slug" ]; then
    projs=()
    for d in "$PROJECTS_DIR"/*/; do [ -d "$d" ] && projs+=("$(basename "$d")"); done
    if [ "${#projs[@]}" -eq 1 ]; then
        slug="${projs[0]}"
    else
        echo "Could not determine which Claude project to install memories into."
        echo "Re-run with the project working-dir path, e.g.:"
        echo "  bash setup.sh /home/mast/PycharmProjects"
        echo "Projects currently under $PROJECTS_DIR:"
        printf '  %s\n' "${projs[@]:-（none）}"
        exit 1
    fi
fi
MEMORY_DIR="$PROJECTS_DIR/$slug/memory"

echo "Installing MAST Claude Code configuration..."
echo "  skills -> $SKILLS_DIR"
echo "  memory -> $MEMORY_DIR"

mkdir -p "$SKILLS_DIR"
mkdir -p "$MEMORY_DIR"

link_file() {
    local src="$1" dst="$2" kind="$3" name
    name="$(basename "$dst")"
    if [ -L "$dst" ]; then
        echo "  $kind: $name (already linked)"
    elif [ -e "$dst" ]; then
        echo "  $kind: $name — skipped (local file exists, not a symlink)"
    else
        ln -s "$src" "$dst"
        echo "  $kind: $name → linked"
    fi
}

# Skills: symlink every file
for f in "$REPO_DIR/skills/"*.md; do
    [ -e "$f" ] || continue
    link_file "$f" "$SKILLS_DIR/$(basename "$f")" "skill"
done

# Memory: symlink every file (existing non-symlink files are never overwritten)
for f in "$REPO_DIR/memory/"*.md "$REPO_DIR/memory/"*.toml; do
    [ -e "$f" ] || continue
    link_file "$f" "$MEMORY_DIR/$(basename "$f")" "memory"
done

echo "Done. Restart Claude Code to pick up new skills."
