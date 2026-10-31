defmodule Tidewake.Webhooks.ManualRetryJobs do
  @moduledoc false

  alias Oban.Engines.Basic
  alias Tidewake.Repo

  @private_opts [log: false, telemetry_event: nil]

  # Oban.insert emits the job changeset; Basic retains its uniqueness algorithm without that span.
  def insert(changeset) do
    conf = Oban.config()

    with true <- conf.engine == Basic,
         {:ok, job} <- Basic.insert_job(%{conf | repo: __MODULE__}, changeset, retry: false),
         :ok <- notify(conf, job) do
      {:ok, job}
    else
      false -> {:error, :persistence_error}
      {:error, _reason} -> {:error, :persistence_error}
    end
  end

  defp notify(%{insert_trigger: true} = conf, %{state: "available", conflict?: false} = job),
    do: Oban.Notifier.notify(conf, :insert, [%{queue: job.queue}])

  defp notify(_conf, _job), do: :ok

  # The Basic engine's internal queries otherwise discard per-insert privacy options.
  def one(query, opts), do: Repo.one(query, Keyword.merge(opts, @private_opts))
  def insert(changeset, opts), do: Repo.insert(changeset, Keyword.merge(opts, @private_opts))
  def update(changeset, opts), do: Repo.update(changeset, Keyword.merge(opts, @private_opts))

  def query("SELECT pg_try_advisory_xact_lock($1)", params, opts),
    do:
      Repo.query(
        "SELECT pg_try_advisory_xact_lock($1)",
        params,
        Keyword.merge(opts, @private_opts)
      )

  def transaction(fun, opts), do: Repo.transaction(fun, Keyword.merge(opts, @private_opts))
  defdelegate get_dynamic_repo(), to: Repo
  defdelegate put_dynamic_repo(repo), to: Repo
  defdelegate in_transaction?(), to: Repo
  defdelegate rollback(reason), to: Repo
end
