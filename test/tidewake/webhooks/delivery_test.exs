defmodule Tidewake.Webhooks.DeliveryTest do
  use Tidewake.DataCase, async: true

  alias Tidewake.Webhooks.{Delivery, Endpoint, Event}

  describe "schema" do
    test "maps event and endpoint associations" do
      event_association = Delivery.__schema__(:association, :event)
      endpoint_association = Delivery.__schema__(:association, :endpoint)

      assert event_association.related == Event
      assert event_association.owner_key == :event_id
      assert endpoint_association.related == Endpoint
      assert endpoint_association.owner_key == :endpoint_id
    end

    test "maps lifecycle fields and microsecond UTC timestamps" do
      delivery = %Delivery{}

      assert delivery.status == "pending"
      assert delivery.attempt_count == 0
      assert Delivery.__schema__(:type, :status) == :string
      assert Delivery.__schema__(:type, :attempt_count) == :integer
      assert Delivery.__schema__(:type, :next_attempt_at) == :utc_datetime_usec
      assert Delivery.__schema__(:type, :completed_at) == :utc_datetime_usec
      assert Delivery.__schema__(:type, :inserted_at) == :utc_datetime_usec
      assert Delivery.__schema__(:type, :updated_at) == :utc_datetime_usec
    end
  end

  describe "changeset/2" do
    test "accepts association IDs set programmatically" do
      changeset = valid_changeset()

      assert changeset.valid?
      assert get_field(changeset, :event_id) == 1
      assert get_field(changeset, :endpoint_id) == 2
      assert get_field(changeset, :status) == "pending"
      assert get_field(changeset, :attempt_count) == 0
    end

    test "does not cast association IDs from attributes" do
      changeset =
        Delivery.changeset(%Delivery{}, %{
          event_id: 1,
          endpoint_id: 2
        })

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).event_id
      assert "can't be blank" in errors_on(changeset).endpoint_id
      refute Map.has_key?(changeset.changes, :event_id)
      refute Map.has_key?(changeset.changes, :endpoint_id)
    end

    test "does not replace programmatic association IDs from attributes" do
      changeset = valid_changeset(%{event_id: 3, endpoint_id: 4})

      assert changeset.valid?
      assert get_field(changeset, :event_id) == 1
      assert get_field(changeset, :endpoint_id) == 2
    end

    test "accepts every status defined by the initial lifecycle" do
      for status <- ~w(pending processing succeeded failed) do
        assert valid_changeset(%{status: status}).valid?
      end
    end

    test "rejects a status outside the initial lifecycle" do
      changeset = valid_changeset(%{status: "exhausted"})

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).status
    end

    test "accepts a non-negative attempt count" do
      assert valid_changeset(%{attempt_count: 0}).valid?
      assert valid_changeset(%{attempt_count: 3}).valid?
    end

    test "rejects a negative attempt count" do
      changeset = valid_changeset(%{attempt_count: -1})

      refute changeset.valid?
      assert "must be greater than or equal to 0" in errors_on(changeset).attempt_count
    end

    test "rejects an invalid attempt count" do
      changeset = valid_changeset(%{attempt_count: "not-an-integer"})

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).attempt_count
    end

    test "casts optional lifecycle timestamps without changing precision" do
      next_attempt_at = ~U[2026-09-09 03:30:00.123456Z]
      completed_at = ~U[2026-09-09 03:31:00.654321Z]

      changeset =
        valid_changeset(%{
          next_attempt_at: next_attempt_at,
          completed_at: completed_at
        })

      assert changeset.valid?
      assert get_change(changeset, :next_attempt_at) == next_attempt_at
      assert get_change(changeset, :completed_at) == completed_at
    end

    test "declares the event and endpoint unique constraint" do
      changeset = valid_changeset()

      assert Enum.any?(changeset.constraints, fn constraint ->
               constraint.type == :unique and constraint.field == :event_id and
                 constraint.constraint == "deliveries_event_id_endpoint_id_index"
             end)
    end
  end

  defp valid_changeset(overrides \\ %{}) do
    delivery = %Delivery{event_id: 1, endpoint_id: 2}

    Delivery.changeset(delivery, overrides)
  end
end
