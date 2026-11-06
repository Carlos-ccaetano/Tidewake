defmodule TidewakeWeb.MetricEvents do
  @moduledoc """
  Allowlisted library events for the project's metric reporters.

  Raw Phoenix/Ecto events remain internal and must not be exported directly.
  """

  @events %{
    [:phoenix, :endpoint, :start] => [:system_time],
    [:phoenix, :endpoint, :stop] => [:duration],
    [:phoenix, :router_dispatch, :start] => [:system_time],
    [:phoenix, :router_dispatch, :stop] => [:duration],
    [:phoenix, :router_dispatch, :exception] => [:duration],
    [:phoenix, :socket_connected] => [:duration],
    [:phoenix, :socket_drain] => [:count],
    [:phoenix, :channel_joined] => [:duration],
    [:phoenix, :channel_handled_in] => [:duration],
    [:tidewake, :repo, :query] => [
      :total_time,
      :decode_time,
      :query_time,
      :queue_time,
      :idle_time
    ]
  }
  @channel_events ["phx_join", "phx_leave", "heartbeat"]

  def attach do
    routes = TidewakeWeb.Router.__routes__() |> Enum.map(& &1.path) |> MapSet.new()
    detach()
    :telemetry.attach_many(__MODULE__, Map.keys(@events), &__MODULE__.handle_event/4, routes)
  end

  def detach, do: :telemetry.detach(__MODULE__)

  def metric(%{event_name: [:phoenix | suffix]} = metric) do
    %{metric | event_name: [:tidewake, :observability, :phoenix | suffix]}
  end

  def metric(%{event_name: [:tidewake, :repo, :query]} = metric) do
    %{metric | event_name: [:tidewake, :observability, :repo, :query]}
  end

  def metric(metric), do: metric

  @doc false
  def handle_event(event, measurements, metadata, routes)
      when is_map(measurements) and is_map(metadata) do
    with {:ok, keys} <- Map.fetch(@events, event),
         true <- owned?(event, metadata) do
      values =
        for key <- keys,
            value = Map.get(measurements, key),
            is_integer(value) and value >= 0,
            into: %{},
            do: {key, value}

      :telemetry.execute(export_event(event), values, labels(event, metadata, routes))
    else
      _ -> :ok
    end
  end

  def handle_event(_event, _measurements, _metadata, _routes), do: :ok

  defp owned?([:phoenix, source, _], metadata) when source in [:endpoint, :router_dispatch] do
    match?(%{conn: %Plug.Conn{private: %{phoenix_endpoint: TidewakeWeb.Endpoint}}}, metadata)
  end

  defp owned?([:phoenix, source], metadata) when source in [:socket_connected, :socket_drain] do
    Map.get(metadata, :endpoint) == TidewakeWeb.Endpoint
  end

  defp owned?([:phoenix, source], metadata)
       when source in [:channel_joined, :channel_handled_in] do
    match?(%{socket: %Phoenix.Socket{endpoint: TidewakeWeb.Endpoint}}, metadata)
  end

  defp owned?([:tidewake, :repo, :query], metadata), do: Map.get(metadata, :repo) == Tidewake.Repo
  defp owned?(_event, _metadata), do: false

  defp export_event([:phoenix | suffix]), do: [:tidewake, :observability, :phoenix | suffix]
  defp export_event([:tidewake, :repo, :query]), do: [:tidewake, :observability, :repo, :query]

  defp labels([:phoenix, :router_dispatch, phase], metadata, routes) do
    route = Map.get(metadata, :route)
    labels = %{route: if(MapSet.member?(routes, route), do: route, else: "unmatched")}

    if phase == :exception do
      kind = Map.get(metadata, :kind)
      Map.put(labels, :kind, if(kind in [:error, :exit, :throw], do: kind, else: :unknown))
    else
      labels
    end
  end

  defp labels([:phoenix, :channel_handled_in], metadata, _routes) do
    event = Map.get(metadata, :event)
    %{event: if(event in @channel_events, do: event, else: "other")}
  end

  defp labels(_event, _metadata, _routes), do: %{}
end
