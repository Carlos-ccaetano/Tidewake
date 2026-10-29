defmodule Tidewake.Projects.ServiceAccountToken do
  @moduledoc "Canonical opaque credentials and redacted one-time issuance results."

  @derive {Inspect, except: [:token, :digest]}
  defstruct [:credential, :token, :digest]

  def generate(public_id) do
    if canonical_uuid?(public_id) do
      secret = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      token = "twk_sa." <> public_id <> "." <> secret

      with {:ok, digest} <- digest(token) do
        {:ok, %__MODULE__{token: token, digest: digest}}
      end
    else
      {:error, :invalid_token}
    end
  end

  def parse(<<"twk_sa.", public_id::binary-size(36), ".", secret::binary-size(43)>>) do
    with true <- canonical_uuid?(public_id),
         true <- Regex.match?(~r/\A[A-Za-z0-9_-]{43}\z/, secret),
         {:ok, decoded} <- Base.url_decode64(secret, padding: false),
         true <- byte_size(decoded) == 32,
         true <- Base.url_encode64(decoded, padding: false) == secret do
      {:ok, public_id}
    else
      _invalid -> {:error, :invalid_token}
    end
  end

  def parse(_token), do: {:error, :invalid_token}

  def digest(token) do
    digest(token, Application.fetch_env!(:tidewake, :service_account_token_pepper))
  rescue
    ArgumentError -> {:error, :invalid_pepper}
  end

  def digest(token, pepper) when is_binary(pepper) and byte_size(pepper) >= 32 do
    with {:ok, _public_id} <- parse(token) do
      {:ok, :crypto.mac(:hmac, :sha256, pepper, token)}
    end
  end

  def digest(_token, _pepper), do: {:error, :invalid_pepper}

  def secure_match?(left, right)
      when is_binary(left) and byte_size(left) == 32 and is_binary(right) and
             byte_size(right) == 32,
      do: Plug.Crypto.secure_compare(left, right)

  def secure_match?(_left, _right), do: false

  defp canonical_uuid?(uuid) when is_binary(uuid) and byte_size(uuid) == 36,
    do: Ecto.UUID.cast(uuid) == {:ok, uuid}

  defp canonical_uuid?(_uuid), do: false
end
