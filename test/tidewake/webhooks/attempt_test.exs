defmodule Tidewake.Webhooks.AttemptTest do
  use Tidewake.DataCase, async: true

  alias Tidewake.Webhooks.{Attempt, Delivery}

  describe "schema" do
    test "maps the delivery association and attempt fields" do
      delivery_association = Attempt.__schema__(:association, :delivery)

      assert delivery_association.related == Delivery
      assert delivery_association.owner_key == :delivery_id
      assert Attempt.__schema__(:type, :attempt_number) == :integer
      assert Attempt.__schema__(:type, :result) == :string
      assert Attempt.__schema__(:type, :http_status) == :integer
      assert Attempt.__schema__(:type, :error_type) == :string
      assert Attempt.__schema__(:type, :duration_ms) == :integer
      assert Attempt.__schema__(:type, :started_at) == :utc_datetime_usec
      assert Attempt.__schema__(:type, :completed_at) == :utc_datetime_usec
      assert Attempt.__schema__(:type, :response_metadata) == :map
      assert Attempt.__schema__(:type, :inserted_at) == :utc_datetime_usec
      assert Attempt.__schema__(:type, :updated_at) == :utc_datetime_usec
    end
  end

  describe "changeset/2" do
    test "accepts a valid attempt with a delivery ID set programmatically" do
      attrs = valid_attrs()
      changeset = valid_changeset()

      assert changeset.valid?
      assert get_field(changeset, :delivery_id) == 1
      assert get_change(changeset, :attempt_number) == attrs.attempt_number
      assert get_change(changeset, :result) == attrs.result
      assert get_change(changeset, :http_status) == attrs.http_status
      assert get_change(changeset, :duration_ms) == attrs.duration_ms
      assert get_change(changeset, :started_at) == attrs.started_at
      assert get_change(changeset, :completed_at) == attrs.completed_at
    end

    test "requires every mandatory field" do
      changeset = Attempt.changeset(%Attempt{}, %{})
      errors = errors_on(changeset)

      refute changeset.valid?
      assert "can't be blank" in errors.delivery_id
      assert "can't be blank" in errors.attempt_number
      assert "can't be blank" in errors.result
      assert "can't be blank" in errors.duration_ms
      assert "can't be blank" in errors.started_at
      assert "can't be blank" in errors.completed_at
    end

    test "does not cast or replace delivery_id from attributes" do
      missing_delivery = Attempt.changeset(%Attempt{}, Map.put(valid_attrs(), :delivery_id, 2))
      existing_delivery = valid_changeset(%{delivery_id: 2})

      refute missing_delivery.valid?
      assert "can't be blank" in errors_on(missing_delivery).delivery_id
      refute Map.has_key?(missing_delivery.changes, :delivery_id)

      assert existing_delivery.valid?
      assert get_field(existing_delivery, :delivery_id) == 1
      refute Map.has_key?(existing_delivery.changes, :delivery_id)
    end

    test "accepts the three normalized results with their HTTP status rules" do
      assert valid_changeset(%{result: "succeeded", http_status: 204}).valid?
      assert valid_changeset(%{result: "http_error", http_status: 503}).valid?

      assert valid_changeset(%{
               result: "transport_error",
               http_status: nil,
               error_type: "timeout"
             }).valid?
    end

    test "rejects a result outside the ADR" do
      changeset = valid_changeset(%{result: "retryable"})

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).result
    end

    test "requires http_status for succeeded and http_error results" do
      for result <- ~w(succeeded http_error) do
        changeset = valid_changeset(%{result: result, http_status: nil})

        refute changeset.valid?
        assert "can't be blank" in errors_on(changeset).http_status
      end
    end

    test "rejects http_status for a transport_error" do
      changeset = valid_changeset(%{result: "transport_error", http_status: 500})

      refute changeset.valid?
      assert "must be absent for a transport error" in errors_on(changeset).http_status
    end

    test "matches HTTP status ranges to normalized results" do
      succeeded = valid_changeset(%{result: "succeeded", http_status: 500})
      http_error = valid_changeset(%{result: "http_error", http_status: 204})

      refute succeeded.valid?
      refute http_error.valid?

      assert "must be between 200 and 299 for a succeeded result" in errors_on(succeeded).http_status

      assert "must be outside 200 through 299 for an HTTP error" in errors_on(http_error).http_status
    end

    test "accepts only valid HTTP status values" do
      for http_status <- [99, 600] do
        changeset = valid_changeset(%{result: "http_error", http_status: http_status})

        refute changeset.valid?
      end
    end

    test "requires a positive attempt number" do
      for attempt_number <- [0, -1] do
        changeset = valid_changeset(%{attempt_number: attempt_number})

        refute changeset.valid?
        assert "must be greater than 0" in errors_on(changeset).attempt_number
      end
    end

    test "requires a non-negative duration" do
      assert valid_changeset(%{duration_ms: 0}).valid?

      changeset = valid_changeset(%{duration_ms: -1})

      refute changeset.valid?
      assert "must be greater than or equal to 0" in errors_on(changeset).duration_ms
    end

    test "accepts equal timestamps and rejects completion before the start" do
      started_at = ~U[2026-09-10 10:00:00.123456Z]

      assert valid_changeset(%{started_at: started_at, completed_at: started_at}).valid?

      changeset =
        valid_changeset(%{
          started_at: started_at,
          completed_at: ~U[2026-09-10 10:00:00.123455Z]
        })

      refute changeset.valid?

      assert "must be equal to or later than started_at" in errors_on(changeset).completed_at
    end

    test "accepts only allowlisted response metadata without transforming it" do
      atom_keys = %{content_type: "application/json", content_length: 42, request_id: "req_123"}

      string_keys = %{
        "content_type" => "application/json",
        "content_length" => 42,
        "request_id" => "req_123"
      }

      atom_changeset = valid_changeset(%{response_metadata: atom_keys})
      string_changeset = valid_changeset(%{response_metadata: string_keys})

      assert atom_changeset.valid?
      assert string_changeset.valid?
      assert get_change(atom_changeset, :response_metadata) == atom_keys
      assert get_change(string_changeset, :response_metadata) == string_keys
    end

    test "rejects response metadata outside the allowlist" do
      changeset = valid_changeset(%{response_metadata: %{"authorization" => "secret"}})

      refute changeset.valid?
      assert "contains unsupported keys" in errors_on(changeset).response_metadata
    end

    test "validates response metadata string types and byte limits" do
      assert valid_changeset(%{
               response_metadata: %{
                 content_type: String.duplicate("a", 255),
                 request_id: String.duplicate("b", 255)
               }
             }).valid?

      for metadata <- [
            %{content_type: 123},
            %{content_type: String.duplicate("é", 128)},
            %{request_id: 123},
            %{request_id: String.duplicate("a", 256)}
          ] do
        refute valid_changeset(%{response_metadata: metadata}).valid?
      end
    end

    test "requires response content_length to be a non-negative integer" do
      assert valid_changeset(%{response_metadata: %{content_length: 0}}).valid?

      for content_length <- [-1, "42"] do
        changeset = valid_changeset(%{response_metadata: %{content_length: content_length}})

        refute changeset.valid?

        assert "content_length must be a non-negative integer" in errors_on(changeset).response_metadata
      end
    end

    test "rejects response_metadata that is not a map" do
      changeset = valid_changeset(%{response_metadata: "application/json"})

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).response_metadata
    end

    test "validates error_type against the string column length" do
      assert valid_changeset(%{error_type: String.duplicate("a", 255)}).valid?

      changeset = valid_changeset(%{error_type: String.duplicate("a", 256)})

      refute changeset.valid?
      assert "should be at most 255 character(s)" in errors_on(changeset).error_type
    end

    test "declares the delivery and attempt number unique constraint" do
      changeset = valid_changeset()

      assert Enum.any?(changeset.constraints, fn constraint ->
               constraint.type == :unique and constraint.field == :delivery_id and
                 constraint.constraint ==
                   "delivery_attempts_delivery_id_attempt_number_index"
             end)
    end
  end

  defp valid_changeset(overrides \\ %{}) do
    attrs = Map.merge(valid_attrs(), overrides)

    Attempt.changeset(%Attempt{delivery_id: 1}, attrs)
  end

  defp valid_attrs do
    %{
      attempt_number: 1,
      result: "succeeded",
      http_status: 200,
      error_type: nil,
      duration_ms: 125,
      started_at: ~U[2026-09-10 10:00:00.123456Z],
      completed_at: ~U[2026-09-10 10:00:00.248456Z],
      response_metadata: %{
        "content_type" => "application/json",
        "content_length" => 42,
        "request_id" => "req_123"
      }
    }
  end
end
