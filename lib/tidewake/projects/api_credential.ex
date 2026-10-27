defmodule Tidewake.Projects.ApiCredential do
  use Ecto.Schema

  import Ecto.Changeset

  alias Tidewake.Projects.ServiceAccount

  schema "service_account_credentials" do
    belongs_to :service_account, ServiceAccount
    field :public_id, Ecto.UUID, autogenerate: true
    field :secret_digest, :binary, redact: true
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  # Identity, digest and insertion time come from trusted code, never attrs.
  def create_changeset(%__MODULE__{__meta__: %{state: :built}} = credential, attrs) do
    trusted =
      Map.take(Map.from_struct(credential), [:service_account_id, :secret_digest, :inserted_at])

    credential
    |> cast(trusted, [:service_account_id, :secret_digest, :inserted_at], force_changes: true)
    |> cast(Map.take(attrs, [:expires_at, "expires_at"]), [:expires_at])
    |> validate_required([:service_account_id, :secret_digest, :inserted_at, :expires_at])
    |> validate_number(:service_account_id, greater_than: 0)
    |> validate_length(:secret_digest, is: 32, count: :bytes)
    |> validate_expiry()
    |> unique_constraint(:public_id, name: :service_account_credentials_public_id_index)
    |> foreign_key_constraint(:service_account_id,
      name: :service_account_credentials_service_account_id_fkey
    )
    |> check_constraint(:service_account_id,
      name: :service_account_credentials_service_account_id_positive
    )
    |> check_constraint(:secret_digest, name: :service_account_credentials_digest_length)
    |> check_constraint(:expires_at, name: :service_account_credentials_expires_after_insert)
    |> check_constraint(:expires_at, name: :service_account_credentials_expiry_bounded)
    |> check_constraint(:revoked_at, name: :service_account_credentials_revocation_time)
  end

  defp validate_expiry(changeset) do
    with %DateTime{} = inserted_at <- get_field(changeset, :inserted_at),
         %DateTime{} = expires_at <- get_field(changeset, :expires_at) do
      if DateTime.compare(expires_at, inserted_at) == :gt and
           DateTime.compare(expires_at, DateTime.add(inserted_at, 365 * 86_400)) != :gt,
         do: changeset,
         else: add_error(changeset, :expires_at, "must be after insertion and within 365 days")
    else
      _missing -> changeset
    end
  end
end
