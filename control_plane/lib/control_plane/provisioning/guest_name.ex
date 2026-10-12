defmodule ControlPlane.Provisioning.GuestName do
  @moduledoc """
  De naam waaronder een gast op de hypervisor komt te staan.

  Een pure module: geen database, geen bijwerkingen. Dezelfde VPS en dezelfde
  node geven altijd dezelfde naam, en dat is precies waar de agent op leunt om
  een opnieuw afgeleverd provision-commando te herkennen.
  """
  alias ControlPlane.Fleet.Vps

  @doc """
  De gastnaam voor `vps` op `node`, volgens het patroon van die node.

  De agent herkent hieraan of hij een machine al heeft aangemaakt, dus het
  unieke deel is geen opsmuk: stond daar ooit alleen de door de klant gekozen
  naam in, dan nam de tweede klant met dezelfde naam op een node de draaiende
  VM van de eerste over. `{id}` is daarom verplicht in een patroon, en zonder
  patroon is het `{naam}-{id}` (zie `guest_name/1`).

  Het is een slug van de weergavenaam plus een kort stuk van de UUID: leesbaar
  voor een mens, uniek per VPS, en bij elke herhaling van hetzelfde commando
  dezelfde naam -- dat laatste is precies wat de agent nodig heeft om een
  opnieuw afgeleverd provision-commando als "die heb ik al" te herkennen.
  """
  @spec guest_name(Vps.t(), map()) :: String.t()
  def guest_name(%Vps{} = vps, %{guest_name_pattern: patroon} = node) when is_binary(patroon) do
    kort = short_vps_id(vps)

    patroon
    |> String.replace("{id}", kort)
    |> String.replace("{naam}", name_slug(vps))
    |> String.replace("{klant}", owner_slug(vps))
    |> String.replace("{node}", slug(node.name, "node"))
    |> String.trim("-")
    |> begrens_met_id(kort)
  end

  def guest_name(%Vps{} = vps, _node_zonder_patroon), do: guest_name(vps)

  @doc """
  De gastnaam zonder patroon: `{naam}-{id}`, met `vps` als de naam leeg is.
  """
  @spec guest_name(Vps.t()) :: String.t()
  def guest_name(%Vps{id: id, name: name}) do
    slug =
      (name || "")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9-]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 40)

    slug = if slug == "", do: "vps", else: slug
    short = id |> String.replace("-", "") |> String.slice(0, 8)
    "#{slug}-#{short}"
  end

  # Een hypervisor accepteert geen gastnaam langer dan 63 tekens, dus er moet
  # worden afgekapt. Maar NOOIT het unieke deel.
  #
  # Een eigenaar mag zijn eigen patroon kiezen en `{id}` is daarin verplicht,
  # maar die eis zegt niets over wat er ná het invullen overblijft: met
  # `{naam}-{klant}-{node}-{id}` en drie lange stukken valt precies het
  # achtervoegsel eraf. Wat overblijft is een naam die twee klanten kunnen
  # delen -- en de agent herkent zijn VM aan die naam. Dan neemt de tweede de
  # draaiende machine van de eerste over, wat de kritieke bevinding van juli
  # was.
  #
  # Daarom wordt er aan de voorkant geknipt en blijft het id achteraan staan.
  defp begrens_met_id(naam, _kort) when byte_size(naam) <= 63, do: naam

  defp begrens_met_id(naam, kort) do
    if String.contains?(naam, kort) do
      ruimte = 63 - String.length(kort) - 1

      voorkant =
        naam
        |> String.replace(kort, "")
        |> String.trim("-")
        |> String.slice(0, max(ruimte, 0))
        |> String.trim("-")

      if voorkant == "", do: kort, else: voorkant <> "-" <> kort
    else
      # Geen id in de naam: dat hoort niet te kunnen (de validatie eist hem),
      # maar afkappen zonder meer is hier het enige wat overblijft.
      String.slice(naam, 0, 63)
    end
  end

  defp short_vps_id(%Vps{id: id}), do: id |> String.replace("-", "") |> String.slice(0, 8)

  defp name_slug(%Vps{name: name}), do: slug(name, "vps")

  defp owner_slug(%Vps{owner_email: email}),
    do: slug(email && List.first(String.split(email, "@")), "klant")

  defp slug(nil, standaard), do: standaard

  defp slug(waarde, standaard) do
    schoon =
      waarde
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9-]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 40)

    if schoon == "", do: standaard, else: schoon
  end
end
