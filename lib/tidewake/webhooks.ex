defmodule Tidewake.Webhooks do
  @moduledoc """
  Manages webhook events, destination endpoints, and their persistence.
  """

  import Ecto.Query, only: [from: 2]

  alias Tidewake.Repo
  alias Tidewake.Webhooks.{Attempt, Delivery, Endpoint, Event}

  def create_event(attrs) do
    %Event{}
    |> Event.changeset(attrs)
    |> Repo.insert()
  end

  def get_event(id) do
    Repo.get(Event, id)
  end

  def get_event_by_external_id(external_id) do
    Repo.get_by(Event, external_id: external_id)
  end

  def create_delivery(%Event{} = event, %Endpoint{active: true} = endpoint) do
    %Delivery{event_id: event.id, endpoint_id: endpoint.id}
    |> Delivery.changeset(%{})
    |> Repo.insert()
  end

  def create_delivery(%Event{}, %Endpoint{active: false}) do
    {:error, :endpoint_inactive}
  end

  def get_delivery(id) do
    Repo.get(Delivery, id)
  end

  def get_delivery_by_event_and_endpoint(%Event{} = event, %Endpoint{} = endpoint) do
    Repo.get_by(Delivery, event_id: event.id, endpoint_id: endpoint.id)
  end

  def create_attempt(%Delivery{} = delivery, attrs) do
    %Attempt{delivery_id: delivery.id}
    |> Attempt.changeset(attrs)
    |> Repo.insert()
  end

  def get_attempt(id) do
    Repo.get(Attempt, id)
  end

  def list_attempts(%Delivery{} = delivery) do
    from(attempt in Attempt,
      where: attempt.delivery_id == ^delivery.id,
      order_by: [asc: attempt.attempt_number]
    )
    |> Repo.all()
  end

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
