defmodule Tidewake.WebhooksFixtures do
  @moduledoc false

  def legacy_project, do: Tidewake.Projects.get_project_by_slug("legacy")
end
