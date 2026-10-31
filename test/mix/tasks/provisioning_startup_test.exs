defmodule Tidewake.ProvisioningStartupTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.Postgres
  alias Tidewake.Repo

  @tag timeout: 120_000
  test "cold provisioning persists all lifecycle operations without starting HTTP or Oban" do
    partition = "_provisioning_#{System.system_time(:microsecond)}"
    database = "tidewake_test#{partition}"

    config =
      Repo.config() |> Keyword.drop([:url, :pool, :name]) |> Keyword.put(:database, database)

    script = Path.join(System.tmp_dir!(), "#{database}.exs")
    assert :ok = Postgres.storage_up(config)

    try do
      File.write!(script, """
      import ExUnit.Assertions
      ExUnit.start(autorun: false)
      alias Tidewake.{Projects, Repo}
      alias Tidewake.Projects.{ApiCredential, ServiceAccount}

      Mix.Task.run("ecto.migrate", ["--quiet"])
      assert Application.fetch_env!(:tidewake, TidewakeWeb.Endpoint)[:server]
      Application.put_env(:tidewake, Oban,
        repo: Repo,
        queues: [default: 10, maintenance: 1],
        cron: [crontab: [{"* * * * *", Tidewake.Workers.RecoverStaleDeliveriesWorker}]]
      )
      conf = Oban.Config.new(Application.fetch_env!(:tidewake, Oban))
      assert conf.queues != [] and conf.plugins != []

      run = fn task, args ->
        try do
          output = ExUnit.CaptureIO.capture_io(fn -> Mix.Task.run(task, args) end)
          String.split(output, "\\n", trim: true)
        after
          for name <- [Tidewake.Supervisor, TidewakeWeb.Endpoint, Oban, Repo] do
            assert Process.whereis(name) == nil
          end
          refute Enum.any?(Application.started_applications(), fn {app, _, _} -> app == :tidewake end)
        end
      end

      ["Project: " <> project] = run.("tidewake.projects.create", ~w(--name Cold --slug cold))
      Mix.Task.reenable("tidewake.projects.create")
      assert_raise Mix.Error, "Provisioning failed; no credential is returned.", fn ->
        run.("tidewake.projects.create", ~w(--name Duplicate --slug cold))
      end
      ["Service account: " <> account, "Credential: " <> credential, "Token: " <> _token] =
        run.("tidewake.service_accounts.provision",
          ["--project", project, "--name", "Cold", "--role", "admin", "--expires-in-days", "1"])
      ["Credential: " <> _second, "Token: " <> token] =
        run.("tidewake.service_accounts.issue_credential",
          ["--project", project, "--service-account", account, "--expires-in-days", "1"])
      {:ok, {:ok, _identity}, _apps} = Ecto.Migrator.with_repo(Repo, fn _repo ->
        Projects.authenticate_credential(token, DateTime.utc_now())
      end)
      assert run.("tidewake.service_accounts.revoke_credential",
        ["--project", project, "--credential", credential]) == ["Credential: " <> credential]
      assert run.("tidewake.service_accounts.disable",
        ["--project", project, "--service-account", account]) == ["Service account: " <> account]
      assert run.("tidewake.projects.suspend", ["--project", project]) == ["Project: " <> project]

      {:ok, :ok, _apps} = Ecto.Migrator.with_repo(Repo, fn _repo ->
        assert Projects.get_project_by_slug("cold").status == "suspended"
        assert Repo.one!(ServiceAccount).disabled_at
        assert Repo.aggregate(ApiCredential, :count) == 2
        assert Repo.get_by!(ApiCredential, public_id: credential).revoked_at
        assert Projects.authenticate_credential(token, DateTime.utc_now()) == {:error, :invalid_credential}
        :ok
      end)
      assert Process.whereis(Repo) == nil
      IO.puts("PROVISIONING_STARTUP_OK")
      """)

      {output, status} =
        System.cmd(System.find_executable("elixir"), ["-S", "mix", "run", "--no-start", script],
          env: [{"MIX_ENV", "test"}, {"MIX_TEST_PARTITION", partition}, {"PHX_SERVER", "true"}],
          stderr_to_stdout: true
        )

      # Never include child output in failures: issuance may have printed a raw token.
      assert status == 0
      completed? = String.contains?(output, "PROVISIONING_STARTUP_OK")
      assert completed?
    after
      File.rm(script)
      assert :ok = Postgres.storage_down(config)
    end
  end
end
