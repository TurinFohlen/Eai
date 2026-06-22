#!/usr/bin/env bash
# SPDX-FileDescription: Scan tools directory for SPDX headers and print a formatted catalog
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo ""
echo "## Tools Catalog"
echo ""

process_file() {
    local file="$1"
    local rel="${file#$TOOLS_DIR/}"
    rel="${rel#./}"

    # SPDX description
    local spdx
    spdx=$(grep -m1 'SPDX-FileDescription:' "$file" 2>/dev/null | sed 's/^[[:space:]]*#[[:space:]]*SPDX-FileDescription:[[:space:]]*//' || true)
    [ -z "$spdx" ] && spdx="(no description)"

    echo "- **\`$rel\`** — $spdx"

    # Usage: check shell comments then Python docstrings
    local uline
    for pattern in \
      '^[[:space:]]*#[[:space:]]*Usage:' \
      '^[[:space:]]*#[[:space:]]*用法:' \
      '^[[:space:]]*Usage:' \
    ; do
      uline=$(grep -m1 "$pattern" "$file" 2>/dev/null | sed 's/^[[:space:]]*#*[[:space:]]*//' || true)
      [ -n "$uline" ] && break
    done
    # Fallback: grab first line of Python docstring that starts with a word
    if [ -z "$uline" ]; then
      uline=$(grep -m1 -A1 '^[[:space:]]*"""' "$file" 2>/dev/null | tail -1 | sed 's/^[[:space:]]*//' | grep -v '^"""' | grep -v '^$' || true)
    fi
    [ -n "$uline" ] && echo "  $uline"

    echo ""
}

find "$TOOLS_DIR" -maxdepth 1 -type f \( -name '*.sh' -o -name '*.py' -o -name '*.exs' \) ! -name "$(basename "$0")" | sort | while IFS= read -r f; do
    process_file "$f"
done

find "$TOOLS_DIR" -mindepth 1 -type d | sort | while IFS= read -r dir; do
    find "$dir" -maxdepth 1 -type f \( -name '*.sh' -o -name '*.py' -o -name '*.exs' \) ! -name "$(basename "$0")" | sort | while IFS= read -r f; do
        process_file "$f"
    done
done
