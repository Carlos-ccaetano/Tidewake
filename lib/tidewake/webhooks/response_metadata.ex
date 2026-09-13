defmodule Tidewake.Webhooks.ResponseMetadata do
  @moduledoc """
  Extracts only bounded response metadata from adapter headers.

  Unknown headers and invalid values are ignored. The first valid value wins
  when a header is repeated. Callers must not place secrets in metadata headers.
  """

  @spec extract(Tidewake.Webhooks.DeliveryAdapter.headers()) :: map() | nil
  def extract(headers) when is_list(headers) do
    metadata = Enum.reduce(headers, %{}, &extract_header/2)
    if map_size(metadata) == 0, do: nil, else: metadata
  end

  defp extract_header({name, value}, metadata) when is_binary(name) and is_binary(value) do
    case String.downcase(name, :ascii) do
      "content-type" -> put_string(metadata, "content_type", value)
      "x-request-id" -> put_string(metadata, "request_id", value)
      "content-length" -> put_length(metadata, value)
      _other -> metadata
    end
  end

  defp extract_header(_header, metadata), do: metadata

  defp put_string(metadata, key, value) do
    if byte_size(value) <= 255 and String.valid?(value) do
      Map.put_new(metadata, key, value)
    else
      metadata
    end
  end

  defp put_length(metadata, value) do
    if Regex.match?(~r/\A[0-9]+\z/, value) do
      Map.put_new(metadata, "content_length", String.to_integer(value))
    else
      metadata
    end
  end
end
