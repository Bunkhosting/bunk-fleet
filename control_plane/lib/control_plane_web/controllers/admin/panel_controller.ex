defmodule ControlPlaneWeb.Admin.PanelController do
  @moduledoc """
  Session-authenticated admin panel API (`/api/v1/admin/*`), gated by
  `ControlPlaneWeb.Plugs.RequireAdmin` (role == :admin on the caller's own token).

  Powers the dashboard admin section: platform stats, user management (role +
  wallet adjustments), a fleet-wide VPS view with lifecycle actions, and a node
  overview. All actions are authorized purely by the admin role — they are NOT
  owner-scoped (that's the whole point of an admin panel).
  """
  use ControlPlaneWeb, :controller
  import Ecto.Query

  alias ControlPlane.Accounts
  alias ControlPlane.Accounts.User
  alias ControlPlane.Billing.Revenue
  alias ControlPlane.Credits
  alias ControlPlane.Credits.LedgerEntry
  alias ControlPlane.Credits.TopupRequest
  alias ControlPlane.Enrollment
  alias ControlPlane.Fleet
  alias ControlPlane.Fleet.Command
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Metrics
  alias ControlPlane.Provisioning
  alias ControlPlane.Repo
  alias ControlPlane.Subscriptions.Subscription

  # --- Stats ---------------------------------------------------------------

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
  `GET /api/v1/beheer/users/:id` — alles wat er over één klant te weten is, op
  één plek.

  De lijst laat per klant een saldo en een aantal VPS'en zien; wat ontbrak was
  de vraag daarachter. Waarom staat deze klant op nul? Wanneer heeft hij voor
  het laatst betaald? Loopt er een abonnement dat niet meer geïnd kan worden?
  Dat waren tot nu toe vragen die alleen in de database te beantwoorden waren.
  """
  def user_detail(conn, %{"id" => id}) do
    with {:ok, uuid} <- Ecto.UUID.cast(id) |> ok_or(:not_found),
         %User{} = user <- Accounts.get_user(uuid) || :not_found do
      json(conn, %{
        user: %{
          id: user.id,
          email: user.email,
          name: user.name,
          role: user.role,
          confirmed: not is_nil(user.confirmed_at),
          totp_enabled: not is_nil(user.totp_confirmed_at),
          passkeys: length(Accounts.list_passkeys(user)),
          created_at: user.inserted_at
        },
        balance_cents: Credits.balance_cents(user.id),
        vpses: Enum.map(vpses_of(user.id), &vps_json/1),
        subscriptions: Enum.map(subscriptions_of(user.id), &subscription_json/1),
        ledger: Enum.map(Credits.list_entries(user.id, 50), &ledger_json/1),
        topups: Enum.map(topups_of(user.id), &topup_json/1)
      })
    else
      _ -> error(conn, :not_found, "not_found")
    end
  end

  defp vpses_of(user_id) do
    Repo.all(
      from v in Vps,
        where: v.owner_id == ^user_id and v.status != :deleted,
        order_by: [desc: v.inserted_at],
        preload: [:region, :node]
    )
  end

  defp subscriptions_of(user_id) do
    Repo.all(
      from s in Subscription,
        where: s.owner_id == ^user_id,
        order_by: [desc: s.inserted_at],
        preload: [:vps]
    )
  end

  defp topups_of(user_id) do
    Repo.all(
      from t in TopupRequest,
        where: t.user_id == ^user_id,
        order_by: [desc: t.inserted_at],
        limit: 25
    )
  end

  defp ledger_json(e) do
    %{
      id: e.id,
      amount_cents: e.amount_cents,
      kind: e.kind,
      description: e.description,
      at: e.inserted_at
    }
  end

  defp topup_json(t) do
    %{
      id: t.id,
      reference: t.reference,
      amount_cents: t.amount_cents,
      status: t.status,
      paid_at: t.paid_at,
      # Telt dit bedrag als omzet? Alleen als er een betaling bij de provider
      # bestond én die niet met de hand op betaald is gezet.
      via_provider: not is_nil(t.mollie_payment_id) and t.paid_via != "manual",
      paid_via: t.paid_via,
      requested_at: t.inserted_at
    }
  end

  defp subscription_json(s) do
    %{
      id: s.id,
      vps_id: s.vps_id,
      vps_name: s.vps && s.vps.name,
      status: s.status,
      price_monthly: s.price_monthly && Decimal.to_string(s.price_monthly),
      next_billing_date: s.next_billing_date,
      retry_at: s.retry_at,
      started_at: s.started_at,
      cancelled_at: s.cancelled_at
    }
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
  `POST /api/v1/beheer/enroll-tokens` — mint een eenmalig token waarmee een
  nieuwe node zich kan aanmelden, plus het installatiecommando dat de operator
  op die machine plakt.

  Dit endpoint bestaat naast dat onder `/admin/v1`. Dat laatste wordt door
  Cloudflare's WAF geblokkeerd voordat het de origin bereikt, waardoor het
  vanuit de browser niet aan te roepen is — precies de reden dat deze hele
  scope op /beheer staat. Zonder deze route was een node toevoegen vanuit het
  dashboard onmogelijk.

  Het token komt maar één keer terug: er staat alleen een hash van in de
  database.
  """
  def create_enroll_token(conn, params) do
    with {:ok, region} <- resolve_region(params),
         {:ok, {plaintext, token}} <-
           Enrollment.create_enroll_token(%{region_id: region.id, ttl_seconds: enroll_ttl(params)}) do
      conn
      |> put_status(:created)
      |> json(%{
        enroll_token: plaintext,
        expires_at: token.expires_at,
        region: region.code,
        install: "curl -fsSL #{public_url(conn)}/install.sh | bash -s -- --token #{plaintext}"
      })
    else
      {:error, :region_not_found} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "region_not_found"})

      {:error, :region_ambiguous} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "region_ambiguous"})

      {:error, _} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "invalid_enroll_token"})
    end
  end

  defp resolve_region(%{"region_code" => code}) when is_binary(code) and code != "" do
    case Fleet.region_by_code(code) do
      %Region{} = region -> {:ok, region}
      nil -> {:error, :region_not_found}
    end
  end

  defp resolve_region(%{"region_id" => id}) when is_binary(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %Region{} = region <- Repo.get(Region, uuid) do
      {:ok, region}
    else
      _ -> {:error, :region_not_found}
    end
  end

  # Geen regio meegegeven en er is er maar één: dan is die bedoeld. Zijn het er
  # meer, dan moet de operator kiezen — een node in de verkeerde regio plaatsen
  # stuurt klanten naar hardware die ergens anders staat dan ze kozen.
  #
  # "Meerdere" en "geen enkele" zijn twee verschillende problemen met twee
  # verschillende oplossingen, en ze gaven allebei dezelfde melding: "controleer
  # of er een regio bestaat", terwijl er net twee bij waren gekomen.
  defp resolve_region(_params) do
    case Repo.all(Region) do
      [%Region{} = only] -> {:ok, only}
      [] -> {:error, :region_not_found}
      _meerdere -> {:error, :region_ambiguous}
    end
  end

  @enroll_ttl_seconds 3600

  defp enroll_ttl(%{"ttl_seconds" => n}) when is_integer(n) and n > 0 and n <= 86_400, do: n
  defp enroll_ttl(_), do: @enroll_ttl_seconds

  defp public_url(conn) do
    case Application.get_env(:control_plane, :public_url) do
      url when is_binary(url) and url != "" -> url
      _ -> "#{conn.scheme}://#{conn.host}"
    end
  end

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

  # --- Users ---------------------------------------------------------------

  def users(conn, _params) do
    users = Repo.all(from u in User, order_by: [asc: u.inserted_at])

    vps_counts =
      Repo.all(
        from v in Vps,
          where: v.status not in [:deleted, :failed],
          group_by: v.owner_id,
          select: {v.owner_id, count(v.id)}
      )
      |> Map.new()

    balances =
      Repo.all(
        from e in LedgerEntry, group_by: e.user_id, select: {e.user_id, sum(e.amount_cents)}
      )
      |> Map.new()

    json(conn, %{
      users:
        Enum.map(users, fn u ->
          %{
            id: u.id,
            name: u.name,
            email: u.email,
            role: u.role,
            confirmed: not is_nil(u.confirmed_at),
            two_factor: not is_nil(u.totp_confirmed_at),
            inserted_at: DateTime.to_iso8601(u.inserted_at),
            vps_count: Map.get(vps_counts, u.id, 0),
            balance_cents: to_int(Map.get(balances, u.id, 0)),
            # Een verwijderd account waarvan de administratie moest blijven
            # staan. De rij bestaat nog; de persoon erachter niet meer.
            anonymised_at: u.anonymised_at && DateTime.to_iso8601(u.anonymised_at)
          }
        end)
    })
  end

  def update_user(conn, %{"id" => id} = params) do
    with {:ok, uid} <- Ecto.UUID.cast(id) |> ok_or(:not_found),
         %User{} = user <- Accounts.get_user(uid) || :not_found,
         {:ok, role} <- parse_role(params),
         :ok <- keeps_own_admin(conn, user, role),
         {:ok, u} <- Accounts.update_user_role(user, role) do
      json(conn, %{id: u.id, role: u.role})
    else
      :not_found -> error(conn, :not_found, "not_found")
      {:error, :invalid_role} -> error(conn, :unprocessable_entity, "invalid_role")
      {:error, :self_demotion} -> error(conn, :unprocessable_entity, "cannot_demote_self")
      {:error, %Ecto.Changeset{}} -> error(conn, :unprocessable_entity, "update_failed")
      _ -> error(conn, :not_found, "not_found")
    end
  end

  @doc """
  Verwijdert een account, of anonimiseert het als er een administratie aan hangt.

  Het antwoord zegt wélke van de twee het is geworden, zodat het scherm dat kan
  tonen in plaats van "verwijderd" te melden bij iets wat blijft bestaan.
  """
  def delete_user(conn, %{"id" => id}) do
    with {:ok, uid} <- Ecto.UUID.cast(id) |> ok_or(:not_found),
         %User{} = user <- Accounts.get_user(uid) || :not_found,
         :ok <- niet_jezelf(conn, user),
         {:ok, uitkomst} <- Accounts.delete_or_anonymise_user(user) do
      json(conn, %{result: uitkomst})
    else
      :not_found -> error(conn, :not_found, "not_found")
      {:error, :self} -> error(conn, :unprocessable_entity, "cannot_delete_self")
      {:error, :has_vpses} -> error(conn, :conflict, "user_has_vpses")
      {:error, _reason} -> error(conn, :unprocessable_entity, "delete_failed")
    end
  end

  # Jezelf verwijderen sluit je buiten je eigen paneel, en bij de laatste
  # beheerder sluit het iedereen buiten. Dezelfde reden als bij het degraderen.
  defp niet_jezelf(conn, %User{} = user) do
    if user.id == conn.assigns.current_user.id, do: {:error, :self}, else: :ok
  end

  # Never let an admin strip their OWN admin role: the last admin demoting
  # themselves locks the whole panel, and nothing in the panel can undo it.
  defp keeps_own_admin(conn, %User{} = user, role) do
    if user.id == conn.assigns.current_user.id and role != :admin,
      do: {:error, :self_demotion},
      else: :ok
  end

  def credit_user(conn, %{"id" => id} = params) do
    with {:ok, uid} <- Ecto.UUID.cast(id) |> ok_or(:not_found),
         %User{} = user <- Accounts.get_user(uid) || :not_found,
         {:ok, cents} <- parse_amount(params) do
      # Met de naam van de beheerder erbij. Er is meer dan één, en bij een regel
      # die geld verplaatst is "een beheerder" geen antwoord op de vraag die
      # achteraf gesteld wordt.
      {:ok, _} =
        Credits.add_entry(
          user.id,
          cents,
          "admin_adjustment",
          "Handmatige aanpassing door #{conn.assigns.current_user.email}"
        )

      json(conn, %{id: user.id, balance_cents: Credits.balance_cents(user.id)})
    else
      :not_found -> error(conn, :not_found, "not_found")
      {:error, :invalid_amount} -> error(conn, :unprocessable_entity, "invalid_amount")
      _ -> error(conn, :not_found, "not_found")
    end
  end

  # --- VPSes ---------------------------------------------------------------

  def vpses(conn, _params) do
    vpses =
      Repo.all(
        from v in Vps,
          where: v.status != :deleted,
          order_by: [desc: v.inserted_at],
          limit: 1000,
          preload: [:region, :node]
      )

    json(conn, %{vpses: Enum.map(vpses, &vps_json/1)})
  end

  def vps_start(conn, %{"id" => id}), do: vps_action(conn, id, &Provisioning.start_vps/1)
  def vps_stop(conn, %{"id" => id}), do: vps_action(conn, id, &Provisioning.stop_vps/1)

  def vps_delete(conn, %{"id" => id}) do
    with_valid_vps(conn, id, fn vps_id ->
      case Provisioning.delete_vps(vps_id) do
        {:ok, _} -> json(conn, %{detail: "deleting"})
        {:error, :not_found} -> error(conn, :not_found, "not_found")
        {:error, reason} -> error(conn, :unprocessable_entity, to_string(reason))
      end
    end)
  end

  # --- Nodes ---------------------------------------------------------------

  @doc """
  De regio's van de vloot: de locaties waar een klant tussen kan kiezen.

  Met het aantal nodes erbij, want een regio zonder nodes kan niets leveren en
  verschijnt niet in het bestelscherm. Dat verschil hoort zichtbaar te zijn
  voordat iemand zich afvraagt waarom er daar niets geplaatst wordt.
  """
  def regions(conn, _params) do
    json(conn, %{regions: Enum.map(Fleet.list_regions_with_counts(), &region_row/1)})
  end

  @doc "Maakt een nieuwe locatie aan."
  def create_region(conn, params) do
    case Fleet.create_region(%{code: params["code"], name: params["name"]}) do
      {:ok, region} ->
        conn
        |> put_status(:created)
        |> json(%{region: region_row(%{region: region, node_count: 0})})

      {:error, changeset} ->
        error(conn, :unprocessable_entity, region_error(changeset))
    end
  end

  @doc """
  Hernoemt een regio, wijzigt zijn code, of zet hem aan of uit.

  Uitzetten is geen verwijderen: wat er draait blijft draaien, er komt alleen
  niets nieuws bij. Dat is wat je wilt als een locatie wordt afgebouwd.
  """
  def update_region(conn, %{"id" => id} = params) do
    with {:ok, region_id} <- Ecto.UUID.cast(id) |> ok_or(:not_found),
         {:ok, region} <- Fleet.update_region(region_id, params) do
      json(conn, %{region: region_row(met_telling(region))})
    else
      :not_found -> error(conn, :not_found, "not_found")
      {:error, :not_found} -> error(conn, :not_found, "not_found")
      {:error, changeset} -> error(conn, :unprocessable_entity, region_error(changeset))
    end
  end

  @doc """
  Verwijdert een locatie die niets meer bevat.

  Waarom dit vaker "nee" zegt dan je zou denken: ook een allang verwijderde VPS
  houdt zijn verwijzing naar de locatie vast, want die rij blijft staan voor de
  administratie. Een locatie waar ooit iets in heeft gedraaid is dus niet meer
  weg te gooien -- de geschiedenis zou naar iets wijzen dat niemand kan opzoeken.
  Wat er wél weg kan is een locatie die nooit is gebruikt.

  Voor een locatie die wordt afgebouwd is uitzetten het antwoord: dan blijft
  draaien wat draait en komt er niets nieuws bij.
  """
  def delete_region(conn, %{"id" => id}) do
    with {:ok, region_id} <- Ecto.UUID.cast(id) |> ok_or(:not_found),
         :ok <- Fleet.delete_region(region_id) do
      send_resp(conn, :no_content, "")
    else
      :not_found -> error(conn, :not_found, "not_found")
      {:error, :not_found} -> error(conn, :not_found, "not_found")
      # Uitgeschreven in plaats van `Atom.to_string(reden)`, om twee redenen.
      # Zo staan de codes in de tekst en ziet `tools/foutcodes.py` ze, dus moet
      # er een zin bij horen. En dit gaat met opzet niet door de foutentabel:
      # `:has_vpses` betekent hier iets anders dan daar. Bij een gebruiker is
      # het "die klant heeft nog VPS'en", hier is het "in deze locatie heeft
      # een VPS gedraaid". Eén tabel kan die twee niet allebei goed vertalen,
      # dus wint de plek die weet waarover het gaat.
      #
      # Geen vangnet eronder, en dat is geen slordigheid: `delete_region/1`
      # geeft volgens zijn @spec precies deze vier dingen terug, en dialyzer
      # weigert een clausule die niets kan matchen. Komt er ooit een vijfde
      # reden bij, dan valt dat om -- in de build, met de reden erbij, en niet
      # bij een beheerder die een 409 met een onbekende code krijgt.
      {:error, :has_nodes} -> error(conn, :conflict, "has_nodes")
      {:error, :has_vpses} -> error(conn, :conflict, "has_vpses")
      {:error, :has_enroll_tokens} -> error(conn, :conflict, "has_enroll_tokens")
    end
  end

  # Twee dingen kunnen er met een code misgaan en ze vragen om iets anders van
  # degene die het intypt: hij bestaat al, of hij heeft niet de vorm die in een
  # URL past. "invalid" zou hem laten raden welke van de twee.
  defp region_error(%Ecto.Changeset{errors: errors}) do
    case Keyword.get(errors, :code) do
      nil ->
        "invalid_region"

      {_melding, opts} ->
        if opts[:constraint], do: "region_code_taken", else: "invalid_region_code"
    end
  end

  # Het paneel voegt dit antwoord samen met de rij die het al toonde, dus een nul
  # die "niet opgevraagd" betekent zou het aantal nodes ter plekke wissen.
  defp met_telling(region) do
    Enum.find(
      Fleet.list_regions_with_counts(),
      %{region: region, node_count: 0},
      &(&1.region.id == region.id)
    )
  end

  defp region_row(%{region: r, node_count: n}) do
    %{id: r.id, code: r.code, name: r.name, enabled: r.enabled, node_count: n}
  end

  def nodes(conn, _params) do
    json(conn, %{nodes: Enum.map(Fleet.list_nodes(), &node_json/1)})
  end

  @doc """
  Closes a node to new VPSes, or reopens it.

  The thing you reach for before maintenance, or when a machine is misbehaving:
  the scheduler stops placing there while everything already on it keeps running
  and keeps being served. Emptying it afterwards is deliberate and manual.
  """
  def drain_node(conn, %{"id" => id}), do: node_transition(conn, id, &Fleet.drain_node/1)

  def resume_node(conn, %{"id" => id}), do: node_transition(conn, id, &Fleet.resume_node/1)

  defp node_transition(conn, id, change) do
    with {:ok, node_id} <- Ecto.UUID.cast(id),
         {:ok, node} <- change.(node_id) do
      json(conn, %{node: node_json(Repo.preload(node, :region))})
    else
      :error -> error(conn, :not_found, "not_found")
      {:error, :not_found} -> error(conn, :not_found, "not_found")
      {:error, {:invalid_status, status}} -> error(conn, :conflict, "invalid_status_#{status}")
      {:error, _reason} -> error(conn, :unprocessable_entity, "invalid_node")
    end
  end

  def delete_node(conn, %{"id" => id}) do
    case Ecto.UUID.cast(id) do
      {:ok, node_id} ->
        case Fleet.delete_node(node_id) do
          {:ok, _} -> json(conn, %{detail: "ok"})
          {:error, :not_found} -> error(conn, :not_found, "not_found")
          {:error, :node_has_vpses} -> error(conn, :conflict, "node_has_vpses")
          {:error, reason} -> error(conn, :unprocessable_entity, to_string(inspect(reason)))
        end

      :error ->
        error(conn, :not_found, "not_found")
    end
  end

  # --- helpers -------------------------------------------------------------

  defp vps_action(conn, id, fun) do
    with_valid_vps(conn, id, fn vps_id ->
      case fun.(vps_id) do
        {:ok, _} -> json(conn, %{detail: "ok"})
        {:error, :not_found} -> error(conn, :not_found, "not_found")
        {:error, reason} -> error(conn, :unprocessable_entity, to_string(inspect(reason)))
      end
    end)
  end

  defp with_valid_vps(conn, id, fun) do
    case Ecto.UUID.cast(id) do
      {:ok, vps_id} -> fun.(vps_id)
      :error -> error(conn, :not_found, "not_found")
    end
  end

  defp vps_json(%Vps{} = v) do
    %{
      id: v.id,
      name: v.name,
      status: v.status,
      owner_email: v.owner_email,
      node: node_name(v),
      region: region_code(v),
      vcpu: v.vcpu,
      ram_mb: v.ram_mb,
      disk_gb: v.disk_gb,
      ip_address: v.ip_address,
      inserted_at: DateTime.to_iso8601(v.inserted_at)
    }
  end

  defp node_json(%Node{} = n) do
    %{
      id: n.id,
      name: n.name,
      status: n.status,
      # Kostenplaats, niet de beheerder: dit label landt in de verbruiksregels en
      # zegt welk team of persoon binnen Bunk de hardware betaalt. Wie de node
      # beheert staat hieronder als `owner` -- twee e-mailachtige eigenaarsvelden
      # met dezelfde naam is vragen om verwarring.
      cost_centre: n.owner_email,
      region: region_code(n),
      total_vcpu: n.total_vcpu,
      total_ram_mb: n.total_ram_mb,
      total_disk_gb: n.total_disk_gb,
      available_vcpu: n.available_vcpu,
      available_ram_mb: n.available_ram_mb,
      available_disk_gb: n.available_disk_gb,
      # Wat de node zelf ziet. Plaatsing vereist dat beide cijfers ruimte hebben,
      # dus het laagste is het bindende -- en alleen het schedulercijfer tonen
      # geeft een beheerder een ruimer beeld dan de werkelijkheid toelaat.
      reported_avail_vcpu: n.reported_avail_vcpu,
      reported_avail_ram_mb: n.reported_avail_ram_mb,
      reported_avail_disk_gb: n.reported_avail_disk_gb,
      last_heartbeat_at: n.last_heartbeat_at && DateTime.to_iso8601(n.last_heartbeat_at),
      agent_version: n.agent_version,
      capacity_error: n.capacity_error,
      drain_reason: n.drain_reason,
      owner_id: n.owner_id,
      owner: owner_label(n),
      settings: Map.take(n, Node.settings_fields())
    }
  end

  defp node_name(%Vps{node: %Node{name: name}}), do: name
  defp node_name(_), do: nil

  defp owner_label(%Node{owner: %User{email: email}}), do: email
  defp owner_label(_node), do: nil

  defp region_code(%{region: %{code: code}}), do: code
  defp region_code(_), do: nil

  defp count_by(query, f) do
    Repo.all(from x in query, group_by: field(x, ^f), select: {field(x, ^f), count(x.id)})
    |> Map.new()
  end

  defp map_total(m), do: m |> Map.values() |> Enum.sum()

  defp parse_role(%{"role" => r}) when r in ["user", "operator", "admin"],
    do: {:ok, String.to_existing_atom(r)}

  defp parse_role(_), do: {:error, :invalid_role}

  defp parse_amount(%{"amount_cents" => v}) do
    cents =
      cond do
        is_integer(v) ->
          v

        is_binary(v) ->
          case Integer.parse(v) do
            {n, ""} -> n
            _ -> nil
          end

        true ->
          nil
      end

    if is_integer(cents) and cents != 0 and abs(cents) <= 10_000_000,
      do: {:ok, cents},
      else: {:error, :invalid_amount}
  end

  defp parse_amount(_), do: {:error, :invalid_amount}

  defp to_int(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_int(n) when is_integer(n), do: n
  defp to_int(_), do: 0

  defp ok_or({:ok, v}, _err), do: {:ok, v}
  defp ok_or(:error, err), do: err

  defp error(conn, status, code) do
    conn |> put_status(status) |> json(%{error: code})
  end
end
