defmodule ControlPlane.FleetReportedCapacityTest do
  @moduledoc """
  De tweede horde bij plaatsing: wat de agent zelf nog vrij ziet.

  `available_*` is van de scheduler en beschermt tegen overboeken door
  gelijktijdige bestellingen. Maar dat cijfer begint bij het totaal van de
  machine en weet niets van wat daar al op draaide voordat Bunk er was. Op de
  eerste node scheelde dat zeven gigabyte: de scheduler dacht 10,8 GB vrij te
  hebben terwijl de agent er 0,9 meldde. Een bestelling van 8 GB zou daar
  geplaatst zijn — op de machine waar de control plane zelf op draait.
  """
  use ControlPlane.DataCase, async: true

  alias ControlPlane.Fleet.Liveness
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Reservation
  alias ControlPlane.Fleet.Scheduler
  alias ControlPlane.Repo

  defp regio,
    do: Repo.insert!(%Region{code: "r-#{System.unique_integer([:positive])}", name: "Regio"})

  defp node(r, attrs) do
    Repo.insert!(
      struct(
        %Node{
          name: "node-#{System.unique_integer([:positive])}",
          region_id: r.id,
          hypervisor: :proxmox,
          status: :online,
          last_heartbeat_at: ControlPlane.Clock.now(),
          total_vcpu: 4,
          total_ram_mb: 11_843,
          total_disk_gb: 94,
          available_vcpu: 4,
          available_ram_mb: 11_843,
          available_disk_gb: 94
        },
        attrs
      )
    )
  end

  defp verzoek(r, ram_mb),
    do: %{region_id: r.id, vcpu: 1, ram_mb: ram_mb, disk_gb: 20}

  test "een node die minder meldt dan de boekhouding denkt, wordt overgeslagen" do
    r = regio()
    node(r, %{reported_avail_ram_mb: 900, reported_avail_vcpu: 4, reported_avail_disk_gb: 70})

    # De boekhouding zegt 11.843 MB vrij, de agent zegt 900. Acht gigabyte past
    # in het eerste getal en niet in het tweede, en dat tweede is de machine.
    assert {:error, :no_capacity} = Scheduler.place(verzoek(r, 8192))
  end

  test "wat in beide past wordt gewoon geplaatst" do
    r = regio()

    n =
      node(r, %{reported_avail_ram_mb: 6211, reported_avail_vcpu: 3, reported_avail_disk_gb: 70})

    assert {:ok, %{node: gekozen}} = Scheduler.place(verzoek(r, 1024))
    assert gekozen.id == n.id
  end

  test "een node die nog niets gemeld heeft blijft bruikbaar" do
    r = regio()
    # nil betekent "geen informatie", niet "geen ruimte". Een node blokkeren op
    # een ontbrekend cijfer zou een werkende machine onbruikbaar maken — precies
    # de fout die een NULL met een eigen betekenis hier eerder aanrichtte.
    n =
      node(r, %{reported_avail_ram_mb: nil, reported_avail_vcpu: nil, reported_avail_disk_gb: nil})

    assert {:ok, %{node: gekozen}} = Scheduler.place(verzoek(r, 2048))
    assert gekozen.id == n.id
  end

  test "de scheduler kiest de node die er in werkelijkheid ruimte voor heeft" do
    r = regio()
    # Beide zien er in de boekhouding identiek uit; alleen wat de agents melden
    # verschilt. Zonder de tweede horde zou de keuze een muntworp zijn.
    vol =
      node(r, %{reported_avail_ram_mb: 512, reported_avail_vcpu: 1, reported_avail_disk_gb: 70})

    leeg =
      node(r, %{reported_avail_ram_mb: 9000, reported_avail_vcpu: 4, reported_avail_disk_gb: 70})

    assert {:ok, %{node: gekozen}} = Scheduler.place(verzoek(r, 4096))
    assert gekozen.id == leeg.id
    refute gekozen.id == vol.id
  end

  defp heartbeat(n, extra \\ %{}) do
    Liveness.mark_online_heartbeat(
      n,
      Map.merge(
        %{
          "total_vcpu" => 4,
          "total_ram_mb" => 11_843,
          "total_disk_gb" => 94,
          "reported_avail_vcpu" => 2,
          "reported_avail_ram_mb" => 3651,
          "reported_avail_disk_gb" => 70
        },
        extra
      )
    )
  end

  defp gereserveerd(n, ram_mb, status) do
    Repo.insert!(%Reservation{
      node_id: n.id,
      vcpu: 1,
      ram_mb: ram_mb,
      disk_gb: 10,
      status: status
    })
  end

  test "de heartbeat leidt de vrije ruimte af in plaats van hem te raden" do
    # available_* begon ooit bij het totaal van de machine en werd daarna alleen
    # nog verlaagd bij een reservering. Op een host die ook iets anders draait is
    # dat vanaf de eerste seconde onwaar, en omdat het maar een keer werd gezet
    # corrigeerde geen enkele heartbeat het ooit nog.
    r = regio()
    n = node(r, %{available_ram_mb: 10_819})

    {:ok, bijgewerkt} = heartbeat(n)

    assert bijgewerkt.reported_avail_ram_mb == 3651
    assert bijgewerkt.available_ram_mb == 3651
  end

  test "ruimte die al aan een lopende bestelling is beloofd telt niet mee" do
    # Dit is de eigenschap waar het echt om gaat, en die deze test bewaakte toen
    # available_* nog onaangeroerd bleef: een VPS die wordt aangemaakt draait nog
    # niet, dus de agent telt zijn geheugen nog als vrij. Zonder aftrek zou
    # dezelfde ruimte twee keer verkocht kunnen worden.
    r = regio()
    n = node(r, %{available_ram_mb: 10_819})
    gereserveerd(n, 1024, :held)

    {:ok, bijgewerkt} = heartbeat(n)

    assert bijgewerkt.available_ram_mb == 3651 - 1024
  end

  test "een afgeronde of losgelaten reservering telt niet dubbel" do
    # Een draaiende VPS zit al in wat de agent meldt; hem hier nog eens aftrekken
    # zou de node ten onrechte voller maken dan hij is.
    r = regio()
    n = node(r, %{available_ram_mb: 10_819})
    gereserveerd(n, 2048, :committed)
    gereserveerd(n, 4096, :released)

    {:ok, bijgewerkt} = heartbeat(n)

    assert bijgewerkt.available_ram_mb == 3651
  end

  test "een node die leeg meldt terwijl er VPS'en op staan, krijgt niet meer dan er over is" do
    # Een node die niet van ons is, kon altijd "alles vrij" melden en won zo elke
    # plaatsing. Wat er aan VPS'en op staat weet de control plane zelf.
    r = regio()
    n = node(r, %{available_ram_mb: 10_819})
    gereserveerd(n, 8192, :committed)

    {:ok, bijgewerkt} = heartbeat(n, %{"reported_avail_ram_mb" => 11_843})

    assert bijgewerkt.available_ram_mb == 11_843 - 8192
  end

  test "een agent die niets meldt houdt de bestaande boekhouding" do
    # Een oudere agent kent reported_avail_* niet. Die node op nul zetten zou hem
    # uit de roulatie halen voor iets wat hij niet verkeerd doet.
    r = regio()
    n = node(r, %{available_ram_mb: 5000})

    {:ok, bijgewerkt} =
      Liveness.mark_online_heartbeat(n, %{
        "total_vcpu" => 4,
        "total_ram_mb" => 11_843,
        "total_disk_gb" => 94
      })

    assert bijgewerkt.available_ram_mb == 5000
  end

  test "een plaatsing die tijdens de heartbeat commit wordt niet overschreven" do
    # De reden dat de heartbeat de node onder slot leest en schrijft. Zonder dat
    # leest hij eerst de lopende reserveringen, commit een plaatsing daar precies
    # tussen, en schrijft de heartbeat daarna de afboeking weg -- waarna dezelfde
    # ruimte een tweede keer verkocht kan worden.
    #
    # Hier wordt die volgorde nagebootst: de reservering bestaat al voordat de
    # heartbeat schrijft, dus hij moet in de uitkomst zitten.
    r = regio()
    n = node(r, %{available_ram_mb: 10_819})
    gereserveerd(n, 2048, :held)

    {:ok, bijgewerkt} = heartbeat(n)

    refute bijgewerkt.available_ram_mb == 3651,
           "de reservering is weggevallen: deze ruimte kan nu twee keer verkocht worden"

    assert bijgewerkt.available_ram_mb == 3651 - 2048
  end

  test "een heartbeat met een verouderde node ondermijnt een afsluiting niet" do
    # De node komt bij het verzoek binnen zoals hij op dat moment in de database
    # stond. Sluit een beheerder hem daarna af -- of doet een mislukte bestelling
    # dat automatisch -- dan mag deze heartbeat die afsluiting niet overschrijven.
    # Met de oude waarde zou een node die je juist leeg wilt hebben weer vollopen.
    r = regio()
    n = node(r, %{status: :online})

    # De verse stand: afgesloten. `n` is nog de oude.
    Repo.update!(Ecto.Changeset.change(n, status: :draining))

    {:ok, bijgewerkt} = heartbeat(n)

    assert bijgewerkt.status == :draining,
           "de heartbeat heeft de afsluiting overschreven met de verouderde status"
  end

  test "een node die offline stond komt wel weer online" do
    # De andere kant: een node die weer aanklopt hoort weer mee te doen.
    r = regio()
    n = node(r, %{status: :offline})

    {:ok, bijgewerkt} = heartbeat(n)

    assert bijgewerkt.status == :online
  end

  test "een agent zonder zicht op zijn hypervisor levert geen plaatsbare ruimte op" do
    r = regio()
    n = node(r, %{available_ram_mb: 10_819})

    {:ok, bijgewerkt} = heartbeat(n, %{"capacity_error" => "geen verbinding"})

    assert bijgewerkt.available_ram_mb == 0
    assert bijgewerkt.reported_avail_ram_mb == 0
  end
end
