defmodule ControlPlaneWeb.VpsZonderRegioTest do
  @moduledoc """
  Hernoemen via de API van een VPS waarvan de regio is opgeruimd.

  Dit gaf `invalid_vps`: de changeset eiste een regio, ook bij een wijziging van
  alleen de naam. Zie `ControlPlane.VpsZonderRegioTest` voor de andere paden.
  """
  use ControlPlaneWeb.ConnCase, async: true

  import ControlPlane.Fixtures
  import Ecto.Query, only: [from: 2]

  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Repo

  test "een VPS zonder regio kan worden hernoemd", %{conn: conn} do
    user = confirmed_user_fixture()
    code = "r-#{System.unique_integer([:positive])}"
    region = %Region{} |> Region.changeset(%{code: code, name: "Regio"}) |> Repo.insert!()

    vps =
      %Vps{}
      |> Vps.changeset(%{
        name: "web",
        region_id: region.id,
        vcpu: 1,
        ram_mb: 1024,
        disk_gb: 10,
        status: :stopped,
        owner_id: user.id,
        owner_email: user.email
      })
      |> Repo.insert!()

    {1, _} = Repo.update_all(from(v in Vps, where: v.id == ^vps.id), set: [region_id: nil])
    assert is_nil(Repo.get!(Vps, vps.id).region_id)

    assert %{"vps" => gevonden} =
             conn
             |> met_sessie(user)
             |> patch(~p"/api/v1/vpses/#{vps.id}", %{"name" => "nieuwe naam"})
             |> json_response(200)

    assert gevonden["name"] == "nieuwe naam"
    assert Repo.get!(Vps, vps.id).name == "nieuwe naam"
  end
end
