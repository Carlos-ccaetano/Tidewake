defmodule Tidewake.Webhooks.EventTest do
  use Tidewake.DataCase, async: true

  alias Tidewake.Webhooks.Event

  describe "schema" do
    test "maps event fields and microsecond UTC timestamps" do
      assert Event.__schema__(:source) == "events"
      assert Event.__schema__(:type, :external_id) == :string
      assert Event.__schema__(:type, :event_type) == :string
      assert Event.__schema__(:type, :payload) == :map
      assert Event.__schema__(:type, :inserted_at) == :utc_datetime_usec
      assert Event.__schema__(:type, :updated_at) == :utc_datetime_usec
    end
  end

  describe "changeset/2" do
    test "accepts valid attributes without transforming the payload" do
      payload = %{"order_id" => "123", "items" => [%{"sku" => "ABC", "quantity" => 2}]}

      changeset =
        Event.changeset(%Event{}, %{
          external_id: "evt_123",
          event_type: "order.created",
          payload: payload
        })

      assert changeset.valid?
      assert get_change(changeset, :payload) === payload
    end

    test "casts only external_id, event_type, and payload" do
      changeset =
        Event.changeset(%Event{}, %{
          external_id: "evt_123",
          event_type: "order.created",
          payload: %{},
          inserted_at: ~U[2026-09-07 10:00:00.000000Z],
          updated_at: ~U[2026-09-07 10:00:00.000000Z]
        })

      assert Map.keys(changeset.changes) |> Enum.sort() == [:event_type, :external_id, :payload]
    end

    test "requires all event fields" do
      changeset = Event.changeset(%Event{}, %{})

      assert "can't be blank" in errors_on(changeset).external_id
      assert "can't be blank" in errors_on(changeset).event_type
      assert "can't be blank" in errors_on(changeset).payload
    end

    test "rejects an empty or whitespace-only external_id" do
      for external_id <- ["", "   "] do
        changeset = valid_changeset(%{external_id: external_id})

        assert "can't be blank" in errors_on(changeset).external_id
      end
    end

    test "rejects an empty or whitespace-only event_type" do
      for event_type <- ["", "   "] do
        changeset = valid_changeset(%{event_type: event_type})

        assert "can't be blank" in errors_on(changeset).event_type
      end
    end

    test "accepts strings up to the database column limit" do
      max_length_value = String.duplicate("a", 255)

      changeset =
        valid_changeset(%{external_id: max_length_value, event_type: max_length_value})

      assert changeset.valid?
    end

    test "rejects strings longer than the database columns" do
      too_long_value = String.duplicate("a", 256)

      changeset =
        valid_changeset(%{external_id: too_long_value, event_type: too_long_value})

      errors = errors_on(changeset)
      assert "should be at most 255 character(s)" in errors.external_id
      assert "should be at most 255 character(s)" in errors.event_type
    end

    test "accepts only a map as payload" do
      for payload <- [[], "payload", 123, true] do
        changeset = valid_changeset(%{payload: payload})

        assert "is invalid" in errors_on(changeset).payload
      end
    end

    test "declares the external_id unique constraint" do
      changeset = valid_changeset()

      assert Enum.any?(changeset.constraints, fn constraint ->
               constraint.type == :unique and constraint.field == :external_id and
                 constraint.constraint == "events_external_id_index"
             end)
    end
  end

  defp valid_changeset(overrides \\ %{}) do
    attrs = %{
      external_id: "evt_123",
      event_type: "order.created",
      payload: %{"order_id" => "123"}
    }

    Event.changeset(%Event{}, Map.merge(attrs, overrides))
  end
end
