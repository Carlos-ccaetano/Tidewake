defmodule Tidewake.ProvisioningTasksTest do
  use Tidewake.DataCase, async: false

  import ExUnit.CaptureIO

  alias Tidewake.Projects
  alias Tidewake.Projects.{ApiCredential, Project, ServiceAccount, ServiceAccountToken}

  @create Mix.Tasks.Tidewake.Projects.Create
  @provision Mix.Tasks.Tidewake.ServiceAccounts.Provision
  @issue Mix.Tasks.Tidewake.ServiceAccounts.IssueCredential
  @revoke Mix.Tasks.Tidewake.ServiceAccounts.RevokeCredential
  @disable Mix.Tasks.Tidewake.ServiceAccounts.Disable
  @suspend Mix.Tasks.Tidewake.Projects.Suspend

  setup do
    {:ok, project} = Projects.create_project(%{name: "Operations", slug: "operations"})
    {:ok, foreign} = Projects.create_project(%{name: "Foreign", slug: "foreign"})
    %{project: project, foreign: foreign}
  end

  test "creates projects with generated identities and rejects duplicate slugs" do
    before_count = Repo.aggregate(Project, :count)
    output = capture_io(fn -> @create.run(~w(--name New --slug new-project)) end)
    project = Projects.get_project_by_slug("new-project")
    assert output == "Project: #{project.public_id}\n"
    assert project.name == "New"
    assert project.status == "active"
    assert_failure(@create, ~w(--name Other --slug new-project))
    assert Repo.aggregate(Project, :count) == before_count + 1
  end

  for role <- ~w(admin producer viewer), days <- [1, 365] do
    test "provisions #{role} with #{days} days without leaking verification material",
         %{project: project} do
      {account, credential, token, output} =
        provision(project, unquote(role), unquote(days))

      assert account.role == unquote(role)
      assert account.project_id == project.id
      assert account.disabled_at == nil
      assert credential.service_account_id == account.id

      assert DateTime.diff(credential.expires_at, credential.inserted_at) ==
               unquote(days) * 86_400

      assert {:ok, digest} = ServiceAccountToken.digest(token)
      assert digest == credential.secret_digest
      assert {:ok, identity} = Projects.authenticate_credential(token, DateTime.utc_now())
      assert identity.service_account.public_id == account.public_id
      assert output =~ "Service account: #{account.public_id}\n"
      assert output =~ "Credential: #{credential.public_id}\n"
      assert_private_output(output, token, digest)
    end
  end

  test "a duplicate name never reuses the existing account or issues another credential",
       %{project: project} do
    {account, _, _, _} = provision(project)
    assert_failure(@provision, provision_args(project))
    assert Repo.all(ServiceAccount) |> Enum.map(& &1.id) == [account.id]
    assert Repo.aggregate(ApiCredential, :count) == 1
  end

  test "rotation preserves account, project, role and audit subject", %{project: project} do
    {account, first, first_token, _} = provision(project)
    output = capture_io(fn -> @issue.run(issue_args(project, account, 365)) end)
    second_token = token!(output)
    {:ok, id} = ServiceAccountToken.parse(second_token)
    second = Repo.get_by!(ApiCredential, public_id: id)
    assert second.id != first.id
    assert second.service_account_id == account.id
    assert {:ok, identity} = Projects.authenticate_credential(second_token, DateTime.utc_now())
    assert identity.service_account.public_id == account.public_id
    assert identity.service_account.project_id == account.project_id
    assert identity.service_account.role == account.role
    assert {:ok, _} = Projects.authenticate_credential(first_token, DateTime.utc_now())
    assert_private_output(output, second_token, second.secret_digest)
    assert Repo.get!(ServiceAccount, account.id) == account
  end

  test "revocation and disable are irreversible and preserve their first timestamp",
       %{project: project} do
    {account, credential, token, _} = provision(project)
    revoke_args = ["--project", project.public_id, "--credential", credential.public_id]
    first_output = capture_io(fn -> @revoke.run(revoke_args) end)
    first = Repo.get!(ApiCredential, credential.id)
    assert first.revoked_at

    assert {:error, :invalid_credential} =
             Projects.authenticate_credential(token, DateTime.utc_now())

    assert capture_io(fn -> @revoke.run(revoke_args) end) == first_output
    assert Repo.get!(ApiCredential, credential.id).revoked_at == first.revoked_at

    rotated = capture_io(fn -> @issue.run(issue_args(project, account)) end) |> token!()
    args = ["--project", project.public_id, "--service-account", account.public_id]
    output = capture_io(fn -> @disable.run(args) end)
    disabled = Repo.get!(ServiceAccount, account.id)
    assert disabled.disabled_at
    assert capture_io(fn -> @disable.run(args) end) == output
    assert Repo.get!(ServiceAccount, account.id).disabled_at == disabled.disabled_at

    assert {:error, :invalid_credential} =
             Projects.authenticate_credential(rotated, DateTime.utc_now())

    assert_failure(@issue, issue_args(project, account))
    refute first_output <> output =~ token
    refute first_output <> output =~ rotated
    refute first_output <> output =~ inspect(credential.secret_digest)

    refute first_output <> output =~
             Application.fetch_env!(:tidewake, :service_account_token_pepper)
  end

  test "cross-project emission, revocation and disable leave all state unchanged",
       %{project: project, foreign: foreign} do
    {account, credential, token, _} = provision(project)
    assert_failure(@issue, issue_args(foreign, account))

    assert_failure(@revoke, ["--project", foreign.public_id, "--credential", credential.public_id])

    assert_failure(@disable, [
      "--project",
      foreign.public_id,
      "--service-account",
      account.public_id
    ])

    assert Repo.get!(ServiceAccount, account.id) == account
    assert Repo.get!(ApiCredential, credential.id) == credential
    assert Repo.aggregate(ApiCredential, :count) == 1
    assert {:ok, _} = Projects.authenticate_credential(token, DateTime.utc_now())
    assert Repo.get!(Project, foreign.id).status == "active"
  end

  test "suspension blocks issuance, provisioning and authentication without implicit reactivation",
       %{project: project, foreign: foreign} do
    {account, _, token, _} = provision(project)
    args = ["--project", project.public_id]
    output = capture_io(fn -> @suspend.run(args) end)
    suspended = Repo.get!(Project, project.id)
    assert suspended.status == "suspended"
    assert capture_io(fn -> @suspend.run(args) end) == output
    assert Repo.get!(Project, project.id) == suspended
    assert Repo.get!(Project, foreign.id).status == "active"
    assert_failure(@provision, provision_args(project, "Other"))
    assert_failure(@issue, issue_args(project, account))

    assert {:error, :invalid_credential} =
             Projects.authenticate_credential(token, DateTime.utc_now())

    assert Repo.aggregate(ServiceAccount, :count) == 1
    assert Repo.aggregate(ApiCredential, :count) == 1
  end

  test "missing projects, accounts and credentials fail without echoing identifiers",
       %{project: project} do
    missing = Ecto.UUID.generate()

    for {task, args} <- [
          {@provision,
           ["--project", missing, "--name", "New", "--role", "admin", "--expires-in-days", "1"]},
          {@issue,
           [
             "--project",
             project.public_id,
             "--service-account",
             missing,
             "--expires-in-days",
             "1"
           ]},
          {@issue,
           ["--project", missing, "--service-account", missing, "--expires-in-days", "1"]},
          {@revoke, ["--project", project.public_id, "--credential", missing]},
          {@disable, ["--project", project.public_id, "--service-account", missing]},
          {@suspend, ["--project", missing]}
        ] do
      assert_failure(task, args)
    end

    assert Repo.aggregate(ServiceAccount, :count) == 0
    assert Repo.aggregate(ApiCredential, :count) == 0
  end

  test "strict parsing rejects missing, duplicate, extra and identity-changing options",
       %{project: project} do
    {account, credential, _, _} = provision(project)

    tasks = [
      {@create, ~w(--name New --slug new-project)},
      {@provision, provision_args(project, "Other")},
      {@issue, issue_args(project, account)},
      {@revoke, ["--project", project.public_id, "--credential", credential.public_id]},
      {@disable, ["--project", project.public_id, "--service-account", account.public_id]},
      {@suspend, ["--project", project.public_id]}
    ]

    for {task, args} <- tasks,
        invalid <- [
          [],
          Enum.drop(args, 2),
          args ++ Enum.take(args, 2),
          args ++ ["extra"],
          args ++ ["--unknown", "value"],
          args ++ ["--digest", "secret"],
          args ++ ["--actor-subject", "actor"],
          args ++ ["--public-id", Ecto.UUID.generate()],
          args ++ ["--delete"],
          args ++ ["--reactivate"],
          args ++ ["--project-id", "1"]
        ] do
      assert_failure(task, invalid)
    end

    for role <- ["owner", "ADMIN", "", "admin producer"],
        do:
          assert_failure(
            @provision,
            replace_option(provision_args(project, "Other"), "--role", role)
          )

    for days <- ["0", "-1", "366", "1.5", "1x", ""] do
      assert_failure(
        @provision,
        replace_option(provision_args(project, "Other"), "--expires-in-days", days)
      )

      assert_failure(
        @issue,
        replace_option(issue_args(project, account), "--expires-in-days", days)
      )
    end

    for bad_id <- ["1", "", String.upcase(project.public_id), " " <> project.public_id] do
      assert_failure(@suspend, ["--project", bad_id])
    end

    for name <- ["", "  ", String.duplicate("a", 256)] do
      assert_failure(@provision, replace_option(provision_args(project, "Other"), "--name", name))
    end

    assert Repo.aggregate(ServiceAccount, :count) == 1
    assert Repo.aggregate(ApiCredential, :count) == 1
    assert Repo.get!(Project, project.id).status == "active"
  end

  test "invalid pepper rolls back both initial account and credential without printing secrets",
       %{project: project} do
    previous = Application.fetch_env!(:tidewake, :service_account_token_pepper)

    try do
      Application.put_env(:tidewake, :service_account_token_pepper, "invalid-private-pepper")
      assert_failure(@provision, provision_args(project))
      assert Repo.aggregate(ServiceAccount, :count) == 0
      assert Repo.aggregate(ApiCredential, :count) == 0
    after
      Application.put_env(:tidewake, :service_account_token_pepper, previous)
    end
  end

  test "issuance inside an outer transaction fails before writing or printing a token",
       %{project: project} do
    {account, _, _, _} = provision(project)

    Repo.transaction(fn ->
      assert_failure(@provision, provision_args(project, "Other"))
      assert_failure(@issue, issue_args(project, account))
      Repo.rollback(:expected)
    end)

    assert Repo.aggregate(ServiceAccount, :count) == 1
    assert Repo.aggregate(ApiCredential, :count) == 1
  end

  defp provision(project, role \\ "admin", days \\ 30) do
    args =
      provision_args(project)
      |> replace_option("--role", role)
      |> replace_option("--expires-in-days", to_string(days))

    output = capture_io(fn -> @provision.run(args) end)
    token = token!(output)
    {:ok, id} = ServiceAccountToken.parse(token)
    credential = Repo.get_by!(ApiCredential, public_id: id)
    {Repo.get!(ServiceAccount, credential.service_account_id), credential, token, output}
  end

  defp provision_args(project, name \\ "Consumer") do
    ["--project", project.public_id, "--name", name, "--role", "admin", "--expires-in-days", "30"]
  end

  defp issue_args(project, account, days \\ 30) do
    [
      "--project",
      project.public_id,
      "--service-account",
      account.public_id,
      "--expires-in-days",
      to_string(days)
    ]
  end

  defp replace_option(args, key, value) do
    args
    |> Enum.chunk_every(2)
    |> Enum.flat_map(fn
      [^key, _old] -> [key, value]
      pair -> pair
    end)
  end

  defp token!(output) do
    [_, token] = Regex.run(~r/^Token: (twk_sa\.[^\s]+)$/m, output)
    token
  end

  defp assert_private_output(output, token, digest) do
    assert length(:binary.matches(output, token)) == 1
    assert length(:binary.matches(output, "twk_sa.")) == 1
    refute output =~ Application.fetch_env!(:tidewake, :service_account_token_pepper)
    refute output =~ inspect(digest)
    refute output =~ Base.encode16(digest)
    refute output =~ Base.encode64(digest)
  end

  defp assert_failure(task, args) do
    output =
      capture_io(fn ->
        error = assert_raise Mix.Error, fn -> task.run(args) end
        refute error.message =~ "twk_sa."
        refute error.message =~ "invalid-private-pepper"
      end)

    assert output == ""
  end
end
