defmodule Tidewake.Webhooks.SignatureTest do
  use ExUnit.Case, async: true

  alias Tidewake.Webhooks.Signature

  @secret "tidewake_test_secret_not_for_production"
  @event_id "evt_test_123"
  @timestamp 1_700_000_000
  @body ~S({"data":{"ok":true},"id":"evt_test_123","type":"test.ping"})

  test "produces the exact ADR vector and all three headers" do
    assert Signature.headers(@event_id, @timestamp, @body, @secret) ==
             {:ok,
              [
                {"Tidewake-Id", "evt_test_123"},
                {"Tidewake-Timestamp", "1700000000"},
                {"Tidewake-Signature",
                 "v1=3323d158355377e1b2d7515e31a40365a48ff11d427a8a8f62cfda1e4bf92128"}
              ]}
  end

  test "signs the exact body bytes" do
    body = <<"{\"message\":\"caf", 0xC3, 0xA9, "\"}\r\n">>

    assert {:ok, headers} = Signature.headers(@event_id, @timestamp, body, @secret)

    assert header(headers, "Tidewake-Signature") ==
             expected_signature(@event_id, @timestamp, body, @secret)

    assert {:ok, changed_headers} =
             Signature.headers(@event_id, @timestamp, body <> "\n", @secret)

    refute header(changed_headers, "Tidewake-Signature") ==
             header(headers, "Tidewake-Signature")
  end

  test "changes the signature when the event ID, timestamp or body changes" do
    assert {:ok, headers} = Signature.headers(@event_id, @timestamp, @body, @secret)
    original = header(headers, "Tidewake-Signature")

    for {event_id, timestamp, body} <- [
          {"evt_test_124", @timestamp, @body},
          {@event_id, @timestamp + 1, @body},
          {@event_id, @timestamp, @body <> " "}
        ] do
      assert {:ok, changed_headers} = Signature.headers(event_id, timestamp, body, @secret)
      refute header(changed_headers, "Tidewake-Signature") == original
    end
  end

  test "does not normalize or re-encode JSON" do
    compact = ~S({"a":1,"b":2})
    reordered = ~S({ "b": 2, "a": 1 })
    assert Jason.decode!(compact) == Jason.decode!(reordered)

    assert {:ok, compact_headers} =
             Signature.headers(@event_id, @timestamp, compact, @secret)

    assert {:ok, reordered_headers} =
             Signature.headers(@event_id, @timestamp, reordered, @secret)

    refute header(compact_headers, "Tidewake-Signature") ==
             header(reordered_headers, "Tidewake-Signature")
  end

  test "rejects an invalid event ID" do
    for event_id <- ["", nil, 123] do
      assert Signature.headers(event_id, @timestamp, @body, @secret) ==
               {:error, :invalid_event_id}
    end
  end

  test "rejects an invalid timestamp" do
    for timestamp <- [-1, "1700000000", 1.5, nil] do
      assert Signature.headers(@event_id, timestamp, @body, @secret) ==
               {:error, :invalid_timestamp}
    end
  end

  test "rejects a non-binary body" do
    for body <- [%{"ok" => true}, ["body"], nil] do
      assert Signature.headers(@event_id, @timestamp, body, @secret) ==
               {:error, :invalid_body}
    end
  end

  test "rejects an invalid secret" do
    for secret <- ["", String.duplicate("s", 31), nil, 123] do
      assert Signature.headers(@event_id, @timestamp, @body, secret) ==
               {:error, :invalid_secret}
    end
  end

  defp header(headers, name) do
    {^name, value} = List.keyfind(headers, name, 0)
    value
  end

  defp expected_signature(event_id, timestamp, body, secret) do
    canonical =
      IO.iodata_to_binary(["v1.", event_id, ".", Integer.to_string(timestamp), ".", body])

    :crypto.mac(:hmac, :sha256, secret, canonical)
    |> Base.encode16(case: :lower)
    |> then(&("v1=" <> &1))
  end
end
