defmodule ControlPlaneWeb.Admin.PanelHelpers do
  @moduledoc """
  Gedeelde stukken van de beheerpaneel-controllers (`Panel*Controller`).

  Alleen wat in meer dan één van die controllers nodig is: de foutvorm
  `{"error": code}`, het omzetten van een mislukte cast naar een eigen fout, en
  de JSON-vorm van een VPS en een abonnement. Wat één controller gebruikt blijft
  daar staan.
  """
  import Plug.Conn, only: [put_status: 2]
  import Phoenix.Controller, only: [json: 2]

  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Repo

  @doc false
  def subscription_json(s) do
    %{
      id: s.id,
      vps_id: s.vps_id,
      vps_name: s.vps && s.vps.name,
      status: s.status,
      price_monthly: s.price_monthly && Decimal.to_string(s.price_monthly),
      next_billing_date: s.next_billing_date,
      retry_at: s.retry_at,
      started_at: s.started_at,
      cancelled_at: s.cancelled_at
    }
  end

  # De huidige aanroepers laden regio en node al in hun query, maar dat is een
  # afspraak die niemand afdwingt. Een volgende aanroeper die de struct uit een
  # context doorgeeft kreeg dan stil `"region": null`. `Repo.preload/2` slaat over
  # wat al geladen is, dus de bestaande lijsten betalen hier niets voor.
  @doc false
  def vps_json(%Vps{} = v) do
    v = Repo.preload(v, [:region, :node])

    %{
      id: v.id,
      name: v.name,
      status: v.status,
      owner_email: v.owner_email,
      node: node_name(v),
      region: region_code(v),
      location: region_name(v),
      vcpu: v.vcpu,
      ram_mb: v.ram_mb,
      disk_gb: v.disk_gb,
      ip_address: v.ip_address,
      inserted_at: DateTime.to_iso8601(v.inserted_at)
    }
  end

  defp node_name(%Vps{node: %Node{name: name}}), do: name
  defp node_name(%Vps{node: nil}), do: nil

  # Voor een VPS en een node allebei. `nil` betekent alleen nog "geen regio";
  # een niet-geladen associatie crasht met opzet in plaats van stil `nil` te
  # worden, want die twee waren in het antwoord niet uit elkaar te houden. Wie
  # hier een `NotLoaded` aanlevert, heeft een preload vergeten -- dat hoort een
  # test te vangen, niet een klant of beheerder die een lege regio leest.
  @doc false
  def region_code(%{region: %Region{code: code}}), do: code
  def region_code(%{region: nil}), do: nil

  defp region_name(%{region: %Region{name: name}}), do: name
  defp region_name(%{region: nil}), do: nil

  @doc false
  def ok_or({:ok, v}, _err), do: {:ok, v}
  def ok_or(:error, err), do: err

  @doc false
  def error(conn, status, code) do
    conn |> put_status(status) |> json(%{error: code})
  end
end
