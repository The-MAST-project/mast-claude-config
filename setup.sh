#!/usr/bin/env bash
# setup.sh — install MAST Claude Code skills and memories
set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_DIR="$HOME/.claude/skills"
MEMORY_DIR="$HOME/.claude/projects/-home-mast-PycharmProjects/memory"

echo "Installing MAST Claude Code configuration..."

mkdir -p "$SKILLS_DIR"
mkdir -p "$MEMORY_DIR"

# Skills: symlink each file
for f in "$REPO_DIR/skills/"*.md; do
    name="$(basename "$f")"
    target="$SKILLS_DIR/$name"
    if [ -L "$target" ]; then
        echo "  skill: $name (already linked)"
    else
        ln -s "$f" "$target"
        echo "  skill: $name → linked"
    fi
done

# Memory: symlink each file (skip MEMORY.md if already exists — user may have local additions)
for f in "$REPO_DIR/memory/"*.md; do
    name="$(basename "$f")"
    target="$MEMORY_DIR/$name"
    if [ -e "$target" ] && [ ! -L "$target" ]; then
        echo "  memory: $name — skipped (local file exists, not a symlink)"
    elif [ -L "$target" ]; then
        echo "  memory: $name (already linked)"
    else
        ln -s "$f" "$target"
        echo "  memory: $name → linked"
    fi
done

echo "Done. Restart Claude Code to pick up new skills."
