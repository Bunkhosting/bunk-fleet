defmodule ControlPlane.Fleet.Region do
  @moduledoc """
  A geographic/logical region into which fleet nodes are grouped (e.g. "nl-1").
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "regions" do
    field :code, :string
    field :name, :string
    field :enabled, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  # De code komt in bestelhistorie en in de installatie-instructies van elke node
  # in die regio terecht, en gaat als `region_code` over de URL. Daarom een vaste
  # vorm in plaats van vrije tekst: kleine letters, cijfers en koppeltekens.
  @code_format ~r/^[a-z0-9]+(-[a-z0-9]+)*$/

  @doc false
  def changeset(region, attrs) do
    region
    |> cast(attrs, [:code, :name, :enabled])
    |> validate_required([:code, :name])
    # Hoofdletters zijn een typfout en geen andere regio: "NL-2" hoort "nl-2" te
    # worden in plaats van te worden afgekeurd.
    |> update_change(:code, &String.downcase(String.trim(&1)))
    |> update_change(:name, &String.trim/1)
    |> validate_format(:code, @code_format,
      message: "mag alleen kleine letters, cijfers en koppeltekens bevatten"
    )
    |> validate_length(:code, max: 32)
    # Wel een bovengrens en geen ondergrens: de naam is een label op een scherm,
    # en een beheerder die er bewust "R" van maakt heeft daar zijn reden voor.
    # Voor de vrije invoer uit het dashboard bewaakt `Fleet.Regions.ensure_region/1` de
    # ondergrens -- dáár is een enkel teken een typfout en geen keuze.
    |> validate_length(:name, max: 60)
    |> unique_constraint(:code)
  end
end
