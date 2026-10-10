defmodule ControlPlane.Repo.Migrations.GeldigeWaarden do
  use Ecto.Migration

  # De status- en soortkolommen waren vrije tekst. Alleen Ecto.Enum in de
  # applicatie hield ongeldige waarden tegen, en een handmatige query, een
  # tweede schrijver of een typfout in een update_all kwam er ongezien langs.
  # Voor het grootboek telt dat dubbel: de weessweep en de omzetindeling lezen
  # de soort als exacte tekst, en een onbekende soort valt stil buiten beide.
  #
  # NOT VALID en daarna VALIDATE: het toevoegen houdt dan geen schrijfslot vast
  # terwijl de bestaande rijen gecontroleerd worden. Bestaande waarden op
  # productie zijn vooraf nagelopen (2026-10-10) en vallen allemaal binnen deze
  # lijsten.

  @regels [
    {:vpses, :vpses_status_geldig, :status,
     ~w(queued provisioning active stopped paused restoring failed deleting deleted)},
    {:commands, :commands_kind_geldig, :kind,
     ~w(provision delete start stop pause resume reboot backup delete_backup restore_backup inventory update)},
    {:commands, :commands_status_geldig, :status, ~w(pending delivered done failed)},
    {:subscriptions, :subscriptions_status_geldig, :status, ~w(active cancelled past_due)},
    {:subscriptions, :subscriptions_billing_cycle_geldig, :billing_cycle, ~w(monthly yearly)},
    {:topup_requests, :topup_requests_status_geldig, :status, ~w(pending paid cancelled)},
    {:reservations, :reservations_status_geldig, :status, ~w(held committed released)},
    {:nodes, :nodes_status_geldig, :status, ~w(pending online draining offline)},
    {:nodes, :nodes_hypervisor_geldig, :hypervisor, ~w(proxmox esxi incus)},
    {:ledger_entries, :ledger_entries_kind_geldig, :kind,
     ~w(topup signup_bonus admin_topup admin_adjustment correction vps_charge vps_charge_refunded vps_refund)}
  ]

  def up do
    for {tabel, naam, kolom, waarden} <- @regels do
      lijst = Enum.map_join(waarden, ", ", &"'#{&1}'")
      create constraint(tabel, naam, check: "#{kolom} IN (#{lijst})", validate: false)
    end

    flush()

    for {tabel, naam, _kolom, _waarden} <- @regels do
      execute("ALTER TABLE #{tabel} VALIDATE CONSTRAINT #{naam}")
    end
  end

  def down do
    for {tabel, naam, _kolom, _waarden} <- @regels do
      drop constraint(tabel, naam)
    end
  end
end
