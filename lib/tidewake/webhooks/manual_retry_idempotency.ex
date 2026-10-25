defmodule Tidewake.Webhooks.ManualRetryIdempotency do
  @moduledoc """
  Derives digest-only identity for a versioned manual retry request.

  This module performs no persistence, logging, configuration lookup, or actor
  validation. Raw keys are used only to derive their digest and are not returned.
  """

  @minimum_key_size 16
  @maximum_key_size 128
  @fingerprint_size 64
  @key_format ~r/\A[A-Za-z0-9._~-]+\z/
  @fingerprint_format ~r/\A[0-9a-f]{64}\z/

  @type prepared :: %{
          idempotency_key_digest: binary(),
          request_fingerprint: binary()
        }
  @type error_reason :: :invalid_idempotency_key | :invalid_delivery_id

  @doc """
  Validates a positive integer delivery ID and a bounded ASCII key.

  Returns lowercase SHA-256 digests of the exact key bytes and of
  `manual_retry:v1:delivery:<id>`, with the ID in base-10 decimal form.
  Keys are never trimmed or case-folded. Invalid delivery IDs take precedence.
  """
  @spec prepare(term(), term()) :: {:ok, prepared()} | {:error, error_reason()}
  def prepare(delivery_id, raw_key) when is_integer(delivery_id) and delivery_id > 0 do
    if valid_key?(raw_key) do
      canonical_request = "manual_retry:v1:delivery:" <> Integer.to_string(delivery_id)

      {:ok,
       %{
         idempotency_key_digest: sha256(raw_key),
         request_fingerprint: sha256(canonical_request)
       }}
    else
      {:error, :invalid_idempotency_key}
    end
  end

  def prepare(_delivery_id, _raw_key), do: {:error, :invalid_delivery_id}

  @doc """
  Compares two valid 64-byte lowercase hexadecimal fingerprints in constant time.

  Malformed values return false without invoking the fixed-size comparison.
  """
  @spec same_fingerprint?(term(), term()) :: boolean()
  def same_fingerprint?(left, right)
      when is_binary(left) and byte_size(left) == @fingerprint_size and
             is_binary(right) and byte_size(right) == @fingerprint_size do
    Regex.match?(@fingerprint_format, left) and Regex.match?(@fingerprint_format, right) and
      Plug.Crypto.secure_compare(left, right)
  end

  def same_fingerprint?(_left, _right), do: false

  defp valid_key?(raw_key)
       when is_binary(raw_key) and byte_size(raw_key) >= @minimum_key_size and
              byte_size(raw_key) <= @maximum_key_size,
       do: Regex.match?(@key_format, raw_key)

  defp valid_key?(_raw_key), do: false

  defp sha256(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end
end
