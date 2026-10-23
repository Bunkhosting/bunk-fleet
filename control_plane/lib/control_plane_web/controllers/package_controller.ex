defmodule ControlPlaneWeb.PackageController do
  @moduledoc """
  Read-only VPS package catalog for the customer frontend.

  Packages are bunk-fleet's own domain (`ControlPlane.Fleet.Package`); this just
  exposes the available ones. Public, read-only catalog (no per-user data) — rate-limited, no auth gate.
  """
  use ControlPlaneWeb, :controller

  alias ControlPlane.Fleet
  alias ControlPlane.Fleet.Scheduler

  def index(conn, _params) do
    # Eén keer de plaatsbare nodes laden; per pakket wordt in het geheugen met
    # dezelfde regel als de scheduler bepaald of er iets past. Alleen een
    # boolean gaat naar buiten, nooit de capaciteit van een node.
    nodes = Scheduler.placeable_nodes()
    results = Enum.map(Fleet.list_available_packages(), &package_json(&1, nodes))
    json(conn, %{count: length(results), results: results})
  end

  defp bestelbaar?(package, nodes) do
    request = %{
      vcpu: package.cpu_cores,
      ram_mb: package.ram_gb * 1024,
      disk_gb: package.disk_gb
    }

    Enum.any?(nodes, &Scheduler.fits?(&1, request))
  end

  defp package_json(package, nodes) do
    %{
      id: package.id,
      name: package.name,
      cpu_cores: package.cpu_cores,
      ram_gb: package.ram_gb,
      disk_gb: package.disk_gb,
      bandwidth_mbit: package.bandwidth_mbit,
      price_monthly: Decimal.to_string(package.price_monthly),
      description: package.description,
      available: bestelbaar?(package, nodes)
    }
  end
end
