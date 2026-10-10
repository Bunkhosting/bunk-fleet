defmodule ControlPlaneWeb.Admin.CreditController do
  @moduledoc """
  Admin credit management — manual wallet top-ups and adjustments. This is the
  operational stand-in for a payment provider until Mollie lands: a customer pays
  by bank/iDEAL, the admin credits their wallet here. Protected by the
  shared-secret admin token (`AdminAuth`).
  """
  use ControlPlaneWeb, :controller

  alias ControlPlane.Accounts
  alias ControlPlane.Credits

  # GET /admin/v1/credits?email=...  -> balance + recent ledger entries
  def show(conn, %{"email" => email}) do
    case Accounts.get_user_by_email(email) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "user_not_found"})

      user ->
        json(conn, %{
          email: email,
          balance_cents: Credits.balance_cents(user.id),
          entries: Enum.map(Credits.list_entries(user.id), &entry_json/1)
        })
    end
  end

  def show(conn, _), do: bad_request(conn, "missing_email", "email query parameter is required")

  # POST /admin/v1/credits  {email, amount_cents, description?}
  # amount_cents > 0 tops up, < 0 is a manual correction. Accepts the amount as a
  # JSON integer or a numeric string (so form- and json-encoded calls both work).
  def create(conn, %{"email" => email, "amount_cents" => raw} = params) do
    with {:ok, cents} when cents != 0 <- to_cents(raw),
         %_{} = user <- Accounts.get_user_by_email(email) do
      kind = if cents > 0, do: "admin_topup", else: "admin_adjustment"
      desc = blank_to_default(params["description"])

      # Geen `{:ok, _} =`: een omschrijving die de changeset weigert (te lang)
      # werd zo een kale 500 zonder reden.
      case Credits.add_entry(user.id, cents, kind, desc) do
        {:ok, _} ->
          json(conn, %{email: email, balance_cents: Credits.balance_cents(user.id)})

        {:error, _changeset} ->
          bad_request(
            conn,
            "invalid_entry",
            "the ledger entry was refused (description too long?)"
          )
      end
    else
      nil -> conn |> put_status(:not_found) |> json(%{error: "user_not_found"})
      _ -> bad_request(conn, "invalid_amount", "amount_cents must be a non-zero integer")
    end
  end

  def create(conn, _),
    do: bad_request(conn, "missing_params", "email and amount_cents are required")

  defp to_cents(n) when is_integer(n), do: {:ok, n}

  defp to_cents(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp to_cents(_), do: :error

  defp blank_to_default(d) when is_binary(d) do
    if String.trim(d) == "", do: "Handmatige bijboeking door beheerder", else: d
  end

  defp blank_to_default(_), do: "Handmatige bijboeking door beheerder"

  # Een code in `error` en de zin in `detail`, zoals overal. Hier stond de zin
  # in `error`, en dat glipte langs de codetest omdat hij uit een variabele kwam.
  defp bad_request(conn, code, detail),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: code, detail: detail})

  defp entry_json(e) do
    %{amount_cents: e.amount_cents, kind: e.kind, description: e.description, at: e.inserted_at}
  end
end
