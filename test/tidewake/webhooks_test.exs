defmodule Tidewake.WebhooksTest do
  use Tidewake.DataCase, async: true

  alias Ecto.Changeset
  alias Tidewake.Webhooks

  describe "endpoints" do
    test "create_endpoint/1 creates a valid endpoint" do
      assert {:ok, endpoint} = Webhooks.create_endpoint(valid_attrs())
      assert endpoint.name == "Ironhold"
      assert endpoint.url == "https://ironhold.example.com/api/webhooks"
      assert endpoint.active
    end

    test "create_endpoint/1 returns an error for invalid attributes" do
      assert {:error, changeset} = Webhooks.create_endpoint(%{name: "", url: "not-a-url"})
      refute changeset.valid?
    end

    test "list_endpoints/0 returns persisted endpoints" do
      endpoint = endpoint_fixture()

      assert Webhooks.list_endpoints() == [endpoint]
    end

    test "get_endpoint/1 returns an existing endpoint" do
      endpoint = endpoint_fixture()

      assert Webhooks.get_endpoint(endpoint.id) == endpoint
    end

    test "get_endpoint/1 returns nil for an unknown ID" do
      assert Webhooks.get_endpoint(-1) == nil
    end

    test "update_endpoint/2 updates the name" do
      endpoint = endpoint_fixture()

      assert {:ok, updated_endpoint} =
               Webhooks.update_endpoint(endpoint, %{name: "Primary Ironhold"})

      assert updated_endpoint.name == "Primary Ironhold"
    end

    test "update_endpoint/2 updates the URL" do
      endpoint = endpoint_fixture()

      assert {:ok, updated_endpoint} =
               Webhooks.update_endpoint(endpoint, %{
                 url: "https://secondary.ironhold.example.com/webhooks"
               })

      assert updated_endpoint.url == "https://secondary.ironhold.example.com/webhooks"
    end

    test "update_endpoint/2 deactivates an endpoint" do
      endpoint = endpoint_fixture()

      assert {:ok, updated_endpoint} = Webhooks.update_endpoint(endpoint, %{active: false})
      refute updated_endpoint.active
    end

    test "update_endpoint/2 returns an error for invalid attributes" do
      endpoint = endpoint_fixture()

      assert {:error, changeset} = Webhooks.update_endpoint(endpoint, %{url: "not-a-url"})
      refute changeset.valid?
    end

    test "change_endpoint/2 returns a changeset without persisting" do
      endpoint = endpoint_fixture()

      assert %Changeset{} = changeset = Webhooks.change_endpoint(endpoint, %{name: "Changed"})
      assert changeset.changes.name == "Changed"
      assert Webhooks.get_endpoint(endpoint.id).name == "Ironhold"
    end
  end

  defp endpoint_fixture(attrs \\ %{}) do
    attrs = Map.merge(valid_attrs(), attrs)
    {:ok, endpoint} = Webhooks.create_endpoint(attrs)
    endpoint
  end

  defp valid_attrs do
    %{name: "Ironhold", url: "https://ironhold.example.com/api/webhooks"}
  end
end
