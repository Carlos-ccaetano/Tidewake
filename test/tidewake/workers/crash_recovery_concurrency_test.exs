defmodule Tidewake.Workers.CrashRecoveryConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import Ecto.Changeset

  alias Ecto.Adapters.SQL.Sandbox
  alias Tidewake.{Projects, Repo, Webhooks}
  alias Tidewake.Webhooks.{Attempt, Delivery, Endpoint, Event}
  alias Tidewake.Webhooks.DeliveryAdapters.Req, as: ReqAdapter
  alias Tidewake.Workers.DeliverWebhookWorker

  @behaviour Plug
  @behaviour Tidewake.Webhooks.DeliveryAdapter

  setup context do
    # Oban also checks the test process in each task's caller chain.
    Process.put(:oban_testing, :manual)
    supervisor = start_supervised!(Task.Supervisor)
    oban = __MODULE__.RestartOban

    oban_spec =
      Supervisor.child_spec(
        {Oban,
         name: oban,
         repo: Repo,
         testing: :disabled,
         queues: false,
         plugins: false,
         peer: false,
         lifeline: false,
         cron: false},
        id: :recovery_test_oban
      )

    start_supervised!(oban_spec)
    phase = Map.get(context, :phase, :normal)
    ref = make_ref()

    start_supervised!(
      Plug.Cowboy.child_spec(
        scheme: :http,
        plug: {__MODULE__, {self(), phase}},
        options: [ip: {127, 0, 0, 1}, port: 0, ref: ref]
      )
    )

    port = :ranch.get_port(ref)

    previous =
      for key <- [:delivery_adapter, ReqAdapter, __MODULE__],
          do: {key, Application.fetch_env(:tidewake, key)}

    Application.put_env(:tidewake, :delivery_adapter, __MODULE__)
    Application.put_env(:tidewake, ReqAdapter, target_mode: :local)
    Application.put_env(:tidewake, __MODULE__, {self(), phase})

    {project, endpoint} =
      unboxed(fn ->
        {:ok, project} =
          Projects.create_project(%{name: "Recovery regression", slug: Ecto.UUID.generate()})

        {:ok, endpoint} =
          Webhooks.create_endpoint(project, %{
            name: "Local synthetic receiver",
            url: "http://127.0.0.1:#{port}/webhooks"
          })

        {project, endpoint}
      end)

    on_exit(fn ->
      for {key, setting} <- previous do
        case setting do
          {:ok, value} -> Application.put_env(:tidewake, key, value)
          :error -> Application.delete_env(:tidewake, key)
        end
      end

      unboxed(fn ->
        ids = Repo.all(from d in Delivery, where: d.project_id == ^project.id, select: d.id)

        Repo.delete_all(
          from j in Oban.Job,
            where: fragment("?->>'delivery_id'", j.args) in ^Enum.map(ids, &to_string/1)
        )

        Repo.delete_all(from a in Attempt, where: a.delivery_id in ^ids)
        Repo.delete_all(from d in Delivery, where: d.project_id == ^project.id)
        Repo.delete_all(from e in Event, where: e.project_id == ^project.id)
        Repo.delete_all(from e in Endpoint, where: e.project_id == ^project.id)
        Repo.delete!(project)
      end)
    end)

    %{
      supervisor: supervisor,
      project: project,
      endpoint: endpoint,
      oban: oban,
      oban_spec: oban_spec
    }
  end

  for phase <- [:before_claim, :before_http, :during_http, :after_response] do
    @tag phase: phase
    test "restart recovers a process killed at #{phase} using real Oban and HTTP", context do
      phase = context.phase
      %{delivery: delivery, job: original} = unboxed(fn -> scheduled(context) end)
      parent = self()

      execution =
        Task.Supervisor.async_nolink(context.supervisor, fn ->
          unboxed(fn ->
            conf = Oban.config(context.oban)
            assert {:ok, meta} = Oban.Engine.init(conf, queue: "default", limit: 1)
            assert {:ok, {_, [job]}} = Oban.Engine.fetch_jobs(conf, meta, %{})
            send(parent, {:fetched, self(), job.id})

            if phase == :before_claim do
              receive do
                :continue -> :ok
              after
                5000 -> raise "missing fetch barrier"
              end
            end

            DeliverWebhookWorker.perform(job)
          end)
        end)

      assert_receive {:fetched, pid, id}, 5000
      assert id == original.id

      case phase do
        :before_claim ->
          :ok

        :before_http ->
          assert_receive {:before_http, ^pid}, 5000

        :during_http ->
          assert_receive {:http_received, receiver}, 5000
          send(self(), {:receiver, receiver})

        :after_response ->
          assert_receive {:http_received, _}, 5000
          assert_receive {:after_response, ^pid}, 5000
      end

      Process.exit(pid, :kill)
      assert_receive {:DOWN, ref, :process, ^pid, :killed}, 5000
      assert ref == execution.ref
      stop_supervised!(:recovery_test_oban)
      start_supervised!(context.oban_spec)

      if phase == :during_http do
        assert_receive {:receiver, receiver}
        send(receiver, :respond)
      end

      Application.put_env(:tidewake, __MODULE__, {self(), :normal})

      unboxed(fn ->
        assert Repo.aggregate(from(a in Attempt, where: a.delivery_id == ^delivery.id), :count) ==
                 0

        old = DateTime.add(DateTime.utc_now(), -600)
        Repo.get!(Oban.Job, original.id) |> change(attempted_at: old) |> Repo.update!()
        Repo.get!(Delivery, delivery.id) |> change(updated_at: old) |> Repo.update!()

        assert {:ok, [%{state: "discarded"}]} =
                 Oban.Engine.rescue_jobs(Oban.config(context.oban), Oban.Job,
                   rescue_after: 300_000
                 )

        assert {:ok, %{recovered_count: 1}} =
                 Webhooks.recover_stale_deliveries(DateTime.utc_now(), 100)
      end)

      restarted =
        Task.Supervisor.async_nolink(context.supervisor, fn ->
          unboxed(fn -> Oban.drain_queue(context.oban, queue: :default) end)
        end)

      if phase == :during_http do
        assert_receive {:http_received, receiver}, 5000
        send(receiver, :respond)
      end

      assert %{success: 1, failure: 0} = Task.await(restarted, 5000)

      unboxed(fn ->
        persisted = Repo.get!(Delivery, delivery.id)
        assert persisted.status == "succeeded"
        assert persisted.attempt_count == 1
        assert persisted.cycle_attempt_count == 1
        assert persisted.recovery_count == 1
        assert [attempt] = Webhooks.list_attempts(persisted)
        assert attempt.http_status == 202
        assert Repo.get!(Oban.Job, original.id).state == "discarded"
        assert Repo.aggregate(from(j in Oban.Job, where: j.state == "completed"), :count) == 1
      end)
    end
  end

  test "two independent recovery connections commit one transition", context do
    %{delivery: delivery, job: job} = unboxed(fn -> scheduled(context) end)

    unboxed(fn ->
      job |> change(state: "discarded") |> Repo.update!()
      age(delivery)
    end)

    parent = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:tidewake, :repo, :query],
      fn _, _, metadata, _ ->
        if Process.get(:hold_recovery_selection) &&
             String.contains?(metadata.query, "FOR UPDATE SKIP LOCKED") do
          Process.delete(:hold_recovery_selection)
          send(parent, {:selected, self()})

          receive do
            :release -> :ok
          after
            5000 -> raise "missing selection barrier"
          end
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    first =
      Task.Supervisor.async_nolink(context.supervisor, fn ->
        unboxed(fn ->
          Process.put(:hold_recovery_selection, true)
          Webhooks.recover_stale_deliveries(DateTime.utc_now(), 100)
        end)
      end)

    assert_receive {:selected, first_pid}, 5000

    second =
      Task.Supervisor.async_nolink(context.supervisor, fn ->
        unboxed(fn -> Webhooks.recover_stale_deliveries(DateTime.utc_now(), 100) end)
      end)

    assert {:ok, %{recovered_count: 0}} = Task.await(second, 5000)
    send(first_pid, :release)
    assert {:ok, %{recovered_count: 1}} = Task.await(first, 5000)
    unboxed(fn -> assert Repo.get!(Delivery, delivery.id).recovery_count == 1 end)
  end

  test "100 row locks do not starve later eligible work", context do
    deliveries =
      unboxed(fn ->
        for _ <- 1..101 do
          %{delivery: delivery, job: job} = scheduled(context)
          job |> change(state: "discarded") |> Repo.update!()
          age(delivery)
        end
      end)

    ids = Enum.map(Enum.take(deliveries, 100), & &1.id)
    parent = self()

    locker =
      Task.Supervisor.async_nolink(context.supervisor, fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            Repo.all(from d in Delivery, where: d.id in ^ids, lock: "FOR UPDATE")
            send(parent, {:locked, self()})

            receive do
              :release -> :ok
            after
              5000 -> raise "missing lock barrier"
            end
          end)
        end)
      end)

    assert_receive {:locked, locker_pid}, 5000

    assert {:ok, %{recovered_count: 1}} =
             unboxed(fn -> Webhooks.recover_stale_deliveries(DateTime.utc_now(), 100) end)

    last = List.last(deliveries)
    unboxed(fn -> assert Repo.get!(Delivery, last.id).recovery_count == 1 end)
    send(locker_pid, :release)
    assert {:ok, :ok} = Task.await(locker, 5000)
  end

  test "replacement insertion failure rolls back generation and state", context do
    %{delivery: delivery, job: original} = unboxed(fn -> scheduled(context) end)

    before =
      unboxed(fn ->
        original |> change(state: "discarded") |> Repo.update!()
        delivery |> change(status: "processing") |> Repo.update!() |> age()
      end)

    assert_raise Ecto.ConstraintError, fn ->
      unboxed(fn ->
        Repo.transaction(fn ->
          Repo.query!(
            "ALTER TABLE oban_jobs ADD CONSTRAINT synthetic_recovery_insert_failure CHECK (NOT jsonb_exists(args, 'recovery_count'))"
          )

          Webhooks.recover_stale_deliveries(DateTime.utc_now(), 100)
        end)
      end)
    end

    unboxed(fn ->
      assert Repo.get!(Delivery, delivery.id) == before
      assert Repo.get!(Oban.Job, original.id).state == "discarded"
      assert Repo.aggregate(Oban.Job, :count) == 1
      assert Repo.aggregate(Attempt, :count) == 0
    end)
  end

  @impl Plug
  def init(options), do: options

  @impl Plug
  def call(conn, {parent, phase}) do
    {:ok, _synthetic_body, conn} = Plug.Conn.read_body(conn)
    send(parent, {:http_received, self()})

    if phase == :during_http do
      receive do
        :respond -> :ok
      after
        5000 -> raise "missing HTTP barrier"
      end
    end

    Plug.Conn.send_resp(conn, 202, "accepted")
  end

  @impl Tidewake.Webhooks.DeliveryAdapter
  def deliver(url, body, headers) do
    {parent, phase} = Application.fetch_env!(:tidewake, __MODULE__)
    barrier(parent, phase, :before_http)
    result = ReqAdapter.deliver(url, body, headers)
    barrier(parent, phase, :after_response)
    result
  end

  defp barrier(parent, phase, phase) do
    send(parent, {phase, self()})

    receive do
      :continue -> :ok
    after
      5000 -> raise "missing adapter barrier"
    end
  end

  defp barrier(_, _, _), do: :ok

  defp unboxed(fun),
    do: Sandbox.unboxed_run(Repo, fn -> Oban.Testing.with_testing_mode(:manual, fun) end)

  defp scheduled(context) do
    {:ok, event} =
      Webhooks.create_event(context.project, %{
        external_id: Ecto.UUID.generate(),
        event_type: "synthetic.created",
        payload: %{"synthetic" => true}
      })

    {:ok, result} = Webhooks.schedule_delivery(event, context.endpoint)
    result
  end

  defp age(delivery),
    do: delivery |> change(updated_at: DateTime.add(DateTime.utc_now(), -600)) |> Repo.update!()
end
