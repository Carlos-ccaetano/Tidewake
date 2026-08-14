defmodule Tidewake.Webhooks.Endpoint do
  use Ecto.Schema

  import Ecto.Changeset

  schema "endpoints" do
    field :name, :string
    field :url, :string
    field :active, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  def changeset(endpoint, attrs) do
    endpoint
    |> cast(attrs, [:name, :url, :active])
    |> validate_required([:name, :url])
    |> validate_non_blank_name()
    |> validate_url()
  end

  defp validate_non_blank_name(changeset) do
    validate_change(changeset, :name, fn :name, name ->
      if String.trim(name) == "", do: [name: "can't be blank"], else: []
    end)
  end

  defp validate_url(changeset) do
    validate_change(changeset, :url, fn :url, url ->
      if valid_http_url?(url) do
        []
      else
        [url: "must be a valid HTTP or HTTPS URL"]
      end
    end)
  end

  defp valid_http_url?(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host}}
      when scheme in ["http", "https"] and is_binary(host) ->
        String.trim(host) != ""

      _other ->
        false
    end
  end
end
