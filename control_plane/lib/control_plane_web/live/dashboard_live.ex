defmodule ControlPlaneWeb.DashboardLive do
  @moduledoc """
  Realtime operator/admin dashboard for the Bunk Fleet control plane.

  Renders a dark-themed overview of regions, nodes and VPSes that updates in real
  time (only once the socket is connected): on mount it subscribes to the
  `ControlPlane.Fleet.Events` `"fleet:changes"` topic and reloads the `Fleet`
  context whenever a fleet change is broadcast — sub-second, event-driven updates
  instead of constant polling.

  A slow 15s fallback timer is kept purely as a safety net: if an event is ever
  dropped (broadcasting is best-effort) the dashboard still reconciles within
  that window.
  """
  use ControlPlaneWeb, :live_view

  alias ControlPlane.Fleet
  alias ControlPlane.Fleet.Events
  alias ControlPlane.Fleet.NodeAdmin
  alias ControlPlane.Fleet.Regions

  # Slow backstop refresh. Updates normally arrive via PubSub (sub-second); this
  # only catches a dropped/best-effort broadcast, so it can be far less frequent
  # than the old 2s full-poll.
  @refresh_ms 15_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Events.subscribe()
      :timer.send_interval(@refresh_ms, :refresh)
    end

    {:ok, load(socket)}
  end

  # Event-driven update: some part of the fleet changed, reload the data. The
  # `kind` is coarse, so we always do a full reload (cheap relative to render).
  @impl true
  def handle_info({:fleet_changed, _kind}, socket) do
    {:noreply, load(socket)}
  end

  # Slow fallback refresh (safety net for a dropped best-effort broadcast).
  def handle_info(:refresh, socket) do
    {:noreply, load(socket)}
  end

  # Reads all dashboard data and computes the summary aggregates.
  defp load(socket) do
    regions = Regions.list_regions()
    nodes = NodeAdmin.list_nodes()
    vpses = Fleet.list_vpses()

    summary = %{
      regions: length(regions),
      online_nodes: Enum.count(nodes, &(&1.status == :online)),
      active_vpses: Enum.count(vpses, &(&1.status == :active)),
      total_vcpu: sum(nodes, :total_vcpu),
      available_vcpu: sum(nodes, :available_vcpu),
      total_ram_mb: sum(nodes, :total_ram_mb),
      available_ram_mb: sum(nodes, :available_ram_mb),
      total_disk_gb: sum(nodes, :total_disk_gb),
      available_disk_gb: sum(nodes, :available_disk_gb)
    }

    socket
    |> assign(:nodes, nodes)
    |> assign(:vpses, vpses)
    |> assign(:summary, summary)
    |> assign(:now, DateTime.utc_now())
  end

  defp sum(nodes, field) do
    Enum.reduce(nodes, 0, fn node, acc -> acc + (Map.get(node, field) || 0) end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <header>
      <h1>Bunk Fleet · Operator Dashboard</h1>
      <div class="muted">
        Live view · realtime updates · {Calendar.strftime(@now, "%Y-%m-%d %H:%M:%S UTC")}
      </div>

      <div class="summary">
        <div class="card">
          <div class="label">Regions</div>
          <div class="value">{@summary.regions}</div>
        </div>
        <div class="card">
          <div class="label">Online nodes</div>
          <div class="value">{@summary.online_nodes}</div>
        </div>
        <div class="card">
          <div class="label">Active VPSes</div>
          <div class="value">{@summary.active_vpses}</div>
        </div>
        <div class="card">
          <div class="label">vCPU avail / total</div>
          <div class="value">{@summary.available_vcpu}/{@summary.total_vcpu}</div>
        </div>
        <div class="card">
          <div class="label">RAM avail / total</div>
          <div class="value">
            {format_gib(@summary.available_ram_mb)}/{format_gib(@summary.total_ram_mb)} GiB
          </div>
        </div>
        <div class="card">
          <div class="label">Disk avail / total</div>
          <div class="value">{@summary.available_disk_gb}/{@summary.total_disk_gb} GB</div>
        </div>
      </div>
    </header>

    <h2>Nodes</h2>
    <div class="table-wrap">
      <table>
        <thead>
          <tr>
            <th>Name</th>
            <th>Region</th>
            <th>Status</th>
            <th>Hypervisor</th>
            <th>vCPU (used/total)</th>
            <th>RAM (used/total)</th>
            <th>Disk (used/total)</th>
            <th>Last heartbeat</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={node <- @nodes}>
            <td>{node.name}</td>
            <td class="mono">{region_code(node.region)}</td>
            <td class="status">
              <span class={"dot " <> status_color(node.status)}></span>{node.status}
            </td>
            <td>{node.hypervisor}</td>
            <td>{capacity_bar(node.available_vcpu, node.total_vcpu, "")}</td>
            <td>{capacity_bar(node.available_ram_mb, node.total_ram_mb, "MiB")}</td>
            <td>{capacity_bar(node.available_disk_gb, node.total_disk_gb, "GB")}</td>
            <td class="mono">{relative_time(node.last_heartbeat_at, @now)}</td>
          </tr>
          <tr :if={@nodes == []}>
            <td colspan="9" class="empty">No nodes enrolled.</td>
          </tr>
        </tbody>
      </table>
    </div>

    <h2>VPSes</h2>
    <div class="table-wrap">
      <table>
        <thead>
          <tr>
            <th>Name</th>
            <th>Region</th>
            <th>Status</th>
            <th>VM ID</th>
            <th>IP</th>
            <th>Specs</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={vps <- @vpses}>
            <td>{vps.name}</td>
            <td class="mono">{region_code(vps.region)}</td>
            <td class="status">
              <span class={"dot " <> vps_status_color(vps.status)}></span>{vps.status}
            </td>
            <td class="mono">{vps.provider_vm_id || "—"}</td>
            <td class="mono">{vps.ip_address || "—"}</td>
            <td class="mono">{vps.vcpu} vCPU · {format_gib(vps.ram_mb)} GiB · {vps.disk_gb} GB</td>
          </tr>
          <tr :if={@vpses == []}>
            <td colspan="6" class="empty">No VPSes provisioned.</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  # ---- formatting helpers -------------------------------------------------

  defp region_code(%{code: code}), do: code
  defp region_code(_), do: "—"

  # Node status color dots.
  defp status_color(:online), do: "green"
  defp status_color(:draining), do: "amber"
  defp status_color(_), do: "grey"

  defp vps_status_color(:active), do: "green"
  defp vps_status_color(status) when status in [:queued, :provisioning, :deleting], do: "amber"
  defp vps_status_color(_), do: "grey"

  # Renders a "used/total" capacity bar. `available` is what's free, so used =
  # total - available. Returns a HEEx component so we get a real progress bar.
  defp capacity_bar(available, total, unit) do
    total = total || 0
    available = available || 0
    used = max(total - available, 0)
    pct = if total > 0, do: round(used / total * 100), else: 0

    level =
      cond do
        pct >= 90 -> "crit"
        pct >= 75 -> "high"
        true -> ""
      end

    assigns = %{used: used, total: total, pct: pct, level: level, unit: unit}

    ~H"""
    <div class={"bar " <> @level}>
      <span style={"width: #{@pct}%"}></span>
    </div>
    <div class="cap-label">{@used}/{@total} {@unit} · {@pct}%</div>
    """
  end

  # Whole GiB from MiB, for display only.
  defp format_gib(nil), do: "0"
  defp format_gib(mib) when is_integer(mib), do: Integer.to_string(div(mib, 1024))

  # Human-friendly relative time, e.g. "12s ago".
  defp relative_time(nil, _now), do: "never"

  defp relative_time(%DateTime{} = ts, now) do
    secs = DateTime.diff(now, ts, :second)

    cond do
      secs < 0 -> "just now"
      secs < 60 -> "#{secs}s ago"
      secs < 3600 -> "#{div(secs, 60)}m ago"
      secs < 86_400 -> "#{div(secs, 3600)}h ago"
      true -> "#{div(secs, 86_400)}d ago"
    end
  end
end
