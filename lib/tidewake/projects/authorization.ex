defmodule Tidewake.Projects.Authorization do
  @moduledoc "Pure, default-deny permissions for an already authenticated Scope."

  alias Tidewake.Projects.Scope

  def allowed?(%Scope{role: role}, :resources_read) when role in ~w(admin producer viewer),
    do: true

  def allowed?(%Scope{role: role}, :events_write) when role in ~w(admin producer),
    do: true

  def allowed?(%Scope{role: "admin"}, :endpoints_write), do: true
  def allowed?(%Scope{role: "admin"}, :manual_retries_write), do: true
  def allowed?(%Scope{role: "admin"}, :manual_retry_audit_read), do: true
  def allowed?(_scope, _permission), do: false
end
