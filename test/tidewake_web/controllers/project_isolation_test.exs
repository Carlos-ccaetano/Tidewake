defmodule TidewakeWeb.ProjectIsolationTest do
  use TidewakeWeb.ConnCase, async: false

  alias Tidewake.Projects
  alias Tidewake.Webhooks

  @valid_endpoint %{name: "Consumer", url: "https://endpoint.invalid/webhook"}
  @event %{external_id: "same-external-id", event_type: "order.created", payload: %{}}

  setup do
    %{project: project, issued: issued} = service_account_fixture()
    {:ok, foreign} = Projects.create_project(%{name: "Foreign", slug: "http-foreign"})
    {:ok, own_endpoint} = Webhooks.create_endpoint(project, @valid_endpoint)
    {:ok, foreign_endpoint} = Webhooks.create_endpoint(foreign, @valid_endpoint)
    {:ok, own_event} = Webhooks.create_event(project, @event)
    {:ok, foreign_event} = Webhooks.create_event(foreign, @event)

    %{
      project: project,
      issued: issued,
      foreign: foreign,
      own_endpoint: own_endpoint,
      foreign_endpoint: foreign_endpoint,
      own_event: own_event,
      foreign_event: foreign_event
    }
  end

  test "reads cannot select another project by header or query",
       %{issued: issued, foreign: foreign, own_endpoint: own, foreign_endpoint: hidden} do
    response =
      authorized_conn(issued)
      |> put_req_header("x-project-id", foreign.public_id)
      |> get("/api/endpoints?project_id=#{foreign.id}")

    assert %{"data" => [data]} = json_response(response, 200)
    assert data["id"] == own.id
    refute Map.has_key?(data, "project_id")
    foreign_response = get(authorized_conn(issued), "/api/endpoints/#{hidden.id}")
    absent_response = get(authorized_conn(issued), "/api/endpoints/9223372036854775807")
    assert json_response(foreign_response, 404) == json_response(absent_response, 404)
    assert_private_error(foreign_response, foreign)
  end

  test "creation and update derive ownership only from Scope",
       %{
         project: project,
         issued: issued,
         foreign: foreign,
         own_endpoint: own,
         foreign_endpoint: hidden
       } do
    attrs = %{"name" => "New", "url" => @valid_endpoint.url, "project_id" => foreign.id}
    response = post(authorized_conn(issued), "/api/endpoints", attrs)
    assert %{"data" => created} = json_response(response, 201)
    assert Webhooks.get_endpoint(project, created["id"]).project_id == project.id
    assert Webhooks.get_endpoint(foreign, created["id"]) == nil

    updated =
      patch(authorized_conn(issued), "/api/endpoints/#{own.id}", %{
        "name" => "Changed",
        "project_id" => foreign.id
      })

    assert json_response(updated, 200)["data"]["name"] == "Changed"
    assert Webhooks.get_endpoint(project, own.id).project_id == project.id

    foreign_response =
      patch(authorized_conn(issued), "/api/endpoints/#{hidden.id}", %{"active" => false})

    absent_response =
      patch(authorized_conn(issued), "/api/endpoints/9223372036854775807", %{"active" => false})

    assert json_response(foreign_response, 404) == json_response(absent_response, 404)
    assert Webhooks.get_endpoint(foreign, hidden.id).active
  end

  test "event and delivery reads resolve the parent inside Scope",
       %{issued: issued, own_event: own, foreign: foreign, foreign_event: hidden} do
    for suffix <- ["", "/deliveries"] do
      foreign_response = get(authorized_conn(issued), "/api/events/#{hidden.id}#{suffix}")
      absent_response = get(authorized_conn(issued), "/api/events/9223372036854775807#{suffix}")
      assert json_response(foreign_response, 404) == json_response(absent_response, 404)
      assert_private_error(foreign_response, foreign)
    end

    assert json_response(get(authorized_conn(issued), "/api/events/#{own.id}"), 200)["data"]["id"] ==
             own.id

    assert json_response(get(authorized_conn(issued), "/api/events/#{own.id}/deliveries"), 200) ==
             %{"data" => []}
  end

  test "ingestion deduplicates and fans out only within Scope despite a supplied project",
       %{
         project: project,
         issued: issued,
         foreign: foreign,
         own_endpoint: own,
         foreign_endpoint: hidden
       } do
    {:ok, _} = Webhooks.create_event(foreign, %{@event | external_id: "only-foreign"})

    attrs = %{
      "external_id" => "only-foreign",
      "type" => @event.event_type,
      "data" => %{},
      "project_id" => foreign.id
    }

    Oban.Testing.with_testing_mode(:manual, fn ->
      response = post(authorized_conn(issued), "/api/events", attrs)
      assert %{"data" => created} = json_response(response, 201)
      event = Webhooks.get_event(project, created["id"])
      assert event.project_id == project.id
      assert [delivery] = Webhooks.list_deliveries_for_event(project, event)
      assert delivery.endpoint_id == own.id
      refute delivery.endpoint_id == hidden.id
      response = get(authorized_conn(issued), "/api/events/#{event.id}/deliveries")
      assert [%{"id" => id}] = json_response(response, 200)["data"]
      assert id == delivery.id

      assert post(authorized_conn(issued), "/api/events", attrs) |> json_response(409) ==
               %{
                 "error" => %{
                   "code" => "external_id_conflict",
                   "message" => "An event with this external_id already exists"
                 }
               }
    end)
  end

  test "each project authenticates its own service account", %{
    foreign: foreign,
    foreign_endpoint: hidden
  } do
    %{issued: issued} = service_account_fixture("viewer", foreign)
    response = get(authorized_conn(issued), "/api/endpoints")
    assert [%{"id" => id}] = json_response(response, 200)["data"]
    assert id == hidden.id
  end

  test "suspension fails closed rather than selecting another project",
       %{project: project, issued: issued, foreign: foreign} do
    assert {:ok, _} = Projects.suspend_project(project, DateTime.utc_now())

    response =
      authorized_conn(issued)
      |> put_req_header("x-project-id", foreign.public_id)
      |> get("/api/endpoints")

    assert json_response(response, 401)["error"]["code"] == "unauthorized"
    assert get_resp_header(response, "cache-control") == ["no-store"]
  end

  defp authorized_conn(issued) do
    build_conn() |> put_req_header("authorization", "Bearer #{issued.token}")
  end

  defp assert_private_error(conn, project) do
    refute conn.resp_body =~ project.public_id
    refute conn.resp_body =~ "project_id"
    refute conn.resp_body =~ "credential"
  end
end
