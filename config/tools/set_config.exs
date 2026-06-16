defmodule Eai.Tool.SetConfig do
  @moduledoc """
  Runtime configuration — modify Application env and :persistent_term at runtime.
  Changes take effect immediately for all processes. No restart needed.

  ## Namespaces

  | Namespace | Backend | Key type | Value type |
  |-----------|---------|----------|------------|
  | `app_env` | `Application.put_env(:eai, key, value)` | string (atomized) | any JSON |
  | `persistent_term` | `:persistent_term.put(key, value)` | string (atomized) | any JSON |

  ## Safety

  This is a **powerful** tool — it mutates live VM state. The hook pipeline
  (config/hooks/*.exs) can block dangerous writes. Prefer `persistent_term` for
  temporary overrides (reboot-safe — lost on restart). Use `app_env` for
  persistent configuration changes.

  Call with no arguments to list current values from both namespaces.
  """

  @behaviour Eai.Tool

  @impl true
  def schema do
    %{
      type: "function",
      function: %{
        name: "set_config",
        description: """
        Dynamically update runtime configuration in Application env or :persistent_term.
        Changes take effect immediately for all processes — no restart needed.

        **Namespaces:**
        - `app_env` — Application.put_env(:eai, key, value). Survives restarts.
        - `persistent_term` — :persistent_term.put(key, value). Lost on restart.

        **When to use each key (app_env):**
        - `poll_cooldown_ms` — Controls how long get_task_result / get_subagent_result
          sleep between polls. Raise to reduce polling cost, lower to speed up (min 500).
        - `pty_init_sleep_ms` — Wait after PTY spawn before sending commands (default 200).
        - `pty_ready_sleep_ms` — Wait after command for first byte of output (default 300).

        **When to use persistent_term:**
        - `eai_hooks` — The hook pipeline registry. Erase and reload!() to force-reset.
        - `eai_llm_tools` — The tool registry (schemas + dispatch map).

        Call with no arguments (or key = "list") to see current values from both namespaces.
        """,
        parameters: %{
          type: "object",
          properties: %{
            namespace: %{
              type: "string",
              description:
                "Which namespace: 'app_env' or 'persistent_term'. Required when setting or reading a single key."
            },
            key: %{
              type: "string",
              description: "Config key name (string, will be atomized). Omit to list all."
            },
            value: %{
              description:
                "New value. Any JSON type: number, string, boolean, object, array. Omit to read current value."
            }
          },
          required: []
        }
      }
    }
  end

  @impl true
  def execute(args, _pty_session_id, _chat_session_id) do
    key = Map.get(args, "key")
    namespace = Map.get(args, "namespace")

    cond do
      is_nil(key) or key == "list" ->
        list_all() |> Jason.encode!()

      is_nil(namespace) or namespace not in ["app_env", "persistent_term"] ->
        %{
          error: "namespace is required and must be 'app_env' or 'persistent_term'",
          got: namespace
        }
        |> Jason.encode!()

      not Map.has_key?(args, "value") ->
        read_one(namespace, key) |> Jason.encode!()

      true ->
        set_one(namespace, key, args["value"]) |> Jason.encode!()
    end
  end

  # ── List all ────────────────────────────────────────────────────

  defp list_all do
    %{
      app_env: list_app_env(),
      persistent_term: list_persistent_term()
    }
  end

  defp list_app_env do
    app_env = Application.get_all_env(:eai)

    interesting = ~w(poll_cooldown_ms sandbox api default_model)a

    interesting
    |> Enum.reduce(%{}, fn k, acc ->
      case Map.fetch(app_env, k) do
        {:ok, v} -> Map.put(acc, Atom.to_string(k), safe_summary(v))
        :error -> acc
      end
    end)
  end

  defp list_persistent_term do
    :persistent_term.get()
    |> Enum.filter(fn {k, _v} -> eai_key?(k) end)
    |> Enum.reduce(%{}, fn {k, v}, acc ->
      Map.put(acc, Atom.to_string(k), safe_summary(v))
    end)
  rescue
    _ -> %{}
  end

  defp eai_key?(k) when is_atom(k) do
    s = Atom.to_string(k)
    String.starts_with?(s, "eai_") or String.starts_with?(s, "Elixir.Eai.")
  end

  defp eai_key?(_), do: false

  # ── Read single ─────────────────────────────────────────────────

  defp read_one("app_env", key) do
    atom = String.to_existing_atom(key)
    value = Application.get_env(:eai, atom)
    %{ok: true, namespace: "app_env", key: key, value: safe_summary(value)}
  rescue
    _ -> %{error: "no such app_env key: #{key}"}
  end

  defp read_one("persistent_term", key) do
    atom = String.to_existing_atom(key)
    value = :persistent_term.get(atom)
    %{ok: true, namespace: "persistent_term", key: key, value: safe_summary(value)}
  rescue
    _ -> %{error: "no such persistent_term key: #{key}"}
  end

  # ── Set ─────────────────────────────────────────────────────────

  defp set_one("app_env", key, value) do
    atom = string_to_key_atom(key)
    Application.put_env(:eai, atom, value)

    %{
      ok: true,
      namespace: "app_env",
      key: key,
      value: safe_summary(value),
      new: not has_app_env?(key)
    }
  end

  defp set_one("persistent_term", key, value) do
    atom = String.to_existing_atom(key)
    :persistent_term.put(atom, value)
    %{ok: true, namespace: "persistent_term", key: key, value: safe_summary(value)}
  rescue
    ArgumentError ->
      %{error: "persistent_term keys must already exist. Use app_env for new keys.", key: key}
  end

  # ── Helpers ─────────────────────────────────────────────────────

  defp string_to_key_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> String.to_atom(key)
  end

  defp has_app_env?(key) do
    atom = String.to_existing_atom(key)
    _ = Application.get_env(:eai, atom)
    true
  rescue
    _ -> false
  end

  defp safe_summary(value) when is_list(value) and length(value) > 20,
    do: "[...] (#{length(value)} items)"

  defp safe_summary(value) when is_list(value), do: value

  defp safe_summary(value) when is_map(value) do
    encoded = Jason.encode!(value)

    if byte_size(encoded) > 500 do
      "#{map_size(value)} keys, #{byte_size(encoded)} bytes"
    else
      value
    end
  rescue
    _ -> "<unencodable map, #{map_size(value)} keys>"
  end

  defp safe_summary(value) when is_pid(value), do: "<pid>"
  defp safe_summary(value) when is_reference(value), do: "<ref>"
  defp safe_summary(value) when is_function(value), do: "<function>"
  defp safe_summary(value) when is_tuple(value), do: "<tuple:#{tuple_size(value)}>"

  defp safe_summary(value) when is_binary(value) and byte_size(value) > 500,
    do: "#{byte_size(value)} bytes"

  defp safe_summary(value), do: value
end
