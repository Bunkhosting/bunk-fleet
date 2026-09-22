defmodule ControlPlane.MollieVerzoeningTest do
  @moduledoc """
  De tweede kans op het geldpad.

  Een Mollie-betaling werd tot nu toe alleen afgehandeld als Mollie's webhook
  binnenkwam. Dat is één HTTP-verzoek van buiten naar ons toe, en het enige
  moment waarop het kan. Komt het niet aan -- de tunnel lag eruit, een uitrol
  viel er precies overheen, Mollie gaf het op -- dan heeft iemand betaald en
  staat er niets op zijn tegoed. Er is geen tweede poging en niemand die het
  merkt.

  `verzoen/1` is die tweede poging. Deze tests leggen vast wat hij wél en niet
  mag doen, en het tweede is het belangrijkste: hij mag nooit op grond van
  ouderdom besluiten dat een betaling wel mislukt zal zijn. Alleen wat Mollie
  zegt telt. Een rij afsluiten die daarna alsnog betaald wordt is geld van een
  klant weggooien, en dat is erger dan de kwaal.
  """
  use ControlPlane.DataCase, async: false

  import Ecto.Query

  alias ControlPlane.Accounts
  alias ControlPlane.Billing.MollieAfhandeling
  alias ControlPlane.Credits
  alias ControlPlane.Credits.TopupRequest
  alias ControlPlane.Mollie
  alias ControlPlane.Repo

  @password "test-only-password-4f2b9c1e"

  setup do
    email = "verzoening-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})
    %{user: user}
  end

  defp openstaand(user, cents, payment_id) do
    {:ok, tr} = Credits.create_mollie_topup(user.id, cents, payment_id)
    tr
  end

  defp mollie_zegt(payment) do
    Req.Test.stub(Mollie, fn conn -> Req.Test.json(conn, payment) end)
  end

  defp verouder(tr, seconden) do
    moment = DateTime.add(DateTime.utc_now(), -seconden, :second)

    from(t in TopupRequest, where: t.id == ^tr.id)
    |> Repo.update_all(set: [inserted_at: moment])

    tr
  end

  defp stand(tr), do: Repo.get!(TopupRequest, tr.id).status

  test "een betaling waarvan de webhook nooit aankwam wordt alsnog bijgeschreven", %{user: user} do
    id = "tr_#{System.unique_integer([:positive])}"
    tr = openstaand(user, 2500, id) |> verouder(3600)
    voor = Credits.balance_cents(user.id)

    mollie_zegt(%{
      "id" => id,
      "status" => "paid",
      "amount" => %{"currency" => "EUR", "value" => "25.00"}
    })

    assert MollieAfhandeling.verzoen(900) == 1
    assert Credits.balance_cents(user.id) == voor + 2500
    assert stand(tr) == :paid
  end

  test "twee keer verzoenen schrijft niet twee keer bij", %{user: user} do
    id = "tr_#{System.unique_integer([:positive])}"
    openstaand(user, 2500, id) |> verouder(3600)
    voor = Credits.balance_cents(user.id)

    mollie_zegt(%{
      "id" => id,
      "status" => "paid",
      "amount" => %{"currency" => "EUR", "value" => "25.00"}
    })

    MollieAfhandeling.verzoen(900)
    # De rij staat nu op :paid en valt dus buiten de volgende ronde. Dat is de
    # hele bescherming: niet een teller, maar een query die hem niet meer ziet.
    assert MollieAfhandeling.verzoen(900) == 0
    assert Credits.balance_cents(user.id) == voor + 2500
  end

  test "een betaling die Mollie nog open noemt blijft staan en levert niets op", %{user: user} do
    id = "tr_#{System.unique_integer([:positive])}"
    tr = openstaand(user, 2500, id) |> verouder(3600)
    voor = Credits.balance_cents(user.id)

    mollie_zegt(%{"id" => id, "status" => "open"})

    assert MollieAfhandeling.verzoen(900) == 1
    assert Credits.balance_cents(user.id) == voor
    # Blijft openstaan: een betaling die nog loopt is niet mislukt, en hem
    # afsluiten zou het geld dat er daarna alsnog aankomt nergens laten landen.
    assert stand(tr) == :pending
  end

  test "een verlopen betaling geeft de plek in de wachtrij terug", %{user: user} do
    id = "tr_#{System.unique_integer([:positive])}"
    tr = openstaand(user, 2500, id) |> verouder(3600)
    voor = Credits.balance_cents(user.id)

    mollie_zegt(%{"id" => id, "status" => "expired"})

    assert MollieAfhandeling.verzoen(900) == 1
    assert Credits.balance_cents(user.id) == voor
    assert stand(tr) == :cancelled
  end

  test "een betaling die net is aangemaakt wordt met rust gelaten", %{user: user} do
    id = "tr_#{System.unique_integer([:positive])}"
    tr = openstaand(user, 2500, id)

    # Zou dit wél worden nagevraagd, dan krijgt iemand die op dit moment bij
    # zijn bank staat een tweede uitgaande aanroep over dezelfde betaling.
    mollie_zegt(%{"id" => id, "status" => "expired"})

    assert MollieAfhandeling.verzoen(900) == 0
    assert stand(tr) == :pending
  end

  test "een opwaardering zonder betaal-id komt niet in de verzoening", %{user: user} do
    {:ok, tr} = Credits.create_topup_request(user.id, 2500)
    verouder(tr, 3600)

    assert MollieAfhandeling.verzoen(900) == 0
    assert stand(tr) == :pending
  end

  test "betalingen van vóór de live-sleutel blijven buiten beeld", %{user: user} do
    # Die betaal-ids komen uit Mollie's testmodus en bestaan niet in de
    # live-omgeving. Zonder ondergrens vraagt de verzoening ze elk kwartier op,
    # krijgt elk kwartier niets, en logt dat tot in de eeuwigheid.
    id = "tr_#{System.unique_integer([:positive])}"
    tr = openstaand(user, 2500, id)

    from(t in TopupRequest, where: t.id == ^tr.id)
    |> Repo.update_all(set: [inserted_at: ~U[2026-07-07 12:00:00.000000Z]])

    assert MollieAfhandeling.verzoen(900) == 0
    assert stand(tr) == :pending
  end

  test "een bedrag dat afwijkt van wat we vastlegden levert niets op", %{user: user} do
    id = "tr_#{System.unique_integer([:positive])}"
    tr = openstaand(user, 2500, id) |> verouder(3600)
    voor = Credits.balance_cents(user.id)

    mollie_zegt(%{
      "id" => id,
      "status" => "paid",
      "amount" => %{"currency" => "EUR", "value" => "250.00"}
    })

    assert MollieAfhandeling.verzoen(900) == 1
    assert Credits.balance_cents(user.id) == voor
    assert stand(tr) == :pending
  end

  test "een Mollie die niet antwoordt laat alles staan", %{user: user} do
    id = "tr_#{System.unique_integer([:positive])}"
    tr = openstaand(user, 2500, id) |> verouder(3600)
    voor = Credits.balance_cents(user.id)

    Req.Test.stub(Mollie, fn conn -> Plug.Conn.send_resp(conn, 503, "{}") end)

    assert MollieAfhandeling.verzoen(900) == 1
    assert Credits.balance_cents(user.id) == voor
    assert stand(tr) == :pending
  end
end
