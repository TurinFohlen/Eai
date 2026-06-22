#!/usr/bin/env bash
# SPDX-FileDescription: Extract <<{A, rel, B}. triples from Elixir source and feed to dispatch.py
# extract_triples.sh
# Extract <<{A, rel, B}. triples from Elixir source and feed to dispatch.py.
#
# Usage:
#   ./priv/scripts/extract_triples.sh                  # print triples
#   ./priv/scripts/extract_triples.sh matrix           # adjacency matrix
#   ./priv/scripts/extract_triples.sh deps Eai.PTY     # deps of node
#   ./priv/scripts/extract_triples.sh path A B         # shortest path

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DISPATCH="${SCRIPT_DIR}/dispatch.py"
TMPFILE="$(mktemp /tmp/eai_triples_XXXXXX.md)"
trap 'rm -f "$TMPFILE"' EXIT

# Extract all <<{...}. lines from .ex and .exs files
grep -rh "<<{" \
  "${PROJECT_ROOT}/lib" \
  "${PROJECT_ROOT}/config" \
  --include="*.ex" \
  --include="*.exs" \
  2>/dev/null \
  | sed 's/[[:space:]]*//' \
  > "$TMPFILE"

COUNT=$(wc -l < "$TMPFILE" | tr -d ' ')

if [[ "${1:-}" == "" ]]; then
  echo "# Extracted ${COUNT} triples from source"
  cat "$TMPFILE"
  exit 0
fi

echo "# Extracted ${COUNT} triples" >&2
python3 "$DISPATCH" "$TMPFILE" "$@"
