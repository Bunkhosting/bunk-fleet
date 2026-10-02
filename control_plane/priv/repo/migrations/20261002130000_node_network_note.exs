defmodule ControlPlane.Repo.Migrations.NodeNetworkNote do
  use Ecto.Migration

  # Een node kan er van buiten volkomen gezond uitzien -- hartslag, capaciteit,
  # API-rechten -- en toch niet bij de VPS'en komen die hij zelf draait. De
  # webterminal loopt via de agent, dus dan valt hij zonder uitleg dicht. De agent
  # wist dat wel, maar zei het alleen in een logbestand op de node.
  #
  # Dit is waar hij het nu kwijt kan. Het is een notitie en geen blokkade: een
  # vermoeden mag de node niet uit de verkoop halen. Een vaststelling gaat in
  # `capacity_error`, dat al bestaat.
  #
  # NULL is hier gewoon "niets te melden", ook voor alle bestaande rijen, dus
  # er valt niets te backfillen.
  def change do
    alter table(:nodes) do
      add :network_note, :string
    end
  end
end
