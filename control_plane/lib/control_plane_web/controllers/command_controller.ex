defmodule ControlPlaneWeb.CommandController do
  @moduledoc """
  Worker-node command API. Authentication is performed by
  `ControlPlaneWeb.Plugs.NodeAuth`, which assigns `conn.assigns.current_node`.

    * `GET /v1/commands` returns the calling node's deliverable commands as a JSON
      array `[{"id", "kind", "payload"}]`, marking each as delivered. This includes
      both never-delivered (`:pending`) commands and stale `:delivered` ones whose
      agent likely crashed before reporting a result, so they are redelivered.
      Redelivery assumes the agent handles commands idempotently (Go side). `[]`
      when none.
      The array also carries any pending `console_connect` requests for the node
      (see `ControlPlane.Console.Relay`); those are transient, report no result,
      and are handed out once.
    * `POST /v1/commands/:id/result` accepts the agent's outcome for one of the
      node's commands and finalises the associated VPS, returning `204`.
  """
  use ControlPlaneWeb, :controller

  alias ControlPlane.Console
  alias ControlPlane.Fleet.Command
  alias ControlPlane.Provisioning
  alias ControlPlane.Repo
  alias ControlPlaneWeb.Fouten

  def index(conn, _params) do
    node = conn.assigns.current_node
    commands = Provisioning.deliverable_commands_for_node(node)

    # Mark the whole batch delivered in one UPDATE rather than one per command
    # (the previous per-row loop was an N+1 on every agent long-poll).
    Provisioning.mark_delivered_all(commands)

    payload =
      Enum.map(commands, fn command ->
        %{
          "id" => command.id,
          "kind" => Atom.to_string(command.kind),
          # De VPS waar dit commando over gaat, of nil bij een commando over de
          # node zelf (inventory, update). De agent gebruikt het alleen om werk
          # te verdelen: commando's voor verschillende VPS'en mogen naast
          # elkaar, commando's voor dezelfde VPS moeten op volgorde. Het staat
          # hier en niet in de payload omdat elke soort payload anders is en
          # er dan zeven plekken zijn om te vergeten.
          "vps_id" => command.vps_id,
          "payload" => command.payload
        }
      end)

    # Console connect requests ride the same poll rather than getting a loop of
    # their own: the agent is already asking every couple of seconds, and a
    # console that waits for the next poll is a console that opens in about a
    # second. They are deliberately NOT `commands` rows — they are in-memory,
    # expire in seconds, carry no result, and must never be redelivered to an
    # agent that restarts, because by then the person has clicked again.
    json(conn, payload ++ Console.Relay.take_for_node(node.id))
  end

  def result(conn, %{"id" => id} = params) do
    node = conn.assigns.current_node

    # L1: validate the id is a UUID before querying — a malformed id would
    # otherwise raise Ecto.Query.CastError -> 500. A bad/unknown id collapses to
    # 404 (existence is never leaked).
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Command{} = command <- Repo.get_by(Command, id: id, node_id: node.id) do
      # apply_result is idempotent; a duplicate/already-applied result still
      # returns {:ok, _} so the agent gets a clean 204.
      case Provisioning.apply_result(command, result_attrs(params)) do
        {:ok, _command} ->
          send_resp(conn, :no_content, "")

        {:error, reason} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: error_message(reason)})
      end
    else
      anders -> Fouten.fout(conn, anders)
    end
  end

  # L2: never to_string/1 an arbitrary error term (a failed-Multi changeset would
  # raise Protocol.UndefinedError -> 500). Only surface known atoms.
  defp error_message(reason) when is_atom(reason), do: to_string(reason)
  defp error_message(_reason), do: "unprocessable_entity"

  # An allow-list, not the raw params: the agent's report is persisted into
  # `commands.result` and read back by the finalisers, so anything accepted here
  # is something the control plane will later act on. Every field a command kind
  # can report has to be named — a backup that reports an archive the control
  # plane then drops is a backup nobody can find.
  defp result_attrs(params) do
    %{
      "status" => params["status"],
      "vm_id" => params["vm_id"],
      "ip" => params["ip"],
      "error" => params["error"],
      # Backups: where the node put the archive, and how big it is.
      "volid" => params["volid"],
      "size_bytes" => params["size_bytes"],
      # Inventarisatie: elk gast-id dat de node zegt te hebben. Begrensd, want
      # dit komt van een machine die niet van ons hoeft te zijn: een lijst van
      # een miljoen strings zou hier een rij van een miljoen strings worden.
      "guests" => gasten(params["guests"])
    }
  end

  @max_guests 5_000

  # Alleen een echte lijst strings telt. Geen lijst betekent `nil` en NIET een
  # lege lijst: die twee zijn hier het verschil tussen "deze node heeft geen
  # gasten" en "dit antwoord gaat niet over gasten", en op het eerste handelen
  # terwijl het het tweede was zou elke VPS als verdwenen aanmerken.
  defp gasten(lijst) when is_list(lijst) do
    lijst
    |> Enum.filter(&is_binary/1)
    |> Enum.take(@max_guests)
  end

  defp gasten(_anders), do: nil
end
