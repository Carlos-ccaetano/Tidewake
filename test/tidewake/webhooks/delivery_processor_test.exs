defmodule Tidewake.Webhooks.DeliveryProcessorTest do
  use Tidewake.DataCase, async: false

  @delivery_cancelled [:tidewake, :webhooks, :delivery, :cancelled]
  @delivery_processed [:tidewake, :webhooks, :delivery, :processed]
  @delivery_error [:tidewake, :webhooks, :delivery, :error]
  @retry_scheduled [:tidewake, :webhooks, :delivery, :retry_scheduled]
  @retry_exhausted [:tidewake, :webhooks, :delivery, :retry_exhausted]

  alias Tidewake.Webhooks
  alias Tidewake.Webhooks.DeliveryAdapters.Deterministic
  alias Tidewake.Webhooks.DeliveryProcessor

  @behaviour Tidewake.Webhooks.DeliveryAdapter

  @impl true
  def deliver(url, body, headers) do
    send(self(), {:delivered, url, body, headers})
    Process.get(:adapter_response, {:ok, %{status: 204, headers: [{"set-cookie", "secret"}]}})
  end

  setup do
    signing_secret = Application.fetch_env(:tidewake, :webhook_signing_secret)

    on_exit(fn ->
      case signing_secret do
        {:ok, secret} -> Application.put_env(:tidewake, :webhook_signing_secret, secret)
        :error -> Application.delete_env(:tidewake, :webhook_signing_secret)
      end
    end)

    :ok
  end

  describe "telemetry" do
    for {label, response, outcome} <- [
          {"success", {:ok, %{status: 204, headers: [{"set-cookie", "header-secret"}]}},
           "succeeded"},
          {"HTTP error",
           {:ok,
            %{
              status: 503,
              headers: [
                {"x-request-id", "secret-request-id"},
                {"authorization", "Bearer secret"}
              ],
              body: "secret-response-body"
            }}, "http_error"},
          {"transport error", {:error, :internal_adapter_detail}, "transport_error"}
        ] do
      test "emits processed with a safe #{label} outcome after finalization" do
        attach_telemetry(@delivery_processed)
        attach_telemetry(@delivery_error)

        response = unquote(Macro.escape(response))
        outcome = unquote(outcome)
        delivery = delivery_fixture()
        Process.put(:adapter_response, response)

        result =
          Oban.Testing.with_testing_mode(:manual, fn ->
            DeliveryProcessor.process(delivery.id, __MODULE__)
          end)

        assert {:ok, %{delivery: finalized, attempt: attempt}} = result
        assert_received {:delivered, _, request_body, request_headers}

        assert attempt.result == outcome
        assert Webhooks.get_delivery(delivery.id) == finalized
        assert Webhooks.list_attempts(delivery) == [attempt]

        assert_received {:telemetry_event, @delivery_processed,
                         %{count: 1, duration_ms: duration_ms} = measurements,
                         %{outcome: ^outcome} = metadata}

        assert is_integer(duration_ms)
        assert duration_ms >= 0
        assert Map.keys(measurements) |> Enum.sort() == [:count, :duration_ms]
        assert Map.keys(metadata) == [:outcome]

        telemetry_data = inspect({measurements, metadata})
        signing_timestamp = header(request_headers, "Tidewake-Timestamp")
        signature = header(request_headers, "Tidewake-Signature")
        refute Map.has_key?(measurements, :delivery_id)
        refute Map.has_key?(metadata, :delivery_id)
        refute telemetry_data =~ "endpoint.invalid"
        refute telemetry_data =~ "evt_processor"
        refute telemetry_data =~ "header-secret"
        refute telemetry_data =~ "secret-request-id"
        refute telemetry_data =~ "secret-response-body"
        refute telemetry_data =~ "internal_adapter_detail"
        refute telemetry_data =~ signing_timestamp
        refute telemetry_data =~ signature
        refute inspect(result) =~ request_body
        refute inspect(result) =~ signature
        refute inspect(result) =~ Application.fetch_env!(:tidewake, :webhook_signing_secret)
        refute telemetry_data =~ Application.fetch_env!(:tidewake, :webhook_signing_secret)
        refute_received {:telemetry_event, @delivery_error, _, _}
      end
    end

    test "emits a bounded not_found error and preserves the return" do
      attach_telemetry(@delivery_processed)
      attach_telemetry(@delivery_error)

      assert {:error, :not_found} =
               DeliveryProcessor.process(2_147_483_647, __MODULE__)

      assert_received {:telemetry_event, @delivery_error, %{count: 1, duration_ms: duration_ms},
                       %{reason: "not_found"}}

      assert is_integer(duration_ms)
      assert duration_ms >= 0
      refute_received {:telemetry_event, @delivery_processed, _, _}
      refute_received {:delivered, _, _, _}
    end

    test "emits a bounded invalid_transition error and preserves the return" do
      delivery = delivery_fixture()
      assert {:ok, _result} = DeliveryProcessor.process(delivery.id, Deterministic)

      attach_telemetry(@delivery_processed)
      attach_telemetry(@delivery_error)

      assert {:error, :invalid_transition} =
               DeliveryProcessor.process(delivery.id, __MODULE__)

      assert_received {:telemetry_event, @delivery_error, %{count: 1, duration_ms: duration_ms},
                       %{reason: "invalid_transition"}}

      assert is_integer(duration_ms)
      assert duration_ms >= 0
      refute_received {:telemetry_event, @delivery_processed, _, _}
      refute_received {:delivered, _, _, _}
    end

    test "normalizes a malformed adapter response without exposing its raw error" do
      attach_telemetry(@delivery_processed)
      attach_telemetry(@delivery_error)

      delivery = delivery_fixture()
      Process.put(:adapter_response, {:error, "raw-secret-error"})

      assert {:error, :invalid_adapter_response} =
               DeliveryProcessor.process(delivery.id, __MODULE__)

      assert_received {:telemetry_event, @delivery_error,
                       %{count: 1, duration_ms: duration_ms} = measurements,
                       %{reason: "invalid_adapter_response"} = metadata}

      assert is_integer(duration_ms)
      assert duration_ms >= 0
      refute inspect({measurements, metadata}) =~ "raw-secret-error"
      refute_received {:telemetry_event, @delivery_processed, _, _}
    end
  end

  test "processes a deterministic delivery and persists its successful attempt" do
    delivery = delivery_fixture()

    assert {:ok, %{delivery: finalized, attempt: attempt}} =
             DeliveryProcessor.process(delivery.id, Deterministic)

    assert finalized.status == "succeeded"
    assert finalized.attempt_count == 1
    assert finalized.completed_at == attempt.completed_at
    assert Webhooks.get_delivery(delivery.id) == finalized
    assert Webhooks.list_attempts(finalized) == [attempt]
    assert attempt.delivery_id == delivery.id
    assert attempt.attempt_number == 1
    assert attempt.result == "succeeded"
    assert attempt.http_status == 204
    assert attempt.duration_ms >= 0
    assert attempt.started_at.time_zone == "Etc/UTC"
    assert attempt.completed_at.time_zone == "Etc/UTC"
    assert DateTime.compare(attempt.completed_at, attempt.started_at) in [:eq, :gt]
    assert attempt.error_type == nil
    assert attempt.response_metadata == nil
  end

  test "passes the exact signed envelope and all prepared headers without persisting them" do
    delivery = delivery_fixture()
    event = Webhooks.get_event(delivery.event_id)
    endpoint = Webhooks.get_endpoint(delivery.endpoint_id)
    before_processing = System.system_time(:second)

    assert {:ok, %{attempt: attempt}} = DeliveryProcessor.process(delivery.id, __MODULE__)

    after_processing = System.system_time(:second)
    assert_received {:delivered, url, body, headers}
    assert url == endpoint.url

    envelope = Jason.decode!(body)

    assert envelope == %{
             "id" => event.external_id,
             "type" => event.event_type,
             "data" => event.payload
           }

    assert headers |> Enum.map(&elem(&1, 0)) |> Enum.sort() ==
             ["Tidewake-Id", "Tidewake-Signature", "Tidewake-Timestamp", "content-type"]

    assert header(headers, "content-type") == "application/json"
    assert header(headers, "Tidewake-Id") == envelope["id"]

    timestamp = header(headers, "Tidewake-Timestamp")
    assert timestamp =~ ~r/^\d+$/
    assert String.to_integer(timestamp) in before_processing..after_processing

    canonical = IO.iodata_to_binary(["v1.", event.external_id, ".", timestamp, ".", body])

    expected_signature =
      :crypto.mac(
        :hmac,
        :sha256,
        Application.fetch_env!(:tidewake, :webhook_signing_secret),
        canonical
      )
      |> Base.encode16(case: :lower)
      |> then(&("v1=" <> &1))

    assert header(headers, "Tidewake-Signature") == expected_signature

    assert attempt.response_metadata == nil
    assert Webhooks.get_event(event.id) == event

    persisted_data = inspect({Webhooks.get_delivery(delivery.id), attempt})
    refute persisted_data =~ timestamp
    refute persisted_data =~ expected_signature
  end

  test "rejects missing signing configuration before claiming or delivering" do
    attach_telemetry(@delivery_error)
    delivery = delivery_fixture()
    attach_retry_telemetry(@retry_scheduled, delivery.id)
    attach_retry_telemetry(@retry_exhausted, delivery.id)
    Application.delete_env(:tidewake, :webhook_signing_secret)

    result = DeliveryProcessor.process(delivery.id, __MODULE__)

    assert result == {:error, :invalid_signing_configuration}
    assert_pending_without_attempt(delivery)
    refute_received {:delivered, _, _, _}

    assert_received {:telemetry_event, @delivery_error, measurements,
                     %{reason: "signing_configuration"} = metadata}

    assert measurements.count == 1
    refute inspect({result, measurements, metadata}) =~ "webhook_signing_secret"
    refute_received {:retry_telemetry, _, _, _, _, _, _}
  end

  test "rejects an invalid signing secret without exposing it or advancing state" do
    attach_telemetry(@delivery_error)
    delivery = delivery_fixture()
    attach_retry_telemetry(@retry_scheduled, delivery.id)
    attach_retry_telemetry(@retry_exhausted, delivery.id)
    invalid_secret = "invalid-secret-must-not-leak"
    Application.put_env(:tidewake, :webhook_signing_secret, invalid_secret)

    result = DeliveryProcessor.process(delivery.id, __MODULE__)

    assert result == {:error, :invalid_signing_configuration}
    assert_pending_without_attempt(delivery)
    refute_received {:delivered, _, _, _}

    assert_received {:telemetry_event, @delivery_error, measurements,
                     %{reason: "signing_configuration"} = metadata}

    assert measurements.count == 1
    refute inspect({result, measurements, metadata}) =~ invalid_secret
    refute_received {:retry_telemetry, _, _, _, _, _, _}
  end

  test "cancels an inactive endpoint without encoding, delivering or creating an attempt" do
    attach_telemetry(@delivery_processed)
    attach_telemetry(@delivery_error)

    delivery = delivery_fixture()
    attach_cancelled_telemetry(delivery.id)
    attach_retry_telemetry(@retry_scheduled, delivery.id)
    attach_retry_telemetry(@retry_exhausted, delivery.id)
    endpoint = Webhooks.get_endpoint(delivery.endpoint_id)
    assert {:ok, _endpoint} = Webhooks.update_endpoint(endpoint, %{active: false})
    before_processing = DateTime.utc_now()

    assert {:ok, %{delivery: cancelled, attempt: nil}} =
             result =
             DeliveryProcessor.process(delivery.id, __MODULE__)

    after_processing = DateTime.utc_now()
    assert cancelled.status == "cancelled"
    assert cancelled.attempt_count == 0
    assert cancelled.completed_at != nil
    assert DateTime.compare(cancelled.completed_at, before_processing) in [:eq, :gt]
    assert DateTime.compare(cancelled.completed_at, after_processing) in [:eq, :lt]
    assert Webhooks.get_delivery(delivery.id).status == "cancelled"
    assert Webhooks.list_attempts(cancelled) == []
    assert result == {:ok, %{delivery: cancelled, attempt: nil}}
    refute_received {:delivered, _, _, _}

    assert_received {:cancelled_telemetry, @delivery_cancelled, measurements, metadata,
                     persisted_at_emission}

    assert measurements == %{count: 1}
    assert metadata == %{reason: "endpoint_inactive"}
    assert persisted_at_emission.status == "cancelled"
    assert persisted_at_emission.completed_at == cancelled.completed_at
    assert persisted_at_emission.attempt_count == 0

    for prohibited_key <- [
          :id,
          :delivery_id,
          :endpoint,
          :endpoint_id,
          :url,
          :payload,
          :headers
        ] do
      refute Map.has_key?(measurements, prohibited_key)
      refute Map.has_key?(metadata, prohibited_key)
    end

    refute Enum.any?(Map.values(measurements) ++ Map.values(metadata), &is_struct/1)
    refute_received {:cancelled_telemetry, @delivery_cancelled, _, _, _}
    refute_received {:telemetry_event, @delivery_processed, _, _}
    refute_received {:telemetry_event, @delivery_error, _, _}
    refute_received {:retry_telemetry, _, _, _, _, _, _}

    assert {:error, :invalid_transition} =
             DeliveryProcessor.process(delivery.id, __MODULE__)

    refute_received {:delivered, _, _, _}
    assert Webhooks.list_attempts(cancelled) == []
  end

  test "propagates not found without calling the adapter" do
    assert {:error, :not_found} =
             DeliveryProcessor.process(2_147_483_647, __MODULE__)

    refute_received {:delivered, _, _, _}
  end

  for status <- [100, 199, 200, 204, 299, 300, 400, 408, 409, 425, 429, 500, 502, 503, 504, 599] do
    test "persists and classifies HTTP #{status} with safe metadata and timing" do
      status = unquote(status)
      delivery = delivery_fixture()
      attach_retry_telemetry(@retry_scheduled, delivery.id)
      attach_retry_telemetry(@retry_exhausted, delivery.id)

      Process.put(:adapter_response, {
        :ok,
        %{
          status: status,
          headers: [
            {"Content-Type", "application/json"},
            {"CONTENT-LENGTH", "0042"},
            {"X-Request-ID", "req_processor"},
            {"Authorization", "Bearer secret"},
            {"Cookie", "session=secret"},
            {"Set-Cookie", "session=secret"},
            {"X-API-Key", "secret"},
            {"X-Webhook-Signature", "secret"},
            {"X-Access-Token", "secret"},
            {"Server", "private"}
          ],
          body: "secret response body"
        }
      })

      before_processing = DateTime.utc_now()

      assert {:ok, %{delivery: persisted, attempt: attempt} = result} =
               Oban.Testing.with_testing_mode(:manual, fn ->
                 DeliveryProcessor.process(delivery.id, 1, __MODULE__)
               end)

      after_processing = DateTime.utc_now()
      assert_received {:delivered, request_url, request_body, request_headers}
      expected_status = expected_http_delivery_status(status)
      assert persisted.status == expected_status
      assert persisted.attempt_count == 1
      assert attempt.delivery_id == delivery.id
      assert attempt.attempt_number == 1
      assert attempt.result == if(status in 200..299, do: "succeeded", else: "http_error")
      assert attempt.http_status == status
      assert attempt.error_type == nil
      assert is_integer(attempt.duration_ms)
      assert attempt.duration_ms >= 0
      assert attempt.started_at.time_zone == "Etc/UTC"
      assert attempt.completed_at.time_zone == "Etc/UTC"
      assert elem(attempt.started_at.microsecond, 1) == 6
      assert elem(attempt.completed_at.microsecond, 1) == 6
      assert DateTime.compare(attempt.started_at, before_processing) in [:eq, :gt]
      assert DateTime.compare(attempt.completed_at, attempt.started_at) in [:eq, :gt]
      assert DateTime.compare(attempt.completed_at, after_processing) in [:eq, :lt]

      assert attempt.response_metadata == %{
               "content_type" => "application/json",
               "content_length" => 42,
               "request_id" => "req_processor"
             }

      if expected_status == "pending" do
        assert %{job: job} = result
        assert persisted.completed_at == nil
        assert persisted.next_attempt_at == attempt.next_attempt_at
        assert job.scheduled_at == attempt.next_attempt_at
        assert job.args == %{"delivery_id" => delivery.id, "attempt_number" => 2}
        assert DateTime.diff(attempt.next_attempt_at, attempt.completed_at, :second) in 5..10

        expected_cause = "http_#{status}"

        expected_delay_ms =
          DateTime.diff(attempt.next_attempt_at, attempt.completed_at, :millisecond)

        assert_received {:retry_telemetry, @retry_scheduled,
                         %{count: 1, delay_ms: ^expected_delay_ms} = measurements,
                         %{cause: ^expected_cause} = metadata, persisted_at_emission,
                         [attempt_at_emission], [job_at_emission]}

        assert Map.keys(measurements) |> Enum.sort() == [:count, :delay_ms]
        assert Map.keys(metadata) == [:cause]
        assert expected_delay_ms >= 0
        assert persisted_at_emission == persisted
        assert attempt_at_emission == attempt
        assert job_at_emission.id == job.id
        assert job_at_emission.scheduled_at == attempt.next_attempt_at

        telemetry_data = inspect({measurements, metadata})

        for prohibited <- [
              request_url,
              request_body,
              header(request_headers, "Tidewake-Timestamp"),
              header(request_headers, "Tidewake-Signature"),
              "secret response body",
              Application.fetch_env!(:tidewake, :webhook_signing_secret)
            ] do
          refute telemetry_data =~ prohibited
        end

        refute_received {:retry_telemetry, @retry_scheduled, _, _, _, _, _}
        refute_received {:retry_telemetry, @retry_exhausted, _, _, _, _, _}
      else
        refute Map.has_key?(result, :job)
        assert persisted.completed_at == attempt.completed_at
        assert persisted.next_attempt_at == nil
        assert attempt.next_attempt_at == nil
        assert Repo.aggregate(Oban.Job, :count) == 0
        refute_received {:retry_telemetry, _, _, _, _, _, _}
      end

      assert Webhooks.get_delivery(delivery.id) == persisted
      assert Webhooks.list_attempts(delivery) == [attempt]

      expected_repeat_error =
        if expected_status == "pending", do: :stale_attempt, else: :invalid_transition

      assert {:error, ^expected_repeat_error} =
               DeliveryProcessor.process(delivery.id, 1, __MODULE__)

      refute_received {:delivered, _, _, _}
      assert Webhooks.get_delivery(delivery.id) == persisted
      assert Webhooks.list_attempts(delivery) == [attempt]
    end
  end

  test "discards invalid metadata values while scheduling a retryable HTTP response" do
    delivery = delivery_fixture()

    Process.put(:adapter_response, {
      :ok,
      %{
        status: 503,
        headers: [
          {"content-type", String.duplicate("a", 256)},
          {"content-length", "42bytes"},
          {"x-request-id", <<255>>},
          {"set-cookie", "secret"}
        ]
      }
    })

    assert {:ok, %{delivery: pending, attempt: attempt, job: job}} =
             Oban.Testing.with_testing_mode(:manual, fn ->
               DeliveryProcessor.process(delivery.id, __MODULE__)
             end)

    assert pending.status == "pending"
    assert attempt.result == "http_error"
    assert attempt.http_status == 503
    assert attempt.response_metadata == nil
    assert attempt.next_attempt_at == pending.next_attempt_at
    assert job.scheduled_at == pending.next_attempt_at
    assert Webhooks.list_attempts(delivery) == [attempt]
  end

  for {label, response} <- [
        {"status below range", {:ok, %{status: 99, headers: []}}},
        {"status above range", {:ok, %{status: 600, headers: []}}},
        {"string status", {:ok, %{status: "204", headers: []}}},
        {"float status", {:ok, %{status: 204.0, headers: []}}},
        {"missing status", {:ok, %{headers: []}}},
        {"missing headers", {:ok, %{status: 204}}},
        {"nil headers", {:ok, %{status: 400, headers: nil}}},
        {"map headers", {:ok, %{status: 503, headers: %{"content-type" => "text/plain"}}}},
        {"atom header name", {:ok, %{status: 204, headers: [{:authorization, "secret"}]}}},
        {"non-string header value", {:ok, %{status: 429, headers: [{"content-length", 42}]}}},
        {"invalid header entry", {:ok, %{status: 503, headers: [nil]}}},
        {"improper headers", {:ok, %{status: 204, headers: [{"x-request-id", "id"} | nil]}}},
        {"non-map response", {:ok, nil}},
        {"invalid error reason", {:error, "secret"}},
        {"unexpected return", :invalid}
      ] do
    test "rejects malformed adapter response: #{label}" do
      delivery = delivery_fixture()
      Process.put(:adapter_response, unquote(Macro.escape(response)))

      assert {:error, :invalid_adapter_response} =
               DeliveryProcessor.process(delivery.id, __MODULE__)

      assert_received {:delivered, _, _, _}
      persisted = Webhooks.get_delivery(delivery.id)
      assert persisted.status == "processing"
      assert persisted.attempt_count == 0
      assert persisted.completed_at == nil
      assert Webhooks.list_attempts(delivery) == []
    end
  end

  test "rejects repeated processing without sending or adding another attempt" do
    delivery = delivery_fixture()
    assert {:ok, result} = DeliveryProcessor.process(delivery.id, Deterministic)

    assert {:error, :invalid_transition} = DeliveryProcessor.process(delivery.id, __MODULE__)
    refute_received {:delivered, _, _, _}
    assert Webhooks.get_delivery(delivery.id) == result.delivery
    assert Webhooks.list_attempts(delivery) == [result.attempt]
  end

  test "rejects a stale logical attempt before calling the adapter" do
    delivery = delivery_fixture()
    attach_retry_telemetry(@retry_scheduled, delivery.id)
    attach_retry_telemetry(@retry_exhausted, delivery.id)

    persisted =
      delivery
      |> change(attempt_count: 1)
      |> Repo.update!()

    assert {:error, :stale_attempt} =
             DeliveryProcessor.process(delivery.id, 1, __MODULE__)

    refute_received {:delivered, _, _, _}
    assert Webhooks.get_delivery(delivery.id) == persisted
    assert Webhooks.list_attempts(delivery) == []
    assert Repo.aggregate(Oban.Job, :count) == 0
    refute_received {:retry_telemetry, _, _, _, _, _, _}
  end

  test "rejects an early logical attempt before calling the adapter" do
    delivery = delivery_fixture()
    attach_retry_telemetry(@retry_scheduled, delivery.id)
    attach_retry_telemetry(@retry_exhausted, delivery.id)
    next_attempt_at = ~U[2099-01-15 12:00:00.123456Z]

    persisted =
      delivery
      |> change(next_attempt_at: next_attempt_at)
      |> Repo.update!()

    assert {:error, :not_due} =
             DeliveryProcessor.process(delivery.id, 1, __MODULE__)

    refute_received {:delivered, _, _, _}
    assert Webhooks.get_delivery(delivery.id) == persisted
    assert Webhooks.list_attempts(delivery) == []
    assert Repo.aggregate(Oban.Job, :count) == 0
    refute_received {:retry_telemetry, _, _, _, _, _, _}
  end

  test "finalizes the sixth retryable failure as exhausted without another job" do
    delivery = delivery_fixture()
    attach_retry_telemetry(@retry_scheduled, delivery.id)
    attach_retry_telemetry(@retry_exhausted, delivery.id)
    timestamp = ~U[2026-10-16 12:00:00.123456Z]

    for attempt_number <- 1..5 do
      assert {:ok, _attempt} =
               Webhooks.create_attempt(%{delivery | cycle_attempt_count: attempt_number - 1}, %{
                 attempt_number: attempt_number,
                 result: "http_error",
                 http_status: 503,
                 duration_ms: 0,
                 started_at: timestamp,
                 completed_at: timestamp
               })
    end

    delivery
    |> change(attempt_count: 5, cycle_attempt_count: 5)
    |> Repo.update!()

    Process.put(:adapter_response, {:ok, %{status: 503, headers: []}})

    assert {:ok, %{delivery: failed, attempt: attempt} = result} =
             DeliveryProcessor.process(delivery.id, 6, __MODULE__)

    assert_received {:delivered, _, _, _}
    assert failed.status == "failed"
    assert failed.attempt_count == 6
    assert failed.retry_cycle == 0
    assert failed.cycle_attempt_count == 6
    assert failed.completed_at == attempt.completed_at
    assert failed.next_attempt_at == nil
    assert attempt.attempt_number == 6
    assert attempt.retry_cycle == 0
    assert attempt.cycle_attempt_number == 6
    assert attempt.result == "http_error"
    assert attempt.http_status == 503
    assert attempt.next_attempt_at == nil
    refute Map.has_key?(result, :job)
    assert Enum.map(Webhooks.list_attempts(delivery), & &1.attempt_number) == Enum.to_list(1..6)
    assert Repo.aggregate(Oban.Job, :count) == 0

    assert_received {:retry_telemetry, @retry_exhausted, measurements, metadata,
                     persisted_at_emission, attempts_at_emission, jobs_at_emission}

    assert measurements == %{count: 1}
    assert metadata == %{cause: "http_503"}
    assert persisted_at_emission == failed
    assert List.last(attempts_at_emission) == attempt
    assert length(attempts_at_emission) == 6
    assert jobs_at_emission == []
    refute_received {:retry_telemetry, @retry_exhausted, _, _, _, _, _}
    refute_received {:retry_telemetry, @retry_scheduled, _, _, _, _, _}
  end

  test "retries the first attempt of a later cycle with the first backoff interval" do
    delivery = delivery_fixture()
    attach_retry_telemetry(@retry_scheduled, delivery.id)
    attach_retry_telemetry(@retry_exhausted, delivery.id)

    delivery
    |> change(attempt_count: 6, retry_cycle: 1, cycle_attempt_count: 0)
    |> Repo.update!()

    Process.put(:adapter_response, {:ok, %{status: 503, headers: []}})

    assert {:ok, %{delivery: pending, attempt: attempt, job: job}} =
             Oban.Testing.with_testing_mode(:manual, fn ->
               DeliveryProcessor.process(delivery.id, 7, __MODULE__)
             end)

    assert_received {:delivered, _, _, _}
    assert pending.status == "pending"
    assert pending.attempt_count == 7
    assert pending.retry_cycle == 1
    assert pending.cycle_attempt_count == 1
    assert pending.next_attempt_at == attempt.next_attempt_at
    assert attempt.attempt_number == 7
    assert attempt.retry_cycle == 1
    assert attempt.cycle_attempt_number == 1
    assert attempt.result == "http_error"
    assert attempt.http_status == 503
    assert job.args == %{"delivery_id" => delivery.id, "attempt_number" => 8}
    assert job.scheduled_at == attempt.next_attempt_at
    assert DateTime.diff(attempt.next_attempt_at, attempt.completed_at, :second) in 5..10
    assert Webhooks.get_delivery(delivery.id) == pending
    assert Webhooks.list_attempts(delivery) == [attempt]

    delay_ms = DateTime.diff(attempt.next_attempt_at, attempt.completed_at, :millisecond)

    assert_received {:retry_telemetry, @retry_scheduled, %{count: 1, delay_ms: ^delay_ms},
                     %{cause: "http_503"}, ^pending, [^attempt], [job_at_emission]}

    assert job_at_emission.id == job.id
    refute_received {:retry_telemetry, @retry_exhausted, _, _, _, _, _}
  end

  test "exhausts the sixth attempt of a later cycle without scheduling a seventh" do
    delivery = delivery_fixture()
    attach_retry_telemetry(@retry_scheduled, delivery.id)
    attach_retry_telemetry(@retry_exhausted, delivery.id)

    delivery
    |> change(attempt_count: 11, retry_cycle: 1, cycle_attempt_count: 5)
    |> Repo.update!()

    Process.put(:adapter_response, {:ok, %{status: 503, headers: []}})

    assert {:ok, %{delivery: failed, attempt: attempt} = result} =
             DeliveryProcessor.process(delivery.id, 12, __MODULE__)

    assert_received {:delivered, _, _, _}
    assert failed.status == "failed"
    assert failed.attempt_count == 12
    assert failed.retry_cycle == 1
    assert failed.cycle_attempt_count == 6
    assert failed.next_attempt_at == nil
    assert attempt.attempt_number == 12
    assert attempt.retry_cycle == 1
    assert attempt.cycle_attempt_number == 6
    assert attempt.next_attempt_at == nil
    refute Map.has_key?(result, :job)
    assert Repo.aggregate(Oban.Job, :count) == 0

    assert_received {:retry_telemetry, @retry_exhausted, %{count: 1}, %{cause: "http_503"},
                     ^failed, [^attempt], []}

    refute_received {:retry_telemetry, @retry_scheduled, _, _, _, _, _}

    assert {:error, :invalid_transition} =
             DeliveryProcessor.process(delivery.id, 13, __MODULE__)

    refute_received {:delivered, _, _, _}
    assert Webhooks.get_delivery(delivery.id) == failed
    assert Webhooks.list_attempts(delivery) == [attempt]
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  for {status, expected_status, expected_result} <- [
        {204, "succeeded", "succeeded"},
        {400, "failed", "http_error"}
      ] do
    test "keeps HTTP #{status} terminal in a later cycle" do
      status = unquote(status)
      expected_status = unquote(expected_status)
      expected_result = unquote(expected_result)
      delivery = delivery_fixture()
      attach_telemetry(@delivery_processed)
      attach_retry_telemetry(@retry_scheduled, delivery.id)
      attach_retry_telemetry(@retry_exhausted, delivery.id)

      delivery
      |> change(attempt_count: 6, retry_cycle: 1, cycle_attempt_count: 0)
      |> Repo.update!()

      Process.put(:adapter_response, {:ok, %{status: status, headers: []}})

      assert {:ok, %{delivery: finalized, attempt: attempt} = result} =
               DeliveryProcessor.process(delivery.id, 7, __MODULE__)

      assert_received {:delivered, _, _, _}
      assert finalized.status == expected_status
      assert finalized.attempt_count == 7
      assert finalized.cycle_attempt_count == 1
      assert attempt.attempt_number == 7
      assert attempt.retry_cycle == 1
      assert attempt.cycle_attempt_number == 1
      assert attempt.result == expected_result
      refute Map.has_key?(result, :job)
      assert Repo.aggregate(Oban.Job, :count) == 0

      assert_received {:telemetry_event, @delivery_processed,
                       %{count: 1, duration_ms: duration_ms}, %{outcome: ^expected_result}}

      assert is_integer(duration_ms)
      assert duration_ms >= 0
      refute_received {:retry_telemetry, _, _, _, _, _, _}
    end
  end

  for {reason, error_type, expected_status} <- [
        {:timeout, "timeout", "pending"},
        {:dns_error, "dns", "pending"},
        {:tls_error, "tls", "failed"},
        {:connection_refused, "connection", "pending"},
        {:connection_closed, "closed", "pending"},
        {:internal_adapter_detail, "unknown", "failed"}
      ] do
    test "persists and classifies transport failure #{reason} as #{error_type}" do
      reason = unquote(reason)
      error_type = unquote(error_type)
      expected_status = unquote(expected_status)
      delivery = delivery_fixture()
      attach_retry_telemetry(@retry_scheduled, delivery.id)
      attach_retry_telemetry(@retry_exhausted, delivery.id)
      Process.put(:adapter_response, {:error, reason})
      before_processing = DateTime.utc_now()

      assert {:ok, %{delivery: persisted, attempt: attempt} = result} =
               Oban.Testing.with_testing_mode(:manual, fn ->
                 DeliveryProcessor.process(delivery.id, 1, __MODULE__)
               end)

      after_processing = DateTime.utc_now()
      assert_received {:delivered, _, _, _}
      assert persisted.status == expected_status
      assert persisted.attempt_count == 1
      assert attempt.delivery_id == delivery.id
      assert attempt.attempt_number == 1
      assert attempt.result == "transport_error"
      assert attempt.http_status == nil
      assert attempt.error_type == error_type

      if error_type == "unknown" do
        refute attempt.error_type == Atom.to_string(reason)
      end

      assert attempt.response_metadata == nil
      assert is_integer(attempt.duration_ms)
      assert attempt.duration_ms >= 0
      assert attempt.started_at.time_zone == "Etc/UTC"
      assert attempt.completed_at.time_zone == "Etc/UTC"
      assert elem(attempt.started_at.microsecond, 1) == 6
      assert elem(attempt.completed_at.microsecond, 1) == 6
      assert DateTime.compare(attempt.started_at, before_processing) in [:eq, :gt]
      assert DateTime.compare(attempt.completed_at, attempt.started_at) in [:eq, :gt]
      assert DateTime.compare(attempt.completed_at, after_processing) in [:eq, :lt]

      if expected_status == "pending" do
        assert %{job: job} = result
        assert persisted.completed_at == nil
        assert persisted.next_attempt_at == attempt.next_attempt_at
        assert job.scheduled_at == attempt.next_attempt_at
        assert job.args == %{"delivery_id" => delivery.id, "attempt_number" => 2}
        assert DateTime.diff(attempt.next_attempt_at, attempt.completed_at, :second) in 5..10

        expected_cause = "transport_#{error_type}"

        expected_delay_ms =
          DateTime.diff(attempt.next_attempt_at, attempt.completed_at, :millisecond)

        assert_received {:retry_telemetry, @retry_scheduled,
                         %{count: 1, delay_ms: ^expected_delay_ms}, %{cause: ^expected_cause},
                         persisted_at_emission, [attempt_at_emission], [job_at_emission]}

        assert persisted_at_emission == persisted
        assert attempt_at_emission == attempt
        assert job_at_emission.id == job.id
        refute_received {:retry_telemetry, @retry_scheduled, _, _, _, _, _}
        refute_received {:retry_telemetry, @retry_exhausted, _, _, _, _, _}
      else
        refute Map.has_key?(result, :job)
        assert persisted.completed_at == attempt.completed_at
        assert persisted.next_attempt_at == nil
        assert attempt.next_attempt_at == nil
        assert Repo.aggregate(Oban.Job, :count) == 0
        refute_received {:retry_telemetry, _, _, _, _, _, _}
      end

      assert Webhooks.get_delivery(delivery.id) == persisted
      assert Webhooks.list_attempts(delivery) == [attempt]
    end
  end

  for {reason, error_type} <- [
        unsafe_destination: "destination",
        response_too_large: "response_limit"
      ] do
    test "persists and observes #{reason} as #{error_type} without destination data" do
      reason = unquote(reason)
      error_type = unquote(error_type)
      attach_telemetry(@delivery_processed)
      attach_telemetry(@delivery_error)

      destination_hostname = "sensitive-destination.invalid"
      destination_ip = "203.0.113.77"

      destination_url =
        "https://#{destination_hostname}/private?resolved_ip=#{destination_ip}&token=destination-secret"

      delivery = delivery_fixture(destination_url)
      Process.put(:adapter_response, {:error, reason})

      assert {:ok, %{delivery: finalized, attempt: attempt}} =
               DeliveryProcessor.process(delivery.id, __MODULE__)

      assert_received {:delivered, ^destination_url, request_body, request_headers}
      assert finalized.status == "failed"
      assert finalized.attempt_count == 1
      assert finalized.completed_at == attempt.completed_at
      assert attempt.delivery_id == delivery.id
      assert attempt.attempt_number == 1
      assert attempt.result == "transport_error"
      assert attempt.error_type == error_type
      assert attempt.http_status == nil
      assert attempt.response_metadata == nil
      assert Webhooks.get_delivery(delivery.id) == finalized
      assert Webhooks.list_attempts(delivery) == [attempt]

      assert_received {:telemetry_event, @delivery_processed,
                       %{count: 1, duration_ms: duration_ms} = measurements,
                       %{outcome: "transport_error"} = metadata}

      assert is_integer(duration_ms)
      assert duration_ms >= 0
      assert Map.keys(measurements) |> Enum.sort() == [:count, :duration_ms]
      assert Map.keys(metadata) == [:outcome]
      refute_received {:telemetry_event, @delivery_error, _, _}

      persisted_data = inspect({finalized, attempt, Webhooks.list_attempts(delivery)})
      telemetry_data = inspect({measurements, metadata})
      raw_reason = Atom.to_string(reason)
      signature = header(request_headers, "Tidewake-Signature")

      for prohibited <- [
            destination_url,
            destination_hostname,
            destination_ip,
            request_body,
            raw_reason,
            signature
          ] do
        refute persisted_data =~ prohibited
        refute telemetry_data =~ prohibited
      end
    end
  end

  test "returns a changeset error when transport failure finalization cannot insert the attempt" do
    attach_telemetry(@delivery_processed)
    attach_telemetry(@delivery_error)

    delivery = delivery_fixture()
    attach_retry_telemetry(@retry_scheduled, delivery.id)
    attach_retry_telemetry(@retry_exhausted, delivery.id)
    timestamp = DateTime.utc_now()

    assert {:ok, existing_attempt} =
             Webhooks.create_attempt(delivery, %{
               attempt_number: 1,
               result: "transport_error",
               error_type: "timeout",
               duration_ms: 0,
               started_at: timestamp,
               completed_at: timestamp
             })

    Process.put(:adapter_response, {:error, :timeout})

    assert {:error, %Ecto.Changeset{}} = DeliveryProcessor.process(delivery.id, __MODULE__)
    assert_received {:delivered, _, _, _}
    persisted = Webhooks.get_delivery(delivery.id)
    assert persisted.status == "processing"
    assert persisted.attempt_count == 0
    assert persisted.completed_at == nil
    assert Webhooks.list_attempts(delivery) == [existing_attempt]

    assert_received {:telemetry_event, @delivery_error, %{count: 1, duration_ms: duration_ms},
                     %{reason: "persistence"}}

    assert is_integer(duration_ms)
    assert duration_ms >= 0
    refute_received {:telemetry_event, @delivery_processed, _, _}
    refute_received {:retry_telemetry, _, _, _, _, _, _}
  end

  @doc false
  def handle_telemetry(event_name, measurements, metadata, test_pid) do
    send(test_pid, {:telemetry_event, event_name, measurements, metadata})
  end

  @doc false
  def handle_cancelled_telemetry(event_name, measurements, metadata, {test_pid, delivery_id}) do
    send(
      test_pid,
      {:cancelled_telemetry, event_name, measurements, metadata,
       Webhooks.get_delivery(delivery_id)}
    )
  end

  @doc false
  def handle_retry_telemetry(event_name, measurements, metadata, {test_pid, delivery_id}) do
    persisted_delivery = Webhooks.get_delivery(delivery_id)

    send(
      test_pid,
      {:retry_telemetry, event_name, measurements, metadata, persisted_delivery,
       Webhooks.list_attempts(persisted_delivery), Repo.all(Oban.Job)}
    )
  end

  defp attach_telemetry(event_name) do
    handler_id = {__MODULE__, event_name, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        event_name,
        &__MODULE__.handle_telemetry/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp attach_cancelled_telemetry(delivery_id) do
    handler_id = {__MODULE__, @delivery_cancelled, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        @delivery_cancelled,
        &__MODULE__.handle_cancelled_telemetry/4,
        {self(), delivery_id}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp attach_retry_telemetry(event_name, delivery_id) do
    handler_id = {__MODULE__, event_name, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        event_name,
        &__MODULE__.handle_retry_telemetry/4,
        {self(), delivery_id}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp assert_pending_without_attempt(delivery) do
    persisted = Webhooks.get_delivery(delivery.id)
    assert persisted.status == "pending"
    assert persisted.attempt_count == 0
    assert persisted.completed_at == nil
    assert Webhooks.list_attempts(delivery) == []
  end

  defp header(headers, name) do
    {^name, value} = List.keyfind(headers, name, 0)
    value
  end

  defp expected_http_delivery_status(status) when status in 200..299, do: "succeeded"

  defp expected_http_delivery_status(status)
       when status in [408, 425, 429, 500, 502, 503, 504],
       do: "pending"

  defp expected_http_delivery_status(_status), do: "failed"

  defp delivery_fixture(endpoint_url \\ "https://endpoint.invalid/webhooks") do
    {:ok, event} =
      Webhooks.create_event(%{
        external_id: "evt_processor",
        event_type: "order.created",
        payload: %{"order" => %{"id" => "123"}}
      })

    {:ok, endpoint} =
      Webhooks.create_endpoint(%{
        name: "Local validation",
        url: endpoint_url
      })

    {:ok, delivery} = Webhooks.create_delivery(event, endpoint)
    delivery
  end
end
