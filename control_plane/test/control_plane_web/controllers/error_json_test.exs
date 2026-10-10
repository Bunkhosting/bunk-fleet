defmodule ControlPlaneWeb.ErrorJSONTest do
  use ControlPlaneWeb.ConnCase, async: true

  # Dezelfde vorm als elke andere API-fout: een code in `error`. Was
  # `{errors: {detail: ...}}`, en dan zag de klant "Internal Server Error".
  test "renders 404 als code" do
    assert ControlPlaneWeb.ErrorJSON.render("404.json", %{}) ==
             %{error: "not_found", detail: "Not Found"}
  end

  test "renders 500 als code, zonder iets over de oorzaak" do
    assert ControlPlaneWeb.ErrorJSON.render("500.json", %{}) ==
             %{error: "internal_error", detail: "Internal Server Error"}
  end

  test "een onbekende status krijgt toch een code" do
    assert %{error: "bad_request"} = ControlPlaneWeb.ErrorJSON.render("418.json", %{})
    assert %{error: "internal_error"} = ControlPlaneWeb.ErrorJSON.render("507.json", %{})
  end

  test "een route die niet bestaat antwoordt met de code", %{conn: conn} do
    conn = get(conn, "/api/v1/bestaat-niet-#{System.unique_integer([:positive])}")
    assert %{"error" => "not_found"} = json_response(conn, 404)
  end
end
