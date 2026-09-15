defmodule Tidewake.Webhooks.DeliveryAdapters.Req do
  @moduledoc """
  Req-backed transport for delivering an already serialized webhook body.

  This adapter only performs the HTTP request and normalizes bounded transport
  outcomes. Delivery classification and persistence remain the caller's
  responsibility.
  """

  @behaviour Tidewake.Webhooks.DeliveryAdapter

  @request_options [
    method: :post,
    retry: false,
    redirect: false,
    http_errors: :return,
    connect_options: [timeout: 5_000],
    receive_timeout: 10_000,
    request_timeout: 15_000,
    compressed: false,
    decode_body: false
  ]

  @impl true
  def deliver(url, body, headers) do
    options =
      Application.get_env(:tidewake, __MODULE__, [])
      |> Keyword.merge(@request_options)
      |> Keyword.merge(url: url, body: body, headers: headers)

    case Elixir.Req.request(options) do
      {:ok, %Elixir.Req.Response{} = response} ->
        {:ok,
         %{
           status: response.status,
           headers: Elixir.Req.get_headers_list(response)
         }}

      {:error, %Elixir.Req.TransportError{reason: reason}} ->
        {:error, normalize_transport_error(reason)}

      {:error, %Elixir.Req.HTTPError{}} ->
        {:error, :unknown}

      {:error, exception} ->
        raise exception
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
