defmodule ControlPlaneWeb.Admin.PanelController do
  @moduledoc """
  Het overzicht van het beheerpaneel (`/api/v1/beheer/*`), afgeschermd door
  `ControlPlaneWeb.Plugs.RequireAdmin` (rol `:admin` op het eigen token).

  Platformcijfers, metrieken, omzet, lopende abonnementen en de recente
  commando's van de fleet. Gebruikers, VPS'en en de fleet zelf hebben elk een
  eigen controller: `PanelUsersController`, `PanelVpsController` en
  `PanelFleetController`. Alles hier is alleen aan de beheerdersrol gebonden en
  niet aan een eigenaar -- dat is het hele punt van een beheerpaneel.
  """
  use ControlPlaneWeb, :controller
  import Ecto.Query
  import ControlPlaneWeb.Admin.PanelHelpers, only: [subscription_json: 1]

  alias ControlPlane.Accounts.User
  alias ControlPlane.Billing.Revenue
  alias ControlPlane.Credits
  alias ControlPlane.Credits.LedgerEntry
  alias ControlPlane.Fleet.Command
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Metrics
  alias ControlPlane.Repo
  alias ControlPlane.Subscriptions.Subscription

  def stats(conn, _params) do
    by_role = count_by(from(u in User), :role)
    by_status = count_by(from(v in Vps), :status)
    # Counted in the database like its two neighbours, rather than pulled into
    # memory a row at a time to be counted here.
    by_node_status = count_by(from(n in Node), :status)

    outstanding =
      Repo.one(from e in LedgerEntry, select: coalesce(sum(e.amount_cents), 0)) || 0

    # Hetzelfde bedrag, maar uitgesplitst. Eén getal maakt handmatig toegekend
    # testsaldo net zo echt als geld dat een klant heeft overgemaakt, en juist
    # dat verschil is wat iemand die naar dit paneel kijkt moet zien.
    herkomst = Credits.saldo_naar_herkomst()

    json(conn, %{
      users: %{
        total: map_total(by_role),
        user: Map.get(by_role, :user, 0),
        admin: Map.get(by_role, :admin, 0)
      },
      vpses: %{
        total: map_total(Map.delete(by_status, :deleted)),
        active: Map.get(by_status, :active, 0),
        stopped: Map.get(by_status, :stopped, 0),
        provisioning: Map.get(by_status, :provisioning, 0) + Map.get(by_status, :queued, 0),
        failed: Map.get(by_status, :failed, 0)
      },
      nodes: %{
        total: map_total(by_node_status),
        online: Map.get(by_node_status, :online, 0)
      },
      credit_outstanding_cents: outstanding,
      credit_breakdown: herkomst
    })
  end

  @doc """
  `GET /api/v1/beheer/metrics` — what the platform is doing, in numbers.

  Deliberately aggregate-only. There is nothing here that identifies a customer:
  the authentication figures are daily totals with no user, address or IP behind
  them, and the fleet figures are about machines. An admin panel that could
  answer "when did this person last log in" is one that needs a legal basis and a
  deletion path; this one is built so that question has no answer to give.
  """
  def metrics(conn, _params) do
    json(conn, %{
      auth: Enum.map(Metrics.auth_history(14), &auth_day_json/1),
      accounts: account_totals(),
      nodes: Enum.map(Metrics.node_capacity(), &node_metrics_json/1),
      commands: Enum.map(Metrics.command_outcomes(24), &command_outcome_json/1),
      backups: Enum.map(Metrics.backup_health(7), &backup_health_json/1)
    })
  end

  @doc """
  `GET /api/v1/beheer/subscriptions` — wat er loopt en wat er niet meer geïnd
  wordt.

  `past_due` eerst: dat is een klant wiens VPS is opgeschort omdat zijn tegoed
  op was. Elke dag dat zo'n rij onopgemerkt blijft staan is een klant die denkt
  dat zijn server stuk is.
  """
  def subscriptions(conn, _params) do
    rijen =
      Repo.all(
        from s in Subscription,
          where: s.status != :cancelled,
          order_by: [asc: s.status, asc: s.next_billing_date],
          limit: 500,
          preload: [:vps]
      )

    maandbedrag =
      rijen
      |> Enum.filter(&(&1.status == :active))
      |> Enum.reduce(Decimal.new(0), fn s, acc -> Decimal.add(acc, s.price_monthly || 0) end)

    json(conn, %{
      subscriptions: Enum.map(rijen, &subscription_json/1),
      active: Enum.count(rijen, &(&1.status == :active)),
      past_due: Enum.count(rijen, &(&1.status == :past_due)),
      monthly_total: Decimal.to_string(maandbedrag)
    })
  end

  @doc """
  `GET /api/v1/beheer/commands` — wat de fleet de afgelopen tijd heeft gedaan.

  De metriekenpagina telt uitkomsten bij elkaar op; dit laat de regels zelf
  zien. Bij een mislukte provisioning is het aantal niet wat je nodig hebt maar
  de foutmelding.
  """
  def commands(conn, params) do
    limiet = params["limit"] |> to_int(100) |> min(500)

    vraag =
      from c in Command,
        order_by: [desc: c.inserted_at],
        limit: ^limiet,
        preload: [:node, :vps]

    vraag =
      case params["status"] do
        s when s in ["pending", "delivered", "done", "failed"] ->
          status = String.to_existing_atom(s)
          from c in vraag, where: c.status == ^status

        _ ->
          vraag
      end

    json(conn, %{commands: Enum.map(Repo.all(vraag), &command_json/1)})
  end

  defp command_json(c) do
    %{
      id: c.id,
      kind: c.kind,
      status: c.status,
      node: c.node && c.node.name,
      vps_id: c.vps_id,
      vps_name: c.vps && c.vps.name,
      # Alleen de foutmelding, niet de hele payload: daar staat cloud-init in,
      # en dat is invoer van de klant die hier niets toevoegt.
      error: c.result && c.result["error"],
      at: c.inserted_at,
      delivered_at: c.delivered_at
    }
  end

  defp to_int(v, standaard) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} when n > 0 -> n
      _ -> standaard
    end
  end

  defp to_int(v, _standaard) when is_integer(v) and v > 0, do: v
  defp to_int(_, standaard), do: standaard

  @doc """
  Omzet, btw en factuurregels over een periode — wat er nodig is om aangifte te
  doen zonder in de database te hoeven kijken.

  `from` en `to` zijn data (`YYYY-MM-DD`) en tellen allebei volledig mee.
  Zonder parameters: het lopende kalenderjaar.
  """
  def revenue(conn, params) do
    with {:ok, from} <- parse_date(params["from"], Date.new!(Date.utc_today().year, 1, 1)),
         {:ok, to} <- parse_date(params["to"], Date.utc_today()) do
      json(conn, %{
        from: Date.to_iso8601(from),
        to: Date.to_iso8601(to),
        vat_percentage: Revenue.vat_percentage(),
        total: Revenue.summary(from, to),
        quarters: Revenue.by_quarter(from, to),
        invoices: Enum.map(Revenue.invoices(from, to), &invoice_json/1),
        # Wat er bewust buiten de telling valt. Uitsluiten zonder tonen is
        # verbergen: dan is het verschil tussen de bank en de aangifte niet meer
        # te verklaren.
        excluded: Enum.map(Revenue.excluded(from, to), &excluded_json/1)
      })
    else
      :error -> conn |> put_status(:unprocessable_entity) |> json(%{error: "invalid_date"})
    end
  end

  defp parse_date(nil, default), do: {:ok, default}

  defp parse_date(value, _default) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  defp parse_date(_, _), do: :error

  defp invoice_json(row) do
    %{
      reference: row.reference,
      paid_at: row.paid_at && DateTime.to_iso8601(row.paid_at),
      customer: row.customer,
      gross_cents: row.gross_cents,
      net_cents: row.net_cents,
      vat_cents: row.vat_cents,
      mollie_payment_id: row.mollie_payment_id,
      paid_via: row.paid_via
    }
  end

  defp excluded_json(row) do
    %{
      reference: row.reference,
      paid_at: row.paid_at && DateTime.to_iso8601(row.paid_at),
      customer: row.customer,
      gross_cents: row.amount_cents,
      reason: row.reason
    }
  end

  # Counts, not people: how many accounts exist, how many finished confirming,
  # how many turned on a second factor. Useful for seeing whether onboarding
  # works; useless for finding anyone.
  defp account_totals do
    %{
      total: Repo.aggregate(User, :count, :id),
      confirmed: Repo.aggregate(from(u in User, where: not is_nil(u.confirmed_at)), :count, :id),
      with_2fa:
        Repo.aggregate(from(u in User, where: not is_nil(u.totp_confirmed_at)), :count, :id)
    }
  end

  defp auth_day_json(row) do
    %{
      day: Date.to_iso8601(row.day),
      successes: row.successes,
      failures: row.failures,
      registrations: row.registrations,
      captcha_refusals: row.captcha_refusals
    }
  end

  defp node_metrics_json(n) do
    %{
      name: n.name,
      status: n.status,
      vps_count: n.vps_count,
      seconds_since_heartbeat: n.seconds_since_heartbeat,
      vcpu: %{total: n.total_vcpu, available: n.available_vcpu},
      ram_mb: %{total: n.total_ram_mb, available: n.available_ram_mb},
      disk_gb: %{total: n.total_disk_gb, available: n.available_disk_gb},
      headroom_pct: n.headroom_pct
    }
  end

  defp command_outcome_json(c), do: %{kind: c.kind, status: c.status, count: c.count}

  defp backup_health_json(b) do
    %{
      name: b.name,
      last_success_at: b.last_success_at && DateTime.to_iso8601(b.last_success_at),
      hours_since_success: b.hours_since_success,
      failures: b.failures
    }
  end

  defp count_by(query, f) do
    Repo.all(from x in query, group_by: field(x, ^f), select: {field(x, ^f), count(x.id)})
    |> Map.new()
  end

  defp map_total(m), do: m |> Map.values() |> Enum.sum()
end
