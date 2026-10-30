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
          request_fingerprint: binary(),
          request_fingerprint_version: 1 | 2
        }
  @type error_reason ::
          :invalid_idempotency_key | :invalid_delivery_id | :invalid_project_public_id

  @doc """
  Explicit version-1 compatibility for the internal command and historical replay.

  Returns lowercase SHA-256 digests of the exact key bytes and of
  `manual_retry:v1:delivery:<id>`, with the ID in base-10 decimal form.
  Keys are never trimmed or case-folded. Invalid delivery IDs take precedence.
  """
  @spec prepare(term(), term()) :: {:ok, prepared()} | {:error, error_reason()}
  def prepare(delivery_id, raw_key) when is_integer(delivery_id) and delivery_id > 0 do
    prepare_request(raw_key, 1, "manual_retry:v1:delivery:" <> Integer.to_string(delivery_id))
  end

  def prepare(_delivery_id, _raw_key), do: {:error, :invalid_delivery_id}

  @doc """
  Prepares version 2 from a trusted project's canonical public UUID and delivery ID.

  Hashes exactly `manual_retry:v2:project:<uuid>:delivery:<id>` with no newline.
  Rejects noncanonical UUIDs rather than normalizing caller input. Invalid delivery
  IDs take precedence, followed by invalid project identity and invalid keys.
  """
  @spec prepare(term(), term(), term()) :: {:ok, prepared()} | {:error, error_reason()}
  def prepare(project_public_id, delivery_id, raw_key)
      when is_integer(delivery_id) and delivery_id > 0 do
    if canonical_project?(project_public_id) do
      canonical =
        "manual_retry:v2:project:" <>
          project_public_id <> ":delivery:" <> Integer.to_string(delivery_id)

      prepare_request(raw_key, 2, canonical)
    else
      {:error, :invalid_project_public_id}
    end
  end

  def prepare(_project_public_id, _delivery_id, _raw_key), do: {:error, :invalid_delivery_id}

  @doc """
  Matches only a supported, identical stored version and its constant-time digest.

  Legacy replay requires an explicit version-1 prepared request. Unknown versions,
  malformed identities and cross-version matches fail closed without a fallback.
  """
  @spec same_request?(term(), term()) :: boolean()
  def same_request?(
        %{request_fingerprint_version: stored_version, request_fingerprint: stored},
        %{request_fingerprint_version: version, request_fingerprint: candidate}
      )
      when version in [1, 2] and stored_version === version,
      do: same_fingerprint?(stored, candidate)

  def same_request?(_stored, _candidate), do: false

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

  defp canonical_project?(value) when is_binary(value) and byte_size(value) == 36,
    do: Ecto.UUID.cast(value) == {:ok, value}

  defp canonical_project?(_value), do: false

  defp prepare_request(raw_key, version, canonical) do
    if valid_key?(raw_key) do
      {:ok,
       %{
         idempotency_key_digest: sha256(raw_key),
         request_fingerprint: sha256(canonical),
         request_fingerprint_version: version
       }}
    else
      {:error, :invalid_idempotency_key}
    end
  end

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
