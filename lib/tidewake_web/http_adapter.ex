defmodule TidewakeWeb.HTTPAdapter do
  @moduledoc "Phoenix's Cowboy adapter without connection-bearing transport instrumentation."

  alias Phoenix.Endpoint.Cowboy2Adapter

  def child_specs(endpoint, config) do
    config =
      Enum.map(config, fn
        {scheme, options} when scheme in [:http, :https] and is_list(options) ->
          {scheme, Keyword.put(options, :stream_handlers, [:cowboy_stream_h])}

        other ->
          other
      end)

    Cowboy2Adapter.child_specs(endpoint, config)
  end

  defdelegate server_info(endpoint, scheme), to: Cowboy2Adapter
end
