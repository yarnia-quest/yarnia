#!/usr/bin/env bash
# Create a git worktree for parallel work, pre-seeded so api/ boots immediately.
#
# Worktrees share one .git but check out separate branches in separate folders, so
# two Claude Code sessions never collide on the index/stash/working tree. The catch:
# gitignored files (api/.env, api/.dev.vars, node_modules) do NOT carry over, so this
# script seeds them from the main checkout.
#
# Usage:
#   scripts/worktree-add.sh <branch-name> [base-branch]
# Examples:
#   scripts/worktree-add.sh cansin/api          # branch off origin/main (or local main)
#   scripts/worktree-add.sh fix/tts-retry main
set -euo pipefail

BRANCH="${1:?usage: scripts/worktree-add.sh <branch-name> [base-branch]}"
BASE="${2:-main}"

# Resolve the MAIN checkout (the one holding the shared .git), works from any worktree.
COMMON="$(git rev-parse --git-common-dir)"
case "$COMMON" in /*) ;; *) COMMON="$(pwd)/$COMMON" ;; esac
MAIN="$(cd "$(dirname "$COMMON")" && pwd)"

# Sibling folder named after the repo + branch, e.g. yarnia-cansin-api.
DEST="$(dirname "$MAIN")/$(basename "$MAIN")-$(echo "$BRANCH" | tr '/' '-')"
[ -e "$DEST" ] && { echo "error: $DEST already exists"; exit 1; }

# Prefer branching off the freshest remote tip so you pick up your teammate's pushes.
git -C "$MAIN" fetch origin --quiet 2>/dev/null || true
if git -C "$MAIN" rev-parse --verify --quiet "origin/$BASE" >/dev/null; then
  START="origin/$BASE"
else
  START="$BASE"
fi
echo "creating worktree $DEST  (branch $BRANCH off $START)"
git -C "$MAIN" worktree add -b "$BRANCH" "$DEST" "$START"

# Seed gitignored secrets the api/ Worker needs at runtime.
for f in api/.env api/.dev.vars; do
  if [ -f "$MAIN/$f" ]; then cp "$MAIN/$f" "$DEST/$f"; echo "  seeded $f"; fi
done

# Share deps via symlink: instant, no npm install, no duplicated disk. Same lockfile
# means identical deps. If a branch changes deps, rm the link and run `npm install`.
# api/ (Worker runtime) and instant/ (schema push + seed-lisa.mjs use @instantdb/admin)
# both need their node_modules.
for d in api instant; do
  if [ -d "$MAIN/$d/node_modules" ] && [ ! -e "$DEST/$d/node_modules" ]; then
    ln -s "$MAIN/$d/node_modules" "$DEST/$d/node_modules"
    echo "  linked $d/node_modules -> main"
  fi
done

# Assign a unique dev-server port so this worktree's `npm run dev` never clashes with
# another. Base 8787 (main's default), +1 per existing worktree, then skip any port
# already listening. Written to api/.dev.port (gitignored); npm run dev/story read it.
WT_COUNT="$(git -C "$MAIN" worktree list | wc -l | tr -d ' ')"
PORT=$((8787 + WT_COUNT - 1))
while lsof -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; do PORT=$((PORT + 1)); done
echo "$PORT" > "$DEST/api/.dev.port"
echo "  dev port: $PORT (api/.dev.port)"

echo
echo "ready. start a Claude Code session there with:"
echo "  cd \"$DEST\" && claude"
