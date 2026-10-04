defmodule Tidewake.Webhooks.Signature do
  @moduledoc """
  Builds versioned webhook signature headers from explicit request data.
  """

  @minimum_secret_size 32

  @type error_reason ::
          :invalid_event_id | :invalid_timestamp | :invalid_body | :invalid_secret
  @type header :: {binary(), binary()}

  @doc """
  Returns the version 1 signature headers for the exact body bytes.

  The timestamp is encoded as base-10 Unix seconds. No body normalization or
  encoding is performed.
  """
  @spec headers(binary(), non_neg_integer(), binary(), binary()) ::
          {:ok, [header()]} | {:error, error_reason()}
  def headers(event_id, timestamp, body, secret) do
    with :ok <- validate_event_id(event_id),
         :ok <- validate_timestamp(timestamp),
         :ok <- validate_body(body),
         :ok <- validate_secret(secret) do
      timestamp = Integer.to_string(timestamp)
      canonical = IO.iodata_to_binary(["v1.", event_id, ".", timestamp, ".", body])

      signature =
        :crypto.mac(:hmac, :sha256, secret, canonical)
        |> Base.encode16(case: :lower)
        |> then(&("v1=" <> &1))

      {:ok,
       [
         {"Tidewake-Id", event_id},
         {"Tidewake-Timestamp", timestamp},
         {"Tidewake-Signature", signature}
       ]}
    end
  end

  defp validate_event_id(event_id) when is_binary(event_id) and byte_size(event_id) > 0,
    do: :ok

  defp validate_event_id(_event_id), do: {:error, :invalid_event_id}

  defp validate_timestamp(timestamp) when is_integer(timestamp) and timestamp >= 0, do: :ok
  defp validate_timestamp(_timestamp), do: {:error, :invalid_timestamp}

  defp validate_body(body) when is_binary(body), do: :ok
  defp validate_body(_body), do: {:error, :invalid_body}

  defp validate_secret(secret)
       when is_binary(secret) and byte_size(secret) >= @minimum_secret_size,
       do: :ok

  defp validate_secret(_secret), do: {:error, :invalid_secret}
end
