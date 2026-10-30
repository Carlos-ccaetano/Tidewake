defmodule Tidewake.Projects.ManualRetryRateLimiter do
  @moduledoc """
  Durable manual-retry admission for a trusted internal service-account ID.

  Call after authentication and admin authorization, outside the domain transaction.
  The default clock is sampled from PostgreSQL after locking; an explicit UTC instant
  makes boundary tests deterministic. Credential identity never enters this API.
  """

  import Ecto.Query, only: [from: 2]

  alias Tidewake.Projects.ManualRetryRateLimit
  alias Tidewake.Repo

  @repo_opts [log: false, telemetry_event: nil]
  @interval_us 12_000_000

  @spec consume(integer(), DateTime.t() | nil) ::
          :allowed | {:denied, pos_integer()} | {:error, :unavailable}
  def consume(service_account_id, now \\ nil)

  def consume(id, now) when is_integer(id) and id > 0 and id <= 9_223_372_036_854_775_807 do
    with true <- valid_clock?(now) and not Repo.in_transaction?(),
         {:ok, result} <- Repo.transaction(fn -> consume_locked(id, now) end, @repo_opts) do
      result
    else
      _failure -> {:error, :unavailable}
    end
  rescue
    _failure -> {:error, :unavailable}
  end

  def consume(_id, _now), do: {:error, :unavailable}

  defp consume_locked(id, injected_now) do
    Repo.query!(
      """
      INSERT INTO manual_retry_rate_limits
        (service_account_id, tokens, refilled_at, inserted_at, updated_at)
      VALUES ($1, 5, COALESCE($2::timestamp, timezone('UTC', clock_timestamp())),
              timezone('UTC', clock_timestamp()), timezone('UTC', clock_timestamp()))
      ON CONFLICT (service_account_id) DO NOTHING
      """,
      [id, if(injected_now, do: DateTime.to_naive(injected_now))],
      @repo_opts
    )

    bucket =
      Repo.one!(
        from(bucket in ManualRetryRateLimit,
          where: bucket.service_account_id == ^id,
          lock: "FOR UPDATE"
        ),
        @repo_opts
      )

    now = DateTime.add(injected_now || database_now(), 0, :microsecond)
    intervals = div(max(DateTime.diff(now, bucket.refilled_at, :microsecond), 0), @interval_us)
    available = min(5, bucket.tokens + intervals)
    refilled_at = DateTime.add(bucket.refilled_at, intervals * @interval_us, :microsecond)

    bucket
    |> Ecto.Changeset.change(
      tokens: max(available - 1, 0),
      refilled_at: refilled_at,
      updated_at: now
    )
    |> Repo.update!(@repo_opts)

    if available > 0 do
      :allowed
    else
      remaining_us = DateTime.diff(DateTime.add(refilled_at, 12, :second), now, :microsecond)
      {:denied, max(1, div(remaining_us + 999_999, 1_000_000))}
    end
  end

  defp database_now do
    %{rows: [[now]]} = Repo.query!("SELECT timezone('UTC', clock_timestamp())", [], @repo_opts)
    DateTime.from_naive!(now, "Etc/UTC")
  end

  defp valid_clock?(nil), do: true

  defp valid_clock?(%DateTime{time_zone: "Etc/UTC", utc_offset: 0, std_offset: 0}), do: true

  defp valid_clock?(_now), do: false
end
