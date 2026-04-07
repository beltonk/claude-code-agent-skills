#!/usr/bin/env bash
# Manage a MEMORY.md index file and individual memory files.
# Handles add, check for duplicates, list, search, and validate.
#
# Usage:
#   ./memory-index.sh init /path/to/memory-dir                # create MEMORY.md and directory
#   ./memory-index.sh add /path/to/memory-dir name "desc"     # add entry (checks duplicates)
#   ./memory-index.sh has /path/to/memory-dir name            # check if memory exists (exit 0=yes)
#   ./memory-index.sh list /path/to/memory-dir                # list all memories
#   ./memory-index.sh search /path/to/memory-dir "query"      # search descriptions
#   ./memory-index.sh validate /path/to/memory-dir            # check index ↔ files consistency
#   ./memory-index.sh count /path/to/memory-dir               # count entries

set -euo pipefail

ACTION="${1:-help}"
MEM_DIR="${2:-}"
INDEX_FILE=""

setup_paths() {
  if [ -z "$MEM_DIR" ]; then
    echo "ERROR: Memory directory required." >&2
    exit 1
  fi
  INDEX_FILE="$MEM_DIR/MEMORY.md"
}

case "$ACTION" in
  init)
    setup_paths
    mkdir -p "$MEM_DIR"
    if [ ! -f "$INDEX_FILE" ]; then
      echo "# Memory Index" > "$INDEX_FILE"
      echo "" >> "$INDEX_FILE"
      echo "Entries below link to individual memory files." >> "$INDEX_FILE"
      echo "" >> "$INDEX_FILE"
      echo "Created: $INDEX_FILE"
    else
      echo "Already exists: $INDEX_FILE"
    fi
    ;;

  add)
    setup_paths
    NAME="${3:-}"
    DESC="${4:-}"
    if [ -z "$NAME" ] || [ -z "$DESC" ]; then
      echo "ERROR: Usage: $0 add <dir> <name> <description>" >&2
      exit 1
    fi

    # Check for duplicate
    if [ -f "$INDEX_FILE" ] && grep -q "\[$NAME\]" "$INDEX_FILE" 2>/dev/null; then
      echo "DUPLICATE: '$NAME' already exists in index. Update the existing file instead."
      exit 2
    fi

    # Check index size
    if [ -f "$INDEX_FILE" ]; then
      lines=$(wc -l < "$INDEX_FILE" | tr -d ' ')
      if [ "$lines" -ge 200 ]; then
        echo "WARNING: Index has $lines lines (limit: 200). Consider archiving old memories."
      fi
    fi

    # Create memory file from template
    MEM_FILE="$MEM_DIR/$NAME.md"
    if [ -f "$MEM_FILE" ]; then
      echo "DUPLICATE: File '$MEM_FILE' already exists."
      exit 2
    fi

    cat > "$MEM_FILE" << TEMPLATE
---
name: $NAME
description: $DESC
type: ${5:-project}
---

