#!/usr/bin/env python3
"""
list_mcp_servers.py — list MCP server files with their @mcp-metadata

Scans a directory of `*.exs` files and prints one line per file with
its declared `mcp_name`, `description`, and `enabled` flag (or the
filename as fallback). Stdlib only — no third-party deps.

Usage:
  python list_mcp_servers.py                       # scan priv/mcp_servers/
  python list_mcp_servers.py <dir>                # scan <dir>
  python list_mcp_servers.py <dir> --filter foo    # case-insensitive substring
  python list_mcp_servers.py --json               # one JSON object per line

Per-file format (top of each *.exs file):
    # @mcp-metadata
    # mcp_name: "filesystem"
    # description: "npx filesystem MCP server"
    # enabled: true

Files without an `@mcp-metadata` block still show up — with
mcp_name = filename (sans .exs), description = "" (empty), and
enabled = True. This matches the Eai default behavior in
Eai.MCP.Catalog.
"""

import argparse
import json
import os
import re
import sys
from pathlib import Path

# Matches `# @mcp-metadata` header.
META_MARKER = re.compile(r"^#\s*@mcp-metadata\b")
# Matches `# key: value` lines (value may be a quoted string, bool, nil, or empty map).
KV_LINE = re.compile(r"^#\s*(\w+)\s*:\s*(.+?)\s*$")

# Cache the default scan dir to match Eai's @mcp_config_dir.
DEFAULT_DIR = "priv/mcp_servers"


def parse_value(raw: str):
    """Coerce a stringified metadata value back into a Python term."""
    s = raw.strip()
    if s == "true":
        return True
    if s == "false":
        return False
    if s == "nil":
        return None
    if s == "{}":
        return {}
    if len(s) >= 2 and s[0] == '"' and s[-1] == '"':
        return s[1:-1]
    return s


def parse_metadata(path: Path):
    """Read the leading comment block of an .exs file and extract its
    `@mcp-metadata` fields. Returns an empty dict when no block is
    present, so callers can fall back to defaults."""
    try:
        content = path.read_text(encoding="utf-8")
    except OSError:
        return {}

    # Take only the part before the first blank line — the header block.
    header = content.split("\n\n", 1)[0]
    lines = header.splitlines()

    if not any(META_MARKER.search(line) for line in lines):
        return {}

    out = {}
    for line in lines:
        m = KV_LINE.match(line)
        if not m:
            continue
        key, value = m.group(1), m.group(2)
        out[key] = parse_value(value)
    return out


def list_servers(scan_dir: Path):
    """Yield (file_path, metadata_dict) for every *.exs file under scan_dir."""
    if not scan_dir.is_dir():
        return
    for path in sorted(scan_dir.glob("*.exs")):
        meta = parse_metadata(path)
        yield path, meta


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="List MCP server files with their @mcp-metadata fields."
    )
    parser.add_argument(
        "dir",
        nargs="?",
        default=DEFAULT_DIR,
        help=f"Directory to scan (default: {DEFAULT_DIR})",
    )
    parser.add_argument(
        "--filter",
        default="",
        help="Case-insensitive substring filter on mcp_name or description",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit one JSON object per line instead of a pretty table",
    )
    args = parser.parse_args(argv)

    scan_dir = Path(args.dir)
    needle = args.filter.strip().lower()

    rows = []
    for path, meta in list_servers(scan_dir):
        # Defaults: empty metadata → derive mcp_name from filename,
        # leave description empty, default enabled=True.
        stem = path.stem
        mcp_name = meta.get("mcp_name") or stem
        description = meta.get("description") or ""
        enabled = meta.get("enabled", True)

        if needle and needle not in mcp_name.lower() and needle not in description.lower():
            continue

        rows.append(
            {
                "mcp_name": mcp_name,
                "description": description,
                "enabled": enabled,
                "file_path": str(path),
            }
        )

    if args.json:
        for row in rows:
            print(json.dumps(row, ensure_ascii=False))
        return 0

    # Pretty print
    if not rows:
        print(f"(no MCP server files found under {scan_dir})")
        return 0

    name_w = max(len(r["mcp_name"]) for r in rows)
    print(f"Found {len(rows)} MCP server file(s) under {scan_dir}:")
    print()
    for r in rows:
        flag = "ON " if r["enabled"] else "OFF"
        print(f"  [{flag}] {r['mcp_name']:<{name_w}}  {r['description']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
