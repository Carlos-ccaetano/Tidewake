defmodule Tidewake.Webhooks.OutboundTarget do
  @moduledoc """
  Prepares a persisted webhook URL as a validated, IP-pinned connection target.
  """

  alias Tidewake.Webhooks.OutboundAddress

  @max_url_bytes 2_048
  @allowed_categories %{
    public: [:global],
    local: [:global, :private, :loopback]
  }

  @enforce_keys [:connection_url, :hostname, :address, :scheme, :port]
  defstruct @enforce_keys

  @type mode :: :public | :local
  @type t :: %__MODULE__{
          connection_url: String.t(),
          hostname: String.t(),
          address: :inet.ip_address(),
          scheme: String.t(),
          port: :inet.port_number()
        }

  @spec prepare(String.t(), module(), mode()) ::
          {:ok, t()} | {:error, :unsafe_destination | :dns_error}
  def prepare(url, resolver, mode) when is_binary(url) and is_atom(resolver) do
    with {:ok, uri} <- parse_url(url, mode),
         {:ok, addresses} <- resolve_addresses(uri.host, resolver),
         {:ok, address} <- select_address(addresses, mode) do
      {:ok,
       %__MODULE__{
         connection_url: connection_url(uri, address),
         hostname: uri.host,
         address: address,
         scheme: uri.scheme,
         port: uri.port
       }}
    end
  end

  def prepare(_url, _resolver, _mode), do: {:error, :unsafe_destination}

  defp parse_url(url, mode) do
    with true <- byte_size(url) <= @max_url_bytes,
         true <- Map.has_key?(@allowed_categories, mode),
         {:ok, uri} <- URI.new(url),
         true <- valid_uri?(uri) do
      {:ok, uri}
    else
      _invalid -> {:error, :unsafe_destination}
    end
  end

  defp valid_uri?(%URI{
         scheme: scheme,
         host: host,
         port: port,
         userinfo: nil,
         fragment: nil
       }) do
    scheme in ["http", "https"] and is_binary(host) and String.trim(host) != "" and
      is_integer(port) and port >= 1 and port <= 65_535
  end

  defp valid_uri?(_uri), do: false

  defp resolve_addresses(hostname, resolver) do
    case :inet.parse_address(String.to_charlist(hostname)) do
      {:ok, address} ->
        {:ok, [address]}

      {:error, _reason} ->
        normalize_resolution(resolver.resolve(hostname))
    end
  end

  defp normalize_resolution({:ok, []}), do: {:error, :dns_error}
  defp normalize_resolution({:ok, addresses}) when is_list(addresses), do: {:ok, addresses}
  defp normalize_resolution(_result), do: {:error, :dns_error}

  defp select_address([], _mode), do: {:error, :dns_error}

  defp select_address(addresses, mode) do
    allowed_categories = Map.fetch!(@allowed_categories, mode)
    classifications = Enum.map(addresses, &OutboundAddress.classify/1)

    if Enum.all?(classifications, &(&1 in allowed_categories)) do
      {:ok, hd(addresses)}
    else
      {:error, :unsafe_destination}
    end
  end

  defp connection_url(uri, address) do
    host = address |> :inet.ntoa() |> List.to_string() |> connection_host(address)
    path = uri.path || ""
    query = if uri.query, do: "?" <> uri.query, else: ""

    "#{uri.scheme}://#{host}:#{uri.port}#{path}#{query}"
  end

  defp connection_host(host, address) when tuple_size(address) == 8, do: "[#{host}]"
  defp connection_host(host, _address), do: host
end
