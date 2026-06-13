# ── Google Drive MCP Server ──────────────────────────────────────────────────
# Requires: @isaacphi/mcp-gdrive (Node.js)
#
# Setup (one-time, on your LOCAL machine — not in a container):
#   1. Google Cloud Console → APIs & Services → Credentials
#      → Create OAuth client ID → Desktop App
#      → Download JSON → rename to gcp-oauth.keys.json
#   2. Set env var GDRIVE_CREDS_DIR to the directory holding that file
#   3. First run: `node ./dist/index.js` opens browser for one-time OAuth consent
#      → generates token.json in the same directory
#   4. Copy gcp-oauth.keys.json + token.json to the path below
#
# The server binary must be built once: npm install && npm run build
#
# NOTE: Anubis 1.6 {:stdio, ...} DOES support :env — it's passed through to
# the underlying Port.  If it doesn't work in your version, use a wrapper
# shell script that exports vars then exec's node.

config :eai, :mcp_servers, [
  {:gdrive,
   [
     transport:
       {:stdio,
        command: "node",
        args: ["/home/rose/.config/mcp-gdrive/dist/index.js"],
        env: %{
          "GDRIVE_CREDS_DIR" => "/home/rose/.config/mcp-gdrive"
        }},
     client_info: %{"name" => "Eai", "version" => "0.1.13"}
   ]}
]
