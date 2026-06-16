defmodule Eai.Adapter.Converse do
  @moduledoc """
  AWS Bedrock Converse API wire format adapter with SigV4 signing.

  Implements AWS Signature Version 4 for authenticating Bedrock Runtime
  requests. Credentials are read from the standard AWS environment variables:

    * `AWS_ACCESS_KEY_ID` (required)
    * `AWS_SECRET_ACCESS_KEY` (required)
    * `AWS_SESSION_TOKEN` (optional — for temporary credentials / IAM roles)
    * `AWS_REGION` (defaults to `us-east-1`)

  ## SigV4 signing flow

  Every `to_request_body/5` call computes a fresh SigV4 signature:

  1. Build the canonical request (method, URI, sorted headers, payload hash)
  2. Build the string to sign (algorithm, timestamp, credential scope, canonical hash)
  3. Derive the signing key via four-round HMAC-SHA256 key derivation
  4. Attach `Authorization` + `x-amz-date` + `x-amz-content-sha256`
     (+ optional `x-amz-security-token`) headers

  The signed headers are returned in the adapter response map, and
  `Eai.LLM.Direct.build_headers/3` passes them through unchanged
  (first clause: `when headers != []`).

  ## Model config example

      # config/models/claude_bedrock.exs
      import Config
      config :eai, :model_claude_bedrock,
        name: :claude_bedrock,
        model: "us.anthropic.claude-sonnet-4-20250514-v1:0",
        provider: :converse,
        region: "us-west-2",
        api_key_env: nil
  """

  @behaviour Eai.Adapter
  alias Eai.Message

  @service "bedrock"
  @algorithm "AWS4-HMAC-SHA256"

  # ── Adapter callbacks ────────────────────────────────────────────────

  @impl true
  def to_request_body(messages, model, system_prompt, tools, opts) do
    region = Keyword.get(opts, :region, System.get_env("AWS_REGION", "us-east-1"))

    :telemetry.execute(
      [:eai, :adapter, :converse, :to_request_body],
      %{msgs: length(messages), tools: length(tools)},
      %{model: model, region: region}
    )

    converse_messages = Enum.map(messages, &Message.to_converse_map/1)

    bedrock_tools =
      Enum.map(tools, fn
        %{function: %{name: name, description: desc, parameters: params}} ->
          %{
            "toolSpec" => %{
              "name" => name,
              "description" => desc,
              "inputSchema" => %{"json" => params}
            }
          }

        %{"toolSpec" => _} = t ->
          t

        t ->
          t
      end)

    body = %{
      "modelId" => model,
      "system" => [%{"text" => system_prompt}],
      "messages" => converse_messages
    }

    body =
      if bedrock_tools != [] do
        Map.put(body, "toolConfig", %{"tools" => bedrock_tools})
      else
        body
      end

    url = "https://bedrock-runtime.#{region}.amazonaws.com/model/#{model}/converse"

    # SigV4 signing — compute fresh signature per request
    headers = sigv4_headers(body, region, model)

    %{url: url, headers: headers, json_body: body}
  end

  @impl true
  def from_response(%{"output" => %{"message" => %{"role" => "assistant", "content" => content}}}) do
    :telemetry.execute(
      [:eai, :adapter, :converse, :from_response],
      %{blocks: length(content)},
      %{shape: :output_message}
    )

    blocks = Enum.map(content, &block_from_converse/1)
    %{role: :assistant, content: blocks}
  end

  def from_response(%{"content" => content}) do
    :telemetry.execute(
      [:eai, :adapter, :converse, :from_response],
      %{blocks: length(content)},
      %{shape: :content_array}
    )

    blocks = Enum.map(content, &block_from_converse/1)
    %{role: :assistant, content: blocks}
  end

  @impl true
  def from_messages(raw_messages) when is_list(raw_messages) do
    :telemetry.execute(
      [:eai, :adapter, :converse, :from_messages],
      %{count: length(raw_messages)},
      %{}
    )

    Enum.map(raw_messages, &Message.from_converse_map/1)
  end

  # ── Converse block → IR block ────────────────────────────────────────

  defp block_from_converse(%{"text" => t}), do: {:text, t}
  defp block_from_converse(%{"thinking" => t}), do: {:thinking, t}
  defp block_from_converse(%{"redactedThinking" => t}), do: {:thinking, t}

  defp block_from_converse(%{"toolUse" => %{"toolUseId" => id, "name" => name, "input" => input}}) do
    {:tool_use, [tool_use_id: id, name: name, input: input]}
  end

  defp block_from_converse(other) do
    {:text, inspect(other)}
  end

  # ── SigV4 signing ────────────────────────────────────────────────────

  defp sigv4_headers(body, region, model) do
    access_key =
      System.get_env("AWS_ACCESS_KEY_ID") ||
        raise "AWS_ACCESS_KEY_ID environment variable is required for Bedrock Converse adapter"

    secret_key =
      System.get_env("AWS_SECRET_ACCESS_KEY") ||
        raise "AWS_SECRET_ACCESS_KEY environment variable is required for Bedrock Converse adapter"

    session_token = System.get_env("AWS_SESSION_TOKEN")

    now = :calendar.universal_time()
    amz_date = amz_date(now)
    date_stamp = String.slice(amz_date, 0, 8)

    host = "bedrock-runtime.#{region}.amazonaws.com"
    canonical_uri = "/model/#{model}/converse"

    # Payload hash: SHA-256 of JSON body (must match what Req sends)
    payload_str = Jason.encode!(body)
    payload_hash = sha256_hex(payload_str)

    # ── Canonical headers (sorted alphabetically, lowercase names) ──
    canonical_headers =
      "content-type:application/json\n" <>
        "host:#{host}\n" <>
        "x-amz-content-sha256:#{payload_hash}\n" <>
        "x-amz-date:#{amz_date}\n"

    signed_headers = "content-type;host;x-amz-content-sha256;x-amz-date"

    {canonical_headers, signed_headers, extra_headers} =
      if session_token do
        {
          canonical_headers <> "x-amz-security-token:#{session_token}\n",
          signed_headers <> ";x-amz-security-token",
          [{"x-amz-security-token", session_token}]
        }
      else
        {canonical_headers, signed_headers, []}
      end

    # ── Canonical request ───────────────────────────────────────────
    canonical_request =
      "POST\n" <>
        canonical_uri <> "\n" <>
        "\n" <>
        canonical_headers <> "\n" <>
        signed_headers <> "\n" <>
        payload_hash

    # ── String to sign ──────────────────────────────────────────────
    credential_scope = "#{date_stamp}/#{region}/#{@service}/aws4_request"

    string_to_sign =
      @algorithm <> "\n" <>
        amz_date <> "\n" <>
        credential_scope <> "\n" <>
        sha256_hex(canonical_request)

    # ── Sign ────────────────────────────────────────────────────────
    signing_key = derive_signing_key(secret_key, date_stamp, region, @service)
    signature = hmac_sha256_hex(signing_key, string_to_sign)

    authorization =
      @algorithm <> " " <>
        "Credential=#{access_key}/#{credential_scope}, " <>
        "SignedHeaders=#{signed_headers}, " <>
        "Signature=#{signature}"

    [
      {"content-type", "application/json"},
      {"host", host},
      {"x-amz-date", amz_date},
      {"x-amz-content-sha256", payload_hash},
      {"authorization", authorization}
      | extra_headers
    ]
  end

  # ── SigV4 crypto helpers ─────────────────────────────────────────────

  @doc false
  def derive_signing_key(secret_key, date_stamp, region, service) do
    k_date = hmac_sha256("AWS4" <> secret_key, date_stamp)
    k_region = hmac_sha256(k_date, region)
    k_service = hmac_sha256(k_region, service)
    hmac_sha256(k_service, "aws4_request")
  end

  defp amz_date({{y, mo, d}, {h, mi, s}}) do
    :io_lib.format(~c"~4..0B~2..0B~2..0BT~2..0B~2..0B~2..0BZ", [y, mo, d, h, mi, s])
    |> IO.iodata_to_binary()
  end

  defp sha256_hex(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  defp hmac_sha256(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
  defp hmac_sha256_hex(key, data), do: hmac_sha256(key, data) |> Base.encode16(case: :lower)
end
