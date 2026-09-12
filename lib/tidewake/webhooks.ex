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

  def claim_delivery(id) do
    now = DateTime.utc_now()

    query =
      from(delivery in Delivery,
        where: delivery.id == ^id and delivery.status == "pending",
        select: delivery
      )

    case Repo.update_all(query, set: [status: "processing", updated_at: now]) do
      {1, [delivery]} -> {:ok, Repo.preload(delivery, [:event, :endpoint])}
      {0, []} -> claim_delivery_error(id)
    end
  end

  def finalize_delivery(delivery_id, attempt_attrs) do
    Repo.transaction(fn ->
      query = from(delivery in Delivery, where: delivery.id == ^delivery_id, lock: "FOR UPDATE")

      case Repo.one(query) do
        nil ->
          Repo.rollback(:not_found)

        %Delivery{status: "processing"} = delivery ->
          finalize_processing_delivery(delivery, attempt_attrs)

        %Delivery{} ->
          Repo.rollback(:invalid_transition)
      end
    end)
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

  defp finalize_processing_delivery(delivery, attrs) do
    attempt_changeset =
      %Attempt{delivery_id: delivery.id, attempt_number: delivery.attempt_count + 1}
      |> Attempt.changeset(Map.drop(attrs, [:attempt_number, "attempt_number"]))

    with {:ok, attempt} <- Repo.insert(attempt_changeset),
         {:ok, finalized} <-
           delivery
           |> Delivery.changeset(%{
             status: if(attempt.result == "succeeded", do: "succeeded", else: "failed"),
             attempt_count: delivery.attempt_count + 1,
             completed_at: attempt.completed_at
           })
           |> Repo.update() do
      %{delivery: finalized, attempt: attempt}
    else
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp claim_delivery_error(id) do
    case Repo.get(Delivery, id) do
      nil -> {:error, :not_found}
      %Delivery{} -> {:error, :invalid_transition}
    end
  end
end
