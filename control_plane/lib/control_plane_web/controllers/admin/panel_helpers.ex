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
  alias ControlPlane.Fleet.Vps

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

  @doc false
  def vps_json(%Vps{} = v) do
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
  defp node_name(_), do: nil

  @doc false
  def region_code(%{region: %{code: code}}), do: code
  def region_code(_), do: nil

  defp region_name(%{region: %{name: name}}), do: name
  defp region_name(_), do: nil

  @doc false
  def ok_or({:ok, v}, _err), do: {:ok, v}
  def ok_or(:error, err), do: err

  @doc false
  def error(conn, status, code) do
    conn |> put_status(status) |> json(%{error: code})
  end
end
