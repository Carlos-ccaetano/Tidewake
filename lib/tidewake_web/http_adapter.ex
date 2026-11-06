defmodule TidewakeWeb.HTTPAdapter do
  @moduledoc "Phoenix's Cowboy adapter without connection-bearing transport instrumentation."

  require Logger

  alias Phoenix.Endpoint.Cowboy2Adapter

  def child_specs(endpoint, config) do
    config =
      Enum.map(config, fn
        {scheme, options} when scheme in [:http, :https] and is_list(options) ->
          options =
            options
            |> Keyword.put(:stream_handlers, [:cowboy_stream_h])
            |> Keyword.update(
              :protocol_options,
              [logger: __MODULE__],
              &Keyword.put(&1, :logger, __MODULE__)
            )
            |> Keyword.update(
              :transport_options,
              [logger: __MODULE__],
              &Keyword.put(&1, :logger, __MODULE__)
            )

          {scheme, options}

        other ->
          other
      end)

    Cowboy2Adapter.child_specs(endpoint, config)
  end

  # Cowboy/Ranch pass arbitrary exception terms as format arguments.
  for level <- [:emergency, :alert, :critical, :error, :warning, :notice, :info, :debug] do
    def unquote(level)(_format, _args), do: Logger.log(unquote(level), "HTTP transport event")
  end

  defdelegate server_info(endpoint, scheme), to: Cowboy2Adapter
end
