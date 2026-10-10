defmodule ControlPlaneWeb.MollieTopupTest do
  @moduledoc """
  De endpoint die een betaling aanmaakt.

  Dit is het enige pad in de applicatie waar een klant geld uitgeeft, en het was
  het enige pad zonder test: de webhook erna was gedekt, de context eronder ook,
  maar niet de deur zelf. Wat hier vastligt is vooral dat een mislukking niet
  stilletjes een openstaande opwaardering achterlaat waar de klant tegenaan
  blijft lopen.
  """
  use ControlPlaneWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]

  alias ControlPlane.Accounts
  alias ControlPlane.Credits.TopupRequest
  alias ControlPlane.Mollie
  alias ControlPlane.Repo

  setup %{conn: conn} do
    email = "topup-#{System.unique_integer([:positive])}@bunk.test"
    {:ok, u} = Accounts.register_user(%{email: email, password: "Str0ngPassphrase!42"})
    token = u |> Accounts.generate_user_session_token() |> Base.url_encode64(padding: false)

    %{conn: put_req_header(conn, "authorization", "Bearer " <> token), user: u}
  end

  defp mollie_antwoordt(betaling) do
    Req.Test.stub(Mollie, fn conn -> Req.Test.json(conn, betaling) end)
  end

  defp mollie_weigert(status, body \\ %{"detail" => "redirectUrl is niet toegestaan"}) do
    Req.Test.stub(Mollie, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(body))
    end)
  end

  defp geslaagde_betaling(id \\ "tr_test123") do
    %{
      "id" => id,
      "status" => "open",
      "_links" => %{"checkout" => %{"href" => "https://www.mollie.com/checkout/#{id}"}}
    }
  end

  test "een geldig bedrag levert een checkout-url en een openstaande rij", %{conn: conn, user: u} do
    mollie_antwoordt(geslaagde_betaling())

    resp =
      conn |> post(~p"/api/v1/billing/topup", %{"amount_cents" => 2500}) |> json_response(200)

    assert resp["checkout_url"] =~ "mollie.com/checkout"
    rij = Repo.one!(from t in TopupRequest, where: t.user_id == ^u.id)
    assert rij.amount_cents == 2500
    assert rij.status == :pending
    assert rij.mollie_payment_id == "tr_test123"
  end

  test "een onzinnig bedrag komt niet bij Mollie langs", %{conn: conn, user: u} do
    # De stub ontploft als er toch een verzoek uitgaat: een bedrag dat we zelf
    # al afkeuren hoort de betaalprovider niet te bereiken.
    Req.Test.stub(Mollie, fn _conn -> raise "er ging een verzoek naar Mollie" end)

    for bedrag <- [0, -100, "veel", nil] do
      assert conn
             |> post(~p"/api/v1/billing/topup", %{"amount_cents" => bedrag})
             |> json_response(422)
    end

    assert Repo.aggregate(from(t in TopupRequest, where: t.user_id == ^u.id), :count) == 0
  end

  test "een weigering van Mollie laat geen openstaande opwaardering achter", %{
    conn: conn,
    user: u
  } do
    # Anders telt die mee voor de limiet op openstaande betalingen en loopt de
    # klant vast op een rij die nooit betaald kan worden.
    mollie_weigert(422)

    resp =
      conn |> post(~p"/api/v1/billing/topup", %{"amount_cents" => 2500}) |> json_response(422)

    assert resp["error"] == "payment_rejected"
    # Mollies eigen tekst gaat over onze configuratie; die hoort in de log.
    refute resp["detail"]
    assert Repo.aggregate(from(t in TopupRequest, where: t.user_id == ^u.id), :count) == 0
  end

  # Een rij die nooit een Mollie-id kreeg (proces viel om tussen de betaling
  # en het vastleggen) bleef voorgoed meetellen; vijf daarvan en de klant kon
  # niet meer opwaarderen.
  test "een oude opwaardering zonder Mollie-id houdt de klant niet tegen", %{conn: conn, user: u} do
    oud = DateTime.add(DateTime.utc_now(), -7200, :second)

    for _ <- 1..5 do
      {:ok, tr} = ControlPlane.Credits.create_topup_request(u.id, 2500)
      Repo.update_all(from(t in TopupRequest, where: t.id == ^tr.id), set: [inserted_at: oud])
    end

    mollie_antwoordt(geslaagde_betaling())

    resp =
      conn |> post(~p"/api/v1/billing/topup", %{"amount_cents" => 2500}) |> json_response(200)

    assert resp["checkout_url"]
  end

  test "verse opwaarderingen zonder Mollie-id tellen wel mee", %{conn: conn, user: u} do
    for _ <- 1..5, do: {:ok, _} = ControlPlane.Credits.create_topup_request(u.id, 2500)

    mollie_antwoordt(geslaagde_betaling())

    resp =
      conn |> post(~p"/api/v1/billing/topup", %{"amount_cents" => 2500}) |> json_response(429)

    assert resp["error"] == "too_many_pending_topups"
  end

  test "een storing bij Mollie is geen 500 maar een nette melding", %{conn: conn} do
    mollie_weigert(503, %{"detail" => "service unavailable"})

    code =
      conn
      |> post(~p"/api/v1/billing/topup", %{"amount_cents" => 2500})
      |> Map.get(:status)

    assert code in [502, 503]
  end

  test "zonder sessie: 401", %{conn: conn} do
    assert build_conn()
           |> post(~p"/api/v1/billing/topup", %{"amount_cents" => 2500})
           |> json_response(401)

    _ = conn
  end
end
