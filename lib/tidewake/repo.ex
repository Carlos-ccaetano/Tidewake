defmodule Tidewake.Repo do
  use Ecto.Repo,
    otp_app: :tidewake,
    adapter: Ecto.Adapters.Postgres
end
