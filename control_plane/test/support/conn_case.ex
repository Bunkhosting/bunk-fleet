defmodule ControlPlaneWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use ControlPlaneWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  alias ControlPlane.Accounts.LoginThrottle

  using do
    quote do
      # The default endpoint for testing
      @endpoint ControlPlaneWeb.Endpoint

      use ControlPlaneWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import ControlPlaneWeb.ConnCase
    end
  end

  setup tags do
    ControlPlane.DataCase.setup_sandbox(tags)
    # The rate limiter is a single global ETS keyed by client IP; every test
    # request comes from 127.0.0.1, so without a per-test reset counters bleed
    # across tests and later ones spuriously hit 429. The two files that assert
    # accumulated limiter state (auth_controller / rate_limiter) run async: false
    # so this reset never races their request sequences.
    ControlPlane.RateLimiter.reset()
    LoginThrottle.reset()
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Zet de sessie van `user` als bearer op `conn`, met een sessie die haar tweede
  factor heeft laten zien.

  Met `mfa: true`, want het beheerpaneel en /admin/v1 eisen dat
  (`Plugs.RequireAdminMfa`). Een gewone gebruiker merkt er niets van.
  """
  def met_sessie(conn, %ControlPlane.Accounts.User{} = user) do
    token =
      user
      |> ControlPlane.Accounts.generate_user_session_token(mfa: true)
      |> Base.url_encode64(padding: false)

    Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token)
  end

  @doc """
  Zet de `Origin` van ons eigen dashboard op `conn`, zoals de browser hem meestuurt.

  Inloggen en registreren weigeren een verzoek zonder herkomst: anders kan een
  andere site een bezoeker ongemerkt op het account van de aanvaller laten
  inloggen (login-CSRF, zie `ControlPlaneWeb.Plugs.SameOrigin`).
  """
  def vanaf_dashboard(conn) do
    Plug.Conn.put_req_header(conn, "origin", Application.get_env(:control_plane, :public_url))
  end

  @doc """
  Een bevestigde beheerder met een tweede factor, en `conn` met diens sessie.

  Vervangt het gedeelde geheim dat de /admin/v1-tests vroeger meestuurden: wat
  daar nu door mag, is een persoon.
  """
  def als_beheerder(conn) do
    beheerder =
      ControlPlane.Fixtures.confirmed_user_fixture()
      |> Ecto.Changeset.change(%{role: :admin})
      |> ControlPlane.Repo.update!()
      |> ControlPlane.Fixtures.with_second_factor()

    {met_sessie(conn, beheerder), beheerder}
  end
end
