defmodule Tidewake.Webhooks do
  @moduledoc """
  Manages webhook destination endpoints and their persistence.
  """

  alias Tidewake.Repo
  alias Tidewake.Webhooks.Endpoint

  def list_endpoints do
    Repo.all(Endpoint)
  end

  def get_endpoint(id) do
    Repo.get(Endpoint, id)
  end

  def create_endpoint(attrs \\ %{}) do
    %Endpoint{}
    |> Endpoint.changeset(attrs)
    |> Repo.insert()
  end

  def update_endpoint(%Endpoint{} = endpoint, attrs) do
    endpoint
    |> Endpoint.changeset(attrs)
    |> Repo.update()
  end

  def change_endpoint(%Endpoint{} = endpoint, attrs \\ %{}) do
    Endpoint.changeset(endpoint, attrs)
  end
end
