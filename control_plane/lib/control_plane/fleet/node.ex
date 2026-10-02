defmodule ControlPlane.Fleet.Node do
  @moduledoc """
  A physical/virtual host enrolled in the fleet that can run VPSes. Nodes report
  their available capacity via heartbeats and are scheduled against by the
  `ControlPlane.Fleet.Scheduler`.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias ControlPlane.Accounts.User
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Net

  # Sane upper bounds on a single node's advertised capacity. A node's
  # totals come from its untrusted agent; without a ceiling a hostile community
  # node could advertise absurd capacity to always look least-loaded and win every
  # placement, drawing other tenants' VPSes onto hardware whose operator has full
  # console/disk access. Generous enough for any real host — this only clamps
  # obviously-bogus values.
  @max_total_vcpu 256
  @max_total_ram_mb 1_048_576
  @max_total_disk_gb 65_536

  @typedoc "A persisted node row."
  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "nodes" do
    field :name, :string

    field :status, Ecto.Enum, values: [:pending, :online, :draining, :offline], default: :pending
    field :hypervisor, Ecto.Enum, values: [:proxmox, :esxi, :incus], default: :proxmox

    # Total advertised capacity of the node.
    field :total_vcpu, :integer
    field :total_ram_mb, :integer
    field :total_disk_gb, :integer

    # Live, currently-available capacity (decremented by the scheduler on placement
    # and refreshed by heartbeats).
    field :available_vcpu, :integer
    field :available_ram_mb, :integer
    field :available_disk_gb, :integer

    field :last_heartbeat_at, :utc_datetime

    # De build die deze node draait, zoals de agent hem zelf meldt. nil = een
    # agent die nog van voor het versiestempel is.
    field :agent_version, :string

    # Waarom deze node geen capaciteit kon melden, in de woorden van de agent.
    # Leeg is het normale geval; staat hier iets, dan leeft de agent maar komt
    # hij niet bij zijn hypervisor -- en plaatst de scheduler er niets.
    field :capacity_error, :string

    # Iets over het VPS-netwerk van deze node dat een operator wil weten, in de
    # woorden van de agent. Anders dan `capacity_error` houdt dit de node niet
    # uit de verkoop: het is een vermoeden, geen vaststelling. Leeg is het
    # normale geval, en de agent haalt hem zelf weg zodra het is rechtgezet.
    field :network_note, :string

    # Waarom deze node dicht staat voor nieuwe VPS'en, als het systeem hem zelf
    # heeft afgesloten. Leeg bij een node die een beheerder met de hand sloot:
    # die weet zelf waarom.
    field :drain_reason, :string

    # Instellingen die de eigenaar vanuit het dashboard beheert. De agent haalt
    # ze op bij zijn heartbeat; NULL betekent "niet ingesteld", en dan houdt hij
    # wat er lokaal in zijn service-bestand staat.
    field :offer_vcpu, :integer
    field :offer_ram_mb, :integer
    field :offer_disk_gb, :integer
    field :vmid_min, :integer
    field :vmid_max, :integer
    field :vcpu_oversubscribe, :integer
    field :guest_name_pattern, :string

    # Wat de agent als vrij meldt. Los van available_*, dat van de scheduler is:
    # deze cijfers kennen ook wat er op de machine draait buiten Bunk om. nil =
    # nog niets gemeld; de scheduler slaat de eis dan over.
    field :reported_avail_vcpu, :integer
    field :reported_avail_ram_mb, :integer
    field :reported_avail_disk_gb, :integer
    field :enroll_token_hash, :string
    field :agent_token_hash, :string
    field :public_key, :string
    # De kostenplaats: welk e-mailadres aan deze node hangt. Losstaand van
    # `owner`, dat zegt wie hem beheert.
    field :owner_email, :string

    # Per-node VPS network (optional; nil = use the global default range).
    #
    # Bridge en VLAN stonden hier eerst niet: die waren agent-lokaal, want het
    # control plane heeft alleen de IP-range nodig om adressen uit te delen die
    # niet botsen. Het gevolg was dat de eigenaar van een node de rest van zijn
    # instellingen in het dashboard zag staan en juist deze twee alleen kon
    # wijzigen door op die machine in te loggen. nil = niet ingesteld: de agent
    # houdt dan wat in zijn eigen config staat.
    field :vps_bridge, :string
    field :vps_vlan, :integer
    field :vps_gateway, :string
    field :vps_cidr_prefix, :integer
    field :vps_range_start, :string
    field :vps_range_end, :string

    # Where customers reach this node's VPSes from the internet, and the port
    # range its operator has forwarded here. nil public_host means "nowhere yet",
    # which is the honest state of a node on a home connection — the UI has to be
    # able to say that rather than print a private address and hope.
    field :public_host, :string
    field :public_port_start, :integer
    field :public_port_end, :integer

    belongs_to :region, Region

    # Wie deze node beheert. Alleen de eigenaar mag de instellingen ervan
    # wijzigen; een beheerder wijst het eigenaarschap toe of draagt het over.
    # nil = nog niemand, bijvoorbeeld bij een node die met een beheerderstoken is
    # ingeschreven.
    belongs_to :owner, User, foreign_key: :owner_id

    timestamps(type: :utc_datetime)
  end

  @settings_fields [
    :vps_bridge,
    :vps_vlan,
    :offer_vcpu,
    :offer_ram_mb,
    :offer_disk_gb,
    :vmid_min,
    :vmid_max,
    :vcpu_oversubscribe,
    :guest_name_pattern
  ]

  @doc "De instellingen die de eigenaar van een node vanuit het dashboard beheert."
  @spec settings_fields() :: [atom()]
  def settings_fields, do: @settings_fields

  # Plaatshouders die in een naampatroon gebruikt mogen worden. `{id}` is
  # verplicht en de rest is smaak -- zie de validatie hieronder voor waarom.
  @placeholders ~w({id} {naam} {klant} {node})

  @doc """
  Changeset voor de instellingen die de eigenaar mag wijzigen.

  Bewust los van `changeset/2`: die cast ook velden die van de agent en de
  scheduler zijn (capaciteit, status, tokens). Een eigenaar hoort daar niet bij
  te kunnen, ook niet per ongeluk via een veld dat hij meestuurt.
  """
  @spec settings_changeset(t(), map(), [integer()]) :: Ecto.Changeset.t()
  def settings_changeset(node, attrs, template_ids \\ []) do
    node
    |> cast(attrs, @settings_fields)
    |> validate_number(:offer_vcpu, greater_than_or_equal_to: 0)
    |> validate_number(:offer_ram_mb, greater_than_or_equal_to: 0)
    |> validate_number(:offer_disk_gb, greater_than_or_equal_to: 0)
    # Meer dan 32 vCPU per core is geen instelling meer maar een vergissing.
    |> validate_number(:vcpu_oversubscribe,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 32
    )
    |> validate_number(:vmid_min,
      greater_than_or_equal_to: 100,
      less_than_or_equal_to: 999_999_999
    )
    |> validate_number(:vmid_max,
      greater_than_or_equal_to: 100,
      less_than_or_equal_to: 999_999_999
    )
    |> validate_vmid_range(template_ids)
    |> validate_guest_name_pattern()
    |> validate_bridge()
    # 0 is untagged en een geldige keuze; 4095 is gereserveerd.
    |> validate_number(:vps_vlan, greater_than_or_equal_to: 0, less_than_or_equal_to: 4094)
  end

  # Dezelfde eis als de agent stelt voordat hij een bridge in de net0-regel zet
  # (safeBridge): alleen letters en cijfers. Een naam met een komma of een
  # gelijkteken erin zou daar extra opties worden in plaats van een bridge, en
  # een naam die de agent toch weigert levert een node op die stil niets doet.
  # Vijftien tekens is wat Linux maximaal aan een interfacenaam geeft.
  defp validate_bridge(changeset) do
    changeset
    |> validate_format(:vps_bridge, ~r/^[a-zA-Z0-9]+$/,
      message: "mag alleen letters en cijfers bevatten (bijvoorbeeld vmbr2)"
    )
    |> validate_length(:vps_bridge, max: 15)
  end

  defp validate_vmid_range(changeset, template_ids) do
    min = get_field(changeset, :vmid_min)
    max = get_field(changeset, :vmid_max)

    # Alle templates waarmee besteld kan worden, niet alleen de standaard: een
    # pakket mag een eigen template aanwijzen, en een bereik dat dáár overheen
    # loopt levert dezelfde storing op.
    gereserveerd =
      [Application.get_env(:control_plane, :default_template_id, 9000) | template_ids]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    botsing = min && max && Enum.find(gereserveerd, &(&1 >= min and &1 <= max))

    cond do
      is_nil(min) != is_nil(max) ->
        add_error(changeset, :vmid_max, "geef een begin en een eind, of geen van beide")

      is_nil(min) ->
        changeset

      min > max ->
        add_error(changeset, :vmid_max, "moet minstens zo hoog zijn als het laagste nummer")

      # Zou een template in het bereik vallen, dan komt de agent daar ooit aan en
      # overschrijft hij zijn eigen bron.
      botsing ->
        add_error(changeset, :vmid_min, "dit bereik bevat template #{botsing}")

      true ->
        changeset
    end
  end

  # De naam van een gast op de hypervisor moet uniek zijn: de agent gebruikt hem
  # om te herkennen of hij een machine al heeft aangemaakt. Stond daar ooit
  # alleen de door de klant gekozen naam in, dan namen twee klanten met dezelfde
  # naam op een node elkaars draaiende VM over. Daarom is `{id}` verplicht en is
  # dit geen vrij tekstveld.
  defp validate_guest_name_pattern(changeset) do
    case get_change(changeset, :guest_name_pattern) do
      nil -> changeset
      "" -> put_change(changeset, :guest_name_pattern, nil)
      patroon -> check_pattern(changeset, patroon)
    end
  end

  defp check_pattern(changeset, patroon) do
    rest = Regex.replace(~r/\{[a-z]+\}/, patroon, "")

    cond do
      not String.contains?(patroon, "{id}") ->
        add_error(
          changeset,
          :guest_name_pattern,
          "moet {id} bevatten, anders zijn twee VPS'en niet uit elkaar te houden"
        )

      onbekend = eerste_onbekende(patroon) ->
        add_error(
          changeset,
          :guest_name_pattern,
          "#{onbekend} bestaat niet; gebruik #{Enum.join(@placeholders, ", ")}"
        )

      not Regex.match?(~r/^[a-z0-9-]*$/, rest) ->
        add_error(
          changeset,
          :guest_name_pattern,
          "gebruik alleen kleine letters, cijfers en streepjes rond de plaatshouders"
        )

      String.length(patroon) > 100 ->
        add_error(changeset, :guest_name_pattern, "is te lang")

      true ->
        changeset
    end
  end

  defp eerste_onbekende(patroon) do
    ~r/\{[a-z]+\}/
    |> Regex.scan(patroon)
    |> List.flatten()
    |> Enum.find(&(&1 not in @placeholders))
  end

  @doc """
  Beperkt een query tot de nodes waarvan de capaciteit gefactureerd mag worden.

  Drie voorwaarden, en de derde is er niet altijd geweest. Een node is
  factureerbaar als hij `:online` staat, als we hem sinds `cutoff` hebben
  gehoord, én als hij zijn hypervisor kan bevragen.

  Die laatste is een reparatie van een bijwerking die niemand had opgeschreven.
  Vóór `capacity_error` bestond, viel een node waarvan de hypervisor-API
  onbereikbaar was vanzelf na twee minuten offline en stopte de facturatie
  daarmee ook. Toen de agent bij zo'n storing een heartbeat mét foutmelding ging
  sturen -- om de goede reden dat stilte dubbelzinnig is -- bleef de node
  `:online` met een verse `last_heartbeat_at`, en bleef de klant dus betalen
  voor machines waarvan niemand meer kon zien of ze draaiden. Het veld had per
  ongeluk het vangnet uitgezet dat er was.

  Dat dit hier als functie staat en niet als drie losse `where`-regels in de
  meteringquery is de eigenlijke les: het volgende veld dat "de node leeft maar
  anders" betekent hoort hier te worden afgewogen, op de plek waar staat wat
  factureerbaar betekent.

  Niet factureren is bewust de veilige kant. Een klant te weinig rekenen tijdens
  een storing van een uur kost ons een paar cent; een klant rekenen voor een
  machine waarvan wij niet kunnen zien of hij bestaat, kost vertrouwen.
  """
  @spec factureerbaar(Ecto.Queryable.t(), DateTime.t()) :: Ecto.Query.t()
  def factureerbaar(query, %DateTime{} = cutoff) do
    from n in query,
      where: n.status == :online,
      where: n.last_heartbeat_at >= ^cutoff,
      where: is_nil(n.capacity_error) or n.capacity_error == ""
  end

  @doc false
  def changeset(node, attrs) do
    node
    |> cast(attrs, [
      :name,
      :region_id,
      :status,
      :hypervisor,
      :total_vcpu,
      :total_ram_mb,
      :total_disk_gb,
      :available_vcpu,
      :available_ram_mb,
      :available_disk_gb,
      :last_heartbeat_at,
      :agent_version,
      :capacity_error,
      :drain_reason,
      :reported_avail_vcpu,
      :reported_avail_ram_mb,
      :reported_avail_disk_gb,
      :enroll_token_hash,
      :agent_token_hash,
      :public_key,
      :owner_email,
      :owner_id,
      :vps_bridge,
      :vps_vlan,
      :vps_gateway,
      :vps_cidr_prefix,
      :vps_range_start,
      :vps_range_end,
      :public_host,
      :public_port_start,
      :public_port_end
    ])
    |> clamp_capacity()
    |> validate_required([:name, :region_id])
    |> validate_vps_network()
    |> validate_public_ports()
    |> assoc_constraint(:region)
    |> unique_constraint(:agent_token_hash)
  end

  @doc """
  How idle this node would be left by `request`: the fraction of each resource
  still free after placement, summed. Higher is less loaded.

  Both the scheduler (choosing a node) and automatic region selection (choosing
  where to send a customer who did not pick) score with this, so "the emptiest
  machine" means the same thing at both levels. Total capacities are guarded
  against nil/zero, which a node that has never heartbeated will have.
  """
  def headroom_score(%__MODULE__{} = node, %{vcpu: vcpu, ram_mb: ram_mb, disk_gb: disk_gb}) do
    frac(node.available_vcpu - vcpu, node.total_vcpu) +
      frac(node.available_ram_mb - ram_mb, node.total_ram_mb) +
      frac(node.available_disk_gb - disk_gb, node.total_disk_gb)
  end

  defp frac(_remaining, total) when is_nil(total) or total <= 0, do: 0.0
  defp frac(remaining, total), do: remaining / total

  @doc """
  Atomically adds a reservation's vcpu/ram/disk back onto its node's available
  capacity in a single statement — no read-modify-write, so a capacity release
  can't clobber a concurrent scheduler decrement (lost update). Shaped for
  `Ecto.Multi.run/3`: returns `{:ok, rows_updated}`.

  Het optellen wordt afgetopt op het totaal van de node. Sinds available_* bij
  elke heartbeat wordt afgeleid uit wat de node vrij meldt min de lopende
  reserveringen, is deze teruggave overbodig zodra zo'n heartbeat er al langs is
  geweest: de vrijgegeven reservering telt dan al niet meer mee. Er nog eens bij
  optellen zou dubbeltellen, en de check-constraint `available_within_total`
  weigert dat terecht — met een mislukte transactie tot gevolg in plaats van een
  fout cijfer. Aftoppen laat de teruggave zijn werk doen tussen twee heartbeats
  door, en laat hem verder geen kwaad doen.

  Een node die nog nooit heeft gemeld heeft NULL in deze kolommen en houdt die.
  Dat staat er met een expliciete CASE bij, want LEAST in PostgreSQL negeert NULL
  en geeft de kleinste niet-lege waarde terug -- `LEAST(NULL, 6)` is 6, niet
  NULL. Zonder die CASE zou een node die nooit iets meldde ineens plaatsbaar
  worden met een capaciteit die niemand heeft gemeten.
  """
  def add_capacity(repo, %{node_id: node_id, vcpu: vcpu, ram_mb: ram_mb, disk_gb: disk_gb}) do
    {count, _} =
      repo.update_all(
        from(n in __MODULE__,
          where: n.id == ^node_id,
          update: [
            set: [
              available_vcpu:
                fragment(
                  "CASE WHEN ? IS NULL THEN NULL ELSE LEAST(? + ?, COALESCE(?, ? + ?)) END",
                  n.available_vcpu,
                  n.available_vcpu,
                  ^vcpu,
                  n.total_vcpu,
                  n.available_vcpu,
                  ^vcpu
                ),
              available_ram_mb:
                fragment(
                  "CASE WHEN ? IS NULL THEN NULL ELSE LEAST(? + ?, COALESCE(?, ? + ?)) END",
                  n.available_ram_mb,
                  n.available_ram_mb,
                  ^ram_mb,
                  n.total_ram_mb,
                  n.available_ram_mb,
                  ^ram_mb
                ),
              available_disk_gb:
                fragment(
                  "CASE WHEN ? IS NULL THEN NULL ELSE LEAST(? + ?, COALESCE(?, ? + ?)) END",
                  n.available_disk_gb,
                  n.available_disk_gb,
                  ^disk_gb,
                  n.total_disk_gb,
                  n.available_disk_gb,
                  ^disk_gb
                )
            ]
          ]
        ),
        []
      )

    {:ok, count}
  end

  @doc "Returns a changeset that subtracts vcpu/ram/disk from the node's available capacity."
  def subtract_capacity_changeset(%__MODULE__{} = node, %{
        vcpu: vcpu,
        ram_mb: ram_mb,
        disk_gb: disk_gb
      }) do
    change(node,
      available_vcpu: node.available_vcpu - vcpu,
      available_ram_mb: node.available_ram_mb - ram_mb,
      available_disk_gb: node.available_disk_gb - disk_gb
    )
  end

  # A range that runs backwards would make the port allocator hand out nothing
  # while looking configured; privileged ports are refused because forwarding
  # them means the operator's own SSH and web server are in the pool.
  defp validate_public_ports(changeset) do
    changeset
    |> validate_number(:public_port_start, greater_than: 1023, less_than: 65_536)
    |> validate_number(:public_port_end, greater_than: 1023, less_than: 65_536)
    |> validate_port_range()
  end

  defp validate_port_range(changeset) do
    from = get_field(changeset, :public_port_start)
    to = get_field(changeset, :public_port_end)

    if is_integer(from) and is_integer(to) and from > to do
      add_error(changeset, :public_port_end, "must be >= public_port_start")
    else
      changeset
    end
  end

  # If a worker declares ANY VPS-network field, require a complete, valid tuple so
  # the allocator can never crash on bad input or hand out a wrong-subnet address.
  defp validate_vps_network(changeset) do
    declared? =
      Enum.any?([:vps_range_start, :vps_range_end, :vps_gateway, :vps_cidr_prefix], fn f ->
        not is_nil(get_field(changeset, f))
      end)

    if declared? do
      changeset
      |> validate_required([:vps_range_start, :vps_range_end, :vps_gateway, :vps_cidr_prefix])
      |> validate_ipv4(:vps_range_start)
      |> validate_ipv4(:vps_range_end)
      |> validate_ipv4(:vps_gateway)
      |> validate_number(:vps_cidr_prefix, greater_than_or_equal_to: 1, less_than_or_equal_to: 32)
      |> validate_range_order()
    else
      changeset
    end
  end

  defp validate_ipv4(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if Net.valid?(value), do: [], else: [{field, "is not a valid IPv4 address"}]
    end)
  end

  defp validate_range_order(changeset) do
    s = get_field(changeset, :vps_range_start)
    e = get_field(changeset, :vps_range_end)

    if is_binary(s) and is_binary(e) and Net.valid?(s) and Net.valid?(e) and
         Net.to_int(s) > Net.to_int(e) do
      add_error(changeset, :vps_range_end, "must be >= vps_range_start")
    else
      changeset
    end
  end

  @doc """
  Changeset applied when a node reports a heartbeat.

  A heartbeat updates only the node's advertised *total* capacity (the operator
  may add/remove hardware) and the heartbeat timestamp. It deliberately does NOT
  touch `available_*` — that is managed exclusively by the
  `ControlPlane.Fleet.Scheduler` (decremented on placement, released on delete),
  so an untrusted heartbeat can never undo a reservation and overcommit a node.
  It also does NOT set `:status`: node status is transitioned by authorized
  server-side logic, never driven by the least-trusted (agent) input.
  """
  def heartbeat_changeset(node, attrs) do
    node
    |> cast(attrs, [
      :total_vcpu,
      :total_ram_mb,
      :total_disk_gb,
      :last_heartbeat_at,
      :agent_version,
      :capacity_error,
      :network_note,
      :drain_reason,
      :reported_avail_vcpu,
      :reported_avail_ram_mb,
      :reported_avail_disk_gb
    ])
    |> clamp_capacity()
    |> trim_agent_version()
    |> trim_network_note()
    |> validate_required([:last_heartbeat_at])
  end

  @doc """
  Server-side changeset applied when an authenticated heartbeat both refreshes a
  node's advertised totals AND (re)asserts it as `:online`.

  Unlike `heartbeat_changeset/2`, this one is allowed to set `:status` because it is
  driven by trusted server logic (`ControlPlane.Fleet.mark_online_heartbeat/2`)
  after the agent's bearer token has been authenticated — not directly from agent
  input. `available_*` may be set ONLY here and ONLY to seed a brand-new node's
  capacity on its first heartbeat (see `Fleet.mark_online_heartbeat/2`); steady-state
  it stays scheduler-owned.
  """
  def mark_online_changeset(node, attrs) do
    node
    |> cast(attrs, [
      :total_vcpu,
      :total_ram_mb,
      :total_disk_gb,
      :available_vcpu,
      :available_ram_mb,
      :available_disk_gb,
      :last_heartbeat_at,
      :agent_version,
      :capacity_error,
      :network_note,
      :drain_reason,
      :reported_avail_vcpu,
      :reported_avail_ram_mb,
      :reported_avail_disk_gb,
      :status
    ])
    |> clamp_capacity()
    |> trim_agent_version()
    |> trim_network_note()
    |> validate_required([:last_heartbeat_at, :status])
  end

  # De versie komt van de agent, dus uit de minst vertrouwde bron die dit schema
  # kent. Er valt weinig kwaad mee te doen — hij stuurt niets aan — maar hij
  # belandt wel in het dashboard, dus hij wordt begrensd en ontdaan van
  # controltekens in plaats van ongezien doorgegeven.
  @max_agent_version 64

  # De kolom is 255 tekens, en een agent is de minst betrouwbare invoer die dit
  # systeem kent. Een te lange notitie laat anders de hele heartbeat afketsen, en
  # dan staat de node dood in het paneel om een melding die te lang was -- precies
  # de fout die `capacity_error` in zijn commentaar beschrijft. Hier wordt hij
  # ingekort in plaats van geweigerd, en controletekens gaan eruit.
  @max_network_note 240

  defp trim_network_note(changeset) do
    case get_change(changeset, :network_note) do
      nil ->
        changeset

      value when is_binary(value) ->
        schoon =
          value
          |> String.replace(~r/[[:cntrl:]]/u, " ")
          |> String.slice(0, @max_network_note)
          |> String.trim()

        if schoon == "",
          do: delete_change(changeset, :network_note),
          else: put_change(changeset, :network_note, schoon)

      _ ->
        changeset
    end
  end

  defp trim_agent_version(changeset) do
    case get_change(changeset, :agent_version) do
      nil ->
        changeset

      value when is_binary(value) ->
        schoon =
          value
          |> String.replace(~r/[[:cntrl:]]/u, "")
          |> String.slice(0, @max_agent_version)
          |> String.trim()

        if schoon == "",
          do: delete_change(changeset, :agent_version),
          else: put_change(changeset, :agent_version, schoon)

      _ ->
        delete_change(changeset, :agent_version)
    end
  end

  # Bound every capacity field an untrusted agent can influence to [0, max], so a
  # node can neither advertise absurd headroom to win scheduling nor poison the
  # capacity math with a negative value.
  defp clamp_capacity(changeset) do
    changeset
    |> clamp_field(:total_vcpu, @max_total_vcpu)
    |> clamp_field(:total_ram_mb, @max_total_ram_mb)
    |> clamp_field(:total_disk_gb, @max_total_disk_gb)
    |> clamp_field(:available_vcpu, @max_total_vcpu)
    |> clamp_field(:available_ram_mb, @max_total_ram_mb)
    |> clamp_field(:available_disk_gb, @max_total_disk_gb)
    |> clamp_available_to_total()
  end

  # An operator removing hardware lowers total_* on the next heartbeat while
  # available_* (scheduler-owned) stays as it was, which would leave
  # available > total — corrupting the capacity display and letting the scheduler
  # place work the node can no longer host. Clamp available down to the new total.
  defp clamp_available_to_total(changeset) do
    Enum.reduce(
      [
        {:available_vcpu, :total_vcpu},
        {:available_ram_mb, :total_ram_mb},
        {:available_disk_gb, :total_disk_gb}
      ],
      changeset,
      fn {available_field, total_field}, cs ->
        total = get_field(cs, total_field)
        available = get_field(cs, available_field)

        if is_integer(total) and is_integer(available) and available > total do
          put_change(cs, available_field, total)
        else
          cs
        end
      end
    )
  end

  defp clamp_field(changeset, field, max) do
    case get_change(changeset, field) do
      v when is_integer(v) and v > max -> put_change(changeset, field, max)
      v when is_integer(v) and v < 0 -> put_change(changeset, field, 0)
      _ -> changeset
    end
  end
end
