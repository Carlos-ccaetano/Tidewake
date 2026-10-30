defmodule Tidewake.Workers.OutboundDeliveryPipelineTest do
  use Tidewake.DataCase, async: false
  import Tidewake.WebhooksFixtures, only: [legacy_project: 0]
  use Oban.Testing, repo: Tidewake.Repo

  alias Tidewake.Webhooks
  alias Tidewake.Webhooks.DeliveryAdapters.Req, as: ReqAdapter

  @behaviour Tidewake.Webhooks.OutboundResolver

  @delivery_processed [:tidewake, :webhooks, :delivery, :processed]
  @public_address {93, 184, 216, 34}

  setup context do
    Req.Test.set_req_test_from_context(context)
    Req.Test.verify_on_exit!(context)

    previous_adapter = Application.fetch_env(:tidewake, :delivery_adapter)
    previous_req_options = Application.fetch_env(:tidewake, ReqAdapter)

    Application.put_env(:tidewake, :delivery_adapter, ReqAdapter)

    Application.put_env(:tidewake, ReqAdapter,
      plug: {Req.Test, context.test},
      resolver: __MODULE__,
      target_mode: :public
    )

    on_exit(fn ->
      restore_env(:delivery_adapter, previous_adapter)
      restore_env(ReqAdapter, previous_req_options)
    end)

    {:ok, stub: context.test}
  end

  test "delivers a signed request through the real worker pipeline", %{stub: stub} do
    secret = Application.fetch_env!(:tidewake, :webhook_signing_secret)
    external_id = "evt_outbound_pipeline_success"
    payload = %{"amount" => 4200, "currency" => "BRL"}

    expected_body =
      Jason.encode!(%{id: external_id, type: "payment.created", data: payload})

    Process.put(:resolver_result, {:ok, [@public_address]})
    test_pid = self()

    Req.Test.expect(stub, 1, fn conn ->
      body = Req.Test.raw_body(conn)
      [header_id] = Plug.Conn.get_req_header(conn, "tidewake-id")
      [timestamp] = Plug.Conn.get_req_header(conn, "tidewake-timestamp")
      [signature] = Plug.Conn.get_req_header(conn, "tidewake-signature")

      assert conn.method == "POST"
      assert conn.host == "93.184.216.34"
      assert conn.request_path == "/api/webhooks"
      assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]
      assert body == expected_body
      assert header_id == external_id
      assert timestamp =~ ~r/^\d+$/
      assert {timestamp_seconds, ""} = Integer.parse(timestamp)
      assert Integer.to_string(timestamp_seconds) == timestamp

      assert "v1=" <> received_digest = signature

      expected_digest =
        :crypto.mac(:hmac, :sha256, secret, "v1.#{header_id}.#{timestamp}.#{body}")
        |> Base.encode16(case: :lower)

      assert received_digest == expected_digest
      send(test_pid, {:signed_request, body, signature})

      Plug.Conn.send_resp(conn, 202, "accepted")
    end)

    {event, delivery, job} =
      Oban.Testing.with_testing_mode(:manual, fn ->
        {event, delivery, job} =
          schedule_delivery(external_id, payload, "https://receiver.example/api/webhooks")

        assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :default)
        {event, delivery, job}
      end)

    assert event.external_id == external_id
    assert Repo.get!(Oban.Job, job.id).state == "completed"
    assert_receive {:resolved, "receiver.example"}
    assert_receive {:signed_request, ^expected_body, signature}

    finalized = Webhooks.get_delivery_internal(delivery.id)
    assert finalized.status == "succeeded"
    assert finalized.attempt_count == 1

    assert [attempt] = Webhooks.list_attempts(finalized)
    assert attempt.attempt_number == 1
    assert attempt.result == "succeeded"
    assert attempt.http_status == 202

    persisted_outcome = inspect({finalized, attempt})
    refute persisted_outcome =~ expected_body
    refute persisted_outcome =~ signature
    refute persisted_outcome =~ secret
  end

  test "blocks a loopback resolution without crossing the HTTP boundary", %{stub: stub} do
    endpoint_url = "https://blocked.example/api/webhooks"
    resolved_ip = "127.0.0.1"
    Process.put(:resolver_result, {:ok, [{127, 0, 0, 1}]})
    attach_delivery_telemetry()
    test_pid = self()

    Req.Test.stub(stub, fn conn ->
      send(test_pid, :unexpected_http_request)
      Plug.Conn.send_resp(conn, 204, "")
    end)

    {_event, delivery, job} =
      Oban.Testing.with_testing_mode(:manual, fn ->
        result =
          schedule_delivery(
            "evt_outbound_pipeline_blocked",
            %{"kind" => "blocked"},
            endpoint_url
          )

        assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :default)
        result
      end)

    refute_received :unexpected_http_request
    assert Repo.get!(Oban.Job, job.id).state == "completed"
    assert_receive {:resolved, "blocked.example"}

    finalized = Webhooks.get_delivery_internal(delivery.id)
    assert finalized.status == "failed"
    assert finalized.attempt_count == 1

    assert [attempt] = Webhooks.list_attempts(finalized)
    assert attempt.result == "transport_error"
    assert attempt.error_type == "destination"

    assert_receive {:delivery_processed, measurements, metadata}
    refute_received {:delivery_processed, _, _}
    assert metadata == %{outcome: "transport_error"}

    persisted_outcome = inspect({finalized, attempt})
    telemetry = inspect({measurements, metadata})

    for bounded_data <- [persisted_outcome, telemetry] do
      refute bounded_data =~ endpoint_url
      refute bounded_data =~ "blocked.example"
      refute bounded_data =~ resolved_ip
    end
  end

  @impl true
  def resolve(hostname) do
    send(self(), {:resolved, hostname})
    Process.get(:resolver_result, {:error, :dns_error})
  end

  def handle_telemetry(@delivery_processed, measurements, metadata, test_pid) do
    send(test_pid, {:delivery_processed, measurements, metadata})
  end

  defp schedule_delivery(external_id, payload, endpoint_url) do
    {:ok, event} =
      Webhooks.create_event(legacy_project(), %{
        external_id: external_id,
        event_type: "payment.created",
        payload: payload
      })

    {:ok, endpoint} =
      Webhooks.create_endpoint(legacy_project(), %{
        name: "Outbound pipeline #{external_id}",
        url: endpoint_url
      })

    assert {:ok, %{delivery: delivery, job: job}} =
             Webhooks.schedule_delivery(event, endpoint)

    {event, delivery, job}
  end

  defp attach_delivery_telemetry do
    handler_id = "outbound-pipeline-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        @delivery_processed,
        &__MODULE__.handle_telemetry/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:tidewake, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:tidewake, key)
end
