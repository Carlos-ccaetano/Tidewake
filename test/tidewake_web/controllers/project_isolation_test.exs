defmodule TidewakeWeb.ProjectIsolationTest do
  use TidewakeWeb.ConnCase, async: false

  alias Tidewake.Projects
  alias Tidewake.Webhooks

  @valid_endpoint %{name: "Consumer", url: "https://endpoint.invalid/webhook"}
  @event %{external_id: "same-external-id", event_type: "order.created", payload: %{}}

  setup do
    legacy = Projects.get_project_by_slug("legacy")
    {:ok, foreign} = Projects.create_project(%{name: "Foreign", slug: "http-foreign"})
    {:ok, own_endpoint} = Webhooks.create_endpoint(legacy, @valid_endpoint)
    {:ok, foreign_endpoint} = Webhooks.create_endpoint(foreign, @valid_endpoint)
    {:ok, own_event} = Webhooks.create_event(legacy, @event)
    {:ok, foreign_event} = Webhooks.create_event(foreign, @event)

    %{
      legacy: legacy,
      foreign: foreign,
      own_endpoint: own_endpoint,
      foreign_endpoint: foreign_endpoint,
      own_event: own_event,
      foreign_event: foreign_event
    }
  end

  test "static-token reads cannot select another project by header or query",
       %{foreign: foreign, own_endpoint: own, foreign_endpoint: hidden} do
    response =
      authorized_conn()
      |> put_req_header("x-project-id", foreign.public_id)
      |> get("/api/endpoints?project_id=#{foreign.id}")

    assert %{"data" => [data]} = json_response(response, 200)
    assert data["id"] == own.id
    refute Map.has_key?(data, "project_id")
    foreign_response = get(authorized_conn(), "/api/endpoints/#{hidden.id}")
    absent_response = get(authorized_conn(), "/api/endpoints/9223372036854775807")
    assert json_response(foreign_response, 404) == json_response(absent_response, 404)
  end

  test "creation and update derive ownership from the legacy context",
       %{legacy: legacy, foreign: foreign, own_endpoint: own, foreign_endpoint: hidden} do
    attrs = %{"name" => "New", "url" => @valid_endpoint.url, "project_id" => foreign.id}
    response = post(authorized_conn(), "/api/endpoints", attrs)
    assert %{"data" => created} = json_response(response, 201)
    assert Webhooks.get_endpoint(legacy, created["id"]).project_id == legacy.id
    assert Webhooks.get_endpoint(foreign, created["id"]) == nil

    updated =
      patch(authorized_conn(), "/api/endpoints/#{own.id}", %{
        "name" => "Changed",
        "project_id" => foreign.id
      })

    assert json_response(updated, 200)["data"]["name"] == "Changed"
    assert Webhooks.get_endpoint(legacy, own.id).project_id == legacy.id

    foreign_response =
      patch(authorized_conn(), "/api/endpoints/#{hidden.id}", %{"active" => false})

    absent_response =
      patch(authorized_conn(), "/api/endpoints/9223372036854775807", %{"active" => false})

    assert json_response(foreign_response, 404) == json_response(absent_response, 404)
    assert Webhooks.get_endpoint(foreign, hidden.id).active
  end

  test "event and delivery reads resolve the parent inside the legacy project",
       %{own_event: own, foreign_event: hidden} do
    for suffix <- ["", "/deliveries"] do
      foreign_response = get(authorized_conn(), "/api/events/#{hidden.id}#{suffix}")
      absent_response = get(authorized_conn(), "/api/events/9223372036854775807#{suffix}")
      assert json_response(foreign_response, 404) == json_response(absent_response, 404)
    end

    assert json_response(get(authorized_conn(), "/api/events/#{own.id}"), 200)["data"]["id"] ==
             own.id

    assert json_response(get(authorized_conn(), "/api/events/#{own.id}/deliveries"), 200) == %{
             "data" => []
           }
  end

  test "ingestion deduplicates and fans out only within legacy despite a supplied project",
       %{legacy: legacy, foreign: foreign, own_endpoint: own, foreign_endpoint: hidden} do
    {:ok, _} = Webhooks.create_event(foreign, %{@event | external_id: "only-foreign"})

    attrs = %{
      "external_id" => "only-foreign",
      "type" => @event.event_type,
      "data" => %{},
      "project_id" => foreign.id
    }

    Oban.Testing.with_testing_mode(:manual, fn ->
      response = post(authorized_conn(), "/api/events", attrs)
      assert %{"data" => created} = json_response(response, 201)
      event = Webhooks.get_event(legacy, created["id"])
      assert event.project_id == legacy.id
      assert [delivery] = Webhooks.list_deliveries_for_event(legacy, event)
      assert delivery.endpoint_id == own.id
      refute delivery.endpoint_id == hidden.id

      assert post(authorized_conn(), "/api/events", attrs) |> json_response(409) ==
               %{
                 "error" => %{
                   "code" => "external_id_conflict",
                   "message" => "An event with this external_id already exists"
                 }
               }
    end)
  end

  test "service-account credentials do not activate the new router boundary", %{foreign: foreign} do
    {:ok, account} = Projects.create_service_account(foreign, "admin", %{name: "Service"})
    {:ok, issued} = Projects.issue_credential(account, DateTime.add(DateTime.utc_now(), 3600))

    response =
      build_conn()
      |> put_req_header("authorization", "Bearer #{issued.token}")
      |> get("/api/endpoints")

    assert json_response(response, 401)["error"]["code"] == "unauthorized"
    assert get_resp_header(response, "www-authenticate") == ["Bearer"]
    assert json_response(get(authorized_conn(), "/api/endpoints"), 200)
  end

  test "a suspended legacy project fails closed rather than selecting another project",
       %{legacy: legacy, foreign: foreign} do
    assert {:ok, _} = Projects.suspend_project(legacy, DateTime.utc_now())

    response =
      authorized_conn()
      |> put_req_header("x-project-id", foreign.public_id)
      |> get("/api/endpoints")

    assert json_response(response, 401)["error"]["code"] == "unauthorized"
  end

  defp authorized_conn do
    build_conn()
    |> put_req_header("authorization", "Bearer #{Application.fetch_env!(:tidewake, :api_token)}")
  end
end
