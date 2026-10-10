defmodule Tidewake.ReqOptionsCaptureAdapter do
  @moduledoc false

  def run(request) do
    send(self(), {:request, request})
    {request, Req.Response.new(status: 204)}
  end
end
