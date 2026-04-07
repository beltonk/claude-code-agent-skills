#!/usr/bin/env bash
# Create or teardown isolated git worktrees for parallel worker execution.
# Each worktree gets its own directory so workers don't conflict on file changes.
#
# Usage:
#   ./setup-worktree.sh create worker-auth      # create worktree named worker-auth
#   ./setup-worktree.sh create worker-api HEAD   # create from specific ref
#   ./setup-worktree.sh list                     # list active worktrees
#   ./setup-worktree.sh teardown worker-auth     # remove worktree and branch
#   ./setup-worktree.sh teardown-all             # remove all worker- worktrees

set -euo pipefail

ACTION="${1:-help}"
NAME="${2:-}"
REF="${3:-HEAD}"

WORKTREE_BASE="../"

require_git() {
  if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    echo "ERROR: Not inside a git repository."
    exit 1
  fi
}

case "$ACTION" in
  create)
    require_git
    if [ -z "$NAME" ]; then
      echo "ERROR: Usage: $0 create <name> [ref]"
      exit 1
    fi

    WORKTREE_DIR="${WORKTREE_BASE}${NAME}"

    if [ -d "$WORKTREE_DIR" ]; then
      echo "ERROR: Worktree directory already exists: $WORKTREE_DIR"
      echo "Run '$0 teardown $NAME' first."
      exit 1
    fi

    echo "Creating worktree '$NAME' from $REF..."
    git worktree add -b "$NAME" "$WORKTREE_DIR" "$REF" 2>&1

    echo ""
    echo "# Worktree Ready"
    echo "- **Name**: $NAME"
    echo "- **Path**: $(cd "$WORKTREE_DIR" && pwd)"
    echo "- **Branch**: $NAME"
    echo "- **Based on**: $REF ($(git rev-parse --short "$REF"))"
    echo ""
    echo "Worker should \`cd $(cd "$WORKTREE_DIR" && pwd)\` before executing."
    echo "When done: \`$0 teardown $NAME\`"
    ;;

  list)
    require_git
    echo "# Active Worktrees"
    echo ""
    echo "| Path | Branch | HEAD |"
    echo "|------|--------|------|"
    git worktree list --porcelain 2>/dev/null | while read -r line; do
      case "$line" in
        worktree\ *) path="${line#worktree }" ;;
        HEAD\ *) head="${line#HEAD }"; head="${head:0:8}" ;;
        branch\ *) branch="${line#branch refs/heads/}"
          echo "| \`$path\` | $branch | $head |"
          ;;
        "")
          if [ -n "${path:-}" ] && [ -z "${branch:-}" ]; then
            echo "| \`$path\` | (detached) | ${head:-?} |"
          fi
          path=""; head=""; branch=""
          ;;
      esac
    done
    echo ""
    ;;

  teardown)
    require_git
    if [ -z "$NAME" ]; then
      echo "ERROR: Usage: $0 teardown <name>"
      exit 1
    fi

    WORKTREE_DIR="${WORKTREE_BASE}${NAME}"

    echo "Tearing down worktree '$NAME'..."

    if git worktree list | grep -q "$WORKTREE_DIR"; then
      git worktree remove "$WORKTREE_DIR" --force 2>&1
      echo "- Worktree removed: $WORKTREE_DIR"
    else
      echo "- Worktree not found (may already be removed)"
      rm -rf "$WORKTREE_DIR" 2>/dev/null && echo "- Cleaned up directory: $WORKTREE_DIR"
    fi

    if git branch --list "$NAME" | grep -q "$NAME"; then
      git branch -D "$NAME" 2>&1
      echo "- Branch deleted: $NAME"
    else
      echo "- Branch '$NAME' not found (may already be deleted)"
    fi

    echo ""
    echo "Teardown complete."
    ;;

  teardown-all)
    require_git
    echo "Tearing down all worker worktrees..."
    echo ""
    git worktree list | grep -o '[^ ]*worker-[^ ]*' | while read -r wt; do
      name=$(basename "$wt")
      echo "--- Removing: $name ---"
      git worktree remove "$wt" --force 2>/dev/null || true
      git branch -D "$name" 2>/dev/null || true
      echo ""
    done
    git worktree prune
    echo "All worker worktrees removed."
    ;;

  help|*)
    echo "Usage: $0 <action> [args...]"
    echo ""
    echo "Actions:"
    echo "  create <name> [ref]   Create isolated worktree (default ref: HEAD)"
    echo "  list                  List active worktrees"
    echo "  teardown <name>       Remove worktree and its branch"
    echo "  teardown-all          Remove all worker-* worktrees"
    echo ""
    echo "Examples:"
    echo "  $0 create worker-auth           # new worktree for auth work"
    echo "  $0 create worker-api main       # worktree from main branch"
    echo "  $0 list                         # see all worktrees"
    echo "  $0 teardown worker-auth         # cleanup when done"
    ;;
esac
