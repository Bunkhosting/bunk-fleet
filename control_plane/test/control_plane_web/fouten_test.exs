defmodule ControlPlaneWeb.FoutenTest do
  @moduledoc """
  De tabel moet elke weigering kennen die de bestelweg kan teruggeven.

  `ControlPlane.Provisioning` somt die op in `@type refusal`, met erbij dat een
  nieuwe reden ook een vertaling in de frontend nodig heeft. Wat daar ontbrak
  bleef vroeger onzichtbaar: een catch-all maakte er "invalid_vps" van, en dan
  kijkt een klant naar zijn eigen invoer voor iets waar hij niets aan kan doen.

  Nu wordt het een 500 met een logregel -- luid, en precies daarom moet deze
  test bestaan: hij vangt de vergeten rij vóór een klant hem tegenkomt.
  """
  use ExUnit.Case, async: true

  alias ControlPlaneWeb.Fouten

  # Handmatig overgenomen uit `@type refusal` in provisioning.ex. Dat is met
  # opzet: een type is niet op te vragen tijdens het draaien, en een lijst die
  # je moet bijwerken is beter dan een controle die er niet is.
  @weigeringen ~w(
    not_found not_provisioned no_node no_capacity already_deleting
    quota_exceeded insufficient_credits port_pool_exhausted
  )a

  test "elke weigering van de bestelweg staat in de tabel" do
    ontbreekt = @weigeringen -- Fouten.bekend()

    assert ontbreekt == [],
           "deze redenen leveren een 500 op in plaats van een antwoord: #{inspect(ontbreekt)}"
  end

  test "de tabel kent ook de redenen die de controllers zelf maken" do
    eigen = ~w(invalid_spec input_too_large no_delivery_consent region_not_found
               invalid_key in_flight forbidden)a

    assert eigen -- Fouten.bekend() == []
  end
end
