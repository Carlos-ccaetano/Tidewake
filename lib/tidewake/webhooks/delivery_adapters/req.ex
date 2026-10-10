defmodule Tidewake.Webhooks.DeliveryAdapters.Req do
  @moduledoc """
  Req-backed transport for delivering an already serialized webhook body.

  This adapter only performs the HTTP request and normalizes bounded transport
  outcomes. Delivery classification and persistence remain the caller's
  responsibility.
  """

  @behaviour Tidewake.Webhooks.DeliveryAdapter

  alias Tidewake.Webhooks.DeliveryAdapters.ResponseLimiter
  alias Tidewake.Webhooks.OutboundResolvers.System
  alias Tidewake.Webhooks.OutboundTarget

  @max_response_bytes 65_536
  @pool_max_idle_time 60_000

  @request_options [
    method: :post,
    retry: false,
    redirect: false,
    http_errors: :return,
    receive_timeout: 10_000,
    request_timeout: 15_000,
    compressed: false,
    decode_body: false
  ]

  @impl true
  def deliver(url, body, headers) do
    config = Application.get_env(:tidewake, __MODULE__, [])
    resolver = Keyword.get(config, :resolver, System)
    target_mode = Keyword.get(config, :target_mode, :public)

    with {:ok, target} <- OutboundTarget.prepare(url, resolver, target_mode) do
      config
      |> Keyword.drop([
        :resolver,
        :target_mode,
        :connect_options,
        :finch,
        :inet6,
        :pool_max_idle_time,
        :unix_socket
      ])
      |> Keyword.merge(request_options(target.hostname))
      |> Keyword.merge(url: target.connection_url, body: body, headers: headers)
      |> Elixir.Req.request()
      |> normalize_result()
    end
  end

  defp normalize_result(result) do
    case result do
      {:ok, %Elixir.Req.Response{} = response} ->
        normalize_response(response)

      {:error, %Elixir.Req.TransportError{reason: reason}} ->
        {:error, normalize_transport_error(reason)}

      {:error, %Elixir.Req.HTTPError{}} ->
        {:error, :unknown}

      {:error, exception} ->
        raise exception
    end
  end

  defp request_options(hostname) do
    @request_options
    |> Keyword.put(:finch,
      pool_max_idle_time: @pool_max_idle_time,
      protocols: [:http1],
      conn_opts: [
        hostname: hostname,
        transport_opts: [timeout: 5_000]
      ]
    )
    |> Keyword.put(:into, ResponseLimiter.into(@max_response_bytes))
  end

  defp normalize_response(response) do
    if ResponseLimiter.exceeded?(response) do
      {:error, :response_too_large}
    else
      {:ok,
       %{
         status: response.status,
         headers: Elixir.Req.get_headers_list(response)
       }}
    end
  end

  defp normalize_transport_error(:timeout), do: :timeout
  defp normalize_transport_error(:nxdomain), do: :dns_error
  defp normalize_transport_error(:econnrefused), do: :connection_refused
  defp normalize_transport_error(:closed), do: :connection_closed
  defp normalize_transport_error(:protocol_not_negotiated), do: :tls_error
  defp normalize_transport_error({:bad_alpn_protocol, _protocol}), do: :tls_error
  defp normalize_transport_error({:tls_alert, _alert}), do: :tls_error
  defp normalize_transport_error(_reason), do: :unknown
end
