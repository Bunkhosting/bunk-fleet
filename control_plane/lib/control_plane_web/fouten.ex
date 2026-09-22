defmodule ControlPlaneWeb.Fouten do
  @moduledoc """
  Van een reden naar een antwoord, op één plek.

  Elke controller had zijn eigen `else`-blok dat `{:error, :iets}` vertaalde naar
  een status en een code. Dat liep uiteen: in `vps_controller.ex` alleen al
  stonden vierenveertig van die takken, dezelfde reden kreeg op twee plekken
  soms een andere status, en onderaan stond overal `_ -> not_found` -- waarmee
  een onvoorziene fout stilletjes een 404 werd. Een knop die niets doet en een
  logregel die niemand schreef.

  Hier staat het één keer. Dat maakt de controllers korter, maar het echte punt
  is dat een nieuwe reden nu niet meer stil verdwijnt.

  ## Wat een onbekende reden krijgt

  Een 500, en een luide logregel met de reden erin. Dat is met opzet
  ongemakkelijk: als het control plane iets teruggeeft dat de webkant niet kent,
  is dat een gat in deze tabel en geen antwoord voor een klant. Het alternatief
  -- er 404 of 422 van maken -- laat het werken alsof er niets aan de hand is, en
  dat is precies hoe het vorige gedrag maandenlang onzichtbaar bleef.

  ## De code is het contract

  De frontend vertaalt de code in het antwoord naar een zin voor de klant
  (`ERROR_MESSAGES` in `lib/api.ts`). Die codes zijn daarom letterlijk
  overgenomen uit wat de controllers deden, ook waar ze afwijken van de naam van
  de reden: `:already_running` heet naar buiten `backup_already_running`, omdat
  een klant "er loopt al een back-up" moet lezen en niet "er loopt al iets".
  """
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  require Logger

  # Reden -> {HTTP-status, code voor de frontend}.
  #
  # Gegroepeerd op wat het antwoord betekent, niet op alfabet: wie hier iets
  # toevoegt moet kiezen wát voor soort weigering het is, en dat is precies de
  # vraag die je wilt stellen.
  @antwoorden %{
    # Bestaat niet -- of is niet van jou, en dat verschil hoort een vreemde niet
    # te leren kennen.
    not_found: {:not_found, "not_found"},

    # Kan nu niet, in deze toestand.
    already_deleting: {:conflict, "already_deleting"},
    already_running: {:conflict, "backup_already_running"},
    backup_not_restorable: {:conflict, "backup_not_restorable"},
    has_vpses: {:conflict, "user_has_vpses"},
    in_flight: {:conflict, "order_in_progress"},
    invalid_status: {:conflict, "invalid_status_deleted"},
    no_capacity: {:conflict, "no_capacity"},
    node_has_vpses: {:conflict, "node_has_vpses"},
    node_unreachable: {:conflict, "node_unreachable"},
    not_provisioned: {:conflict, "not_provisioned"},

    # Het verzoek zelf deugt niet.
    input_too_large: {:unprocessable_entity, "input_too_large"},
    invalid_amount: {:unprocessable_entity, "invalid_amount"},
    invalid_key: {:unprocessable_entity, "invalid_idempotency_key"},
    invalid_role: {:unprocessable_entity, "invalid_role"},
    no_delivery_consent: {:unprocessable_entity, "no_delivery_consent"},
    no_node: {:unprocessable_entity, "no_node"},
    region_not_found: {:unprocessable_entity, "region_not_found"},
    self: {:unprocessable_entity, "cannot_delete_self"},
    self_demotion: {:unprocessable_entity, "cannot_demote_self"},

    # Te veel, te vaak.
    quota_exceeded: {:too_many_requests, "quota_exceeded"},
    too_many_pending: {:too_many_requests, "too_many_pending_topups"},

    # Geld.
    insufficient_credits: {:payment_required, "insufficient_credits"},

    # Aan ons, niet aan de klant.
    not_configured: {:service_unavailable, "payments_unavailable"}
  }

  @doc "De redenen die deze module kent. Bedoeld voor tests."
  @spec bekend() :: [atom()]
  def bekend, do: Map.keys(@antwoorden)

  @doc """
  Beantwoordt `conn` op grond van `reden`.

  `opts[:changeset_code]` is de code die een changeset-fout krijgt; die verschilt
  per hulpbron ("invalid_vps", "invalid_settings") en is daarom geen vaste waarde.
  """
  @spec fout(Plug.Conn.t(), term(), keyword()) :: Plug.Conn.t()
  def fout(conn, reden, opts \\ [])

  def fout(conn, {:error, reden}, opts), do: fout(conn, reden, opts)

  def fout(conn, %Ecto.Changeset{} = changeset, opts) do
    antwoord(conn, :unprocessable_entity, Keyword.get(opts, :changeset_code, "invalid"), %{
      details: velden(changeset)
    })
  end

  # Een reden die iets meedraagt. De code is hier geen vaste waarde maar hangt af
  # van de toestand waarin de VPS stond -- "invalid_status_deleted" zegt de klant
  # iets, "invalid_status" niet. Daarom een eigen clausule en geen rij in de
  # tabel hierboven.
  def fout(conn, {:invalid_status, status}, _opts),
    do: antwoord(conn, :conflict, "invalid_status_#{status}")

  # `nil` en `:error` komen uit `Repo.get/2` en `Ecto.UUID.cast/1`. Allebei
  # betekenen ze "niet gevonden", en allebei horen ze hetzelfde antwoord te geven
  # als "niet van jou".
  def fout(conn, nil, _opts), do: antwoord(conn, :not_found, "not_found")
  def fout(conn, :error, _opts), do: antwoord(conn, :not_found, "not_found")

  def fout(conn, reden, _opts) when is_atom(reden) do
    case Map.fetch(@antwoorden, reden) do
      {:ok, {status, code}} -> antwoord(conn, status, code)
      :error -> onbekend(conn, reden)
    end
  end

  def fout(conn, reden, _opts), do: onbekend(conn, reden)

  # Geen 404 en geen 422: als het control plane iets teruggeeft dat hier niet
  # staat, is dat een gat in de tabel. Dat hoort op te vallen -- bij ons, niet
  # bij de klant die zich afvraagt waarom zijn knop niets doet.
  defp onbekend(conn, reden) do
    Logger.error(
      "#{conn.method} #{conn.request_path}: onverwachte reden #{inspect(reden)}; " <>
        "voeg hem toe aan ControlPlaneWeb.Fouten"
    )

    antwoord(conn, :internal_server_error, "internal_error")
  end

  defp antwoord(conn, status, code, extra \\ %{}) do
    conn
    |> put_status(status)
    |> json(Map.merge(%{error: code}, extra))
  end

  defp velden(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
    end)
  end
end
