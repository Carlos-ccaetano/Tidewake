defmodule Tidewake.Webhooks.DeliveryAdapters.ResponseLimiterTest do
  use ExUnit.Case, async: true

  alias Tidewake.Webhooks.DeliveryAdapters.ResponseLimiter

  test "accepts a response with zero body bytes" do
    {_request, response, chunks_consumed} = consume([], 10)

    assert response.body == ""
    refute ResponseLimiter.exceeded?(response)
    assert chunks_consumed == 0
  end

  test "counts and discards several chunks below the limit" do
    {_request, response, chunks_consumed} = consume(["abc", "de", "fghi"], 10)

    assert response.body == ""
    assert response.private.tidewake_response_limiter_bytes_received == 9
    refute ResponseLimiter.exceeded?(response)
    assert chunks_consumed == 3
  end

  test "accepts exactly the configured byte limit" do
    {_request, response, chunks_consumed} = consume(["abc", "def"], 6)

    assert response.body == ""
    assert response.private.tidewake_response_limiter_bytes_received == 6
    refute ResponseLimiter.exceeded?(response)
    assert chunks_consumed == 2
  end

  test "halts on the first chunk that exceeds the limit by one byte" do
    {_request, response, chunks_consumed} = consume(["abc", "defg", "not consumed"], 6)

    assert response.body == ""
    assert response.private.tidewake_response_limiter_bytes_received == 7
    assert response.private.tidewake_response_limiter_exceeded
    assert ResponseLimiter.exceeded?(response)
    assert chunks_consumed == 2
  end

  test "halts when the first chunk is larger than the limit" do
    {_request, response, chunks_consumed} = consume(["12345", "not consumed"], 4)

    assert response.body == ""
    assert response.private.tidewake_response_limiter_bytes_received == 5
    assert ResponseLimiter.exceeded?(response)
    assert chunks_consumed == 1
  end

  test "does not accumulate a pre-existing response body" do
    callback = ResponseLimiter.into(10)
    request = Req.new()
    response = Req.Response.new(body: "discard me")

    assert {:cont, {^request, response}} = callback.({:data, "chunk"}, {request, response})
    assert response.body == ""
  end

  test "does not use content-length to decide whether to halt" do
    response = Req.Response.new(headers: [{"content-length", "1"}])

    {_request, response, chunks_consumed} = consume(["1234", "5678"], 8, response)

    refute ResponseLimiter.exceeded?(response)
    assert response.private.tidewake_response_limiter_bytes_received == 8
    assert chunks_consumed == 2
  end

  defp consume(chunks, limit, response \\ Req.Response.new()) do
    callback = ResponseLimiter.into(limit)
    request = Req.new()

    {request, response, chunks_consumed} =
      Enum.reduce_while(chunks, {request, response, 0}, fn chunk, {request, response, count} ->
        case callback.({:data, chunk}, {request, response}) do
          {:cont, {request, response}} ->
            {:cont, {request, response, count + 1}}

          {:halt, {request, response}} ->
            {:halt, {request, response, count + 1}}
        end
      end)

    {request, response, chunks_consumed}
  end
end
