import Config

# ── MCP Server Registry ───────────────────────────────────────────────────
#
# Each entry declares an MCP server to connect at boot.
# Format:
#   {server_id, transport_config}
#
# server_id    — atom, used as Anubis.Client process name and tool prefix
#                 (e.g. :filesystem → tools registered as "mcp:filesystem:*")
#
# transport_config — keyword list, passed directly to Anubis.Client.start_link
#   STDIO:   [transport: [layer: Anubis.Transport.STDIO, command: "...", args: [...]]]
#   SSE:     [transport: [layer: Anubis.Transport.SSE, base_url: "http://..."]]
#   WebSocket: [transport: [layer: Anubis.Transport.WebSocket, url: "ws://..."]]
#
# Examples (commented out — enable when you have the MCP servers installed):
#
# config :eai, :mcp_servers, [
#   {:filesystem,
#    [
#      transport: [layer: Anubis.Transport.STDIO, command: "npx", args: ~w(-y @anthropic/mcp-server-filesystem /tmp)],
#      client_info: %{name: "Eai", version: "0.1.13"}
#    ]},
#   {:github,
#    [
#      transport: [layer: Anubis.Transport.SSE, base_url: "https://api.githubcopilot.com/mcp/"],
#      client_info: %{name: "Eai", version: "0.1.13"}
#    ]}
# ]

# Default: empty (no MCP servers). Uncomment and edit above to enable.
config :eai, :mcp_servers, []
