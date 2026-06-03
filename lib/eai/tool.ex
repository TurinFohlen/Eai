defmodule Eai.Tool do
  @moduledoc """
  Tool behaviour — each tool in config/tools/ implements schema/0 + execute/4.
  """

  @callback schema() :: map()
  @callback execute(args :: map(), pty_session_id :: String.t(), chat_session_id :: String.t()) ::
              String.t()
end
