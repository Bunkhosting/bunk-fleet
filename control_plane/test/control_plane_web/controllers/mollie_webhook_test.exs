defmodule ControlPlaneWeb.MollieWebhookTest do
  @moduledoc """
  The Mollie webhook, which is the only unauthenticated route that moves money.

  Mollie does not sign its webhooks. The body carries a payment id and nothing
  else, so the whole integrity model is fetch-to-verify: whatever arrives, the
  control plane re-asks Mollie what that payment actually did, over an
  authenticated connection, before crediting a cent. These tests drive that fetch
  from a stub, which is the only way to assert what happens on a "paid" the
  control plane never asked for.

  The endpoint answers 200 to everything on purpose — a non-200 makes Mollie
  retry, and a forged or unknown id retried forever is a denial of service
  pointed at us. What must differ between a real payment and a forged one is the
  wallet, not the status code, so every test here asserts on the balance and the
  top-up row.
  """
  use ControlPlaneWeb.ConnCase, async: false

  alias ControlPlane.Accounts
  alias ControlPlane.Credits
  alias ControlPlane.Credits.TopupRequest
  alias ControlPlane.Credits.Topups
  alias ControlPlane.Mollie
  alias ControlPlane.Repo

  @password "test-only-password-4f2b9c1e"
  @path "/api/v1/billing/mollie/webhook"

  setup do
    email = "payer-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})
    %{user: user}
  end

  defp pending_topup(user, cents, payment_id) do
    {:ok, tr} = Topups.create_mollie_topup(user.id, cents, payment_id)
    tr
  end

  # Answers the control plane's GET /payments/:id with whatever Mollie would say.
  defp mollie_says(payment) do
    Req.Test.stub(Mollie, fn conn -> Req.Test.json(conn, payment) end)
  end

  defp mollie_fails(status) do
    Req.Test.stub(Mollie, fn conn -> Plug.Conn.send_resp(conn, status, "{}") end)
  end

  defp balance(user), do: Credits.balance_cents(user.id)
  defp status_of(payment_id), do: Repo.get_by(TopupRequest, mollie_payment_id: payment_id).status

  test "a paid payment credits the wallet exactly once", %{conn: conn, user: user} do
    id = "tr_#{System.unique_integer([:positive])}"
    pending_topup(user, 2500, id)
    before = balance(user)

    mollie_says(%{
      "id" => id,
      "status" => "paid",
      "amount" => %{"currency" => "EUR", "value" => "25.00"}
    })

    assert %{status: 200} = post(conn, @path, %{"id" => id})
    assert balance(user) == before + 2500
    assert status_of(id) == :paid

    # Mollie retries a webhook it is unsure about. A second delivery must not pay
    # the customer twice.
    assert %{status: 200} = post(conn, @path, %{"id" => id})
    assert balance(user) == before + 2500
  end

  test "een betaling wordt ook bijgeschreven als het betaal-id nooit is vastgelegd", %{
    conn: conn,
    user: user
  } do
    # Het gat dat overblijft nadat de volgorde is omgedraaid: de rij bestaat, de
    # betaling bestaat, en daartussen viel het proces om -- dus het Mollie-id is
    # nooit aan de rij gehangen. Zoeken op dat id vindt niets.
    #
    # Ons eigen id zit in de metadata die wij aan de betaling hebben meegegeven,
    # en die komt langs Mollie terug. Dat is veilig om op af te gaan: het komt
    # niet uit de webhook maar uit de betaling die we zojuist bij Mollie hebben
    # opgehaald, en we kijken er pas naar nadat die op "paid" stond.
    {:ok, tr} = Topups.create_topup_request(user.id, 2500)
    assert is_nil(tr.mollie_payment_id)
    id = "tr_#{System.unique_integer([:positive])}"
    before = balance(user)

    mollie_says(%{
      "id" => id,
      "status" => "paid",
      "amount" => %{"currency" => "EUR", "value" => "25.00"},
      "metadata" => %{"user_id" => user.id, "topup_id" => tr.id}
    })

    assert %{status: 200} = post(conn, @path, %{"id" => id})
    assert balance(user) == before + 2500
    assert Repo.get!(TopupRequest, tr.id).status == :paid

    # En ook hier telt een herhaalde aflevering maar één keer.
    assert %{status: 200} = post(conn, @path, %{"id" => id})
    assert balance(user) == before + 2500
  end

  test "een verzonnen topup_id in de metadata schrijft niets bij", %{conn: conn, user: user} do
    # De metadata is alleen te vertrouwen omdat hij van Mollie terugkomt. Zou er
    # een id in staan dat hier niets betekent, dan hoort er geen tegoed te
    # ontstaan -- en al helemaal geen fout die de webhook laat klappen.
    before = balance(user)

    mollie_says(%{
      "id" => "tr_#{System.unique_integer([:positive])}",
      "status" => "paid",
      "amount" => %{"currency" => "EUR", "value" => "25.00"},
      "metadata" => %{"topup_id" => "dit-is-geen-uuid"}
    })

    assert %{status: 200} =
             post(conn, @path, %{"id" => "tr_#{System.unique_integer([:positive])}"})

    assert balance(user) == before
  end

  test "een betaling op een testsleutel schrijft niets bij", %{conn: conn, user: user} do
    # Een betaling in Mollie's testmodus ziet er in elk antwoord identiek uit aan
    # een echte, inclusief "paid". Het enige verschil is de sleutel waarmee hij
    # is aangemaakt. Zou dit tegoed opleveren, dan komt er geld uit het niets --
    # en dat is precies wat er in de eerste weken is gebeurd: duizenden euro's
    # saldo waar nooit iets voor is betaald.
    eerder = Application.get_env(:control_plane, :mollie)
    Application.put_env(:control_plane, :mollie, Keyword.put(eerder, :api_key, "test_stub_key"))
    on_exit(fn -> Application.put_env(:control_plane, :mollie, eerder) end)

    id = "tr_#{System.unique_integer([:positive])}"
    tr = pending_topup(user, 2500, id)
    before = balance(user)

    mollie_says(%{
      "id" => id,
      "status" => "paid",
      "amount" => %{"currency" => "EUR", "value" => "25.00"}
    })

    assert %{status: 200} = post(conn, @path, %{"id" => id})
    assert balance(user) == before
    # En de opwaardering blijft openstaan: er is niets betaald, dus hem op
    # betaald zetten zou een leugen in de administratie zijn.
    assert Repo.get!(TopupRequest, tr.id).status == :pending
  end

  test "a forged webhook for a payment Mollie calls open credits nothing", %{
    conn: conn,
    user: user
  } do
    id = "tr_#{System.unique_integer([:positive])}"
    pending_topup(user, 5000, id)
    before = balance(user)

    # This is the attack: anyone can POST the endpoint with a real id. Only the
    # fetch decides, and the fetch says the customer never paid.
    mollie_says(%{
      "id" => id,
      "status" => "open",
      "amount" => %{"currency" => "EUR", "value" => "50.00"}
    })

    assert %{status: 200} = post(conn, @path, %{"id" => id})
    assert balance(user) == before
    assert status_of(id) == :pending
  end

  test "a settled amount that differs from the request is refused", %{conn: conn, user: user} do
    id = "tr_#{System.unique_integer([:positive])}"
    pending_topup(user, 10_000, id)
    before = balance(user)

    # Mollie says paid, but for one euro. Crediting the requested hundred would
    # turn an adjustable-amount payment method into free money.
    mollie_says(%{
      "id" => id,
      "status" => "paid",
      "amount" => %{"currency" => "EUR", "value" => "1.00"}
    })

    assert %{status: 200} = post(conn, @path, %{"id" => id})
    assert balance(user) == before
    assert status_of(id) == :pending
  end

  test "an expired payment releases the pending row", %{conn: conn, user: user} do
    id = "tr_#{System.unique_integer([:positive])}"
    pending_topup(user, 1500, id)

    mollie_says(%{
      "id" => id,
      "status" => "expired",
      "amount" => %{"currency" => "EUR", "value" => "15.00"}
    })

    assert %{status: 200} = post(conn, @path, %{"id" => id})
    # Freed, so it stops counting against the customer's cap on open checkouts.
    assert status_of(id) == :cancelled
    assert balance(user) == 0
  end

  test "a paid payment with no top-up row behind it credits nobody", %{conn: conn, user: user} do
    id = "tr_#{System.unique_integer([:positive])}"

    mollie_says(%{
      "id" => id,
      "status" => "paid",
      "amount" => %{"currency" => "EUR", "value" => "99.00"}
    })

    assert %{status: 200} = post(conn, @path, %{"id" => id})
    assert balance(user) == 0
  end

  test "a malformed id never reaches Mollie", %{conn: conn} do
    # The stub raises rather than answers: if the control plane fetched, the test
    # fails instead of quietly passing on a shape check that was never reached.
    Req.Test.stub(Mollie, fn _conn -> raise "the control plane fetched a malformed id" end)

    for bad <- ["../payments/tr_real", "tr_", "", "tr_abc/../../x", "not-an-id", "tr_ᴬᴮᶜ"] do
      assert %{status: 200} = post(conn, @path, %{"id" => bad})
    end
  end

  test "a webhook with no id at all is answered, not crashed", %{conn: conn} do
    assert %{status: 200} = post(conn, @path, %{})
    assert %{status: 200} = post(conn, @path, %{"id" => 12_345})
  end

  test "Mollie being down credits nothing and still answers 200", %{conn: conn, user: user} do
    id = "tr_#{System.unique_integer([:positive])}"
    pending_topup(user, 3000, id)
    mollie_fails(503)

    assert %{status: 200} = post(conn, @path, %{"id" => id})
    assert balance(user) == 0
    assert status_of(id) == :pending
  end

  test "one customer's payment never lands in another customer's wallet", %{
    conn: conn,
    user: user
  } do
    {:ok, other} =
      Accounts.register_user(%{
        email: "other-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    id = "tr_#{System.unique_integer([:positive])}"
    pending_topup(user, 4000, id)

    mollie_says(%{
      "id" => id,
      "status" => "paid",
      "amount" => %{"currency" => "EUR", "value" => "40.00"}
    })

    assert %{status: 200} = post(conn, @path, %{"id" => id})
    assert balance(user) == 4000
    assert balance(other) == 0
  end
end
