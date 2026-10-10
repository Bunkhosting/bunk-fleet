defmodule ControlPlaneWeb.Plugs.AdminAuditLog do
  @moduledoc """
  Legt vast wie welke beheerhandeling deed.

  Er zijn twee beheerders. Het grootboek zei tot nu toe "handmatige aanpassing
  door beheerder" zonder te zeggen door wie, en een verwijderde gebruiker of een
  gewijzigde rol liet helemaal geen spoor na. Bij geld en bij andermans account
  is "er is iets gebeurd" te weinig: de vraag die achteraf gesteld wordt is wie.

  Alleen handelingen, geen leesverzoeken. Een beheerder die een lijst opent is
  geen gebeurtenis; elke GET meelopen zou de log vullen met ruis waarin de
  regels die ertoe doen verdwijnen.

  Wat er in staat: wie, wat, welk pad, welke uitkomst. Geen request body -- daar
  zitten bedragen en e-mailadressen in, en een log is geen plek die zichzelf
  opruimt. Het pad bevat wel de id waar de handeling over ging, want zonder dat
  is de regel niet na te trekken.

  Sinds 2026-10-10 staat het ook in de tabel `beheer_audit` (alleen
  toevoegen, zie `ControlPlane.Beheer.Audit`), met het IP-adres en een paar
  velden uit het verzoek die ertoe doen en geen persoonsgegevens zijn: een
  bedrag, een rol, aan of uit. Een wachtwoord of e-mailadres komt er niet in.
  De applicatielog blijft er ook, voor wie de logs doorzoekt.

  Ook de API met het gedeelde geheim (/admin/v1) loopt hierdoorheen. Daar is de
  actor "admin-token": wie het was, weet die API niet, en dat is precies waarom
  hij beter niet gebruikt wordt.
  """
  import Plug.Conn

  require Logger

  alias ControlPlane.Accounts.User
  alias ControlPlane.Beheer.Audit

  @behaviour Plug

  # GET en HEAD veranderen niets; die horen hier niet in.
  @veranderende_methodes ~w(POST PUT PATCH DELETE)

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: method} = conn, _opts) when method in @veranderende_methodes do
    register_before_send(conn, &schrijf/1)
  end

  def call(conn, _opts), do: conn

  defp schrijf(conn) do
    Logger.info("beheerhandeling",
      admin: actor(conn),
      methode: conn.method,
      pad: conn.request_path,
      uitkomst: conn.status
    )

    # Een mislukte vastlegging mag het antwoord niet breken -- de handeling is
    # al gebeurd -- maar hoort wel luid te zijn.
    try do
      case Audit.vastleggen(%{
             actor: actor(conn),
             methode: conn.method,
             pad: conn.request_path,
             uitkomst: conn.status,
             ip: ip(conn),
             details: details(conn)
           }) do
        {:ok, _} -> :ok
        {:error, reden} -> Logger.error("beheerhandeling niet vastgelegd: #{inspect(reden)}")
      end
    rescue
      e -> Logger.error("beheerhandeling niet vastgelegd: " <> Exception.message(e))
    end

    conn
  end

  # De velden uit het verzoek die zeggen WAT er veranderde, en geen
  # persoonsgegevens of geheimen zijn.
  @veilige_velden ~w(amount_cents role enabled code status kind region_code)

  # body_params is altijd een map: de geparste velden, of een
  # Plug.Conn.Unfetched-struct waar Map.take niets uit haalt.
  defp details(%Plug.Conn{body_params: params}) do
    params
    |> Map.take(@veilige_velden)
    |> Map.new(fn {k, v} -> {k, beperk(v)} end)
  end

  defp beperk(v) when is_binary(v), do: String.slice(v, 0, 64)
  defp beperk(v) when is_integer(v) or is_boolean(v) or is_nil(v), do: v
  defp beperk(_v), do: "(weggelaten)"

  defp ip(conn) do
    case get_req_header(conn, "cf-connecting-ip") do
      [ip | _] -> String.slice(ip, 0, 64)
      _ -> conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end

  defp actor(%Plug.Conn{assigns: %{current_user: %User{} = user}}), do: user.email
  defp actor(_conn), do: "admin-token"
end
