defmodule ControlPlane.Fleet.Housekeeping do
  @moduledoc """
  Periodiek opruimwerk in de vloot dat geen klant ziet, maar dat zonder deze
  module stilletjes zou blijven liggen.

  `scrub_deleted_vpses/1` wist de persoons- en machinegegevens van VPS'en die al
  langer dan de beloofde bewaartermijn verwijderd zijn; de rij zelf blijft staan
  voor de administratie. `release_orphaned_reservations/0` geeft capaciteit terug
  die nog vastgehouden wordt voor een VPS die er niet meer is, zodat een node
  niet ten onrechte als vol te boek blijft staan.
  """
  import Ecto.Query

  alias ControlPlane.Clock
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Reservation
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Repo
  alias Ecto.Multi

  @doc """
  Wist wat er van een verwijderde VPS niet bewaard hoeft te blijven, en geeft
  terug hoeveel rijen er zijn opgeschoond.

  De privacyverklaring belooft dat VPS-gegevens dertig dagen na het verwijderen
  weg zijn. In de code gebeurde dat niet: een rij met `:deleted` bleef staan met
  het IP-adres, het e-mailadres als los label, de hostsleutel en de versleutelde
  consolesleutel erin -- voor altijd. Een belofte die alleen in een tekst staat
  is geen bewaartermijn.

  De rij zelf blijft wél staan. Daar hangt de administratie aan (grootboek,
  abonnementen, verbruik), en die moet zeven jaar bewaard blijven. Wat eruit
  gaat zijn de velden die daar niets mee te maken hebben en die de persoon of
  zijn machine aanwijzen. Dat is precies wat de AVG bedoelt met minimalisatie:
  de bedragen houden, de identiteit eruit.

  Idempotent: rijen waar niets meer in staat komen niet terug in de selectie.

  De termijn staat als argument en niet vast, omdat hij een BELOFTE is en geen
  technische constante. Verandert de tekst, dan verandert dit getal mee -- en
  niet andersom.
  """
  @spec scrub_deleted_vpses(pos_integer()) :: non_neg_integer()
  def scrub_deleted_vpses(dagen \\ 30) do
    cutoff = Clock.shift(-dagen * 24 * 3600)

    {aantal, _} =
      Repo.update_all(
        from(v in Vps,
          where: v.status == :deleted and v.updated_at < ^cutoff,
          where:
            not is_nil(v.ip_address) or not is_nil(v.owner_email) or
              not is_nil(v.ssh_host_key) or not is_nil(v.console_key_sealed) or
              not is_nil(v.console_key_public)
        ),
        set: [
          ip_address: nil,
          owner_email: nil,
          ssh_host_key: nil,
          console_key_sealed: nil,
          console_key_public: nil
        ]
      )

    aantal
  end

  @doc """
  Reclaims capacity reservations that are still `:held` but no longer back a live
  VPS — the VPS was deleted/failed, or the reservation was orphaned (null `vps_id`)
  by a rolled-back placement. Each reclaimed reservation is marked `:released` and
  its vcpu/ram/disk are added back to its node's advertised capacity, so a leaked
  reservation can never keep a node wrongly reported as "full".

  Reservations backing a VPS that is still `:queued`/`:provisioning`/`:active`
  (or `:stopped`/`:paused`/`:deleting`) are left untouched — those hold capacity
  for a real workload. Returns the number of reservations reclaimed.
  """
  @spec release_orphaned_reservations() :: non_neg_integer()
  def release_orphaned_reservations do
    orphaned =
      Repo.all(
        from r in Reservation,
          left_join: v in Vps,
          on: v.id == r.vps_id,
          where: r.status == :held and (is_nil(r.vps_id) or v.status in [:deleted, :failed])
      )

    Enum.reduce(orphaned, 0, fn reservation, reclaimed ->
      case release_reservation(reservation) do
        {:ok, _} -> reclaimed + 1
        {:error, _} -> reclaimed
      end
    end)
  end

  # Atomically marks a held reservation released and returns its capacity to the node.
  defp release_reservation(%Reservation{} = reservation) do
    Multi.new()
    |> Multi.update(:reservation, Reservation.changeset(reservation, %{status: :released}))
    |> Multi.run(:restore_capacity, fn repo, _changes ->
      Node.add_capacity(repo, reservation)
    end)
    |> Repo.transaction()
  end
end
