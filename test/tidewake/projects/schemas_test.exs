defmodule Tidewake.Projects.SchemasTest do
  use Tidewake.DataCase, async: true

  alias Tidewake.Projects
  alias Tidewake.Projects.{ApiCredential, Project, ServiceAccount}

  @now ~U[2030-01-01 00:00:00.123456Z]

  test "schemas match persisted columns, types, associations, and UUID generation" do
    expected = [
      {Project, "projects",
       [public_id: Ecto.UUID, slug: :string, name: :string, status: :string]},
      {ServiceAccount, "service_accounts",
       [
         project_id: :id,
         public_id: Ecto.UUID,
         name: :string,
         role: :string,
         disabled_at: :utc_datetime_usec
       ]},
      {ApiCredential, "service_account_credentials",
       [
         service_account_id: :id,
         public_id: Ecto.UUID,
         secret_digest: :binary,
         expires_at: :utc_datetime_usec,
         revoked_at: :utc_datetime_usec
       ]}
    ]

    for {schema, source, types} <- expected do
      assert schema.__schema__(:source) == source
      types = types ++ [id: :id, inserted_at: :utc_datetime_usec, updated_at: :utc_datetime_usec]
      assert Enum.sort(schema.__schema__(:fields)) == Enum.sort(Keyword.keys(types))
      assert schema.__schema__(:virtual_fields) == []
      for {field, type} <- types, do: assert(schema.__schema__(:type, field) == type)
      assert :public_id in schema.__schema__(:autogenerate_fields)
    end

    assert Project.__schema__(:association, :service_accounts).related == ServiceAccount
    assert ServiceAccount.__schema__(:association, :project).related == Project
    assert ServiceAccount.__schema__(:association, :credentials).related == ApiCredential
    assert ApiCredential.__schema__(:association, :service_account).related == ServiceAccount
  end

  test "credentials persist a binary digest, redact Inspect, and never model raw token material" do
    account = account_fixture()
    changeset = credential_changeset(account)
    assert {:ok, credential} = Repo.insert(changeset, log: false, telemetry_event: nil)
    assert {:ok, _uuid} = Ecto.UUID.cast(credential.public_id)
    assert credential.secret_digest == :binary.copy(<<255>>, 32)
    assert credential.inserted_at == @now
    assert Repo.preload(credential, :service_account).service_account == account
    assert Repo.preload(account, :credentials).credentials == [credential]
    assert ApiCredential.__schema__(:redact_fields) == [:secret_digest]
    refute inspect(credential) =~ inspect(credential.secret_digest)
    refute inspect(changeset) =~ inspect(credential.secret_digest)

    for field <- [:raw_token, :token, :pepper, :authorization, :metadata] do
      refute Map.has_key?(credential, field)
    end
  end

  test "credential attrs cannot replace trusted identity, digest, insertion time, or revocation" do
    account = account_fixture()
    forged_uuid = Ecto.UUID.generate()

    attrs = %{
      service_account_id: 1,
      public_id: forged_uuid,
      secret_digest: "forged",
      inserted_at: DateTime.add(@now, 60),
      revoked_at: @now,
      raw_token: "never-store-this-token",
      token: "never-store-this-token",
      expires_at: DateTime.add(@now, 60)
    }

    for attrs <- [attrs, Map.new(attrs, fn {k, v} -> {Atom.to_string(k), v} end)] do
      changeset = credential_changeset(account, attrs)
      assert changeset.valid?
      assert get_field(changeset, :service_account_id) == account.id
      assert get_field(changeset, :public_id) == nil
      assert get_field(changeset, :secret_digest) == :binary.copy(<<255>>, 32)
      assert get_field(changeset, :inserted_at) == @now
      assert get_field(changeset, :revoked_at) == nil
      refute inspect(changeset) =~ "never-store-this-token"
      refute Map.has_key?(changeset.params, "raw_token")
      refute Map.has_key?(changeset.params, "token")
      assert {:ok, credential} = Repo.insert(changeset, log: false, telemetry_event: nil)
      refute credential.public_id == forged_uuid
    end
  end

  test "credential validation rejects missing identity/digest/time and invalid digest lengths" do
    for identity <- [
          %{service_account_id: nil},
          %{service_account_id: 0},
          %{service_account_id: "bad"},
          %{secret_digest: nil},
          %{secret_digest: <<>>},
          %{secret_digest: <<1>>},
          %{secret_digest: :binary.copy(<<1>>, 31)},
          %{secret_digest: :binary.copy(<<1>>, 33)},
          %{inserted_at: nil}
        ] do
      credential =
        struct!(
          %ApiCredential{service_account_id: 1, secret_digest: <<0::256>>, inserted_at: @now},
          identity
        )

      changeset =
        ApiCredential.create_changeset(credential, %{expires_at: DateTime.add(@now, 60)})

      refute changeset.valid?
    end

    for expiry <- [nil, "bad", @now, DateTime.add(@now, -1)] do
      refute credential_changeset(%ServiceAccount{id: 1}, %{expires_at: expiry}).valid?
    end

    over_limit = @now |> DateTime.add(365 * 86_400) |> DateTime.add(1, :microsecond)
    refute credential_changeset(%ServiceAccount{id: 1}, %{expires_at: over_limit}).valid?
  end

  test "accepts a one-microsecond lifetime and exactly 365 days, including credential overlap" do
    account = account_fixture()

    for expiry <- [DateTime.add(@now, 1, :microsecond), DateTime.add(@now, 365 * 86_400)] do
      assert {:ok, credential} =
               credential_changeset(account, %{expires_at: expiry})
               |> Repo.insert(log: false, telemetry_event: nil)

      assert credential.expires_at == expiry
    end

    assert length(Repo.preload(account, :credentials).credentials) == 2
  end

  test "all named PostgreSQL checks return controlled changeset errors when validators are bypassed" do
    project = project_fixture()
    account = account_fixture(project)
    project_changeset = Project.create_changeset(%{slug: "fresh-project", name: "Fresh"})
    account_changeset = ServiceAccount.create_changeset(project, "admin", %{name: "Fresh"})
    credential_changeset = credential_changeset(account)

    cases = [
      {project_changeset, :slug, "A--B", "projects_slug_format"},
      {project_changeset, :name, " ", "projects_name_not_blank"},
      {project_changeset, :name, String.duplicate("é", 128), "projects_name_not_blank"},
      {project_changeset, :status, "paused", "projects_status_allowed"},
      {account_changeset, :project_id, 0, "service_accounts_project_id_positive"},
      {account_changeset, :name, " ", "service_accounts_name_not_blank"},
      {account_changeset, :role, "owner", "service_accounts_role_allowed"},
      {credential_changeset, :service_account_id, 0,
       "service_account_credentials_service_account_id_positive"},
      {credential_changeset, :secret_digest, <<0>>, "service_account_credentials_digest_length"},
      {credential_changeset, :expires_at, @now,
       "service_account_credentials_expires_after_insert"},
      {credential_changeset, :expires_at, DateTime.add(@now, 366 * 86_400),
       "service_account_credentials_expiry_bounded"},
      {credential_changeset, :revoked_at, DateTime.add(@now, -1),
       "service_account_credentials_revocation_time"}
    ]

    for {base, field, value, constraint} <- cases do
      assert_database_error(put_change(base, field, value), field, constraint)
    end
  end

  test "all five unique indexes map real PostgreSQL conflicts to changesets" do
    project = project_fixture()
    account = account_fixture(project)

    {:ok, credential} =
      credential_changeset(account) |> Repo.insert(log: false, telemetry_event: nil)

    for {changeset, field, constraint} <- [
          {Project.create_changeset(%{slug: project.slug, name: "Duplicate"}), :slug,
           "projects_slug_index"},
          {Project.create_changeset(%{slug: "unique-slug", name: "Duplicate"})
           |> put_change(:public_id, project.public_id), :public_id, "projects_public_id_index"},
          {ServiceAccount.create_changeset(project, "viewer", %{name: account.name}), :name,
           "service_accounts_project_id_name_index"},
          {ServiceAccount.create_changeset(project, "viewer", %{name: "Unique"})
           |> put_change(:public_id, account.public_id), :public_id,
           "service_accounts_public_id_index"},
          {credential_changeset(account) |> put_change(:public_id, credential.public_id),
           :public_id, "service_account_credentials_public_id_index"}
        ] do
      assert_database_error(changeset, field, constraint)
    end
  end

  test "both named foreign keys map missing parents into controlled changesets" do
    missing_id = 9_223_372_036_854_775_807

    changeset =
      ServiceAccount.create_changeset(%Project{id: missing_id}, "admin", %{name: "Missing"})

    assert_database_error(changeset, :project_id, "service_accounts_project_id_fkey")
    changeset = credential_changeset(%ServiceAccount{id: missing_id})

    assert_database_error(
      changeset,
      :service_account_id,
      "service_account_credentials_service_account_id_fkey"
    )
  end

  defp assert_database_error(changeset, field, constraint) do
    assert changeset.valid?

    assert {:error, error} =
             Repo.insert(changeset, mode: :savepoint, log: false, telemetry_event: nil)

    assert {_message, opts} = Keyword.fetch!(error.errors, field)
    assert opts[:constraint_name] == constraint
  end

  defp project_fixture do
    {:ok, project} =
      Projects.create_project(%{
        slug: "schema-#{System.unique_integer([:positive])}",
        name: "Project"
      })

    project
  end

  defp account_fixture(project \\ project_fixture()) do
    {:ok, account} = Projects.create_service_account(project, "admin", %{name: "Account"})
    account
  end

  defp credential_changeset(account, attrs \\ %{}) do
    attrs =
      if Map.has_key?(attrs, "expires_at"),
        do: attrs,
        else: Map.merge(%{expires_at: DateTime.add(@now, 60)}, attrs)

    %ApiCredential{
      service_account_id: account.id,
      secret_digest: :binary.copy(<<255>>, 32),
      inserted_at: @now
    }
    |> ApiCredential.create_changeset(attrs)
  end
end