TEMPLATE
    echo "Created: $MEM_FILE"

    # Add to index
    if [ ! -f "$INDEX_FILE" ]; then
      echo "# Memory Index" > "$INDEX_FILE"
      echo "" >> "$INDEX_FILE"
    fi
    echo "- [$NAME]($NAME.md) — $DESC" >> "$INDEX_FILE"
    echo "Indexed: $NAME"
    ;;

  has)
    setup_paths
    NAME="${3:-}"
    if [ -z "$NAME" ]; then echo "ERROR: Usage: $0 has <dir> <name>" >&2; exit 1; fi
    if [ -f "$INDEX_FILE" ] && grep -q "\[$NAME\]" "$INDEX_FILE" 2>/dev/null; then
      echo "EXISTS: $NAME"
      exit 0
    elif [ -f "$MEM_DIR/$NAME.md" ]; then
      echo "EXISTS (not indexed): $NAME"
      exit 0
    else
      echo "NOT FOUND: $NAME"
      exit 1
    fi
    ;;

  list)
    setup_paths
    if [ ! -f "$INDEX_FILE" ]; then
      echo "No index found at $INDEX_FILE"
      exit 1
    fi
    grep '^\- \[' "$INDEX_FILE" 2>/dev/null || echo "(empty)"
    ;;

  search)
    setup_paths
    QUERY="${3:-}"
    if [ -z "$QUERY" ]; then echo "ERROR: Usage: $0 search <dir> <query>" >&2; exit 1; fi
    echo "# Search: $QUERY"
    echo ""
    # Search index descriptions
    if [ -f "$INDEX_FILE" ]; then
      matches=$(grep -i "$QUERY" "$INDEX_FILE" 2>/dev/null || true)
      if [ -n "$matches" ]; then
        echo "**Index matches:**"
        echo "$matches"
        echo ""
      fi
    fi
    # Search file contents
    content_matches=$(grep -rl -i "$QUERY" "$MEM_DIR"/*.md 2>/dev/null | grep -v MEMORY.md || true)
    if [ -n "$content_matches" ]; then
      echo "**Content matches:**"
      echo "$content_matches" | while read -r f; do
        name=$(basename "$f" .md)
        desc=$(grep '^description:' "$f" 2>/dev/null | sed 's/description: *//' | head -1)
        echo "- [$name]($name.md) — ${desc:-no description}"
      done
    fi
    if [ -z "$matches" ] && [ -z "$content_matches" ]; then
      echo "No matches found."
    fi
    ;;

  validate)
    setup_paths
    echo "# Validation: $MEM_DIR"
    echo ""
    errors=0

    # Check for indexed files that don't exist
    if [ -f "$INDEX_FILE" ]; then
      grep -o '\[[^]]*\]([^)]*)' "$INDEX_FILE" 2>/dev/null | while IFS= read -r match; do
        file=$(echo "$match" | sed 's/.*(\(.*\))/\1/')
        if [ ! -f "$MEM_DIR/$file" ]; then
          echo "MISSING FILE: $file (referenced in index)"
          errors=$((errors + 1))
        fi
      done
    fi

    # Check for memory files not in index
    for f in "$MEM_DIR"/*.md; do
      [ -f "$f" ] || continue
      name=$(basename "$f")
      [ "$name" = "MEMORY.md" ] && continue
      if [ -f "$INDEX_FILE" ] && ! grep -q "$name" "$INDEX_FILE" 2>/dev/null; then
        echo "ORPHAN: $name (file exists but not in index)"
        errors=$((errors + 1))
      fi
    done

    # Check for files missing frontmatter
    for f in "$MEM_DIR"/*.md; do
      [ -f "$f" ] || continue
      name=$(basename "$f")
      [ "$name" = "MEMORY.md" ] && continue
      if ! head -1 "$f" | grep -q '^---' 2>/dev/null; then
        echo "NO FRONTMATTER: $name"
        errors=$((errors + 1))
      fi
    done

    lines=$(wc -l < "$INDEX_FILE" 2>/dev/null | tr -d ' ' || echo 0)
    file_count=$(find "$MEM_DIR" -maxdepth 1 -name '*.md' -not -name 'MEMORY.md' | wc -l | tr -d ' ')
    echo ""
    echo "**Index lines**: $lines / 200"
    echo "**Memory files**: $file_count"
    if [ "$errors" -gt 0 ]; then
      echo "**Issues**: $errors"
      exit 1
    else
      echo "**Status**: OK"
    fi
    ;;

  count)
    setup_paths
    if [ -f "$INDEX_FILE" ]; then
      count=$(grep -c '^\- \[' "$INDEX_FILE" 2>/dev/null || echo 0)
      echo "$count"
    else
      echo "0"
    fi
    ;;

  help|*)
    echo "Usage: $0 <action> <memory-dir> [args...]"
    echo ""
    echo "Actions:"
    echo "  init <dir>                    Create memory directory and MEMORY.md index"
    echo "  add <dir> <name> <desc> [type]  Add new memory (checks duplicates). Type: user|correction|project|reference"
    echo "  has <dir> <name>              Check if memory exists (exit 0=yes, 1=no)"
    echo "  list <dir>                    List all indexed memories"
    echo "  search <dir> <query>          Search index and file contents"
    echo "  validate <dir>                Check index ↔ file consistency"
    echo "  count <dir>                   Count indexed entries"
    ;;
esac
