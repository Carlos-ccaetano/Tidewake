defmodule Tidewake.Repo.Migrations.ScopeWebhookResourcesByProject do
  use Ecto.Migration

  def up do
    # Quiesce old writers for the entire transactional backfill and constraint swap.
    execute "LOCK TABLE endpoints, events, deliveries IN ACCESS EXCLUSIVE MODE"

    execute """
    DO $$ BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM projects WHERE id = 1 AND slug = 'legacy'
          AND public_id = '00000000-0000-4000-8000-000000000001'
      ) THEN
        RAISE EXCEPTION 'Expected the recorded legacy project before ownership backfill';
      END IF;
    END $$
    """

    for table <- [:endpoints, :events, :deliveries] do
      alter table(table) do
        add :project_id,
            references(:projects, on_delete: :restrict, name: :"#{table}_project_id_fkey")
      end

      execute "UPDATE #{table} SET project_id = 1"
      execute "ALTER TABLE #{table} ALTER COLUMN project_id SET NOT NULL"
    end

    create unique_index(:events, [:project_id, :external_id],
             name: :events_project_id_external_id_index
           )

    drop index(:events, [:external_id], name: :events_external_id_index)

    create unique_index(:events, [:id, :project_id], name: :events_id_project_id_index)
    create unique_index(:endpoints, [:id, :project_id], name: :endpoints_id_project_id_index)
    create index(:endpoints, [:project_id], name: :endpoints_project_id_index)

    create index(:deliveries, [:project_id, :event_id],
             name: :deliveries_project_id_event_id_index
           )

    for {column, parent} <- [event_id: :events, endpoint_id: :endpoints] do
      drop constraint(:deliveries, :"deliveries_#{column}_fkey")

      execute """
      ALTER TABLE deliveries ADD CONSTRAINT deliveries_#{column}_fkey
        FOREIGN KEY (#{column}, project_id) REFERENCES #{parent}(id, project_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT
      """
    end
  end

  def down do
    execute "LOCK TABLE endpoints, events, deliveries IN ACCESS EXCLUSIVE MODE"

    execute """
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM events GROUP BY external_id HAVING count(*) > 1) THEN
        RAISE EXCEPTION 'Unsafe ownership rollback: duplicate external_id across projects; preserve data and migrate forward';
      END IF;
      IF EXISTS (SELECT 1 FROM endpoints WHERE project_id <> 1)
        OR EXISTS (SELECT 1 FROM events WHERE project_id <> 1)
        OR EXISTS (SELECT 1 FROM deliveries WHERE project_id <> 1) THEN
        RAISE EXCEPTION 'Unsafe ownership rollback: non-legacy resources would lose ownership; preserve data and migrate forward';
      END IF;
    END $$
    """

    create unique_index(:events, [:external_id], name: :events_external_id_index)

    for {column, parent} <- [event_id: :events, endpoint_id: :endpoints] do
      drop constraint(:deliveries, :"deliveries_#{column}_fkey")

      execute """
      ALTER TABLE deliveries ADD CONSTRAINT deliveries_#{column}_fkey
        FOREIGN KEY (#{column}) REFERENCES #{parent}(id) ON DELETE RESTRICT
      """
    end

    drop index(:deliveries, [:project_id, :event_id], name: :deliveries_project_id_event_id_index)
    drop index(:endpoints, [:project_id], name: :endpoints_project_id_index)
    drop index(:endpoints, [:id, :project_id], name: :endpoints_id_project_id_index)
    drop index(:events, [:id, :project_id], name: :events_id_project_id_index)
    drop index(:events, [:project_id, :external_id], name: :events_project_id_external_id_index)

    for table <- [:deliveries, :events, :endpoints] do
      alter table(table) do
        remove :project_id
      end
    end
  end
end
