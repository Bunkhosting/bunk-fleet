defmodule ControlPlane.Beheer.Audit do
  @moduledoc """
  Het spoor van beheerhandelingen: wie deed wat, waar, met welke uitkomst.

  Alleen toevoegen (een trigger in de database weigert wijzigen en wissen). Zie
  `ControlPlaneWeb.Plugs.AdminAuditLog` voor wat er wanneer in komt.
  """
  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias ControlPlane.Repo

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "beheer_audit" do
    field :actor, :string
    field :methode, :string
    field :pad, :string
    field :uitkomst, :integer
    field :ip, :string
    field :details, :map, default: %{}

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{}

  @doc "Legt één handeling vast."
  @spec vastleggen(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def vastleggen(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:actor, :methode, :pad, :uitkomst, :ip, :details])
    |> validate_required([:actor, :methode, :pad])
    |> update_change(:pad, &String.slice(&1, 0, 255))
    |> Repo.insert()
  end

  @doc "De laatste handelingen, nieuwste eerst."
  @spec recent(pos_integer()) :: [t()]
  def recent(aantal \\ 100) do
    Repo.all(from a in __MODULE__, order_by: [desc: a.inserted_at], limit: ^aantal)
  end
end
