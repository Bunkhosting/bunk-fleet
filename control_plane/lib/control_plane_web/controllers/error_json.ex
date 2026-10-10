defmodule ControlPlaneWeb.ErrorJSON do
  @moduledoc """
  Het antwoord op een fout die geen controller zelf afhandelde: een exceptie
  (500), een route die niet bestaat (404), een body die niet te lezen is (400),
  een te groot verzoek (413).

  Zelfde vorm als `ControlPlaneWeb.Fouten`: een code in `error`, waar de
  frontend een Nederlandse zin bij zoekt. Het was de standaard van Phoenix,
  `{errors: {detail: "Internal Server Error"}}`, en die las de frontend als een
  validatiefout -- de klant kreeg "Internal Server Error" in beeld. Er staat
  bewust niets in over wat er misging: dat hoort in de log, niet bij de klant.
  """

  @codes %{
    "400" => "bad_request",
    "401" => "unauthorized",
    "403" => "forbidden",
    "404" => "not_found",
    "405" => "method_not_allowed",
    "406" => "not_acceptable",
    "413" => "payload_too_large",
    "415" => "unsupported_media_type",
    "429" => "rate_limited",
    "500" => "internal_error",
    "502" => "bad_gateway",
    "503" => "service_unavailable"
  }

  def render(template, _assigns) do
    status = template |> String.split(".") |> hd()

    %{
      error:
        Map.get(@codes, status, if(status >= "500", do: "internal_error", else: "bad_request")),
      detail: Phoenix.Controller.status_message_from_template(template)
    }
  end
end
