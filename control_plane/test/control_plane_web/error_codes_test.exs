defmodule ControlPlaneWeb.ErrorCodesTest do
  @moduledoc """
  The shape of the `error` field every JSON endpoint answers with.

  It is a machine code: snake_case, no spaces, no punctuation, stable across
  releases. The frontend switches on it to pick a Dutch sentence, and anything it
  does not recognise falls back to a generic message — so a code that drifts into
  a sentence does not break loudly, it just quietly stops being translated. That
  is exactly the kind of regression a test has to catch, because nobody will.

  The human-readable half goes in `detail`, which is free to be a sentence.
  """
  use ControlPlaneWeb.ConnCase, async: true

  @web_root "lib/control_plane_web"

  # `error: "..."` in a controller or plug, and `error(conn, status, "...")`
  # through the shared helper. Interpolated codes (invalid_status_#{status}) are
  # checked on their literal prefix.
  defp declared_codes do
    Path.wildcard(@web_root <> "/**/*.ex")
    |> Enum.flat_map(fn path ->
      source = File.read!(path)

      Regex.scan(~r/error: "([^"]*)"/, source, capture: :all_but_first) ++
        Regex.scan(~r/error\(conn, :[a-z_]+, "([^"]*)"/, source, capture: :all_but_first)
    end)
    |> List.flatten()
    |> Enum.uniq()
  end

  # The two Dutch sentences live in server-rendered HTML forms, where they are the
  # text the person reads rather than a code a client switches on.
  defp html_form_messages,
    do: ["Ongeldig e-mailadres of wachtwoord.", "Ongeldige code. Probeer opnieuw."]

  # Everything except the HTML form messages, which are the two exceptions.
  defp api_codes, do: Enum.reject(declared_codes(), &(&1 in html_form_messages()))

  test "every API error code is snake_case" do
    offenders =
      Enum.reject(api_codes(), &String.match?(&1, ~r/\A[a-z][a-z0-9_]*(#\{[a-z_]+\})?\z/))

    assert offenders == [],
           "these are sentences where a machine code belongs: #{inspect(offenders)}"
  end

  test "no error code carries punctuation or capitals" do
    offenders = Enum.filter(api_codes(), &String.match?(&1, ~r/[A-Z.,!?:;]/))

    assert offenders == [], inspect(offenders)
  end

  describe "the codes the live endpoints actually answer with" do
    test "a wrong password", %{conn: conn} do
      resp =
        conn
        |> post(~p"/api/v1/auth/login", %{"email" => "nobody@example.com", "password" => "wrong"})
        |> json_response(401)

      assert resp["error"] == "invalid_credentials"
    end

    test "a login with nothing in it", %{conn: conn} do
      resp = conn |> post(~p"/api/v1/auth/login", %{}) |> json_response(422)

      assert resp["error"] == "missing_credentials"
      # The sentence belongs in detail, where it is free to be one.
      assert is_binary(resp["detail"])
    end

    test "an unauthenticated call to an owner-scoped endpoint", %{conn: conn} do
      assert conn |> get(~p"/api/v1/vpses") |> json_response(401) |> Map.fetch!("error") ==
               "unauthorized"
    end

    test "a heartbeat with no node", %{conn: conn} do
      resp =
        conn
        |> put_req_header("authorization", "Bearer nope")
        |> post(~p"/v1/heartbeat", %{})
        |> json_response(401)

      assert resp["error"] =~ ~r/\A[a-z][a-z0-9_]*\z/
    end
  end

  describe "every code has a Dutch sentence in the dashboard" do
    # The frontend falls back to a contextual sentence for a code it does not
    # know, so a missing entry never breaks loudly -- the customer just reads
    # "Kon de VPS niet starten." instead of why. That is how
    # "weak_password" came to be shown as "het opgegeven wachtwoord klopt
    # niet": nobody looked. This test does.
    @frontend "../frontend/src/lib/api.ts"

    # Codes no dashboard screen ever receives: the node agent's own API and
    # the enrolment handshake. They are read by a program, not a person.
    @machine_only ~w(invalid_heartbeat missing_node_id node_id_mismatch)

    defp frontend_codes(source) do
      [_, body] = Regex.run(~r/const ERROR_MESSAGES[^{]*\{(.*?)\n\};/s, source)
      Regex.scan(~r/^\s*([a-z][a-z0-9_]*):/m, body, capture: :all_but_first) |> List.flatten()
    end

    defp all_codes do
      vps_statuses = Ecto.Enum.values(ControlPlane.Fleet.Vps, :status)

      literal =
        declared_codes()
        |> Enum.flat_map(fn code ->
          case String.split(code, "\#{") do
            [prefix, _] -> Enum.map(vps_statuses, &(prefix <> Atom.to_string(&1)))
            [_] -> [code]
          end
        end)

      fouten =
        ControlPlaneWeb.Fouten.bekend()
        |> Enum.map(fn reden ->
          conn = Phoenix.ConnTest.build_conn() |> ControlPlaneWeb.Fouten.fout(reden)
          Jason.decode!(conn.resp_body)["error"]
        end)

      error_json =
        for s <- ~w(400 404 413 500),
            do: ControlPlaneWeb.ErrorJSON.render(s <> ".json", %{}).error

      (literal ++ fouten ++ error_json)
      |> Enum.reject(&(&1 in html_form_messages()))
      |> Enum.uniq()
    end

    test "no code reaches a customer untranslated" do
      case File.read(@frontend) do
        {:ok, source} ->
          known = MapSet.new(frontend_codes(source))

          missing =
            all_codes()
            |> Enum.reject(&(MapSet.member?(known, &1) or &1 in @machine_only))
            |> Enum.sort()

          assert missing == [],
                 "codes without a sentence in ERROR_MESSAGES (#{@frontend}): #{inspect(missing)}"

        {:error, :enoent} ->
          # The gate on the build machine mounts only control_plane/. CI has
          # the whole repository and runs this for real.
          IO.puts("skipped: #{@frontend} is not in this checkout")
      end
    end
  end
end
