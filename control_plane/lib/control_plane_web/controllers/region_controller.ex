defmodule ControlPlaneWeb.RegionController do
  @moduledoc """
  The regions a customer can currently be placed in.

  Only regions with an online node reporting free capacity are listed: a region
  with nothing behind it is not a choice, it is a disappointment. A customer who
  expresses no preference gets placed automatically on the emptiest machine in the
  fleet (see `Regions.auto_region_id/1`), which is why this list can be
  empty without the create flow breaking.
  """
  use ControlPlaneWeb, :controller

  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Regions

  def index(conn, _params) do
    json(conn, %{regions: Enum.map(Regions.available_regions(), &region_json/1)})
  end

  defp region_json(%Region{} = region) do
    %{id: region.id, code: region.code, name: region.name}
  end
end
