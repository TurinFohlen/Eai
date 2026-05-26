import Config

config :eai, :telemetry_events, [
  {[:eai, :session, :spawn], "PTY session spawned"},
  {[:eai, :session, :reset], "PTY session force-reset"},
  {[:eai, :task, :start], "Task submitted"},
  {[:eai, :task, :chunk], "PTY chunk received"},
  {[:eai, :task, :complete], "Task complete"},
  {[:eai, :task, :timeout], "Task timed out"},
  {[:eai, :llm, :request, :start], "LLM request start"},
  {[:eai, :llm, :request, :stop], "LLM request stop"},
  {[:eai, :tool, :execute], "Tool executed"}
]
