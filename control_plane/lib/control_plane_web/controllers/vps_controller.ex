defmodule ControlPlaneWeb.VpsController do
  @moduledoc """
  End-user VPS API: a registered user manages only the VPSes they own.

  Authenticated by `ControlPlaneWeb.Plugs.ApiAuth`, so `conn.assigns.current_user`
  is always present. Ownership is enforced on every read and on delete by scoping
  queries to `current_user.id`; a VPS belonging to someone else is indistinguishable
  from one that does not exist (404), never leaking its existence.

  `create` provisions on behalf of the current user (stamping `owner_id` and
  `owner_email` server-side — never from the request body) and accepts either a
  `region_id` or a human `region_code`.
  """
  use ControlPlaneWeb, :controller
  import ControlPlaneWeb.ApiResponse

  require Logger

  alias ControlPlane.Backups
  alias ControlPlane.Backups.VpsBackup
  alias ControlPlane.Clock
  alias ControlPlane.Credits
  alias ControlPlane.Fleet
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Package
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Idempotency
  alias ControlPlane.Provisioning
  alias ControlPlane.Repo
  alias ControlPlaneWeb.Fouten

  def index(conn, _params) do
    vpses =
      conn.assigns.current_user.id
      |> Fleet.list_vpses_for_owner()
      |> Enum.map(&vps_json/1)

    json(conn, %{vpses: vpses})
  end

  def show(conn, %{"id" => id}) do
    with {:ok, id} <- valid_id(id),
         %Vps{} = vps <- Fleet.get_vps_for_owner(conn.assigns.current_user.id, id) do
      json(conn, %{vps: vps_json(vps)})
    else
      anders -> Fouten.fout(conn, anders)
    end
  end

  def create(conn, params) do
    user = conn.assigns.current_user

    # Een bestelling die twee keer binnenkomt hoort één VPS op te leveren. De
    # client stuurt daarvoor een `Idempotency-Key`; zonder sleutel verandert er
    # niets aan het gedrag, want een oudere client mag hier niet op stuklopen.
    case Idempotency.claim(user.id, sleutel(conn), Idempotency.vps_create()) do
      {:ok, {:done, vps_id}} ->
        # Dit verzoek is al eerder gelukt. Hetzelfde antwoord teruggeven is het
        # hele punt: de klant heeft zijn VPS, hij heeft alleen het antwoord
        # gemist.
        json(conn, %{vps: vps_json(Fleet.get_vps_for_owner(user.id, vps_id))})

      {:error, :in_flight} ->
        error(conn, :conflict, "order_in_progress")

      {:error, :invalid_key} ->
        error(conn, :unprocessable_entity, "invalid_idempotency_key")

      {:ok, claim} ->
        bestel(conn, user, params, claim)
    end
  end

  # De claim is `{:claimed, rij}` met een sleutel, of `:zonder_sleutel`.
  defp bestel(conn, user, params, claim) do
    case maak_vps(conn, user, params) do
      {:gelukt, conn, vps_id} ->
        afronden(claim, vps_id)
        conn

      {:mislukt, conn} ->
        # Vrijgeven, zodat de klant het met dezelfde sleutel opnieuw kan
        # proberen. Blijven plakken zou hem buitensluiten van zijn eigen
        # bestelling.
        vrijgeven(claim)
        conn
    end
  end

  defp afronden({:claimed, rij}, vps_id), do: Idempotency.finish(rij, vps_id)
  defp afronden(:zonder_sleutel, _vps_id), do: :ok

  defp vrijgeven({:claimed, rij}), do: Idempotency.release(rij)
  defp vrijgeven(:zonder_sleutel), do: :ok

  # De sleutel zoals de client hem meestuurt. Alleen de header: een veld in de
  # body zou door een herhaalde submit van een formulier meekomen, en dan dekt
  # hij precies het geval niet af waarvoor hij bestaat.
  defp sleutel(conn) do
    case get_req_header(conn, "idempotency-key") do
      [waarde | _] when is_binary(waarde) -> String.trim(waarde)
      _ -> nil
    end
  end

  defp maak_vps(conn, user, params) do
    attrs = build_attrs(params)

    with :ok <- validate_provision_input(attrs),
         :ok <- immediate_delivery_consent(params),
         {:ok, region_id} <- resolve_region_id(params, attrs),
         attrs = Map.put(attrs, :region_id, region_id),
         %Package{} = pkg <- Fleet.package_for_specs(attrs.vcpu, attrs.ram_mb, attrs.disk_gb),
         price = package_price_cents(pkg),
         {:ok, charge} <- Credits.charge(user.id, price, "vps_charge", "VPS #{pkg.name}"),
         {:ok, %{vps: vps}} <-
           charge_safe_create(
             user,
             attrs |> Map.put(:package_id, pkg.id) |> Map.put(:withdrawal_waiver_at, Clock.now()),
             charge
           ),
         # The charge had to come first — the wallet is checked and debited before
         # anything is provisioned — so only now can it be told which machine it
         # paid for. Until this lands the entry is an orphan, which is exactly
         # what Credits.refund_orphan_charges/1 looks for.
         {:ok, _} <- Credits.attach_vps(charge, vps.id) do
      antwoord =
        conn
        |> put_status(:created)
        # Re-read rather than render the struct the transaction returned: that one
        # has no node or port forwards loaded, so create would answer with a null
        # endpoint for a VPS that has one, and disagree with show/index about the
        # same machine.
        |> json(%{vps: vps_json(Fleet.get_vps_for_owner(user.id, vps.id) || vps)})

      {:gelukt, antwoord, vps.id}
    else
      # `nil` betekent hier iets anders dan overal elders: niet "bestaat niet"
      # maar "er is geen pakket dat bij deze specificaties hoort". Vandaar een
      # eigen tak vóór de algemene afhandeling, die er een 404 van zou maken.
      nil ->
        {:mislukt, error(conn, :unprocessable_entity, "no_matching_package")}

      anders ->
        {:mislukt, Fouten.fout(conn, anders, changeset_code: "invalid_vps")}
    end
  end

  # Provision after the wallet was charged; refund if provisioning fails so a
  # failed create never leaves the customer debited.
  #
  # De afschrijving zelf gaat mee, niet alleen het bedrag. Terugbetalen is meer
  # dan een tegenboeking: de oorspronkelijke regel moet gemerkt worden, anders
  # blijft hij liggen als een verweesde afschrijving en betaalt
  # `Credits.refund_orphan_charges/1` hem tien minuten later nóg een keer. Dat
  # is op productie gebeurd.
  defp charge_safe_create(user, attrs, charge) do
    case Provisioning.create_vps_for_owner(user, attrs) do
      {:ok, _} = ok ->
        ok

      other ->
        refund_charge(charge)
        other
    end
  rescue
    # A raise after the wallet was debited (bug, changeset explosion, etc.) must
    # still refund, otherwise the customer is charged for a VPS they never got.
    e ->
      refund_charge(charge)
      reraise e, __STACKTRACE__
  catch
    # DBConnection pool timeouts surface as an :exit, not a rescue-able error.
    :exit, reason ->
      refund_charge(charge)
      exit(reason)
  end

  defp refund_charge(charge) do
    case Credits.refund_failed_charge(charge) do
      {:ok, _} ->
        :ok

      {:error, reden} ->
        # Niet stilhouden: de klant staat nu gedebiteerd voor een VPS die er niet
        # is. De sweeper pakt hem alsnog op -- de regel is niet gemerkt -- maar
        # dat duurt tien minuten en niemand weet het zonder deze regel.
        Logger.error("terugbetaling na een mislukte VPS-aanmaak mislukte: #{inspect(reden)}")
        :ok
    end
  end

  defp package_price_cents(%Package{price_monthly: price}) do
    ControlPlane.Money.to_cents(price)
  end

  def delete(conn, %{"id" => id}) do
    # Authorize first: only an owned VPS may be deleted. An unknown id, a bad id, or
    # someone else's VPS all collapse to 404 so ownership isn't leaked.
    with {:ok, id} <- valid_id(id),
         %Vps{} <- Fleet.get_vps_for_owner(conn.assigns.current_user.id, id),
         {:ok, %{vps: vps}} <- Provisioning.delete_vps(id) do
      conn
      |> put_status(:accepted)
      |> json(%{vps: vps_json(vps)})
    else
      anders -> Fouten.fout(conn, anders)
    end
  end

  @doc """
  A VPS's restore points, newest first.

  Failures are listed too. "The last three nightly backups failed" is the single
  most useful thing this endpoint can say, and it can only say it if failures
  appear.
  """
  def backups(conn, %{"id" => id}) do
    with {:ok, uuid} <- valid_id(id),
         %Vps{} <- Fleet.get_vps_for_owner(conn.assigns.current_user.id, uuid) do
      json(conn, %{backups: Enum.map(Backups.list_for_vps(uuid), &backup_json/1)})
    else
      anders -> Fouten.fout(conn, anders)
    end
  end

  defp backup_json(%VpsBackup{} = backup) do
    %{
      id: backup.id,
      status: backup.status,
      size_bytes: backup.size_bytes,
      started_at: backup.started_at,
      finished_at: backup.finished_at,
      # Deliberately not the volid: it is the node's internal handle on a file,
      # of no use to a customer and no business of theirs.
      error: if(backup.status == :failed, do: backup.error)
    }
  end

  @doc """
  Start nu een back-up van een eigen VPS, buiten het nachtelijke schema om.

  Het moment vóór iets engs -- een upgrade, een configuratie die je zelf niet
  vertrouwt -- is precies wanneer je er een wilt, en dan is "vannacht" geen
  antwoord.
  """
  def backup_now(conn, %{"id" => id}) do
    with {:ok, uuid} <- valid_id(id),
         %Vps{} = vps <- Fleet.get_vps_for_owner(conn.assigns.current_user.id, uuid),
         {:ok, backup} <- Backups.start_on_demand(vps) do
      conn |> put_status(:accepted) |> json(%{backup: backup_json(backup)})
    else
      anders -> Fouten.fout(conn, anders)
    end
  end

  @doc """
  Rolls an owned VPS back to one of its own restore points.

  Destructive: everything written since that backup is gone. The VPS goes to
  `:restoring` until the node reports back, which blocks every other action on it
  — including a second restore over the same disk.
  """
  def restore(conn, %{"id" => id, "backup_id" => backup_id}) do
    with {:ok, uuid} <- valid_id(id),
         {:ok, backup_uuid} <- valid_id(backup_id),
         %Vps{} = vps <- Fleet.get_vps_for_owner(conn.assigns.current_user.id, uuid),
         {:ok, restoring} <- Backups.restore(vps, backup_uuid) do
      conn |> put_status(:accepted) |> json(%{vps: vps_json(restoring)})
    else
      anders -> Fouten.fout(conn, anders)
    end
  end

  @doc "Starts an owned, stopped VPS. 404 if not owned (existence is never leaked)."
  def start(conn, params), do: power(conn, params, &Provisioning.start_vps/1)

  @doc "Stops an owned, running VPS. 404 if not owned."
  def stop(conn, params), do: power(conn, params, &Provisioning.stop_vps/1)

  @doc """
  Hernoemt een eigen VPS.

  Alleen het label. De naam waaronder de gast op de hypervisor staat blijft wat
  hij was -- daar herkent de agent zijn machine aan.
  """
  def update(conn, %{"id" => id, "name" => naam}) when is_binary(naam) do
    with {:ok, uuid} <- valid_id(id),
         %Vps{} = vps <- Fleet.get_vps_for_owner(conn.assigns.current_user.id, uuid),
         {:ok, hernoemd} <- Fleet.rename_vps(vps, naam) do
      json(conn, %{vps: vps_json(hernoemd)})
    else
      anders -> Fouten.fout(conn, anders, changeset_code: "invalid_vps")
    end
  end

  def update(conn, _params), do: error(conn, :unprocessable_entity, "invalid_vps")

  @doc """
  Herstart een eigen, draaiende VPS. 404 als hij niet van jou is.

  Van binnenuit: het besturingssysteem wordt gevraagd af te sluiten en komt weer
  op. Wie de stekker eruit wil trekken doet stop en daarna start -- dat is een
  andere handeling en hoort er ook als een andere handeling uit te zien.
  """
  def reboot(conn, params), do: power(conn, params, &Provisioning.reboot_vps/1)

  defp power(conn, %{"id" => id}, transition) do
    with {:ok, id} <- valid_id(id),
         %Vps{} <- Fleet.get_vps_for_owner(conn.assigns.current_user.id, id),
         {:ok, _} <- transition.(id) do
      json(conn, %{detail: "ok"})
    else
      anders -> Fouten.fout(conn, anders)
    end
  end

  # --- helpers --------------------------------------------------------------

  # Ownership is deliberately omitted here: `Provisioning.create_vps_for_owner/2`
  # stamps `owner_id`/`owner_email` from the authenticated session and drops any
  # owner fields a caller might try to smuggle in, so spoofing is impossible.
  # Bound caller-supplied provision input so a request can't carry an absurd
  # number/size of SSH keys or a giant cloud-init blob (targets the user's own VM,
  # but unbounded input is unbounded work). Limits are generous for real use.
  # Een consument heeft veertien dagen bedenktijd. Die vervalt alleen als hij
  # uitdrukkelijk om onmiddellijke levering vraagt en erkent daarmee zijn
  # herroepingsrecht te verliezen (art. 6:230p sub f BW). Een VPS staat binnen
  # twee minuten te draaien, dus zonder die bevestiging zouden we veertien dagen
  # lang een dienst leveren die de klant nog kosteloos kan terugdraaien.
  #
  # Weigeren gebeurt hier, vóór Credits.charge: anders is de klant al gedebiteerd
  # voor een bestelling die we alsnog afwijzen.
  defp immediate_delivery_consent(params) do
    case params["immediate_delivery_consent"] do
      true -> :ok
      "true" -> :ok
      _ -> {:error, :no_delivery_consent}
    end
  end

  defp validate_provision_input(%{
         vcpu: vcpu,
         ram_mb: ram_mb,
         disk_gb: disk_gb,
         ssh_keys: ssh,
         cloud_init: ci
       }) do
    with :ok <- valid_spec(vcpu, ram_mb, disk_gb), do: bounded_input(ssh, ci)
  end

  # Reject an out-of-bounds spec up front (matches Vps.validate_spec) so an
  # invalid request fails with a clear `invalid_vps` rather than slipping through
  # to package pricing and surfacing as `no_matching_package`.
  defp valid_spec(vcpu, ram_mb, disk_gb) do
    if valid_spec_field?(vcpu, 64) and valid_spec_field?(ram_mb, 262_144) and
         valid_spec_field?(disk_gb, 8_192),
       do: :ok,
       else: {:error, :invalid_spec}
  end

  defp bounded_input(ssh, cloud_init) do
    cond do
      not is_list(ssh) -> {:error, :input_too_large}
      length(ssh) > 20 -> {:error, :input_too_large}
      Enum.any?(ssh, &oversized_key?/1) -> {:error, :input_too_large}
      encoded_size(cloud_init) > 16_384 -> {:error, :input_too_large}
      true -> :ok
    end
  end

  defp oversized_key?(key), do: not is_binary(key) or byte_size(key) > 4096

  defp valid_spec_field?(v, max) when is_integer(v), do: v > 0 and v <= max
  defp valid_spec_field?(_v, _max), do: false

  defp encoded_size(term) do
    case Jason.encode(term) do
      {:ok, json} -> byte_size(json)
      _ -> 1_000_000
    end
  end

  # Region is added after this: choosing it automatically needs the spec, so the
  # spec has to be built (and validated) first.
  defp build_attrs(params) do
    %{
      name: params["name"],
      vcpu: params["vcpu"],
      ram_mb: params["ram_mb"],
      disk_gb: params["disk_gb"],
      template_id: default_template_id(),
      ssh_keys: params["ssh_keys"] || [],
      cloud_init: allowed_cloud_init(params["cloud_init"])
      # SECURITY: never accept ip_config/ip_address from the self-service body. It
      # is a staff-only override (admin controller sets it); letting a customer set
      # it bypasses IpPool.allocate — they could pin a co-tenant's or the gateway's
      # IP (conflict/MITM) and, because ip_address stays nil, slip past the
      # vpses_active_node_ip_uidx uniqueness backstop. Force allocation via the pool.
    }
  end

  # An allow-list, not a size cap. The agent reads exactly two cloud-init keys;
  # everything else was stored in the command payload forever and then ignored,
  # which is retention without a purpose. Anything not named here is dropped.
  @cloud_init_keys ~w(user password)
  @max_cloud_init_value 128

  defp allowed_cloud_init(%{} = cloud_init) do
    cloud_init
    |> Map.take(@cloud_init_keys)
    |> Map.filter(fn {_key, value} ->
      is_binary(value) and value != "" and byte_size(value) <= @max_cloud_init_value
    end)
  end

  defp allowed_cloud_init(_), do: %{}

  defp resolve_region_id(%{"region_id" => region_id}, _attrs) when is_binary(region_id) do
    case valid_id(region_id) do
      {:ok, id} -> open_regio(Repo.get(Region, id))
      :error -> {:error, :region_not_found}
    end
  end

  defp resolve_region_id(%{"region_code" => region_code}, _attrs) when is_binary(region_code) do
    open_regio(Fleet.region_by_code(region_code))
  end

  # No preference: Bunk picks. A named region that does not exist is still an
  # error — only the *absence* of one means "anywhere", so a typo'd region code
  # cannot quietly land a customer on the other side of the country.
  defp resolve_region_id(_params, attrs), do: Fleet.auto_region_id(attrs)

  # Een gesloten locatie staat niet in de lijst die de klant te zien krijgt,
  # maar dat is geen slot. Wie de code zelf meestuurt -- een oud tabblad, een
  # script, iemands eigen client -- kwam er gewoon langs, en kreeg een draaiende
  # machine in een regio die bewust dicht stond.
  #
  # Het wrange was welke kant beschermd was: `Fleet.auto_region_id/1` slaat een
  # uitgeschakelde regio wél over, met een comment erbij waarom. Alleen de
  # BEWUSTE keuze van een klant ging er ongehinderd langs. Gemeten op productie
  # op 23 september: ehv stond dicht, en een bestelling met `region_code: "ehv"`
  # gaf 201 en een provisionende VPS.
  #
  # Het beheerpad (`Admin.VpsController`) houdt dit bewust niet tegen: een
  # locatie sluiten betekent "geen nieuwe klantbestellingen", niet "personeel
  # kan er niets meer neerzetten".
  # De reden heet naar de kolom (`enabled`), de code naar wat de klant leest.
  # Dat onderscheid staat in de tabel zelf ook zo -- `:already_running` heet
  # naar buiten `backup_already_running` -- en toen ik het hier door elkaar
  # haalde gaf het systeem een 500 met "voeg hem toe aan ControlPlaneWeb.Fouten"
  # in plaats van er stilletjes iets van te maken. Precies waarvoor die tabel er
  # is.
  defp open_regio(%Region{enabled: true, id: id}), do: {:ok, id}
  defp open_regio(%Region{}), do: {:error, :region_disabled}
  defp open_regio(nil), do: {:error, :region_not_found}

  defp valid_id(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> :error
    end
  end

  defp valid_id(_), do: :error

  defp default_template_id do
    Application.get_env(:control_plane, :default_template_id, 9000)
  end

  # Wat dit antwoord over een VPS zegt, hangt af van wat de aanroeper toevallig
  # had geladen. Dat is geen detail: `region`, `public_host`, `ssh_port` en
  # `port_forwards` vielen allemaal terug op `nil` of `[]` zodra hun associatie
  # er niet in zat, en dat leest als "deze VPS heeft er geen" in plaats van
  # "niemand heeft het opgehaald".
  #
  # Zichtbaar bij herstellen, verwijderen en hernoemen: die geven de struct door
  # die de context teruggaf, zonder preload. De regio verdween daar uit het
  # antwoord. Geen klant heeft het gemerkt omdat het scherm die antwoorden
  # negeert en opnieuw ophaalt -- maar een antwoord dat afhangt van de weg
  # erheen is een antwoord waar je niet op kunt bouwen.
  #
  # `Repo.preload/2` is gratis voor wat al geladen is, dus de paden die het goed
  # deden betalen hier niets voor. `package_json/1` deed dit al op zijn eigen
  # manier; nu doet de rest het ook.
  defp vps_json(%Vps{} = vps) do
    vps = Repo.preload(vps, [:region, :node, :port_forwards])

    %{
      id: vps.id,
      name: vps.name,
      status: vps.status,
      region: region_code(vps),
      provider_vm_id: vps.provider_vm_id,
      ip_address: vps.ip_address,
      vcpu: vps.vcpu,
      ram_mb: vps.ram_mb,
      disk_gb: vps.disk_gb,
      inserted_at: vps.inserted_at,
      # Where a customer connects. Null when the node this VPS landed on has no
      # public address yet: the honest answer, and the one the UI needs in order
      # to say "console only" instead of printing an address that goes nowhere.
      public_host: public_host(vps),
      ssh_port: ssh_port(vps),
      port_forwards: port_forwards_json(vps),
      # De prijs hoort van de server te komen. De frontend leidde hem af uit de
      # specificaties door een pakket in de catalogus te zoeken, en verzon bij
      # geen match een pakket van EUR 0,00 -- waarna de klant las dat zijn
      # machine gratis was zodra een pakket uit het aanbod ging. Wat iemand
      # betaalt is een feit van de server, en `package_id` staat op de rij.
      package: package_json(vps)
    }
  end

  defp package_json(%Vps{package_id: nil}), do: nil

  # Het pakket is uit de catalogus gehaald. Dat is iets anders dan gratis: `null`
  # laat het scherm "onbekend" tonen in plaats van een bedrag dat niet klopt.
  defp package_json(%Vps{package: nil}), do: nil

  defp package_json(%Vps{package: %Package{} = pkg}), do: pakket_velden(pkg)

  # De relatie is niet geladen. Dat overkomt de paden die een VPS teruggeven die
  # ze zelf net hebben aangemaakt of gewijzigd in plaats van hem op te halen; één
  # query is daar niets, en het alternatief -- `nil` teruggeven -- zou betekenen
  # dat de prijs verdwijnt zodra iemand zijn VPS hernoemt.
  defp package_json(%Vps{package_id: id}) do
    case Repo.get(Package, id) do
      nil -> nil
      pkg -> pakket_velden(pkg)
    end
  end

  defp pakket_velden(%Package{} = pkg) do
    %{
      id: pkg.id,
      name: pkg.name,
      cpu_cores: pkg.cpu_cores,
      ram_gb: pkg.ram_gb,
      disk_gb: pkg.disk_gb,
      bandwidth_mbit: pkg.bandwidth_mbit,
      price_monthly: pkg.price_monthly
    }
  end

  defp public_host(%Vps{node: %Node{public_host: host}}), do: host
  defp public_host(%Vps{}), do: nil

  defp ssh_port(%Vps{port_forwards: forwards}) when is_list(forwards) do
    Enum.find_value(forwards, fn f -> if f.target_port == 22, do: f.public_port end)
  end

  defp ssh_port(%Vps{}), do: nil

  defp port_forwards_json(%Vps{port_forwards: forwards}) when is_list(forwards) do
    Enum.map(forwards, fn f ->
      %{
        public_port: f.public_port,
        target_port: f.target_port,
        protocol: f.protocol,
        purpose: f.purpose
      }
    end)
  end

  defp port_forwards_json(%Vps{}), do: []

  defp region_code(%Vps{region: %{code: code}}), do: code
  defp region_code(%Vps{}), do: nil
end
