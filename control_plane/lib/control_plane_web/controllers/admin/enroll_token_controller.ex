defmodule ControlPlaneWeb.Admin.EnrollTokenController do
  @moduledoc """
  Operator/admin API for minting single-use node enroll tokens.

  `create` mints a token via `ControlPlane.Enrollment.create_enroll_token/1` and
  returns the plaintext token (shown only once) together with a ready-to-run
  `install` one-liner a node operator pastes onto a host to bootstrap `bunk-agent`.

  Protected by the `:admin_session_api` pipeline: an admin's own session,
  with a second factor (see `ControlPlaneWeb.Plugs.RequireAdmin`).
  """
  use ControlPlaneWeb, :controller

  alias ControlPlane.Enrollment
  alias ControlPlane.Fleet
  alias ControlPlane.Fleet.Region

  @default_ttl_seconds 3600

  def create(conn, params) do
    with {:ok, %Region{} = region} <- resolve_region(params),
         ttl_seconds <- parse_ttl(params),
         {:ok, {plaintext, enroll_token}} <-
           Enrollment.create_enroll_token(%{
             region_id: region.id,
             ttl_seconds: ttl_seconds
           }) do
      conn
      |> put_status(:created)
      |> json(%{
        enroll_token: plaintext,
        expires_at: enroll_token.expires_at,
        region: region.code,
        install: install_command(conn, plaintext)
      })
    else
      {:error, :region_not_found} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "region_not_found"})

      {:error, _changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid_enroll_token"})
    end
  end

  # Accepts either `region_id` (binary_id) or `region_code` (e.g. "nl-1").
  defp resolve_region(%{"region_id" => region_id}) when is_binary(region_id) do
    # Validate the UUID format first so a malformed id is a clean 422, not a 500
    # from Ecto.Query.CastError inside get_region!/1.
    case Ecto.UUID.cast(region_id) do
      {:ok, id} ->
        case Fleet.get_region!(id) do
          %Region{} = region -> {:ok, region}
        end

      :error ->
        {:error, :region_not_found}
    end
  rescue
    Ecto.NoResultsError -> {:error, :region_not_found}
  end

  defp resolve_region(%{"region_code" => region_code}) when is_binary(region_code) do
    case Fleet.region_by_code(region_code) do
      %Region{} = region -> {:ok, region}
      nil -> {:error, :region_not_found}
    end
  end

  defp resolve_region(_params), do: {:error, :region_not_found}

  defp parse_ttl(%{"ttl_seconds" => ttl}) when is_integer(ttl) and ttl > 0, do: ttl

  defp parse_ttl(%{"ttl_seconds" => ttl}) when is_binary(ttl) do
    case Integer.parse(ttl) do
      {n, _} when n > 0 -> n
      _ -> @default_ttl_seconds
    end
  end

  defp parse_ttl(_params), do: @default_ttl_seconds

  # A ready-to-run command a node operator pastes onto their hypervisor host.
  #
  # The wizard, not a `docker run`: it asks for the hypervisor credentials rather
  # than making the operator fill in placeholders, and — the part that cannot be
  # done from a container — it installs the agent on the host, where it can put
  # the assigned gateway on the customer bridge and NAT that subnet out of the
  # node's own uplink.
  defp install_command(conn, token) do
    "curl -fsSL #{control_plane_url(conn)}/install.sh | bash -s -- --token #{token}"
  end

  defp control_plane_url(conn) do
    case Application.get_env(:control_plane, :public_url) do
      url when is_binary(url) and url != "" -> url
      _ -> derive_base_url(conn)
    end
  end

  defp derive_base_url(conn) do
    "#{conn.scheme}://#{conn.host}#{port_suffix(conn)}"
  end

  defp port_suffix(%{scheme: :http, port: 80}), do: ""
  defp port_suffix(%{scheme: :https, port: 443}), do: ""
  defp port_suffix(%{port: port}), do: ":#{port}"
end
