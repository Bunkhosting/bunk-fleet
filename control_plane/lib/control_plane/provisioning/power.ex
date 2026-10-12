defmodule ControlPlane.Provisioning.Power do
  @moduledoc """
  Aan- en uitzetten, pauzeren, hervatten en herstarten van een VPS.

  Elke handeling wordt een commando voor de agent op de node waar de VPS staat.
  Het control plane bewaakt alleen of de overgang mag vanuit de huidige status;
  de status zelf verandert pas als de agent meldt dat het gelukt is (zie
  `ControlPlane.Provisioning.apply_result/2`), zodat het paneel laat zien wat de
  hypervisor echt doet.

  Hetzelfde commando twee keer tegelijk inplannen kan niet: een lopend commando
  van dezelfde soort maakt een nieuw verzoek een no-op, en een partiële unieke
  index vangt wat tegelijk binnenkomt.
  """
  alias ControlPlane.Fleet.Command
  alias ControlPlane.Fleet.Events
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Provisioning
  alias ControlPlane.Provisioning.CommandQueue
  alias ControlPlane.Repo
  alias Ecto.Multi

  @doc """
  Dispatches a power command (`:start`/`:stop`/`:pause`/`:resume`) to a VPS's node.

  Guards on the VPS's current status so only valid transitions are issued: start
  from `:stopped`; stop from `:active`/`:paused`; pause from `:active`; resume from
  `:paused`. The VPS must be placed and provisioned (`node_id` + `provider_vm_id`).
  The status only changes once the agent reports the command done (see
  `apply_result/2`), so the dashboard reflects the real hypervisor state.

  Returns `{:ok, %{vps: vps, command: command}}`, or `{:error, reason}` where reason
  is `:not_found`, `:not_provisioned`, or `{:invalid_status, status}`.
  """
  @spec start_vps(binary()) :: {:ok, Provisioning.dispatch()} | {:error, Provisioning.refusal()}
  def start_vps(vps_id), do: dispatch_power(vps_id, :start, [:stopped])
  @spec stop_vps(binary()) :: {:ok, Provisioning.dispatch()} | {:error, Provisioning.refusal()}
  def stop_vps(vps_id), do: dispatch_power(vps_id, :stop, [:active, :paused])
  @spec pause_vps(binary()) :: {:ok, Provisioning.dispatch()} | {:error, Provisioning.refusal()}
  def pause_vps(vps_id), do: dispatch_power(vps_id, :pause, [:active])
  @spec resume_vps(binary()) :: {:ok, Provisioning.dispatch()} | {:error, Provisioning.refusal()}
  def resume_vps(vps_id), do: dispatch_power(vps_id, :resume, [:paused])

  @doc """
  Herstart een draaiende VPS: het besturingssysteem wordt gevraagd af te sluiten
  en komt weer op.

  Alleen vanuit `:active`. Een gestopte machine "herstarten" zou betekenen dat
  de aanvrager denkt dat hij draait, en er dan stilletjes iets anders van maken
  verbergt dat.

  De status blijft `:active`. Er is geen moment waarop de VPS uit staat in de
  zin die het paneel bedoelt -- hij is niet uitgezet -- en een tussenstand
  verzinnen zou elke andere actie erop blokkeren zolang de agent niet
  terugmeldt.
  """
  @spec reboot_vps(binary()) :: {:ok, Provisioning.dispatch()} | {:error, Provisioning.refusal()}
  def reboot_vps(vps_id), do: dispatch_power(vps_id, :reboot, [:active])

  defp dispatch_power(vps_id, kind, allowed) do
    case Repo.get(Vps, vps_id) do
      nil ->
        {:error, :not_found}

      %Vps{node_id: nil} ->
        {:error, :not_provisioned}

      %Vps{provider_vm_id: nil} ->
        {:error, :not_provisioned}

      %Vps{} = vps ->
        power_if_allowed(vps, kind, allowed)
    end
  end

  defp power_if_allowed(%Vps{status: status} = vps, kind, allowed) do
    if status in allowed,
      do: enqueue_power_command(vps, kind),
      else: {:error, {:invalid_status, status}}
  end

  defp enqueue_power_command(vps, kind) do
    # An identical power command is already queued/delivered (e.g. a
    # double-clicked Stop) — don't enqueue a duplicate. Idempotent no-op.
    #
    # Deze controle is de goedkope voorwacht en niet het slot. Kijken-dan-
    # schrijven verliest van echte gelijktijdigheid: tien verzoeken tegelijk
    # lezen alle tien "er loopt niets" voordat er één invoegt. Het slot is de
    # partiële unieke index `commands_een_machtscommando_per_vps_uidx`.
    if CommandQueue.in_flight?(vps.id, kind) do
      {:ok, %{vps: vps, command: nil}}
    else
      vps
      |> machtscommando(kind)
      |> Repo.transaction()
      |> machtsuitkomst(vps)
    end
  end

  defp machtscommando(vps, kind) do
    Multi.insert(Multi.new(), :command, fn _ ->
      Command.changeset(%Command{}, %{
        node_id: vps.node_id,
        vps_id: vps.id,
        kind: kind,
        status: :pending,
        payload: %{"vm_id" => vps.provider_vm_id}
      })
    end)
  end

  defp machtsuitkomst({:ok, %{command: command}}, vps) do
    Events.broadcast_changed(:vps)
    {:ok, %{vps: vps, command: command}}
  end

  # Een botsing op de index betekent dat een gelijktijdig verzoek net vóór ons
  # hetzelfde commando heeft ingepland. Dat is geen fout maar precies de
  # uitkomst die we wilden: er staat er één, en het antwoord is hetzelfde als
  # wanneer de voorwacht hem had gevangen.
  defp machtsuitkomst({:error, _step, reason, _changes}, vps) do
    if unieke_botsing?(reason),
      do: {:ok, %{vps: vps, command: nil}},
      else: {:error, reason}
  end

  defp unieke_botsing?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {_veld, {_bericht, opts}} -> opts[:constraint] == :unique
      _ -> false
    end)
  end

  defp unieke_botsing?(_), do: false
end
