defmodule Tidewake.Webhooks.DeliveryAdapters.ResponseLimiter do
  @moduledoc """
  Builds a Req response streaming callback that discards bounded response bodies.
  """

  @bytes_received_key :tidewake_response_limiter_bytes_received
  @exceeded_key :tidewake_response_limiter_exceeded

  @doc """
  Returns a Req `into:` callback that halts after receiving more than `limit` bytes.
  """
  @spec into(non_neg_integer()) ::
          ({:data, binary()}, {Req.Request.t(), Req.Response.t()} ->
             {:cont | :halt, {Req.Request.t(), Req.Response.t()}})
  def into(limit) when is_integer(limit) and limit >= 0 do
    fn {:data, chunk}, {request, response} ->
      consume_chunk(chunk, request, response, limit)
    end
  end

  @doc """
  Returns whether the response exceeded the configured limit.
  """
  @spec exceeded?(Req.Response.t()) :: boolean()
  def exceeded?(%Req.Response{} = response) do
    Req.Response.get_private(response, @exceeded_key, false)
  end

  defp consume_chunk(chunk, request, response, limit) when is_binary(chunk) do
    if exceeded?(response) do
      {:halt, {request, discard_body(response)}}
    else
      bytes_received =
        Req.Response.get_private(response, @bytes_received_key, 0) + byte_size(chunk)

      response =
        response
        |> discard_body()
        |> Req.Response.put_private(@bytes_received_key, bytes_received)

      if bytes_received > limit do
        {:halt, {request, Req.Response.put_private(response, @exceeded_key, true)}}
      else
        {:cont, {request, response}}
      end
    end
  end

  defp discard_body(response), do: %{response | body: ""}
end
