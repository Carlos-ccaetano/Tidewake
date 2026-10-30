defmodule Tidewake.Webhooks.ManualRetryRequest do
  @moduledoc """
  Append-only evidence of a manual retry decision.

  Trusted delivery, actor, source, and request identity belong on the struct.
  Caller attributes can supply only decision and observation fields.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Tidewake.Webhooks.{Delivery, ManualRetryPolicy}

  @identity_fields [
    :delivery_id,
    :actor_type,
    :actor_subject,
    :source,
    :idempotency_key_digest,
    :request_fingerprint,
    :request_fingerprint_version
  ]
  @fields [
    :requested_at,
    :outcome,
    :reason,
    :observed_status,
    :observed_attempt_count,
    :observed_retry_cycle,
    :observed_completed_at,
    :resulting_retry_cycle
  ]
  @required_fields @identity_fields ++
                     [
                       :requested_at,
                       :outcome,
                       :observed_status,
                       :observed_attempt_count,
                       :observed_retry_cycle
                     ]
  @reasons ~w(state_not_failed endpoint_inactive manual_cycle_limit_reached)
  @statuses ~w(pending processing succeeded failed cancelled)
  @digest_format ~r/\A[0-9a-f]{64}\z/
  @check_constraints [
    delivery_id: :manual_retry_requests_delivery_id_positive,
    actor_type: :manual_retry_requests_actor_type_allowed,
    actor_subject: :manual_retry_requests_actor_subject_not_blank,
    source: :manual_retry_requests_source_allowed,
    idempotency_key_digest: :manual_retry_requests_idempotency_key_digest_format,
    request_fingerprint: :manual_retry_requests_request_fingerprint_format,
    request_fingerprint_version: :manual_retry_requests_request_fingerprint_version_allowed,
    outcome: :manual_retry_requests_outcome_allowed,
    reason: :manual_retry_requests_reason_allowed,
    observed_status: :manual_retry_requests_observed_status_allowed,
    observed_attempt_count: :manual_retry_requests_observed_attempt_count_non_negative,
    observed_retry_cycle: :manual_retry_requests_observed_retry_cycle_in_range,
    resulting_retry_cycle: :manual_retry_requests_resulting_retry_cycle_in_range
  ]

  schema "manual_retry_requests" do
    belongs_to :delivery, Delivery

    field :actor_type, :string
    field :actor_subject, :string, redact: true
    field :source, :string
    field :idempotency_key_digest, :string, redact: true
    field :request_fingerprint, :string, redact: true
    field :request_fingerprint_version, :integer
    field :requested_at, :utc_datetime_usec
    field :outcome, :string
    field :reason, :string
    field :observed_status, :string
    field :observed_attempt_count, :integer
    field :observed_retry_cycle, :integer
    field :observed_completed_at, :utc_datetime_usec
    field :resulting_retry_cycle, :integer

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(%__MODULE__{} = request, attrs) do
    identity = Map.take(Map.from_struct(request), @identity_fields)

    request
    |> cast(identity, @identity_fields, force_changes: true)
    |> cast(attrs, @fields)
    |> validate_required(@required_fields)
    |> validate_number(:delivery_id, greater_than: 0)
    |> validate_inclusion(:actor_type, ~w(service_account user))
    |> validate_inclusion(:source, ~w(api liveview admin_cli))
    |> validate_inclusion(:outcome, ~w(accepted rejected))
    |> validate_inclusion(:reason, @reasons)
    |> validate_inclusion(:observed_status, @statuses)
    |> validate_length(:actor_type, max: 32, count: :bytes)
    |> validate_length(:actor_subject, min: 1, max: 255, count: :bytes)
    |> validate_length(:source, max: 16, count: :bytes)
    |> validate_length(:outcome, max: 16, count: :bytes)
    |> validate_length(:reason, max: 64, count: :bytes)
    |> validate_length(:observed_status, max: 16, count: :bytes)
    |> validate_length(:idempotency_key_digest, is: 64, count: :bytes)
    |> validate_length(:request_fingerprint, is: 64, count: :bytes)
    |> validate_format(:idempotency_key_digest, @digest_format)
    |> validate_format(:request_fingerprint, @digest_format)
    |> validate_inclusion(:request_fingerprint_version, [1, 2])
    |> validate_number(:observed_attempt_count, greater_than_or_equal_to: 0)
    |> validate_number(:observed_retry_cycle,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: ManualRetryPolicy.max_manual_cycles()
    )
    |> validate_number(:resulting_retry_cycle,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: ManualRetryPolicy.max_manual_cycles()
    )
    |> validate_decision()
    |> database_constraints()
  end

  defp validate_decision(changeset) do
    case get_field(changeset, :outcome) do
      "accepted" ->
        changeset
        |> validate_required([:resulting_retry_cycle])
        |> require_absent(:reason, "must be absent for an accepted request")

      "rejected" ->
        changeset
        |> validate_required([:reason])
        |> require_absent(:resulting_retry_cycle, "must be absent for a rejected request")

      _other ->
        changeset
    end
  end

  defp require_absent(changeset, field, message) do
    if is_nil(get_field(changeset, field)),
      do: changeset,
      else: add_error(changeset, field, message)
  end

  defp database_constraints(changeset) do
    changeset =
      Enum.reduce(@check_constraints, changeset, fn {field, name}, changeset ->
        check_constraint(changeset, field, name: name)
      end)

    changeset
    |> check_constraint(:outcome,
      name: :manual_retry_requests_decision_consistent,
      message: "is inconsistent with the observed delivery state"
    )
    |> unique_constraint([:actor_type, :actor_subject, :idempotency_key_digest],
      name: :manual_retry_requests_actor_idempotency_key_index,
      error_key: :idempotency_key_digest,
      message: "has already been used by this actor"
    )
    |> foreign_key_constraint(:delivery_id, name: :manual_retry_requests_delivery_id_fkey)
  end
end
