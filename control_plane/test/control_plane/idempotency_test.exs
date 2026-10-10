defmodule ControlPlane.IdempotencyTest do
  @moduledoc """
  Een idempotency-sleutel beschermt tegen een dubbele bestelling, maar mag een
  klant niet buitensluiten.

  Een sleutel die "bezig" zei, bleef dat voorgoed als het verzoek halverwege
  stierf (een uitrol, een crash): alleen dat verzoek kon hem vrijgeven. De klant
  kreeg op elke nieuwe poging "bestelling loopt al".
  """
  use ControlPlane.DataCase, async: true

  import ControlPlane.Fixtures

  alias ControlPlane.Idempotency
  alias ControlPlane.Idempotency.Key

  @scope "vps_create"

  setup do
    %{user: confirmed_user_fixture()}
  end

  defp verouder(%Key{id: id}, seconden) do
    t = DateTime.utc_now() |> DateTime.add(-seconden, :second) |> DateTime.truncate(:second)
    Repo.update_all(from(k in Key, where: k.id == ^id), set: [updated_at: t, inserted_at: t])
  end

  test "een lopend verzoek houdt een tweede tegen", %{user: u} do
    assert {:ok, {:claimed, _}} = Idempotency.claim(u.id, "sleutel-1", @scope)
    assert {:error, :in_flight} = Idempotency.claim(u.id, "sleutel-1", @scope)
  end

  test "een verlaten sleutel mag na tien minuten worden overgenomen", %{user: u} do
    assert {:ok, {:claimed, rij}} = Idempotency.claim(u.id, "sleutel-2", @scope)

    verouder(rij, 300)
    assert {:error, :in_flight} = Idempotency.claim(u.id, "sleutel-2", @scope)

    verouder(rij, 700)
    assert {:ok, {:claimed, nieuw}} = Idempotency.claim(u.id, "sleutel-2", @scope)
    refute nieuw.id == rij.id

    # En de overname is zelf weer een gewone, lopende claim.
    assert {:error, :in_flight} = Idempotency.claim(u.id, "sleutel-2", @scope)
  end

  test "een afgeronde sleutel zonder VPS houdt niemand tegen", %{user: u} do
    Repo.insert!(%Key{
      user_id: u.id,
      key: "sleutel-3",
      scope: @scope,
      status: "done",
      vps_id: nil
    })

    # Zonder VPS (de verwijzing is leeggemaakt) valt er niets terug te geven en
    # niets af te wachten: geen "loopt al".
    assert {:ok, :zonder_sleutel} = Idempotency.claim(u.id, "sleutel-3", @scope)
  end

  test "opruimen haalt alleen oude sleutels weg", %{user: u} do
    {:ok, {:claimed, oud}} = Idempotency.claim(u.id, "oud", @scope)
    {:ok, {:claimed, _vers}} = Idempotency.claim(u.id, "vers", @scope)
    verouder(oud, 31 * 86_400)

    assert Idempotency.ruim_op() == 1
    assert [%Key{key: "vers"}] = Repo.all(from k in Key, where: k.user_id == ^u.id)
  end

  # finish/2 gooide zijn uitkomst weg. Bleef de sleutel op in_flight staan,
  # dan nam een herhaling hem na tien minuten over en ontstond een tweede VPS.
  test "een sleutel die niet afgesloten kan worden, valt op in plaats van stil", %{user: u} do
    assert {:ok, {:claimed, rij}} = Idempotency.claim(u.id, "weg-onder-de-handen", @scope)
    Repo.delete!(rij)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert Idempotency.finish(rij, Ecto.UUID.generate(), 2) == :ok
      end)

    assert log =~ "niet afgesloten"
  end
end
