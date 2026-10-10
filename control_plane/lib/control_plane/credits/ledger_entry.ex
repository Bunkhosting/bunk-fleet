defmodule ControlPlane.Credits.LedgerEntry do
  @moduledoc "A single signed-cents movement in a customer's prepaid credit wallet."
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @soorten ~w(topup signup_bonus admin_topup admin_adjustment correction vps_charge vps_charge_refunded vps_refund)

  @doc "De grootboeksoorten die bestaan."
  def soorten, do: @soorten

  schema "ledger_entries" do
    field :amount_cents, :integer
    field :kind, :string
    field :description, :string
    belongs_to :user, ControlPlane.Accounts.User

    # The machine this movement was about, when there is one. A `vps_charge`
    # without it is an orphan: money taken for a VPS that never got created.
    belongs_to :vps, ControlPlane.Fleet.Vps

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:user_id, :vps_id, :amount_cents, :kind, :description])
    |> validate_required([:user_id, :amount_cents, :kind])
    # Dezelfde lijst als de CHECK-constraint in de database (migratie
    # GeldigeWaarden). De weessweep en de omzetindeling lezen de soort als exacte
    # tekst; een onbekende soort viel stil buiten beide.
    |> validate_inclusion(:kind, @soorten)
    |> check_constraint(:kind, name: :ledger_entries_kind_geldig)
    # De kolom is varchar(255). Langer gaf een exceptie uit de database in
    # plaats van een fout die een aanroeper kan afhandelen.
    |> validate_length(:description, max: 255)
  end
end
