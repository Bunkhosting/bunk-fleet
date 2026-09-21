defmodule ControlPlane.Backups.VpsBackup do
  @moduledoc """
  One archive of one VPS's disk, as the control plane knows it.

  The control plane never holds the bytes. It records that an archive exists,
  where the node put it, and how big it is — enough to show a customer their
  restore points, to decide what to prune, and to tell the agent which archive to
  restore. Reading the archive is the node's business and the node's alone.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Vps

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "vps_backups" do
    belongs_to :vps, Vps
    belongs_to :node, Node

    field :status, Ecto.Enum, values: [:pending, :running, :done, :failed], default: :pending
    field :volid, :string
    field :size_bytes, :integer
    field :error, :string

    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(backup, attrs) do
    backup
    |> cast(attrs, [
      :vps_id,
      :node_id,
      :status,
      :volid,
      :size_bytes,
      :error,
      :started_at,
      :finished_at
    ])
    |> validate_required([:vps_id, :status])
    |> validate_number(:size_bytes, greater_than_or_equal_to: 0)
    # Eén lopende back-up per VPS, afgedwongen door de database. De controle in
    # `Backups.start_on_demand/1` kijkt eerst en schrijft daarna, en dat verliest
    # van gelijktijdigheid: drie verzoeken tegelijk leverden er drie op, en een
    # back-up is een volledige vzdump op de machine van een operator.
    |> unique_constraint(:vps_id, name: :vps_backups_een_lopende_per_vps_uidx)
    # The volid comes back from the node and is later handed to it again as the
    # archive to restore. Keep it to what a storage identifier can be, so nothing
    # that arrives here can become anything else there.
    |> validate_length(:volid, max: 255)
    |> validate_format(:volid, ~r{\A[A-Za-z0-9._:/+-]*\z},
      message: "is geen geldige storage-identifier"
    )
    |> validate_length(:error, max: 2_000)
    |> assoc_constraint(:vps)
    |> assoc_constraint(:node)
    |> unique_constraint([:node_id, :volid])
  end
end
