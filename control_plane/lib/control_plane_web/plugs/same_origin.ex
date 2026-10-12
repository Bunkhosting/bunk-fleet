defmodule ControlPlaneWeb.Plugs.SameOrigin do
  @moduledoc """
  Weigert een wijzigend verzoek dat alleen op de sessiecookie leunt en niet van
  ons eigen dashboard komt.

  De browser logt in met de HttpOnly-cookie `bunk_session`, en een browser stuurt
  die cookie mee met elk verzoek naar dit domein -- ook als een andere site het
  verzoek in gang zet. `SameSite=Lax` houdt dat tegen voor andere sites, maar niet
  voor een andere host onder bunkhosting.nl: voor de browser is dat "dezelfde
  site". Een beheerder die op zo'n pagina belandde, kon dan ongemerkt iemand
  beheerder maken of tegoed geven, met zijn eigen, al met 2FA bevestigde sessie.

  De regel:

    * GET, HEAD en OPTIONS gaan door; die wijzigen niets.
    * Een verzoek zonder sessiecookie gaat door naar de authenticatie, die er
      een 401 van maakt.
    * Een verzoek met een `Authorization`-header gaat door. Een andere site kan
      die header niet zetten zonder dat de browser eerst om toestemming vraagt,
      en die geven we niet. Agents, de e2e-harnas en API-klanten gebruiken hem.
    * Al het andere moet een `Origin` hebben -- of bij gebrek daaraan een
      `Referer` -- die precies ons publieke adres is. Een browser stuurt Origin
      mee bij elk niet-GET-verzoek, ook vanaf de eigen pagina, dus het dashboard
      merkt hier niets van.

  Ontbreken beide, dan weigeren we. Dat is een verzoek dat geen browser stuurt,
  en "geen bewijs van herkomst" mag niet hetzelfde betekenen als "goed".

  ## Inloggen en registreren: `ook_zonder_cookie: true`

  Daar is de regel "zonder cookie gaat het door" precies het gat. Een andere
  site kan met een gewoon formulier een POST naar /auth/login laten doen met de
  gegevens van de AANVALLER; wij zetten dan zijn sessiecookie in de browser van
  de bezoeker (login-CSRF). Die werkt daarna, zonder het te merken, in andermans
  account: een betaling of een SSH-sleutel komt bij de aanvaller terecht.

  Met deze optie moet ook een verzoek zonder cookie van ons komen. Ontbreken
  Origin en Referer, dan weigeren we, net als hierboven. Een browser stuurt bij
  een formulier-POST naar een andere site altijd een Origin mee, dus een
  ontbrekende Origin uitzonderen zou geen aanval openzetten -- maar `Origin: null`
  (een sandbox-iframe, een omleiding via een andere site) valt hier ook onder "geen
  herkomst", en een uitzondering voor "niets" is er vroeg of laat een voor
  "null". Wie geen browser is (curl, de e2e-harnas) zet de Origin zelf; dat kost
  één header. Een `Authorization`-header blijft ook hier volstaan, om dezelfde
  reden als bij de sessieroutes: een andere site kan hem niet zetten.
  """
  import Plug.Conn

  alias ControlPlaneWeb.Plugs.Bearer

  @veilig ~w(GET HEAD OPTIONS)

  def init(opts), do: opts

  def call(%Plug.Conn{method: method} = conn, _opts) when method in @veilig, do: conn

  def call(conn, opts) do
    conn = fetch_cookies(conn)

    cond do
      get_req_header(conn, "authorization") != [] -> conn
      # Zonder cookie valt er niets te misbruiken; de authenticatie hierna geeft
      # dan de gewone 401, en dat is het antwoord dat de client verwacht. Niet
      # bij inloggen: daar is het verzoek zonder cookie juist de aanval.
      zonder_cookie_vrij?(conn, opts) -> conn
      van_ons?(herkomst(conn)) -> conn
      true -> weiger(conn)
    end
  end

  defp zonder_cookie_vrij?(conn, opts) do
    not Keyword.get(opts, :ook_zonder_cookie, false) and
      not Map.has_key?(conn.req_cookies, Bearer.cookie_name())
  end

  defp herkomst(conn) do
    case get_req_header(conn, "origin") do
      [origin | _] when origin not in ["", "null"] -> origin
      _ -> referer_origin(conn)
    end
  end

  defp referer_origin(conn) do
    with [referer | _] <- get_req_header(conn, "referer"),
         %URI{scheme: scheme, host: host, port: port} when is_binary(host) <- URI.parse(referer) do
      URI.to_string(%URI{scheme: scheme, host: host, port: port})
    else
      _ -> nil
    end
  end

  defp van_ons?(nil), do: false

  defp van_ons?(origin) do
    case Application.get_env(:control_plane, :public_url) do
      url when is_binary(url) -> normaliseer(origin) == normaliseer(url)
      _ -> false
    end
  end

  # "https://app.bunkhosting.nl", "https://app.bunkhosting.nl/" en
  # "https://app.bunkhosting.nl:443" zijn dezelfde herkomst.
  defp normaliseer(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, port: port} when is_binary(host) ->
        {String.downcase(scheme || ""), String.downcase(host), port}

      _ ->
        :ongeldig
    end
  end

  defp weiger(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(403, Jason.encode!(%{error: "cross_origin_request"}))
    |> halt()
  end
end
