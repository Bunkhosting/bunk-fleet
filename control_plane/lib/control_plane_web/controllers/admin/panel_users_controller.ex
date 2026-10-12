defmodule ControlPlaneWeb.Admin.PanelUsersController do
  @moduledoc """
  Gebruikersbeheer in het beheerpaneel (`/api/v1/beheer/users*`).

  De lijst van klanten, alles over één klant op één plek, de rol wijzigen,
  saldo handmatig bij- of afboeken en een account verwijderen of anonimiseren.
  Afgeschermd door `ControlPlaneWeb.Plugs.RequireAdmin`, zoals de rest van het
  paneel.
  """
  use ControlPlaneWeb, :controller
  import Ecto.Query

  import ControlPlaneWeb.Admin.PanelHelpers,
    only: [error: 3, ok_or: 2, subscription_json: 1, vps_json: 1]

  alias ControlPlane.Accounts
  alias ControlPlane.Accounts.User
  alias ControlPlane.Credits
  alias ControlPlane.Credits.LedgerEntry
  alias ControlPlane.Credits.TopupRequest
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Repo
  alias ControlPlane.Subscriptions.Subscription

  def users(conn, _params) do
    users = Repo.all(from u in User, order_by: [asc: u.inserted_at])

    vps_counts =
      Repo.all(
        from v in Vps,
          where: v.status not in [:deleted, :failed],
          group_by: v.owner_id,
          select: {v.owner_id, count(v.id)}
      )
      |> Map.new()

    balances =
      Repo.all(
        from e in LedgerEntry, group_by: e.user_id, select: {e.user_id, sum(e.amount_cents)}
      )
      |> Map.new()

    json(conn, %{
      users:
        Enum.map(users, fn u ->
          %{
            id: u.id,
            name: u.name,
            email: u.email,
            role: u.role,
            confirmed: not is_nil(u.confirmed_at),
            two_factor: not is_nil(u.totp_confirmed_at),
            inserted_at: DateTime.to_iso8601(u.inserted_at),
            vps_count: Map.get(vps_counts, u.id, 0),
            balance_cents: to_int(Map.get(balances, u.id, 0)),
            # Een verwijderd account waarvan de administratie moest blijven
            # staan. De rij bestaat nog; de persoon erachter niet meer.
            anonymised_at: u.anonymised_at && DateTime.to_iso8601(u.anonymised_at)
          }
        end)
    })
  end

  @doc """
  `GET /api/v1/beheer/users/:id` — alles wat er over één klant te weten is, op
  één plek.

  De lijst laat per klant een saldo en een aantal VPS'en zien; wat ontbrak was
  de vraag daarachter. Waarom staat deze klant op nul? Wanneer heeft hij voor
  het laatst betaald? Loopt er een abonnement dat niet meer geïnd kan worden?
  Dat waren tot nu toe vragen die alleen in de database te beantwoorden waren.
  """
  def user_detail(conn, %{"id" => id}) do
    with {:ok, uuid} <- Ecto.UUID.cast(id) |> ok_or(:not_found),
         %User{} = user <- Accounts.get_user(uuid) || :not_found do
      json(conn, %{
        user: %{
          id: user.id,
          email: user.email,
          name: user.name,
          role: user.role,
          confirmed: not is_nil(user.confirmed_at),
          totp_enabled: not is_nil(user.totp_confirmed_at),
          passkeys: length(Accounts.list_passkeys(user)),
          created_at: user.inserted_at
        },
        balance_cents: Credits.balance_cents(user.id),
        vpses: Enum.map(vpses_of(user.id), &vps_json/1),
        subscriptions: Enum.map(subscriptions_of(user.id), &subscription_json/1),
        ledger: Enum.map(Credits.list_entries(user.id, 50), &ledger_json/1),
        topups: Enum.map(topups_of(user.id), &topup_json/1)
      })
    else
      _ -> error(conn, :not_found, "not_found")
    end
  end

  defp vpses_of(user_id) do
    Repo.all(
      from v in Vps,
        where: v.owner_id == ^user_id and v.status != :deleted,
        order_by: [desc: v.inserted_at],
        preload: [:region, :node]
    )
  end

  defp subscriptions_of(user_id) do
    Repo.all(
      from s in Subscription,
        where: s.owner_id == ^user_id,
        order_by: [desc: s.inserted_at],
        preload: [:vps]
    )
  end

  defp topups_of(user_id) do
    Repo.all(
      from t in TopupRequest,
        where: t.user_id == ^user_id,
        order_by: [desc: t.inserted_at],
        limit: 25
    )
  end

  defp ledger_json(e) do
    %{
      id: e.id,
      amount_cents: e.amount_cents,
      kind: e.kind,
      description: e.description,
      at: e.inserted_at
    }
  end

  defp topup_json(t) do
    %{
      id: t.id,
      reference: t.reference,
      amount_cents: t.amount_cents,
      status: t.status,
      paid_at: t.paid_at,
      # Telt dit bedrag als omzet? Alleen als er een betaling bij de provider
      # bestond én die niet met de hand op betaald is gezet.
      via_provider: not is_nil(t.mollie_payment_id) and t.paid_via != "manual",
      paid_via: t.paid_via,
      requested_at: t.inserted_at
    }
  end

  def update_user(conn, %{"id" => id} = params) do
    with {:ok, uid} <- Ecto.UUID.cast(id) |> ok_or(:not_found),
         %User{} = user <- Accounts.get_user(uid) || :not_found,
         {:ok, role} <- parse_role(params),
         :ok <- keeps_own_admin(conn, user, role),
         {:ok, u} <- Accounts.update_user_role(user, role) do
      json(conn, %{id: u.id, role: u.role})
    else
      :not_found -> error(conn, :not_found, "not_found")
      {:error, :invalid_role} -> error(conn, :unprocessable_entity, "invalid_role")
      {:error, :self_demotion} -> error(conn, :unprocessable_entity, "cannot_demote_self")
      {:error, %Ecto.Changeset{}} -> error(conn, :unprocessable_entity, "update_failed")
      _ -> error(conn, :not_found, "not_found")
    end
  end

  @doc """
  Verwijdert een account, of anonimiseert het als er een administratie aan hangt.

  Het antwoord zegt wélke van de twee het is geworden, zodat het scherm dat kan
  tonen in plaats van "verwijderd" te melden bij iets wat blijft bestaan.
  """
  def delete_user(conn, %{"id" => id}) do
    with {:ok, uid} <- Ecto.UUID.cast(id) |> ok_or(:not_found),
         %User{} = user <- Accounts.get_user(uid) || :not_found,
         :ok <- niet_jezelf(conn, user),
         {:ok, uitkomst} <- Accounts.delete_or_anonymise_user(user) do
      json(conn, %{result: uitkomst})
    else
      :not_found -> error(conn, :not_found, "not_found")
      {:error, :self} -> error(conn, :unprocessable_entity, "cannot_delete_self")
      {:error, :has_vpses} -> error(conn, :conflict, "user_has_vpses")
      {:error, _reason} -> error(conn, :unprocessable_entity, "delete_failed")
    end
  end

  # Jezelf verwijderen sluit je buiten je eigen paneel, en bij de laatste
  # beheerder sluit het iedereen buiten. Dezelfde reden als bij het degraderen.
  defp niet_jezelf(conn, %User{} = user) do
    if user.id == conn.assigns.current_user.id, do: {:error, :self}, else: :ok
  end

  # Never let an admin strip their OWN admin role: the last admin demoting
  # themselves locks the whole panel, and nothing in the panel can undo it.
  defp keeps_own_admin(conn, %User{} = user, role) do
    if user.id == conn.assigns.current_user.id and role != :admin,
      do: {:error, :self_demotion},
      else: :ok
  end

  def credit_user(conn, %{"id" => id} = params) do
    with {:ok, uid} <- Ecto.UUID.cast(id) |> ok_or(:not_found),
         %User{} = user <- Accounts.get_user(uid) || :not_found,
         {:ok, cents} <- parse_amount(params) do
      # Met de naam van de beheerder erbij. Er is meer dan één, en bij een regel
      # die geld verplaatst is "een beheerder" geen antwoord op de vraag die
      # achteraf gesteld wordt.
      {:ok, _} =
        Credits.add_entry(
          user.id,
          cents,
          "admin_adjustment",
          "Handmatige aanpassing door #{conn.assigns.current_user.email}"
        )

      json(conn, %{id: user.id, balance_cents: Credits.balance_cents(user.id)})
    else
      :not_found -> error(conn, :not_found, "not_found")
      {:error, :invalid_amount} -> error(conn, :unprocessable_entity, "invalid_amount")
      _ -> error(conn, :not_found, "not_found")
    end
  end

  defp parse_role(%{"role" => r}) when r in ["user", "operator", "admin"],
    do: {:ok, String.to_existing_atom(r)}

  defp parse_role(_), do: {:error, :invalid_role}

  defp parse_amount(%{"amount_cents" => v}) do
    cents =
      cond do
        is_integer(v) ->
          v

        is_binary(v) ->
          case Integer.parse(v) do
            {n, ""} -> n
            _ -> nil
          end

        true ->
          nil
      end

    if is_integer(cents) and cents != 0 and abs(cents) <= 10_000_000,
      do: {:ok, cents},
      else: {:error, :invalid_amount}
  end

  defp parse_amount(_), do: {:error, :invalid_amount}

  defp to_int(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_int(n) when is_integer(n), do: n
  defp to_int(_), do: 0
end
