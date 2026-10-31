defmodule Tidewake.Repo.Migrations.IndexManualRetryAuditCursor do
  use Ecto.Migration

  def change do
    create index(:manual_retry_requests, [:delivery_id, "id DESC"],
             name: :manual_retry_requests_delivery_id_cursor_index
           )
  end
end
