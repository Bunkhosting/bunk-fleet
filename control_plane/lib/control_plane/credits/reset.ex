defmodule ControlPlane.Credits.Reset do
  @moduledoc """
  Zet alle tegoeden terug op nul.

  Wat er op de saldi stond kwam uit de testperiode: handmatige ophogingen uit het
  beheerpaneel van duizenden euro's, en opwaarderingen die met de testsleutel van
  Mollie op betaald zijn gezet. Daar heeft nooit geld in gezeten, en zolang het
  bleef staan kon er wel echte capaciteit mee besteld worden.

  Er wordt niets weggehaald. Het grootboek is de verantwoording en hoort alleen
  aan te groeien; een saldo dat verandert doordat oude regels verdwijnen valt
  niet meer na te rekenen. In plaats daarvan komt er per gebruiker één regel bij
  die het saldo precies op nul brengt, met in de omschrijving waarom.

  De logica staat hier en niet in de Mix-taak, omdat productie een release draait
  waar geen Mix in zit. Zo is hij van beide kanten aan te roepen:

      mix bunk.reset_credits --doen
      bin/control_plane eval 'ControlPlane.Release.reset_credits(doen: true)'
  """

  import Ecto.Query

  alias ControlPlane.Credits
  alias ControlPlane.Credits.LedgerEntry
  alias ControlPlane.Repo

  @kind "correction"
  @description "Saldo teruggezet bij de overgang naar echte betalingen"

  @typedoc "Eén gebruiker met een saldo dat niet nul is."
  @type saldo :: %{user_id: Ecto.UUID.t(), email: String.t(), saldo: integer()}

  @doc """
  De saldi die niet op nul staan, grootste eerst.

  Het saldo is de som van het grootboek en geen kolom die wordt bijgehouden;
  daarom wordt het hier ook zo uitgerekend.
  """
  @spec plan() :: [saldo()]
  def plan do
    from(l in LedgerEntry,
      join: u in assoc(l, :user),
      group_by: [l.user_id, u.email],
      having: sum(l.amount_cents) != 0,
      order_by: [desc: sum(l.amount_cents)],
      select: %{user_id: l.user_id, email: u.email, saldo: sum(l.amount_cents)}
    )
    |> Repo.all()
  end

  @doc """
  Boekt per gebruiker de correctie die het saldo op nul brengt.

  Geeft de regels terug die zijn weggeboekt, zodat de aanroeper kan laten zien
  wat er gebeurd is in plaats van alleen dát er iets gebeurd is.
  """
  #
  # Alles of niets, onder een slot op het grootboek. Het waren losse boekingen
  # na een losse telling: een fout halverwege liet een deel van de saldi op
  # nul en de rest niet, en een opwaardering die tussen tellen en boeken
  # binnenkwam werd mee weggeboekt.
  #
  # En niet meer zonder meer: sinds 14 september staat er echt geld op de
  # saldi. Deze taak deed precies wat hij moest bij de overgang naar echte
  # betalingen; nu zou hij betaald tegoed van klanten wissen. Daarom weigert
  # hij zodra er een echte Mollie-betaling is bijgeschreven, tenzij de
  # aanroeper uitdrukkelijk zegt dat dat de bedoeling is.
  @spec apply!(keyword()) :: [saldo()]
  def apply!(opts \\ []) do
    if echte_betalingen?() and not Keyword.get(opts, :ook_echte_betalingen, false) do
      raise ArgumentError,
            "er zijn echte Mollie-betalingen bijgeschreven; dit zou betaald tegoed van " <>
              "klanten wissen. Geef ook_echte_betalingen: true mee als dat echt de bedoeling is."
    end

    {:ok, regels} =
      Repo.transaction(fn ->
        Repo.query!("LOCK TABLE ledger_entries IN SHARE ROW EXCLUSIVE MODE")
        regels = plan()
        Enum.each(regels, &boek_weg/1)
        regels
      end)

    regels
  end

  defp boek_weg(%{user_id: user_id, saldo: saldo}) do
    case Credits.add_entry(user_id, -saldo, @kind, @description) do
      {:ok, _} -> :ok
      {:error, reden} -> Repo.rollback(reden)
    end
  end

  @live_sinds ~U[2026-09-14 00:00:00.000000Z]

  defp echte_betalingen? do
    Repo.exists?(
      from t in ControlPlane.Credits.TopupRequest,
        where: t.status == :paid and t.paid_via == "mollie" and t.inserted_at > ^@live_sinds
    )
  end

  @doc "Een bedrag in centen als leesbaar euroteken-loos bedrag."
  @spec euro(integer()) :: String.t()
  def euro(cents), do: :erlang.float_to_binary(cents / 100, decimals: 2) <> " EUR"
end
