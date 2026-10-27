defmodule Tidewake.ProjectsTest do
  use Tidewake.DataCase, async: true

  alias Tidewake.Projects
  alias Tidewake.Projects.{Project, ServiceAccount}

  @now ~U[2030-01-01 00:00:00.123456Z]

  test "reads the stable legacy project by UUID and slug" do
    legacy = Projects.get_project_by_slug("legacy")
    assert legacy.id == 1
    assert legacy.public_id == "00000000-0000-4000-8000-000000000001"
    assert legacy.name == "Legacy project"
    assert legacy.status == "active"
    assert Projects.get_project_by_public_id(legacy.public_id) == legacy
  end

  test "generates project identities and ignores non-allowlisted attributes" do
    for attrs <- [
          %{id: 1, public_id: Ecto.UUID.generate(), status: "suspended", inserted_at: @now},
          %{"id" => 1, "public_id" => Ecto.UUID.generate(), "status" => "suspended"}
        ] do
      attrs = Map.merge(attrs, same_key_style(attrs, project_attrs()))
      assert {:ok, project} = Projects.create_project(attrs)
      assert project.id > 1
      assert {:ok, _uuid} = Ecto.UUID.cast(project.public_id)
      refute project.public_id == (attrs[:public_id] || attrs["public_id"])
      assert project.status == "active"
      refute project.inserted_at == @now
      assert Projects.get_project_by_public_id(project.public_id) == project
      assert Projects.get_project_by_slug(project.slug) == project
    end
  end

  test "project creation rejects invalid slugs, names, and field types" do
    for slug <- [
          nil,
          "ab",
          "ABC",
          "-abc",
          "abc-",
          "a--b",
          "a_b",
          "a b",
          "abc\n",
          String.duplicate("a", 64),
          123
        ] do
      assert {:error, changeset} = Projects.create_project(%{name: "Project", slug: slug})
      assert errors_on(changeset).slug != []
    end

    for name <- [nil, "", " \t\n", String.duplicate("a", 256), String.duplicate("é", 128), 42] do
      assert {:error, changeset} = Projects.create_project(Map.put(project_attrs(), :name, name))
      assert errors_on(changeset).name != []
    end
  end

  test "accepts slug and UTF-8 name byte boundaries" do
    for {slug, name} <- [
          {"abc", "x"},
          {String.duplicate("a", 63), String.duplicate("a", 255)},
          {"utf8-name", String.duplicate("é", 127) <> "a"}
        ] do
      assert {:ok, project} = Projects.create_project(%{slug: slug, name: name})
      assert project.name == name
      assert project.slug == slug
    end
  end

  test "project slug conflicts return controlled changeset errors" do
    project = project_fixture()
    assert {:error, changeset} = Projects.create_project(%{slug: project.slug, name: "Duplicate"})
    assert "has already been taken" in errors_on(changeset).slug
  end

  test "lookups return nil for missing and malformed identifiers" do
    for value <- [nil, "", "invalid", 123, Ecto.UUID.generate()] do
      assert Projects.get_project_by_public_id(value) == nil
      assert Projects.get_service_account_by_public_id(value) == nil
    end

    for slug <- [nil, 123, "absent-project", String.duplicate("a", 64), <<255, 255, 255>>] do
      assert Projects.get_project_by_slug(slug) == nil
    end
  end

  test "creates each role and loads project/account associations" do
    project = project_fixture()

    accounts =
      for role <- ~w(admin producer viewer) do
        assert {:ok, account} = Projects.create_service_account(project, role, %{name: role})
        assert account.role == role
        assert account.disabled_at == nil
        assert {:ok, _uuid} = Ecto.UUID.cast(account.public_id)
        assert Projects.get_service_account_by_public_id(account.public_id) == account
        assert Repo.preload(account, :project).project == project
        account
      end

    assert Enum.sort_by(Repo.preload(project, :service_accounts).service_accounts, & &1.id) ==
             accounts
  end

  test "account attributes cannot replace trusted role, project, public identity, or lifecycle" do
    project = project_fixture()
    other = project_fixture()

    for string_keys? <- [false, true] do
      attrs = %{
        name: "Consumer #{string_keys?}",
        id: 1,
        project_id: other.id,
        public_id: Ecto.UUID.generate(),
        role: "admin",
        disabled_at: @now,
        inserted_at: @now,
        updated_at: @now
      }

      attrs = if string_keys?, do: string_keys(attrs), else: attrs
      assert {:ok, account} = Projects.create_service_account(project, "producer", attrs)
      assert account.project_id == project.id
      assert account.role == "producer"
      assert account.disabled_at == nil
      refute account.public_id == (attrs[:public_id] || attrs["public_id"])
      refute account.inserted_at == @now
    end
  end

  test "account names are bounded in bytes and roles are required and allowlisted" do
    project = project_fixture()

    for role <- [nil, "owner", "ADMIN", "", 123] do
      assert {:error, changeset} =
               Projects.create_service_account(project, role, %{name: "Account"})

      assert errors_on(changeset).role != []
    end

    for name <- [nil, "", " \t", String.duplicate("a", 256), String.duplicate("é", 128), 123] do
      assert {:error, changeset} =
               Projects.create_service_account(project, "admin", %{name: name})

      assert errors_on(changeset).name != []
    end

    assert {:ok, _account} =
             Projects.create_service_account(project, "viewer", %{
               name: String.duplicate("é", 127) <> "a"
             })
  end

  test "account name uniqueness is local to a project" do
    project = project_fixture()
    other = project_fixture()
    assert {:ok, _first} = Projects.create_service_account(project, "admin", %{name: "Consumer"})
    assert {:ok, _other} = Projects.create_service_account(other, "viewer", %{name: "Consumer"})

    assert {:error, changeset} =
             Projects.create_service_account(project, "producer", %{name: "Consumer"})

    assert "has already been taken" in errors_on(changeset).name
  end

  test "requires a persisted project and maps missing project references" do
    assert {:error, invalid} =
             Projects.create_service_account(%Project{}, "admin", %{name: "Account"})

    assert "can't be blank" in errors_on(invalid).project_id

    assert {:error, missing} =
             Projects.create_service_account(%Project{id: 9_223_372_036_854_775_807}, "admin", %{
               name: "Account"
             })

    assert "does not exist" in errors_on(missing).project_id
  end

  test "disable is permanent and preserves the first timestamp through a stale or altered struct" do
    project = project_fixture()
    {:ok, account} = Projects.create_service_account(project, "viewer", %{name: "Consumer"})

    altered = %{
      account
      | project_id: 1,
        public_id: Ecto.UUID.generate(),
        role: "admin",
        name: "Spoofed"
    }

    assert {:ok, disabled} = Projects.disable_service_account(altered, @now)
    assert disabled.disabled_at == @now
    assert disabled.updated_at == @now

    assert Map.take(disabled, [:project_id, :public_id, :role, :name]) ==
             Map.take(account, [:project_id, :public_id, :role, :name])

    assert {:ok, repeated} = Projects.disable_service_account(account, DateTime.add(@now, 60))
    assert repeated == disabled
    assert Projects.get_service_account_by_public_id(account.public_id) == disabled
  end

  test "suspension is one-way and preserves persisted identity and first transition time" do
    project = project_fixture()
    altered = %{project | public_id: Ecto.UUID.generate(), slug: "spoofed", name: "Spoofed"}
    assert {:ok, suspended} = Projects.suspend_project(altered, @now)
    assert suspended.status == "suspended"
    assert suspended.updated_at == @now

    assert {suspended.public_id, suspended.slug, suspended.name} ==
             {project.public_id, project.slug, project.name}

    assert {:ok, repeated} = Projects.suspend_project(project, DateTime.add(@now, 60))
    assert repeated == suspended
    assert Projects.get_project_by_public_id(project.public_id) == suspended
  end

  test "lifecycle operations require explicit UTC DateTimes and accept second precision" do
    project = project_fixture()
    {:ok, account} = Projects.create_service_account(project, "admin", %{name: "Consumer"})

    for invalid <- [nil, "2030-01-01", ~N[2030-01-01 00:00:00], %{@now | time_zone: "Other/Zone"}] do
      assert {:error, :invalid_timestamp} = Projects.disable_service_account(account, invalid)
      assert {:error, :invalid_timestamp} = Projects.suspend_project(project, invalid)
    end

    assert {:ok, disabled} = Projects.disable_service_account(account, ~U[2030-01-01 00:00:00Z])
    assert disabled.disabled_at == ~U[2030-01-01 00:00:00.000000Z]
    assert {:ok, suspended} = Projects.suspend_project(project, ~U[2030-01-01 00:00:00Z])
    assert suspended.updated_at == ~U[2030-01-01 00:00:00.000000Z]
  end

  test "lifecycle operations return controlled not_found for missing rows" do
    for id <- [nil, 9_223_372_036_854_775_807] do
      assert {:error, :not_found} =
               Projects.disable_service_account(%ServiceAccount{id: id}, @now)

      assert {:error, :not_found} = Projects.suspend_project(%Project{id: id}, @now)
    end
  end

  defp project_attrs do
    %{slug: "project-#{System.unique_integer([:positive])}", name: "Project"}
  end

  defp project_fixture do
    {:ok, project} = Projects.create_project(project_attrs())
    project
  end

  defp same_key_style(attrs, values) do
    if Enum.all?(Map.keys(attrs), &is_binary/1), do: string_keys(values), else: values
  end

  defp string_keys(attrs), do: Map.new(attrs, fn {key, value} -> {Atom.to_string(key), value} end)
end
