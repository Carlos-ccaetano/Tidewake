defmodule Tidewake.Provisioning do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias Tidewake.Projects
  alias Tidewake.Projects.{ApiCredential, Project, ServiceAccount, ServiceAccountToken}
  alias Tidewake.Repo

  @repo_opts [log: false, telemetry_event: nil]
  @failure "Provisioning failed; no credential is returned."

  def run(action, args, switches) do
    opts = parse!(args, switches)
    Mix.Task.run("app.start")

    result = execute(action, opts)
    print_result(result)
  end

  defp parse!(args, switches) do
    strict = Enum.map(switches, fn {key, type} -> {key, [type, :keep]} end)
    {opts, rest, invalid} = OptionParser.parse(args, strict: strict)
    keys = Keyword.keys(opts)

    unless rest == [] and invalid == [] and
             Enum.sort(keys) == Enum.sort(Keyword.keys(switches)) do
      Mix.raise("Expected each required option exactly once; no extra arguments are accepted.")
    end

    Enum.each(opts, &validate_option!/1)
    opts
  end

  defp validate_option!({key, value}) when key in [:project, :service_account, :credential] do
    unless Ecto.UUID.cast(value) == {:ok, value},
      do: Mix.raise("Expected a canonical public UUID.")
  end

  defp validate_option!({:role, role}) do
    unless role in ~w(admin producer viewer),
      do: Mix.raise("Expected role admin, producer or viewer.")
  end

  defp validate_option!({:expires_in_days, days}) do
    unless days in 1..365, do: Mix.raise("Expected expires-in-days between 1 and 365.")
  end

  defp validate_option!({_key, value}) do
    unless String.valid?(value) and String.trim(value) != "" and byte_size(value) <= 255,
      do: Mix.raise("Expected a nonblank name or slug of at most 255 bytes.")
  end

  defp execute(action, opts) do
    # Never emit a token from an enclosing transaction that could still roll back.
    if Repo.in_transaction?(), do: Mix.raise(@failure)
    perform(action, opts)
  rescue
    _failure -> Mix.raise(@failure)
  end

  defp perform(:create, opts) do
    Projects.create_project(%{name: opts[:name], slug: opts[:slug]})
  end

  defp perform(:provision, opts) do
    Repo.transaction(
      fn ->
        project = project!(opts[:project], true)
        unless project.status == "active", do: Repo.rollback(:inactive_project)

        with {:ok, account} <-
               Projects.create_service_account(project, opts[:role], %{name: opts[:name]}),
             {:ok, generated} <- ServiceAccountToken.generate(Ecto.UUID.generate()),
             now = DateTime.utc_now(),
             changeset =
               ApiCredential.create_changeset(
                 %ApiCredential{
                   service_account_id: account.id,
                   public_id: credential_id(generated.token),
                   secret_digest: generated.digest,
                   inserted_at: now
                 },
                 %{expires_at: DateTime.add(now, opts[:expires_in_days] * 86_400)}
               ),
             {:ok, credential} <- Repo.insert(changeset, @repo_opts) do
          %{
            account: account,
            issued: %{generated | credential: %{credential | secret_digest: nil}, digest: nil}
          }
        else
          _failure -> Repo.rollback(:provisioning_failed)
        end
      end,
      @repo_opts
    )
  end

  defp perform(:issue, opts) do
    account = account!(opts[:project], opts[:service_account])

    Projects.issue_credential(
      account,
      DateTime.add(DateTime.utc_now(), opts[:expires_in_days] * 86_400)
    )
  end

  defp perform(:revoke, opts) do
    project = project!(opts[:project])

    account =
      Repo.one!(
        from(account in ServiceAccount,
          join: credential in assoc(account, :credentials),
          where: account.project_id == ^project.id and credential.public_id == ^opts[:credential]
        ),
        @repo_opts
      )

    Projects.revoke_credential(account, opts[:credential], DateTime.utc_now())
  end

  defp perform(:disable, opts) do
    opts[:project]
    |> account!(opts[:service_account])
    |> Projects.disable_service_account(DateTime.utc_now())
  end

  defp perform(:suspend, opts) do
    opts[:project] |> project!() |> Projects.suspend_project(DateTime.utc_now())
  end

  defp project!(public_id, lock? \\ false) do
    query = from(project in Project, where: project.public_id == ^public_id)
    query = if lock?, do: from(project in query, lock: "FOR SHARE"), else: query
    Repo.one!(query, @repo_opts)
  end

  defp account!(project_id, account_id) do
    project = project!(project_id)

    Repo.one!(
      from(account in ServiceAccount,
        where: account.project_id == ^project.id and account.public_id == ^account_id
      ),
      @repo_opts
    )
  end

  defp credential_id(token) do
    {:ok, public_id} = ServiceAccountToken.parse(token)
    public_id
  end

  defp print_result({:ok, %ServiceAccountToken{} = issued}) do
    IO.puts("Credential: #{issued.credential.public_id}")
    IO.puts("Token: #{issued.token}")
  end

  defp print_result({:ok, %{account: account, issued: issued}}) do
    IO.puts("Service account: #{account.public_id}")
    print_result({:ok, issued})
  end

  defp print_result({:ok, %Project{} = project}), do: IO.puts("Project: #{project.public_id}")

  defp print_result({:ok, %ServiceAccount{} = account}),
    do: IO.puts("Service account: #{account.public_id}")

  defp print_result({:ok, %ApiCredential{} = credential}),
    do: IO.puts("Credential: #{credential.public_id}")

  defp print_result(_failure), do: Mix.raise(@failure)
end
