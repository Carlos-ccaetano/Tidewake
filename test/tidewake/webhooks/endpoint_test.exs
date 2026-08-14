defmodule Tidewake.Webhooks.EndpointTest do
  use Tidewake.DataCase, async: true

  alias Tidewake.Webhooks.Endpoint

  describe "changeset/2" do
    test "accepts a valid endpoint" do
      changeset =
        Endpoint.changeset(%Endpoint{}, %{
          name: "Ironhold",
          url: "https://ironhold.example.com/api/webhooks"
        })

      assert changeset.valid?
    end

    test "defaults active to true" do
      changeset =
        Endpoint.changeset(%Endpoint{}, %{
          name: "Ironhold",
          url: "https://ironhold.example.com/api/webhooks"
        })

      assert get_field(changeset, :active)
    end

    test "requires a name" do
      changeset =
        Endpoint.changeset(%Endpoint{}, %{url: "https://ironhold.example.com/api/webhooks"})

      assert "can't be blank" in errors_on(changeset).name
    end

    test "rejects an empty name" do
      changeset =
        Endpoint.changeset(%Endpoint{}, %{
          name: "",
          url: "https://ironhold.example.com/api/webhooks"
        })

      assert "can't be blank" in errors_on(changeset).name
    end

    test "rejects a name containing only whitespace" do
      changeset =
        Endpoint.changeset(%Endpoint{}, %{
          name: "   ",
          url: "https://ironhold.example.com/api/webhooks"
        })

      assert "can't be blank" in errors_on(changeset).name
    end

    test "requires a URL" do
      changeset = Endpoint.changeset(%Endpoint{}, %{name: "Ironhold"})

      assert "can't be blank" in errors_on(changeset).url
    end

    test "accepts an HTTP URL" do
      changeset =
        Endpoint.changeset(%Endpoint{}, %{
          name: "Local consumer",
          url: "http://localhost:4001/api/webhooks"
        })

      assert changeset.valid?
    end

    test "accepts an HTTPS URL" do
      changeset =
        Endpoint.changeset(%Endpoint{}, %{
          name: "Ironhold",
          url: "https://ironhold.example.com/api/webhooks"
        })

      assert changeset.valid?
    end

    test "rejects a URL without a scheme" do
      changeset =
        Endpoint.changeset(%Endpoint{}, %{
          name: "Ironhold",
          url: "ironhold.example.com/api/webhooks"
        })

      assert "must be a valid HTTP or HTTPS URL" in errors_on(changeset).url
    end

    test "rejects a URL without a host" do
      changeset =
        Endpoint.changeset(%Endpoint{}, %{name: "Ironhold", url: "https:///api/webhooks"})

      assert "must be a valid HTTP or HTTPS URL" in errors_on(changeset).url
    end

    test "rejects a URL with an unsupported scheme" do
      changeset =
        Endpoint.changeset(%Endpoint{}, %{
          name: "Ironhold",
          url: "ftp://ironhold.example.com/webhooks"
        })

      assert "must be a valid HTTP or HTTPS URL" in errors_on(changeset).url
    end
  end
end
