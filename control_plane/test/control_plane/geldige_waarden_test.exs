defmodule ControlPlane.GeldigeWaardenTest do
  @moduledoc """
  De database zelf weigert een status of soort die niet bestaat.

  Ecto.Enum hield ongeldige waarden tegen, maar alleen langs de weg van een
  changeset. Een update_all, een handmatige query of een tweede schrijver kwam
  er ongezien langs -- en voor het grootboek is een onbekende soort geld dat
  stil buiten de omzetindeling en de weessweep valt.
  """
  use ControlPlane.DataCase, async: true

  import ControlPlane.Fixtures

  alias ControlPlane.Credits
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Vps

  test "een onbekende grootboeksoort komt niet door de changeset" do
    user = confirmed_user_fixture()
    assert {:error, changeset} = Credits.add_entry(user.id, 100, "verzonnen", "x")
    assert %{kind: [_ | _]} = errors_on(changeset)
  end

  test "ook niet langs de changeset om" do
    user = confirmed_user_fixture()

    assert_raise Postgrex.Error, ~r/ledger_entries_kind_geldig/, fn ->
      Repo.query!(
        "INSERT INTO ledger_entries (id, user_id, amount_cents, kind, inserted_at, updated_at) " <>
          "VALUES (gen_random_uuid(), $1, 100, 'verzonnen', now(), now())",
        [Ecto.UUID.dump!(user.id)]
      )
    end
  end

  test "een VPS-status die niet bestaat wordt geweigerd, ook via update_all" do
    region =
      %Region{}
      |> Region.changeset(%{code: "r-#{System.unique_integer([:positive])}", name: "Regio"})
      |> Repo.insert!()

    vps =
      %Vps{}
      |> Vps.changeset(%{name: "v1", region_id: region.id, vcpu: 1, ram_mb: 1024, disk_gb: 10})
      |> Repo.insert!()

    assert_raise Postgrex.Error, ~r/vpses_status_geldig/, fn ->
      Repo.query!("UPDATE vpses SET status = 'zwevend' WHERE id = $1", [Ecto.UUID.dump!(vps.id)])
    end
  end
end
