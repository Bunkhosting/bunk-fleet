defmodule ControlPlaneWeb.Admin.PanelFleetController do
  @moduledoc """
  De fleet in het beheerpaneel: regio's, nodes en het aanmelden van nieuwe
  nodes (`/api/v1/beheer/regions*`, `/nodes*` en `/enroll-tokens`).

  Locaties aanmaken, wijzigen en opruimen; nodes dichtzetten, heropenen en
  verwijderen; en een eenmalig aanmeldtoken uitgeven voor een nieuwe machine.
  Afgeschermd door `ControlPlaneWeb.Plugs.RequireAdmin`.
  """
  use ControlPlaneWeb, :controller
  import ControlPlaneWeb.Admin.PanelHelpers, only: [error: 3, ok_or: 2, region_code: 1]

  alias ControlPlane.Accounts.User
  alias ControlPlane.Enrollment
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.NodeAdmin
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Regions
  alias ControlPlane.Repo

  @doc """
  De regio's van de vloot: de locaties waar een klant tussen kan kiezen.

  Met het aantal nodes erbij, want een regio zonder nodes kan niets leveren en
  verschijnt niet in het bestelscherm. Dat verschil hoort zichtbaar te zijn
  voordat iemand zich afvraagt waarom er daar niets geplaatst wordt.
  """
  def regions(conn, _params) do
    json(conn, %{regions: Enum.map(Regions.list_regions_with_counts(), &region_row/1)})
  end

  @doc "Maakt een nieuwe locatie aan."
  def create_region(conn, params) do
    case Regions.create_region(%{code: params["code"], name: params["name"]}) do
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
         {:ok, region} <- Regions.update_region(region_id, params) do
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
         :ok <- Regions.delete_region(region_id) do
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
      Regions.list_regions_with_counts(),
      %{region: region, node_count: 0},
      &(&1.region.id == region.id)
    )
  end

  defp region_row(%{region: r, node_count: n}) do
    %{id: r.id, code: r.code, name: r.name, enabled: r.enabled, node_count: n}
  end

  def nodes(conn, _params) do
    json(conn, %{nodes: Enum.map(NodeAdmin.list_nodes(), &node_json/1)})
  end

  @doc """
  Closes a node to new VPSes, or reopens it.

  The thing you reach for before maintenance, or when a machine is misbehaving:
  the scheduler stops placing there while everything already on it keeps running
  and keeps being served. Emptying it afterwards is deliberate and manual.
  """
  def drain_node(conn, %{"id" => id}), do: node_transition(conn, id, &NodeAdmin.drain_node/1)

  def resume_node(conn, %{"id" => id}), do: node_transition(conn, id, &NodeAdmin.resume_node/1)

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
        case NodeAdmin.delete_node(node_id) do
          {:ok, _} -> json(conn, %{detail: "ok"})
          {:error, :not_found} -> error(conn, :not_found, "not_found")
          {:error, :node_has_vpses} -> error(conn, :conflict, "node_has_vpses")
          {:error, reason} -> error(conn, :unprocessable_entity, to_string(inspect(reason)))
        end

      :error ->
        error(conn, :not_found, "not_found")
    end
  end

  @doc """
  `POST /api/v1/beheer/enroll-tokens` — mint een eenmalig token waarmee een
  nieuwe node zich kan aanmelden, plus het installatiecommando dat de operator
  op die machine plakt.

  Dit endpoint bestaat naast dat onder `/admin/v1`. Dat laatste wordt door
  Cloudflare's WAF geblokkeerd voordat het de origin bereikt (en de edge stuurt
  het ook niet door), waardoor het vanuit de browser niet aan te roepen is —
  precies de reden dat deze hele scope op /beheer staat. Zonder deze route was
  een node toevoegen vanuit het dashboard onmogelijk.

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
    case Regions.region_by_code(code) do
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
      network_note: n.network_note,
      drain_reason: n.drain_reason,
      owner_id: n.owner_id,
      owner: owner_label(n),
      settings: Map.take(n, Node.settings_fields())
    }
  end

  defp owner_label(%Node{owner: %User{email: email}}), do: email
  defp owner_label(_node), do: nil
end
