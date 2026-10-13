defmodule ControlPlane.Repo.Migrations.AddDeliveredAtToCommands do
  use Ecto.Migration

  def change do
    alter table(:commands) do
      # Stamped each time a command is (re)delivered to a node's agent. Used to
      # detect and redeliver commands whose agent crashed before reporting a
      # result (see `Provisioning.CommandQueue.deliverable_commands_for_node/1`).
      add :delivered_at, :utc_datetime
    end
  end
end
