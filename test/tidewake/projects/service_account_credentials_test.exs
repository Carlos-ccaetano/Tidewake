defmodule Tidewake.Projects.ServiceAccountCredentialsTest do
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias Ecto.Adapters.SQL.Sandbox
  alias Tidewake.Projects
  alias Tidewake.Projects.{ApiCredential, Project, ServiceAccount, ServiceAccountToken}
  alias Tidewake.Repo

  @pepper String.duplicate("p", 32)
  @opts [log: false, telemetry_event: nil]

  setup tags do
    previous = Application.fetch_env(:tidewake, :service_account_token_pepper)
    Application.put_env(:tidewake, :service_account_token_pepper, @pepper)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:tidewake, :service_account_token_pepper, value)
        :error -> Application.delete_env(:tidewake, :service_account_token_pepper)
      end
    end)

    if tags[:unboxed] do
      fixture = Sandbox.unboxed_run(Repo, &fixture/0)
      on_exit(fn -> cleanup(fixture) end)
      fixture
    else
      Tidewake.DataCase.setup_sandbox(tags)
      fixture()
    end
  end

  test "issuance persists only a digest and authentication returns only account/project", %{
    account: account,
    project: project
  } do
    issued = issue(account)
    stored = Repo.get!(ApiCredential, issued.credential.id)
    assert {:ok, digest} = ServiceAccountToken.digest(issued.token, @pepper)
    assert stored.secret_digest == digest
    assert stored.service_account_id == account.id
    assert byte_size(stored.secret_digest) == 32
    assert issued.digest == nil
    assert issued.credential.secret_digest == nil
    refute inspect(issued) =~ issued.token
    refute inspect(stored) =~ inspect(digest)
    refute Map.has_key?(stored, :token)
    refute Map.has_key?(stored, :raw_token)
    assert {:ok, identity} = Projects.authenticate_credential(issued.token, DateTime.utc_now())
    assert Enum.sort(Map.keys(identity)) == [:project, :service_account]
    assert identity.project.id == project.id
    assert identity.service_account.id == account.id
    assert identity.service_account.public_id == account.public_id
    refute Ecto.assoc_loaded?(identity.service_account.credentials)
    refute inspect(identity) =~ issued.token
    refute inspect(identity) =~ inspect(digest)
  end

  test "rotation creates independent overlapping credentials without changing account identity",
       %{account: account} do
    first = issue(account)
    second = issue(account)
    refute first.token == second.token
    refute first.credential.public_id == second.credential.public_id

    for issued <- [first, second] do
      assert {:ok, %{service_account: authenticated}} =
               Projects.authenticate_credential(issued.token, DateTime.utc_now())

      assert authenticated.public_id == account.public_id
      assert authenticated.role == account.role
    end

    assert Repo.aggregate(ApiCredential, :count) == 2
  end

  test "failed issuance creates no row and returns no token-bearing changeset", %{
    account: account
  } do
    for expiry <- [
          nil,
          "bad",
          DateTime.add(DateTime.utc_now(), -1),
          DateTime.add(DateTime.utc_now(), 366 * 86_400)
        ] do
      assert Projects.issue_credential(account, expiry) == {:error, :credential_issue_failed}
    end

    assert Projects.issue_credential(%ServiceAccount{}, future()) ==
             {:error, :credential_issue_failed}

    assert Projects.issue_credential(%ServiceAccount{id: 9_223_372_036_854_775_807}, future()) ==
             {:error, :credential_issue_failed}

    assert Repo.aggregate(ApiCredential, :count) == 0
  end

  test "issuance rejects an outer transaction instead of returning a token before commit", %{
    account: account
  } do
    assert {:ok, {:error, :credential_issue_failed}} =
             Repo.transaction(fn -> Projects.issue_credential(account, future()) end)

    assert Repo.aggregate(ApiCredential, :count) == 0
  end

  test "revocation preserves its first timestamp and is scoped to its account", %{
    account: account,
    project: project
  } do
    issued = issue(account)
    {:ok, other} = Projects.create_service_account(project, "viewer", %{name: "Other"})
    now = DateTime.utc_now()

    assert Projects.revoke_credential(other, issued.credential.public_id, now) ==
             {:error, :invalid_credential}

    assert {:ok, _identity} = Projects.authenticate_credential(issued.token, now)
    assert {:ok, revoked} = Projects.revoke_credential(account, issued.credential.public_id, now)
    assert revoked.revoked_at == now
    assert revoked.secret_digest == nil

    assert {:ok, repeated} =
             Projects.revoke_credential(
               account,
               issued.credential.public_id,
               DateTime.add(now, 60)
             )

    assert repeated.revoked_at == now
    assert repeated.updated_at == revoked.updated_at
    assert Projects.authenticate_credential(issued.token, now) == {:error, :invalid_credential}
    assert Repo.aggregate(ApiCredential, :count) == 1
  end

  test "invalid revocation and backdating fail without changing the credential", %{
    account: account
  } do
    issued = issue(account)

    for {uuid, time} <- [
          {"bad", DateTime.utc_now()},
          {Ecto.UUID.generate(), DateTime.utc_now()},
          {issued.credential.public_id, nil},
          {issued.credential.public_id, DateTime.add(issued.credential.inserted_at, -1)}
        ] do
      assert Projects.revoke_credential(account, uuid, time) == {:error, :invalid_credential}
    end

    assert Repo.get!(ApiCredential, issued.credential.id).revoked_at == nil
  end

  test "expiry equality is invalid but one microsecond before expiry is valid", %{
    account: account
  } do
    issued = issue(account)
    expiry = issued.credential.expires_at

    assert {:ok, _identity} =
             Projects.authenticate_credential(
               issued.token,
               DateTime.add(expiry, -1, :microsecond)
             )

    assert Projects.authenticate_credential(issued.token, expiry) == {:error, :invalid_credential}

    assert Projects.authenticate_credential(issued.token, DateTime.add(expiry, 1)) ==
             {:error, :invalid_credential}
  end

  test "disabled account is reloaded for authentication and issuance", %{account: account} do
    issued = issue(account)
    assert {:ok, _disabled} = Projects.disable_service_account(account, DateTime.utc_now())

    assert Projects.authenticate_credential(issued.token, DateTime.utc_now()) ==
             {:error, :invalid_credential}

    assert Projects.issue_credential(account, future()) == {:error, :credential_issue_failed}
  end

  test "suspended project is reloaded for authentication and issuance", %{
    account: account,
    project: project
  } do
    issued = issue(account)
    assert {:ok, _suspended} = Projects.suspend_project(project, DateTime.utc_now())

    assert Projects.authenticate_credential(issued.token, DateTime.utc_now()) ==
             {:error, :invalid_credential}

    assert Projects.issue_credential(account, future()) == {:error, :credential_issue_failed}
  end

  test "unknown credential, wrong secret, wrong digest, and malformed inputs share one error", %{
    account: account
  } do
    issued = issue(account)
    uuid = issued.credential.public_id
    wrong_secret = "twk_sa." <> uuid <> "." <> Base.url_encode64(<<0::256>>, padding: false)
    unknown = String.replace(issued.token, uuid, Ecto.UUID.generate())

    for token <- [nil, "bad", issued.token <> " ", wrong_secret, unknown] do
      assert Projects.authenticate_credential(token, DateTime.utc_now()) ==
               {:error, :invalid_credential}
    end

    assert Projects.authenticate_credential(issued.token, nil) == {:error, :invalid_credential}

    Repo.update_all(
      from(c in ApiCredential, where: c.id == ^issued.credential.id),
      [set: [secret_digest: <<0::256>>]],
      @opts
    )

    assert Projects.authenticate_credential(issued.token, DateTime.utc_now()) ==
             {:error, :invalid_credential}
  end

  test "pepper changes or missing configuration fail closed", %{account: account} do
    issued = issue(account)

    for pepper <- [nil, "too-short", String.duplicate("q", 32)] do
      Application.put_env(:tidewake, :service_account_token_pepper, pepper)

      assert Projects.authenticate_credential(issued.token, DateTime.utc_now()) ==
               {:error, :invalid_credential}
    end

    Application.delete_env(:tidewake, :service_account_token_pepper)
    assert Projects.issue_credential(account, future()) == {:error, :credential_issue_failed}

    assert Projects.authenticate_credential(issued.token, DateTime.utc_now()) ==
             {:error, :invalid_credential}

    assert Repo.aggregate(ApiCredential, :count) == 1
  end

  test "credential operations emit no query Telemetry and no secrets in debug logs or errors", %{
    account: account
  } do
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(handler, [:tidewake, :repo, :query], &__MODULE__.query_event/4, self())

    on_exit(fn -> :telemetry.detach(handler) end)
    Repo.query!("SELECT 1")
    assert_receive :credential_query_event
    level = Logger.level()
    Logger.configure(level: :debug)

    try do
      logs =
        capture_log(fn ->
          issued = issue(account)
          send(self(), {:issued_for_privacy, issued})

          assert {:ok, _identity} =
                   Projects.authenticate_credential(issued.token, DateTime.utc_now())

          assert {:ok, _revoked} =
                   Projects.revoke_credential(
                     account,
                     issued.credential.public_id,
                     DateTime.utc_now()
                   )

          assert Projects.authenticate_credential(issued.token, DateTime.utc_now()) ==
                   {:error, :invalid_credential}

          assert Projects.authenticate_credential(issued.token <> " ", DateTime.utc_now()) ==
                   {:error, :invalid_credential}
        end)

      assert_receive {:issued_for_privacy, issued}
      [_, _, secret] = String.split(issued.token, ".")
      assert {:ok, digest} = ServiceAccountToken.digest(issued.token, @pepper)

      for sensitive <- [
            issued.token,
            secret,
            @pepper,
            inspect(digest),
            Base.encode16(digest),
            issued.credential.public_id
          ] do
        refute logs =~ sensitive
      end

      refute logs =~ "service_account_credentials"
      refute_received :credential_query_event
    after
      Logger.configure(level: level)
    end
  end

  @tag :unboxed
  test "revocation and authentication race on separate PostgreSQL connections", %{
    account: account
  } do
    issued = Sandbox.unboxed_run(Repo, fn -> issue(account) end)
    supervisor = start_supervised!(Task.Supervisor)
    parent = self()
    barrier = make_ref()

    tasks =
      for operation <- [:revoke, :authenticate] do
        Task.Supervisor.async_nolink(supervisor, fn ->
          Sandbox.unboxed_run(Repo, fn ->
            %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()", [], @opts)
            send(parent, {barrier, :ready, self(), backend})

            receive do
              {^barrier, :go} ->
                case operation do
                  :revoke ->
                    Projects.revoke_credential(
                      account,
                      issued.credential.public_id,
                      DateTime.utc_now()
                    )

                  :authenticate ->
                    Projects.authenticate_credential(issued.token, DateTime.utc_now())
                end
            after
              5_000 -> flunk("credential race barrier timed out")
            end
          end)
        end)
      end

    backends =
      for task <- tasks do
        pid = task.pid
        assert_receive {^barrier, :ready, ^pid, backend}, 5_000
        backend
      end

    assert length(Enum.uniq(backends)) == 2
    Enum.each(tasks, &send(&1.pid, {barrier, :go}))

    assert [{:ok, %ApiCredential{revoked_at: %DateTime{}}}, authentication] =
             Enum.map(tasks, &Task.await(&1, 5_000))

    assert match?({:ok, %{service_account: %ServiceAccount{}}}, authentication) or
             authentication == {:error, :invalid_credential}

    Sandbox.unboxed_run(Repo, fn ->
      assert Projects.authenticate_credential(issued.token, DateTime.utc_now()) ==
               {:error, :invalid_credential}
    end)
  end

  def query_event(_event, _measurements, _metadata, test_pid) do
    if self() == test_pid, do: send(test_pid, :credential_query_event)
  end

  defp fixture do
    {:ok, project} =
      Projects.create_project(%{
        slug: "credentials-#{System.unique_integer([:positive])}",
        name: "Credentials"
      })

    {:ok, account} = Projects.create_service_account(project, "admin", %{name: "Consumer"})
    %{project: project, account: account}
  end

  defp issue(account) do
    assert {:ok, issued} = Projects.issue_credential(account, future())
    issued
  end

  defp future, do: DateTime.add(DateTime.utc_now(), 3_600)

  defp cleanup(%{project: project, account: account}) do
    Sandbox.unboxed_run(Repo, fn ->
      Repo.delete_all(from(c in ApiCredential, where: c.service_account_id == ^account.id), @opts)
      Repo.delete_all(from(a in ServiceAccount, where: a.id == ^account.id), @opts)
      Repo.delete_all(from(p in Project, where: p.id == ^project.id), @opts)
    end)
  end
end
