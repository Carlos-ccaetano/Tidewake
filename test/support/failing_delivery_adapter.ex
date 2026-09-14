defmodule Tidewake.FailingDeliveryAdapter do
  @moduledoc false

  @behaviour Tidewake.Webhooks.DeliveryAdapter

  @impl true
  def deliver(url, _body, _headers) do
    case URI.parse(url).path do
      "/http-error" -> {:ok, %{status: 503, headers: []}}
      "/timeout" -> {:error, :timeout}
    end
  end
end
