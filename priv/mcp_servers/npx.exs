# ── Filesystem MCP Server (via npx) ─────────────────────────────────────────
# Requires: Node.js ≥ 18 (npx will auto-download @modelcontextprotocol/server-filesystem)
# No auth needed — safe for first-run sanity check.
# Adjust the last arg to change which directory is exposed.

[
  {:filesystem,
   [
     transport:
       {:stdio, command: "npx", args: ~w(-y @modelcontextprotocol/server-filesystem /tmp)},
     client_info: %{"name" => "Eai", "version" => "0.1.13"}
   ]}
]
