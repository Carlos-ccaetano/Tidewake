defmodule Tidewake.Webhooks.ResponseMetadataTest do
  use ExUnit.Case, async: true

  alias Tidewake.Webhooks.ResponseMetadata

  test "returns nil without allowed metadata" do
    assert ResponseMetadata.extract([]) == nil
    assert ResponseMetadata.extract([{"server", "local"}]) == nil
  end

  test "extracts only string keys with case-insensitive header names" do
    assert ResponseMetadata.extract([
             {"Content-Type", "application/json"},
             {"CONTENT-LENGTH", "0042"},
             {"X-Request-ID", "req_123"},
             {"server", "local"}
           ]) == %{
             "content_type" => "application/json",
             "content_length" => 42,
             "request_id" => "req_123"
           }
  end

  test "ignores sensitive headers regardless of case" do
    headers = [
      {"Authorization", "Bearer secret"},
      {"Cookie", "session=secret"},
      {"Set-Cookie", "session=secret"},
      {"X-API-Key", "secret"},
      {"Signature", "secret"},
      {"X-Webhook-Signature", "secret"},
      {"body", "secret"}
    ]

    assert ResponseMetadata.extract(headers) == nil

    assert ResponseMetadata.extract(headers ++ [{"content-length", "0"}]) ==
             %{"content_length" => 0}
  end

  test "enforces string limits in bytes without truncation" do
    for {header, key} <- [{"content-type", "content_type"}, {"x-request-id", "request_id"}] do
      boundary = String.duplicate("é", 127) <> "a"
      assert ResponseMetadata.extract([{header, boundary}]) == %{key => boundary}
      assert ResponseMetadata.extract([{header, boundary <> "b"}]) == nil
      assert ResponseMetadata.extract([{header, String.duplicate("é", 128)}]) == nil
      assert ResponseMetadata.extract([{header, <<255>>}]) == nil
      assert ResponseMetadata.extract([{header, 42}]) == nil
    end
  end

  test "ignores invalid content lengths rather than parsing a prefix" do
    for value <- ["", "-1", "+1", "1.5", "42bytes", " 42", "42 ", "1\n", "1,2", "abc", 42] do
      assert ResponseMetadata.extract([{"content-length", value}]) == nil
    end
  end

  test "ignores invalid entries while preserving valid metadata" do
    assert ResponseMetadata.extract([
             {"content-type", String.duplicate("a", 256)},
             {"content-length", "-1"},
             {"x-request-id", "req_valid"},
             {:authorization, "secret"},
             nil
           ]) == %{"request_id" => "req_valid"}
  end

  test "keeps the first valid value for duplicate headers" do
    assert ResponseMetadata.extract([
             {"content-length", "invalid"},
             {"Content-Length", "12"},
             {"CONTENT-LENGTH", "24"},
             {"x-request-id", "first"},
             {"X-Request-Id", "second"}
           ]) == %{"content_length" => 12, "request_id" => "first"}
  end
end
