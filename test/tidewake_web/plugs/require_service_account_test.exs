defmodule TidewakeWeb.Plugs.RequireServiceAccountTest do
  use Tidewake.DataCase, async: false

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias Tidewake.Projects
  alias Tidewake.Projects.{ApiCredential, Scope, ServiceAccountToken}
  alias TidewakeWeb.Plugs.RequireServiceAccount

  @opts [log: false, telemetry_event: nil]
  @unauthorized %{
    "error" => %{
      "code" => "unauthorized",
      "message" => "Valid service account credential required"
    }
  }

  setup do
    {:ok, project} = Projects.create_project(%{name: "Private project", slug: "boundary-test"})

    {:ok, account} =
      Projects.create_service_account(project, "producer", %{name: "Private consumer"})

    {:ok, issued} = Projects.issue_credential(account, DateTime.add(DateTime.utc_now(), 3600))
    %{project: project, account: account, issued: issued}
  end

  test "valid credential yields only the trusted scope and permits subsequent work",
       %{project: project, account: account, issued: issued} do
    result = authorized_conn(issued.token) |> run_pipeline()
    refute result.halted
    assert result.status == nil
    assert_receive :controller_reached
    assert get_req_header(result, "authorization") == []

    assert result.assigns == %{
             current_scope: %Scope{
               service_account_id: account.id,
               actor_subject: account.public_id,
               project_id: project.id,
               project_public_id: project.public_id,
               role: account.role
             }
           }

    refute inspect(result) =~ issued.token
    refute inspect(result) =~ issued.credential.public_id
    refute inspect(result) =~ Application.fetch_env!(:tidewake, :service_account_token_pepper)
    assert RequireServiceAccount.init([]) == []
  end

  for variant <- [
        :missing,
        :empty_header,
        :empty_token,
        :basic,
        :lowercase,
        :mixed_case,
        :leading_space,
        :double_space,
        :trailing_space,
        :tab_separator,
        :trailing_tab,
        :newline,
        :comma_combined,
        :duplicate,
        :duplicate_different,
        :bad_token,
        :extra_segment,
        :wrong_prefix,
        :uppercase_uuid
      ] do
    test "uniformly rejects #{variant} before downstream work", %{issued: issued} do
      conn(:get, "/boundary")
      |> prepend_req_headers(headers(unquote(variant), issued.token))
      |> assert_unauthorized([issued.token, issued.credential.public_id])
    end
  end

  test "an unknown UUID and wrong secret share the same public failure", %{issued: issued} do
    unknown = String.replace(issued.token, issued.credential.public_id, Ecto.UUID.generate())

    wrong =
      "twk_sa.#{issued.credential.public_id}." <> Base.url_encode64(<<0::256>>, padding: false)

    for token <- [unknown, wrong] do
      assert_unauthorized(authorized_conn(token), [
        token,
        issued.token,
        issued.credential.public_id
      ])
    end
  end

  test "a stored digest mismatch fails uniformly", %{issued: issued} do
    Repo.update_all(
      from(c in ApiCredential, where: c.id == ^issued.credential.id),
      [set: [secret_digest: <<0::256>>]],
      @opts
    )

    assert_unauthorized(authorized_conn(issued.token), [issued.token])
  end

  test "expired credentials fail uniformly using current server time", %{issued: issued} do
    now = DateTime.utc_now()

    Repo.update_all(
      from(c in ApiCredential, where: c.id == ^issued.credential.id),
      [set: [inserted_at: DateTime.add(now, -3600), expires_at: DateTime.add(now, -1)]],
      @opts
    )

    assert_unauthorized(authorized_conn(issued.token), [issued.token])
  end

  test "rotation preserves subject and revocation is checked on every call",
       %{account: account, issued: first} do
    {:ok, second} = Projects.issue_credential(account, DateTime.add(DateTime.utc_now(), 3600))

    first_scope =
      RequireServiceAccount.call(authorized_conn(first.token), []).assigns.current_scope

    second_scope =
      RequireServiceAccount.call(authorized_conn(second.token), []).assigns.current_scope

    assert first_scope == second_scope

    assert {:ok, _} =
             Projects.revoke_credential(account, first.credential.public_id, DateTime.utc_now())

    assert_unauthorized(authorized_conn(first.token), [first.token])

    assert RequireServiceAccount.call(authorized_conn(second.token), []).assigns.current_scope ==
             first_scope
  end

  test "disabled accounts invalidate every credential after earlier successful calls",
       %{account: account, issued: first} do
    {:ok, second} = Projects.issue_credential(account, DateTime.add(DateTime.utc_now(), 3600))
    refute RequireServiceAccount.call(authorized_conn(first.token), []).halted
    assert {:ok, _} = Projects.disable_service_account(account, DateTime.utc_now())

    for issued <- [first, second],
        do: assert_unauthorized(authorized_conn(issued.token), [issued.token])
  end

  test "suspension invalidates earlier successful authentication", %{
    project: project,
    issued: issued
  } do
    refute RequireServiceAccount.call(authorized_conn(issued.token), []).halted
    assert {:ok, _} = Projects.suspend_project(project, DateTime.utc_now())
    assert_unauthorized(authorized_conn(issued.token), [issued.token])
  end

  test "missing or invalid pepper fails uniformly without leaking configuration", %{
    issued: issued
  } do
    previous = Application.fetch_env!(:tidewake, :service_account_token_pepper)

    try do
      for pepper <- [nil, "private-short-pepper", String.duplicate("other-pepper", 4)] do
        Application.put_env(:tidewake, :service_account_token_pepper, pepper)
        assert_unauthorized(authorized_conn(issued.token), [issued.token])
      end

      Application.delete_env(:tidewake, :service_account_token_pepper)
      assert_unauthorized(authorized_conn(issued.token), [issued.token])
    after
      Application.put_env(:tidewake, :service_account_token_pepper, previous)
    end
  end

  test "params, additional headers and preassigned scopes cannot choose authority",
       %{account: account, project: project, issued: issued} do
    {:ok, foreign} = Projects.create_project(%{name: "Foreign", slug: "foreign-boundary"})

    forged = %{
      project_id: foreign.id,
      project_public_id: foreign.public_id,
      role: "admin",
      actor_subject: Ecto.UUID.generate(),
      service_account_id: 999
    }

    result =
      conn(:post, "/boundary", forged)
      |> put_req_header("authorization", "Bearer #{issued.token}")
      |> put_req_header("x-project-id", foreign.public_id)
      |> put_req_header("x-role", "admin")
      |> put_req_header("x-actor-subject", forged.actor_subject)
      |> assign(:current_scope, forged)
      |> RequireServiceAccount.call([])

    assert result.assigns.current_scope.project_id == project.id
    assert result.assigns.current_scope.role == "producer"
    assert result.assigns.current_scope.actor_subject == account.public_id

    conn(:get, "/boundary", forged)
    |> assign(:current_scope, forged)
    |> assert_unauthorized()
  end

  test "cookies, body, query parameters and other headers do not provide credentials",
       %{issued: issued} do
    for input <- [
          conn(:get, "/boundary?access_token=#{issued.token}"),
          conn(:post, "/boundary", %{"token" => issued.token}),
          conn(:get, "/boundary") |> put_req_header("cookie", "token=#{issued.token}"),
          conn(:get, "/boundary") |> put_req_header("x-api-key", issued.token),
          authorized_conn(Application.fetch_env!(:tidewake, :api_token))
        ] do
      result = run_pipeline(input)
      assert_failure_response(result)
      refute Map.has_key?(result.assigns, :current_scope)
      refute_received :controller_reached
    end
  end

  test "authentication adds no secrets to returned conns, responses, debug logs or query Telemetry",
       %{project: project, account: account, issued: issued} do
    {:ok, digest} = ServiceAccountToken.digest(issued.token)
    [_, _, secret] = String.split(issued.token, ".")

    credential_material = [
      issued.token,
      secret,
      issued.credential.public_id,
      inspect(digest),
      Base.encode16(digest),
      Base.encode64(digest),
      Application.fetch_env!(:tidewake, :service_account_token_pepper)
    ]

    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(handler, [:tidewake, :repo, :query], &__MODULE__.query_event/4, self())

    on_exit(fn -> :telemetry.detach(handler) end)
    Repo.query!("SELECT 1")
    assert_receive :authentication_query_event
    previous_level = Logger.level()
    Logger.configure(level: :debug)

    try do
      logs =
        capture_log(fn ->
          for token <- [
                issued.token,
                "twk_sa.#{Ecto.UUID.generate()}." <> Base.url_encode64(<<0::256>>, padding: false),
                issued.token <> " ",
                nil
              ] do
            result = if token, do: authorized_conn(token), else: conn(:get, "/boundary")
            result = RequireServiceAccount.call(result, [])
            for sensitive <- credential_material, do: refute(inspect(result) =~ sensitive)
          end

          assert {:ok, _} =
                   Projects.revoke_credential(
                     account,
                     issued.credential.public_id,
                     DateTime.utc_now()
                   )

          assert_unauthorized(authorized_conn(issued.token), [issued.token])
        end)

      for sensitive <- credential_material ++ [account.public_id, project.public_id],
          do: refute(logs =~ sensitive)

      refute logs =~ "service_account_credentials"
      refute_received :authentication_query_event
    after
      Logger.configure(level: previous_level)
    end
  end

  def query_event(_event, _measurements, _metadata, owner) do
    if self() == owner, do: send(owner, :authentication_query_event)
  end

  defp authorized_conn(token) do
    conn(:get, "/boundary") |> put_req_header("authorization", "Bearer #{token}")
  end

  defp run_pipeline(conn) do
    Plug.run(conn, [
      {RequireServiceAccount, []},
      fn conn ->
        send(self(), :controller_reached)
        conn
      end
    ])
  end

  defp assert_unauthorized(conn, sensitive \\ []) do
    result = run_pipeline(conn)
    assert_failure_response(result)
    refute Map.has_key?(result.assigns, :current_scope)
    assert get_req_header(result, "authorization") == []
    refute_received :controller_reached

    for value <- sensitive do
      refute inspect(result) =~ value
    end

    result
  end

  defp assert_failure_response(conn) do
    assert conn.halted
    assert conn.status == 401
    assert Jason.decode!(conn.resp_body) == @unauthorized
    assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
    assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
  end

  defp headers(:missing, _token), do: []
  defp headers(:empty_header, _token), do: [{"authorization", ""}]
  defp headers(:empty_token, _token), do: [{"authorization", "Bearer "}]
  defp headers(:basic, token), do: [{"authorization", "Basic " <> token}]
  defp headers(:lowercase, token), do: [{"authorization", "bearer " <> token}]
  defp headers(:mixed_case, token), do: [{"authorization", "BEARER " <> token}]
  defp headers(:leading_space, token), do: [{"authorization", " Bearer " <> token}]
  defp headers(:double_space, token), do: [{"authorization", "Bearer  " <> token}]
  defp headers(:trailing_space, token), do: [{"authorization", "Bearer " <> token <> " "}]
  defp headers(:tab_separator, token), do: [{"authorization", "Bearer\t" <> token}]
  defp headers(:trailing_tab, token), do: [{"authorization", "Bearer " <> token <> "\t"}]
  defp headers(:newline, token), do: [{"authorization", "Bearer " <> token <> "\n"}]

  defp headers(:comma_combined, token),
    do: [{"authorization", "Bearer #{token}, Bearer #{token}"}]

  defp headers(:duplicate, token),
    do: [{"authorization", "Bearer " <> token}, {"authorization", "Bearer " <> token}]

  defp headers(:duplicate_different, token),
    do: [{"authorization", "Bearer " <> token}, {"authorization", "Basic bad"}]

  defp headers(:bad_token, _token), do: [{"authorization", "Bearer not-a-token"}]
  defp headers(:extra_segment, token), do: [{"authorization", "Bearer " <> token <> ".extra"}]

  defp headers(:wrong_prefix, token),
    do: [{"authorization", "Bearer " <> String.replace_prefix(token, "twk_sa.", "twk.")}]

  defp headers(:uppercase_uuid, token) do
    [prefix, _uuid, secret] = String.split(token, ".")
    [{"authorization", "Bearer #{prefix}.AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA.#{secret}"}]
  end
end
