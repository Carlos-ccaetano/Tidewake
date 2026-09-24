defmodule TidewakeWeb.TelemetryTest do
  use ExUnit.Case, async: true

  alias Telemetry.Metrics.{Counter, Sum, Summary}
  alias TidewakeWeb.Telemetry

  @domain_metric_names [
    [:tidewake, :webhooks, :event, :ingested, :count],
    [:tidewake, :webhooks, :event, :ingested, :delivery_count],
    [:tidewake, :webhooks, :event, :rejected, :count],
    [:tidewake, :webhooks, :delivery, :processed, :count],
    [:tidewake, :webhooks, :delivery, :processed, :duration_ms],
    [:tidewake, :webhooks, :delivery, :error, :count],
    [:tidewake, :webhooks, :delivery, :error, :duration_ms]
  ]

  test "defines webhook domain metrics with bounded tags" do
    metrics = Telemetry.metrics()

    assert %Counter{tags: []} = metric!(metrics, "tidewake.webhooks.event.ingested.count")
    assert %Sum{tags: []} = metric!(metrics, "tidewake.webhooks.event.ingested.delivery_count")

    assert %Counter{tags: [:reason]} =
             metric!(metrics, "tidewake.webhooks.event.rejected.count")

    assert %Counter{tags: [:outcome]} =
             metric!(metrics, "tidewake.webhooks.delivery.processed.count")

    assert %Summary{tags: [:outcome], unit: :millisecond} =
             metric!(metrics, "tidewake.webhooks.delivery.processed.duration_ms")

    assert %Counter{tags: [:reason]} =
             metric!(metrics, "tidewake.webhooks.delivery.error.count")

    assert %Summary{tags: [:reason], unit: :millisecond} =
             metric!(metrics, "tidewake.webhooks.delivery.error.duration_ms")

    assert metrics
           |> domain_metrics()
           |> Enum.flat_map(& &1.tags)
           |> Enum.uniq()
           |> Enum.sort() == [:outcome, :reason]
  end

  test "uses the expected event and measurement names" do
    domain_metrics = Telemetry.metrics() |> domain_metrics()

    assert MapSet.new(domain_metrics, & &1.name) == MapSet.new(@domain_metric_names)

    Enum.each(domain_metrics, fn metric ->
      assert metric.event_name == Enum.drop(metric.name, -1)
      assert metric.measurement == List.last(metric.name)
    end)
  end

  test "keeps the existing Phoenix, Ecto, and VM metrics" do
    names = Telemetry.metrics() |> MapSet.new(& &1.name)

    for name <- [
          [:phoenix, :endpoint, :start, :system_time],
          [:phoenix, :router_dispatch, :stop, :duration],
          [:tidewake, :repo, :query, :total_time],
          [:vm, :memory, :total]
        ] do
      assert MapSet.member?(names, name)
    end
  end

  defp domain_metrics(metrics) do
    Enum.filter(metrics, &(Enum.take(&1.name, 2) == [:tidewake, :webhooks]))
  end

  defp metric!(metrics, name) do
    expected_name = String.split(name, ".") |> Enum.map(&String.to_existing_atom/1)

    Enum.find(metrics, &(&1.name == expected_name)) ||
      flunk("expected metric #{name} to be defined")
  end
end
