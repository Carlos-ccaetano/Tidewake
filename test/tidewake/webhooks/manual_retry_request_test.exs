defmodule Tidewake.Webhooks.ManualRetryRequestTest do
  use Tidewake.DataCase, async: true

  alias Tidewake.Webhooks
  alias Tidewake.Webhooks.{Delivery, ManualRetryRequest}

  @identity_fields [
    :delivery_id,
    :actor_type,
    :actor_subject,
    :source,
    :idempotency_key_digest,
    :request_fingerprint
  ]

  describe "schema" do
    test "maps exactly the stored fields, types, and delivery association" do
      assert ManualRetryRequest.__schema__(:source) == "manual_retry_requests"

      types =
        Map.new(ManualRetryRequest.__schema__(:fields), fn field ->
          {field, ManualRetryRequest.__schema__(:type, field)}
        end)

      assert types == %{
               id: :id,
               delivery_id: :id,
               actor_type: :string,
               actor_subject: :string,
               source: :string,
               idempotency_key_digest: :string,
               request_fingerprint: :string,
               requested_at: :utc_datetime_usec,
               outcome: :string,
               reason: :string,
               observed_status: :string,
               observed_attempt_count: :integer,
               observed_retry_cycle: :integer,
               observed_completed_at: :utc_datetime_usec,
               resulting_retry_cycle: :integer,
               inserted_at: :utc_datetime_usec
             }

      association = ManualRetryRequest.__schema__(:association, :delivery)
      assert association.related == Delivery
      assert association.owner_key == :delivery_id
    end

    test "has no updated_at, virtual fields, or raw key storage" do
      refute Map.has_key?(%ManualRetryRequest{}, :updated_at)
      assert ManualRetryRequest.__schema__(:virtual_fields) == []

      for field <- [:raw_key, :idempotency_key, :raw_idempotency_key] do
        refute Map.has_key?(%ManualRetryRequest{}, field)
      end
    end

    test "redacts protected values in structs and valid or invalid changesets" do
      request = trusted_request()

      invalid_request = %{
        request
        | idempotency_key_digest: "private-invalid-key-digest",
          request_fingerprint: "private-invalid-fingerprint"
      }

      assert Enum.sort(ManualRetryRequest.__schema__(:redact_fields)) ==
               Enum.sort([:actor_subject, :idempotency_key_digest, :request_fingerprint])

      for data <- [request, invalid_request] do
        changeset = ManualRetryRequest.changeset(data, valid_attrs())

        for value <- [data, changeset, {:error, changeset}] do
          inspected = inspect(value, pretty: true, limit: :infinity)
          refute inspected =~ data.actor_subject
          refute inspected =~ data.idempotency_key_digest
          refute inspected =~ data.request_fingerprint
        end
      end
    end
  end

  describe "changeset/2" do
    test "accepts an accepted decision with trusted identity on the struct" do
      changeset = valid_changeset()
      assert changeset.valid?
      assert get_field(changeset, :outcome) == "accepted"
      assert get_field(changeset, :resulting_retry_cycle) == 1
      assert get_field(changeset, :reason) == nil
    end

    test "accepts rejected decisions with each bounded reason" do
      for reason <- ~w(state_not_failed endpoint_inactive manual_cycle_limit_reached) do
        changeset = valid_changeset(rejected_attrs(%{reason: reason}))
        assert changeset.valid?
        assert get_field(changeset, :resulting_retry_cycle) == nil
      end
    end

    test "requires identity, observation, and decision fields" do
      changeset = ManualRetryRequest.changeset(%ManualRetryRequest{}, %{})
      refute changeset.valid?

      for field <-
            @identity_fields ++
              [
                :requested_at,
                :outcome,
                :observed_status,
                :observed_attempt_count,
                :observed_retry_cycle
              ] do
        assert "can't be blank" in Map.fetch!(errors_on(changeset), field)
      end
    end

    test "cannot populate missing trusted identity through atom or string attributes" do
      attrs =
        Map.merge(valid_attrs(), Map.take(Map.from_struct(trusted_request()), @identity_fields))

      for attrs <- [attrs, string_keys(attrs)] do
        changeset = ManualRetryRequest.changeset(%ManualRetryRequest{}, attrs)
        refute changeset.valid?

        for field <- @identity_fields do
          assert "can't be blank" in Map.fetch!(errors_on(changeset), field)
        end
      end
    end

    test "cannot replace trusted identity through atom or string attributes" do
      request = trusted_request()

      replacements = %{
        delivery_id: 999,
        actor_type: "user",
        actor_subject: "different-actor",
        source: "admin_cli",
        idempotency_key_digest: String.duplicate("c", 64),
        request_fingerprint: String.duplicate("d", 64)
      }

      attrs = Map.merge(valid_attrs(), replacements)

      for attrs <- [attrs, string_keys(attrs)] do
        changeset = ManualRetryRequest.changeset(request, attrs)
        assert changeset.valid?

        for field <- @identity_fields do
          assert get_field(changeset, field) == Map.fetch!(request, field)
        end
      end
    end

    test "rejects invalid trusted actor and source values" do
      for {field, value} <- [actor_type: "robot", source: "web", delivery_id: 0] do
        request = Map.put(trusted_request(), field, value)
        changeset = ManualRetryRequest.changeset(request, valid_attrs())
        refute changeset.valid?
        assert Map.has_key?(errors_on(changeset), field)
      end
    end

    test "returns cast errors for malformed programmatic identity types" do
      for field <- @identity_fields do
        changeset =
          trusted_request()
          |> Map.put(field, %{})
          |> ManualRetryRequest.changeset(valid_attrs())

        refute changeset.valid?
        assert "is invalid" in Map.fetch!(errors_on(changeset), field)
      end
    end

    test "rejects invalid outcome, reason, and observed status values" do
      for {field, value} <- [
            outcome: "unknown",
            reason: "invalid_input",
            observed_status: "unknown"
          ] do
        changeset = valid_changeset(%{field => value})
        refute changeset.valid?
        assert "is invalid" in Map.fetch!(errors_on(changeset), field)
      end
    end

    test "enforces varchar byte bounds including multibyte actor subjects" do
      assert valid_changeset(%{}, %{actor_subject: String.duplicate("a", 255)}).valid?
      assert valid_changeset(%{}, %{actor_subject: String.duplicate("é", 127) <> "x"}).valid?

      for {field, value} <- [
            actor_type: String.duplicate("a", 33),
            actor_subject: String.duplicate("é", 128),
            source: String.duplicate("a", 17)
          ] do
        changeset = valid_changeset(%{}, %{field => value})
        refute changeset.valid?
        assert Map.has_key?(errors_on(changeset), field)
      end

      for {field, size} <- [outcome: 17, reason: 65, observed_status: 17] do
        changeset = valid_changeset(%{field => String.duplicate("a", size)})
        refute changeset.valid?
        assert Map.has_key?(errors_on(changeset), field)
      end
    end

    test "rejects blank actor subjects" do
      for subject <- ["", "   ", "\t\n"] do
        changeset = valid_changeset(%{}, %{actor_subject: subject})
        refute changeset.valid?
        assert "can't be blank" in errors_on(changeset).actor_subject
      end
    end

    test "requires exactly 64 lowercase hexadecimal bytes for both digests" do
      for field <- [:idempotency_key_digest, :request_fingerprint],
          value <- [
            "",
            String.duplicate("a", 63),
            String.duplicate("a", 65),
            String.duplicate("A", 64),
            String.duplicate("g", 64),
            String.duplicate("é", 64),
            String.duplicate("a", 63) <> "\n",
            String.duplicate("a", 64) <> "\n"
          ] do
        changeset = valid_changeset(%{}, %{field => value})
        refute changeset.valid?
        assert Map.has_key?(errors_on(changeset), field)
      end

      assert valid_changeset(%{}, %{
               idempotency_key_digest: String.duplicate("0123456789abcdef", 4)
             }).valid?
    end

    test "bounds observation counters and resulting cycles" do
      for {field, value} <- [
            observed_attempt_count: -1,
            observed_retry_cycle: -1,
            observed_retry_cycle: 4,
            resulting_retry_cycle: 0,
            resulting_retry_cycle: 4
          ] do
        changeset = valid_changeset(%{field => value})
        refute changeset.valid?
        assert Map.has_key?(errors_on(changeset), field)
      end

      assert valid_changeset(%{observed_attempt_count: 0}).valid?
    end

    test "requires a resulting cycle and no reason for acceptance" do
      missing_cycle = valid_changeset(%{resulting_retry_cycle: nil})
      refute missing_cycle.valid?
      assert "can't be blank" in errors_on(missing_cycle).resulting_retry_cycle

      with_reason = valid_changeset(%{reason: "endpoint_inactive"})
      refute with_reason.valid?
      assert "must be absent for an accepted request" in errors_on(with_reason).reason
    end

    test "requires a reason and no resulting cycle for rejection" do
      missing_reason = valid_changeset(rejected_attrs(%{reason: nil}))
      refute missing_reason.valid?
      assert "can't be blank" in errors_on(missing_reason).reason

      with_cycle = valid_changeset(rejected_attrs(%{resulting_retry_cycle: 1}))
      refute with_cycle.valid?

      assert "must be absent for a rejected request" in errors_on(with_cycle).resulting_retry_cycle
    end

    test "casts timestamps to microsecond UTC values and rejects malformed timestamps" do
      changeset = valid_changeset(%{requested_at: "2026-10-25T02:00:00.123456-03:00"})
      assert changeset.valid?
      assert get_field(changeset, :requested_at) == ~U[2026-10-25 05:00:00.123456Z]
      assert valid_changeset(%{observed_completed_at: nil}).valid?

      for field <- [:requested_at, :observed_completed_at] do
        changeset = valid_changeset(%{field => "not-a-timestamp"})
        refute changeset.valid?
        assert "is invalid" in Map.fetch!(errors_on(changeset), field)
      end
    end

    test "ignores raw keys and caller-supplied insertion timestamps" do
      changeset =
        valid_changeset(%{
          raw_key: "never-keep-this-key",
          idempotency_key: "never-keep-this-key",
          raw_idempotency_key: "never-keep-this-key",
          inserted_at: ~U[2000-01-01 00:00:00.000000Z]
        })

      assert changeset.valid?
      refute Map.has_key?(changeset.changes, :raw_key)
      refute Map.has_key?(changeset.changes, :idempotency_key)
      refute Map.has_key?(changeset.changes, :raw_idempotency_key)
      assert get_field(changeset, :inserted_at) == nil
    end
  end

  describe "PostgreSQL constraints" do
    test "maps every CHECK constraint present on the real table" do
      %{rows: rows} =
        Repo.query!("""
        SELECT conname FROM pg_constraint
        WHERE conrelid = 'manual_retry_requests'::regclass AND contype = 'c'
        """)

      declared =
        valid_changeset().constraints
        |> Enum.filter(&(&1.type == :check))
        |> Enum.map(& &1.constraint)

      assert Enum.sort(declared) == Enum.sort(Enum.map(rows, &hd/1))
    end

    test "persists an accepted record and generates only inserted_at" do
      delivery = delivery_fixture()
      changeset = valid_changeset(%{}, %{delivery_id: delivery.id})

      assert {:ok, request} = Repo.insert(changeset)
      assert request.id > 0
      assert %DateTime{time_zone: "Etc/UTC", microsecond: {_, 6}} = request.inserted_at
      assert request.requested_at == valid_attrs().requested_at
      assert request.observed_completed_at == valid_attrs().observed_completed_at
      assert request == Repo.get!(ManualRetryRequest, request.id)
      assert Repo.preload(request, :delivery).delivery.id == delivery.id
      refute Map.has_key?(request, :updated_at)
    end

    test "persists a rejected record with nullable prior completion and no resulting cycle" do
      delivery = delivery_fixture()

      assert {:ok, request} =
               rejected_attrs(%{observed_completed_at: nil})
               |> valid_changeset(%{delivery_id: delivery.id})
               |> Repo.insert()

      assert request.outcome == "rejected"
      assert request.reason == "state_not_failed"
      assert request.resulting_retry_cycle == nil
      assert request.observed_completed_at == nil
    end

    test "returns a controlled changeset for a real actor-scoped key conflict" do
      delivery = delivery_fixture()
      attrs = %{delivery_id: delivery.id}
      assert {:ok, first} = valid_changeset(%{}, attrs) |> Repo.insert()

      for identity <- [attrs, Map.put(attrs, :source, "admin_cli")] do
        assert {:error, %Ecto.Changeset{} = changeset} =
                 valid_changeset(%{}, identity) |> Repo.insert(mode: :savepoint)

        assert "has already been used by this actor" in errors_on(changeset).idempotency_key_digest
      end

      assert Repo.all(ManualRetryRequest) == [first]
    end

    test "allows the same key digest for different actor subjects or types" do
      delivery = delivery_fixture()
      original = %{delivery_id: delivery.id}
      assert {:ok, first} = valid_changeset(%{}, original) |> Repo.insert()

      for identity <- [
            Map.put(original, :actor_subject, "another-opaque-actor"),
            Map.put(original, :actor_type, "user")
          ] do
        assert {:ok, request} = valid_changeset(%{}, identity) |> Repo.insert()
        assert request.idempotency_key_digest == first.idempotency_key_digest
      end

      assert Repo.aggregate(ManualRetryRequest, :count) == 3
    end

    test "maps the restrictive delivery foreign key to a changeset error" do
      changeset = valid_changeset(%{}, %{delivery_id: 9_223_372_036_854_775_807})
      assert changeset.valid?
      assert {:error, %Ecto.Changeset{} = changeset} = Repo.insert(changeset, mode: :savepoint)
      assert "does not exist" in errors_on(changeset).delivery_id
    end

    test "persists each allowed accepted cycle advance" do
      delivery = delivery_fixture()

      for observed_retry_cycle <- 0..2 do
        assert {:ok, request} =
                 valid_changeset(
                   %{
                     observed_retry_cycle: observed_retry_cycle,
                     resulting_retry_cycle: observed_retry_cycle + 1
                   },
                   %{
                     delivery_id: delivery.id,
                     idempotency_key_digest: digest(observed_retry_cycle)
                   }
                 )
                 |> Repo.insert()

        assert request.resulting_retry_cycle == request.observed_retry_cycle + 1
      end
    end

    test "maps accepted state and successor inconsistencies from PostgreSQL" do
      delivery = delivery_fixture()

      for attrs <- [
            %{observed_retry_cycle: 0, resulting_retry_cycle: 2},
            %{observed_retry_cycle: 3, resulting_retry_cycle: 3},
            %{observed_status: "pending"}
          ] do
        changeset = valid_changeset(attrs, %{delivery_id: delivery.id})
        assert changeset.valid?

        assert {:error, %Ecto.Changeset{} = changeset} =
                 Repo.insert(changeset, mode: :savepoint)

        assert "is inconsistent with the observed delivery state" in errors_on(changeset).outcome
      end
    end

    test "maps database errors even when changeset field validation is bypassed" do
      delivery = delivery_fixture()

      for {field, value} <- [
            actor_type: "robot",
            source: "web",
            actor_subject: " ",
            idempotency_key_digest: String.duplicate("A", 64),
            request_fingerprint: String.duplicate("g", 64),
            observed_attempt_count: -1,
            observed_status: "unknown"
          ] do
        changeset =
          valid_changeset(rejected_attrs(), %{delivery_id: delivery.id})
          |> put_change(field, value)

        assert changeset.valid?
        assert {:error, %Ecto.Changeset{} = changeset} = Repo.insert(changeset, mode: :savepoint)
        assert "is invalid" in Map.fetch!(errors_on(changeset), field)
      end
    end
  end

  defp valid_changeset(attrs \\ %{}, identity \\ %{}) do
    trusted_request(identity)
    |> ManualRetryRequest.changeset(Map.merge(valid_attrs(), attrs))
  end

  defp trusted_request(overrides \\ %{}) do
    struct!(
      ManualRetryRequest,
      Map.merge(
        %{
          delivery_id: 1,
          actor_type: "service_account",
          actor_subject: "opaque-private-actor-001",
          source: "api",
          idempotency_key_digest: String.duplicate("a", 64),
          request_fingerprint: String.duplicate("b", 64)
        },
        overrides
      )
    )
  end

  defp valid_attrs do
    %{
      requested_at: ~U[2026-10-25 05:00:00.123456Z],
      outcome: "accepted",
      reason: nil,
      observed_status: "failed",
      observed_attempt_count: 6,
      observed_retry_cycle: 0,
      observed_completed_at: ~U[2026-10-25 04:59:00.123456Z],
      resulting_retry_cycle: 1
    }
  end

  defp rejected_attrs(overrides \\ %{}) do
    Map.merge(
      %{outcome: "rejected", reason: "state_not_failed", resulting_retry_cycle: nil},
      overrides
    )
  end

  defp string_keys(attrs), do: Map.new(attrs, fn {key, value} -> {Atom.to_string(key), value} end)

  defp digest(number), do: number |> Integer.to_string(16) |> String.pad_leading(64, "0")

  defp delivery_fixture do
    {:ok, event} =
      Webhooks.create_event(%{
        external_id: "evt_manual_retry_schema_#{System.unique_integer([:positive])}",
        event_type: "order.created",
        payload: %{}
      })

    {:ok, endpoint} =
      Webhooks.create_endpoint(%{
        name: "Audit schema validation",
        url: "https://endpoint.invalid/webhooks"
      })

    Repo.insert!(%Delivery{
      event_id: event.id,
      endpoint_id: endpoint.id,
      status: "failed",
      attempt_count: 6,
      cycle_attempt_count: 6,
      completed_at: valid_attrs().observed_completed_at
    })
  end
end
