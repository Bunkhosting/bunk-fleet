defmodule ControlPlaneWeb.BeheerAuditTest do
  @moduledoc """
  Elke beheerhandeling laat een spoor na in de database, en dat spoor is niet
  te wijzigen.

  Het stond alleen in de applicatielog: te wissen, zonder bedrag of rol, en de
  API met het gedeelde geheim liet helemaal niets achter -- ook niet bij het
  bijboeken van tegoed.
  """
  use ControlPlaneWeb.ConnCase, async: false

  import ControlPlane.Fixtures, only: [confirmed_user_fixture: 0, with_second_factor: 1]

  alias ControlPlane.Accounts
  alias ControlPlane.Beheer.Audit
  alias ControlPlane.Repo

  defp beheerder_conn do
    u =
      confirmed_user_fixture()
      |> Ecto.Changeset.change(%{role: :admin})
      |> Repo.update!()
      |> with_second_factor()

    token =
      u |> Accounts.generate_user_session_token(mfa: true) |> Base.url_encode64(padding: false)

    {u, build_conn() |> put_req_header("authorization", "Bearer " <> token)}
  end

  test "tegoed bijboeken legt wie, wat, bedrag en uitkomst vast -- en geen e-mailadres" do
    {beheerder, conn} = beheerder_conn()
    klant = confirmed_user_fixture()

    conn
    |> put_req_header("cf-connecting-ip", "203.0.113.7")
    |> post(~p"/api/v1/beheer/users/#{klant.id}/credit", %{"amount_cents" => 1234})
    |> json_response(200)

    assert [regel | _] = Audit.recent(1)
    assert regel.actor == beheerder.email
    assert regel.methode == "POST"
    assert regel.pad =~ klant.id
    assert regel.uitkomst == 200
    assert regel.ip == "203.0.113.7"
    assert regel.details == %{"amount_cents" => 1234}
  end

  test "een leesverzoek laat geen spoor na" do
    {_beheerder, conn} = beheerder_conn()
    voor = length(Audit.recent(1000))

    conn |> get(~p"/api/v1/beheer/stats") |> json_response(200)

    assert length(Audit.recent(1000)) == voor
  end

  test "de API met het gedeelde geheim wordt ook vastgelegd" do
    klant = confirmed_user_fixture()

    build_conn()
    |> put_req_header("authorization", "Bearer test-admin-token")
    |> post("/admin/v1/credits", %{"email" => klant.email, "amount_cents" => 500})
    |> json_response(200)

    assert [regel | _] = Audit.recent(1)
    assert regel.actor == "admin-token"
    assert regel.details == %{"amount_cents" => 500}
    refute inspect(regel.details) =~ klant.email
  end

  test "een regel is niet te wijzigen of te wissen" do
    {:ok, regel} = Audit.vastleggen(%{actor: "x", methode: "POST", pad: "/p"})

    assert_raise Postgrex.Error, ~r/alleen-toevoegen/, fn ->
      Repo.query!("UPDATE beheer_audit SET actor = 'iemand anders' WHERE id = $1", [
        Ecto.UUID.dump!(regel.id)
      ])
    end

    assert_raise Postgrex.Error, ~r/alleen-toevoegen/, fn ->
      Repo.query!("DELETE FROM beheer_audit WHERE id = $1", [Ecto.UUID.dump!(regel.id)])
    end
  end
end
