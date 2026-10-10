"use client";

import { PageHeader } from "@/components/layout/page-header";
import { useBevestig } from "@/components/ui/use-bevestig";
import { useCallback, useEffect, useState } from "react";
import { AlertTriangle, HardDrive, Loader2, RefreshCw, Save } from "lucide-react";
import { Card, CardContent } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { useToast } from "@/components/ui/use-toast";
import { nodeApi, parseApiError, type MyNode, type NodeRegion, type NodeSettings } from "@/lib/api";

// Wat de agent doet als een veld leeg blijft. Dat staat er expliciet bij, want
// "leeg" betekent hier niet nul maar "houd wat er op de machine staat".
const LEEG_BETEKENT = "leeg = ongewijzigd laten";

type Formulier = Record<keyof NodeSettings, string>;

function naarFormulier(s: NodeSettings): Formulier {
  return {
    offer_vcpu: s.offer_vcpu?.toString() ?? "",
    offer_ram_mb: s.offer_ram_mb?.toString() ?? "",
    offer_disk_gb: s.offer_disk_gb?.toString() ?? "",
    vmid_min: s.vmid_min?.toString() ?? "",
    vmid_max: s.vmid_max?.toString() ?? "",
    vcpu_oversubscribe: s.vcpu_oversubscribe?.toString() ?? "",
    guest_name_pattern: s.guest_name_pattern ?? "",
    vps_bridge: s.vps_bridge ?? "",
    vps_vlan: s.vps_vlan?.toString() ?? "",
  };
}

// Een leeg getalveld wordt null, niet 0: nul vCPU aanbieden is iets anders dan
// niets ingesteld hebben.
function naarInstellingen(f: Formulier): Partial<NodeSettings> {
  const getal = (v: string) => (v.trim() === "" ? null : Number(v));

  return {
    offer_vcpu: getal(f.offer_vcpu),
    offer_ram_mb: getal(f.offer_ram_mb),
    offer_disk_gb: getal(f.offer_disk_gb),
    vmid_min: getal(f.vmid_min),
    vmid_max: getal(f.vmid_max),
    vcpu_oversubscribe: getal(f.vcpu_oversubscribe),
    guest_name_pattern: f.guest_name_pattern.trim() === "" ? null : f.guest_name_pattern.trim(),
    vps_bridge: f.vps_bridge.trim() === "" ? null : f.vps_bridge.trim(),
    // Leeg is hier niet 0: untagged is een keuze, en die moet de agent kunnen
    // onderscheiden van "hier is niets over gezegd, houd wat je had".
    vps_vlan: getal(f.vps_vlan),
  };
}

function Veld({
  id,
  label,
  hint,
  waarde,
  onChange,
  placeholder,
}: {
  id: string;
  label: string;
  hint: string;
  waarde: string;
  onChange: (v: string) => void;
  placeholder?: string;
}) {
  return (
    <div className="space-y-1">
      <Label htmlFor={id}>{label}</Label>
      <Input id={id} value={waarde} placeholder={placeholder} onChange={(e) => onChange(e.target.value)} />
      <p className="text-xs text-muted-foreground">{hint}</p>
    </div>
  );
}

function NodeKaart({
  node,
  regions,
  onSaved,
}: {
  node: MyNode;
  regions: NodeRegion[];
  onSaved: (n: MyNode) => void;
}) {
  const { dialoog, bevestig, vraag } = useBevestig();
  const { toast } = useToast();
  const [form, setForm] = useState<Formulier>(() => naarFormulier(node.settings));
  const [locatie, setLocatie] = useState(node.region?.name ?? "");
  const [saving, setSaving] = useState(false);

  const zet = (veld: keyof NodeSettings) => (v: string) => setForm((f) => ({ ...f, [veld]: v }));

  // De VPS'en gaan mee naar de nieuwe locatie. Een regio beschrijft waar de
  // machine fysiek staat, en een VPS kan niet ergens anders staan dan de machine
  // waarop hij draait -- laat je ze achter, dan liegt het label bij elke klant
  // die het opvraagt. Vandaar de bevestiging.
  //
  // Vrije tekst, geen keuzelijst: bestaat de plaats nog niet, dan maakt het
  // control plane hem aan. Wachten tot een beheerder jouw stad heeft toegevoegd
  // is geen instelling maar een blokkade. De bestaande locaties staan als
  // suggestie in de datalist, zodat "Eindhoven" niet naast "eindhoven" belandt.
  const verplaats = async () => {
    const gewenst = locatie.trim();
    if (!gewenst || gewenst.toLowerCase() === (node.region?.name ?? "").toLowerCase()) return;

    const bestaat = regions.some((r) => r.name.toLowerCase() === gewenst.toLowerCase());
    const bevestigd = await bevestig({
      titel: `${node.name} verplaatsen naar ${gewenst}?`,
      uitleg:
        (bestaat ? "" : `"${gewenst}" bestaat nog niet en wordt aangemaakt. `) +
        "De VPS'en die op deze machine draaien verhuizen mee: hun locatie verandert " +
        "met de machine, want ze staan er fysiek op.",
      bevestigLabel: "Verplaatsen",
    });
    if (!bevestigd) return;

    setSaving(true);
    try {
      const bijgewerkt = await nodeApi.moveRegion(node.id, gewenst);
      onSaved(bijgewerkt);
      setLocatie(bijgewerkt.region?.name ?? gewenst);
      toast({
        title: "Verplaatst",
        description: `Deze node staat nu in ${bijgewerkt.region?.name ?? gewenst}.`,
      });
    } catch (err) {
      toast({
        title: "Niet verplaatst",
        description: parseApiError(err, "Vul een plaatsnaam van minstens twee tekens in."),
        variant: "destructive",
      });
    } finally {
      setSaving(false);
    }
  };

  // Overdragen kan alleen de eigenaar zelf. Dat is bewust geen beheerdersactie:
  // zodra een node een eigenaar heeft, gaat alleen die erover. De keerzijde staat
  // in de bevestiging, want daarna kun je er zelf niet meer bij.
  const overdragen = async () => {
    const email = await vraag({
      titel: `${node.name} overdragen`,
      uitleg:
        "Het Bunk-account dat je hier invult, neemt deze node over. Laat leeg om hem " +
        "zonder eigenaar achter te laten. Daarna kun jij de instellingen niet meer wijzigen.",
      bevestigLabel: "Overdragen",
      variant: "destructive",
      invoer: { label: "E-mailadres van de nieuwe eigenaar", placeholder: "naam@voorbeeld.nl" },
    });
    if (email === null) return;

    setSaving(true);
    try {
      const bijgewerkt = await nodeApi.assignOwner(node.id, email.trim() === "" ? null : email.trim());
      onSaved(bijgewerkt);
      toast({
        title: "Overgedragen",
        description: email.trim() === "" ? "De node heeft geen eigenaar meer." : `Nu van ${email.trim()}.`,
      });
    } catch (err) {
      toast({
        title: "Niet overgedragen",
        description: parseApiError(err, "Bestaat dat account, en ben jij de eigenaar van deze node?"),
        variant: "destructive",
      });
    } finally {
      setSaving(false);
    }
  };

  const opslaan = async () => {
    setSaving(true);
    try {
      const bijgewerkt = await nodeApi.updateSettings(node.id, naarInstellingen(form));
      onSaved(bijgewerkt);
      setForm(naarFormulier(bijgewerkt.settings));
      toast({
        title: "Opgeslagen",
        description: "De node past dit toe bij zijn volgende heartbeat, binnen een halve minuut.",
      });
    } catch (err) {
      // De server zegt per veld wat er mis is; die tekst is bruikbaarder dan
      // "er ging iets mis", want hij noemt de regel die is overtreden.
      toast({ title: "Niet opgeslagen", description: parseApiError(err, "Controleer de ingevulde waarden."),
        variant: "destructive",
      });
    } finally {
      setSaving(false);
    }
  };

  return (
    <>
      {dialoog}
    <Card>
      <CardContent className="space-y-6 p-6">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <div className="flex items-center gap-2">
            <HardDrive className="h-4 w-4 text-muted-foreground" />
            <span className="font-medium">{node.name}</span>
            <span className="text-xs text-muted-foreground">
              {node.hypervisor} · {node.status}
              {node.agent_version ? ` · agent ${node.agent_version}` : ""}
            </span>
          </div>
          <div className="flex items-center gap-2">
            <Button variant="ghost" size="sm" disabled={saving} onClick={overdragen}>
              Overdragen
            </Button>
            <Button size="sm" className="gap-2" disabled={saving} onClick={opslaan}>
              {saving ? <Loader2 className="h-4 w-4 animate-spin" /> : <Save className="h-4 w-4" />}
              Opslaan
            </Button>
          </div>
        </div>

        {node.capacity_error && (
          <div className="flex items-start gap-2 rounded-lg border border-amber-500/40 bg-amber-500/5 p-3 text-xs">
            <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0 text-amber-500" />
            <div>
              {/* De reden kan de hypervisor zijn, maar ook het VPS-netwerk van deze
                  machine. Een kop die er één van noemt, wijst bij de ander de
                  verkeerde kant op. */}
              <p className="font-medium">Deze node neemt op dit moment niets nieuws aan</p>
              <p className="mt-0.5 break-words text-muted-foreground">{node.capacity_error}</p>
            </div>
          </div>
        )}
        {node.network_note && (
          <div className="flex items-start gap-2 rounded-lg border border-amber-500/40 bg-amber-500/5 p-3 text-xs">
            <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0 text-amber-500" />
            <div>
              <p className="font-medium">Het VPS-netwerk van deze machine</p>
              <p className="mt-0.5 break-words text-muted-foreground">{node.network_note}</p>
              <p className="mt-1 text-muted-foreground">
                De node blijft te bestellen. Verdwijnt deze melding niet vanzelf nadat je dit hebt
                aangepast, dan komt de webterminal nog niet bij je VPS&apos;en.
              </p>
            </div>
          </div>
        )}

        <div>
          <h3 className="text-sm font-medium">Locatie</h3>
          <p className="mb-3 text-xs text-muted-foreground">
            Waar deze machine fysiek staat. Klanten kiezen hierop bij het bestellen. Typ een
            plaats die er nog niet is en hij wordt aangemaakt.
          </p>
          <div className="flex flex-wrap items-center gap-2">
            <Input
              list={`locaties-${node.id}`}
              className="max-w-xs"
              placeholder="Eindhoven"
              value={locatie}
              disabled={saving}
              onChange={(e) => setLocatie(e.target.value)}
            />
            <datalist id={`locaties-${node.id}`}>
              {regions.map((r) => (
                <option key={r.id} value={r.name} />
              ))}
            </datalist>
            <Button
              variant="outline"
              size="sm"
              disabled={saving || !locatie.trim() || locatie.trim() === (node.region?.name ?? "")}
              onClick={verplaats}
            >
              Verplaatsen
            </Button>
          </div>
        </div>

        <div>
          <h3 className="text-sm font-medium">Wat er naar de pool gaat</h3>
          <p className="mb-3 text-xs text-muted-foreground">
            Hoeveel van deze machine aan klanten mag worden verkocht. Draait er niets anders op,
            dan kun je dit leeg laten.
          </p>
          <div className="grid gap-4 sm:grid-cols-3">
            <Veld id="offer_vcpu" label="vCPU-cores" hint={LEEG_BETEKENT} waarde={form.offer_vcpu} onChange={zet("offer_vcpu")} placeholder="alles" />
            <Veld id="offer_ram_mb" label="RAM (MB)" hint={LEEG_BETEKENT} waarde={form.offer_ram_mb} onChange={zet("offer_ram_mb")} placeholder="alles" />
            <Veld id="offer_disk_gb" label="Schijf (GB)" hint={LEEG_BETEKENT} waarde={form.offer_disk_gb} onChange={zet("offer_disk_gb")} placeholder="alles" />
          </div>
        </div>

        <div>
          <h3 className="text-sm font-medium">Netwerk van de VPS&apos;en</h3>
          <p className="mb-3 text-xs text-muted-foreground">
            De bridge waar klant-VPS&apos;en aan hangen. Die stond eerder alleen in het
            configuratiebestand op de machine zelf; hier kun je hem zien en wijzigen. Een
            wijziging geldt voor VPS&apos;en die hierna worden aangemaakt &mdash; een draaiende
            machine wordt niet onder een klant vandaan verhangen.
          </p>
          <div className="grid gap-4 sm:grid-cols-2">
            <Veld
              id="vps_bridge"
              label="Bridge"
              hint="letters en cijfers, bijvoorbeeld vmbr2; leeg = van de template overnemen"
              waarde={form.vps_bridge}
              onChange={zet("vps_bridge")}
              placeholder="vmbr2"
            />
            <Veld
              id="vps_vlan"
              label="VLAN-tag"
              hint="0 = untagged; leeg = niet ingesteld"
              waarde={form.vps_vlan}
              onChange={zet("vps_vlan")}
              placeholder="—"
            />
          </div>
        </div>

        <div>
          <h3 className="text-sm font-medium">Nummers en namen op de hypervisor</h3>
          <p className="mb-3 text-xs text-muted-foreground">
            Proxmox geeft standaard het laagste vrije nummer vanaf 100, waardoor klant-VPS&apos;en
            tussen je eigen machines komen te staan. Met een eigen blok gebeurt dat niet.
          </p>
          <div className="grid gap-4 sm:grid-cols-3">
            <Veld id="vmid_min" label="Laagste VMID" hint="bijvoorbeeld 2000" waarde={form.vmid_min} onChange={zet("vmid_min")} placeholder="—" />
            <Veld id="vmid_max" label="Hoogste VMID" hint="bijvoorbeeld 2999" waarde={form.vmid_max} onChange={zet("vmid_max")} placeholder="—" />
            <Veld
              id="vcpu_oversubscribe"
              label="vCPU per core"
              hint="RAM wordt nooit overboekt"
              waarde={form.vcpu_oversubscribe}
              onChange={zet("vcpu_oversubscribe")}
              placeholder="3"
            />
          </div>
          <div className="mt-4">
            <Veld
              id="guest_name_pattern"
              label="Naam van een gast"
              hint="moet {id} bevatten; verder {naam}, {klant} en {node}"
              waarde={form.guest_name_pattern}
              onChange={zet("guest_name_pattern")}
              placeholder="{naam}-{id}"
            />
            <p className="mt-2 text-xs text-muted-foreground">
              Het {"{id}"}-deel is verplicht. De agent herkent aan de naam of hij een machine al
              heeft aangemaakt; zonder uniek deel kunnen twee VPS&apos;en niet uit elkaar worden
              gehouden.
            </p>
          </div>
        </div>
      </CardContent>
    </Card>
    </>
  );
}

export default function MijnNodesPagina() {
  const { toast } = useToast();
  const [nodes, setNodes] = useState<MyNode[] | null>(null);
  const [regions, setRegions] = useState<NodeRegion[]>([]);

  const laden = useCallback(() => {
    nodeApi
      .mine()
      .then(({ nodes, regions }) => {
        setNodes(nodes);
        setRegions(regions);
      })
      .catch(() => {
        setNodes([]);
        toast({ title: "Fout", description: "Kon je nodes niet laden.", variant: "destructive" });
      });
  }, [toast]);

  useEffect(() => laden(), [laden]);

  if (nodes === null) {
    return (
      <div className="flex justify-center py-20">
        <Loader2 className="h-8 w-8 animate-spin text-primary" />
      </div>
    );
  }

  return (
    <div className="space-y-6">
      <PageHeader title="Mijn nodes" description={<>De machines die jij beheert. Een wijziging is binnen een halve minuut actief; je hoeft niet op de machine in te loggen.</>}>
        <Button variant="ghost" size="sm" className="gap-2" onClick={laden}>
          <RefreshCw className="h-4 w-4" /> Vernieuwen
        </Button>
      </PageHeader>

      {nodes.length === 0 ? (
        <Card>
          <CardContent className="p-6 text-sm text-muted-foreground">
            Je beheert nog geen node. Zet je zelf hardware neer, dan wijst een beheerder hem aan je
            toe — of geef je e-mailadres op tijdens de installatie.
          </CardContent>
        </Card>
      ) : (
        nodes.map((n) => (
          <NodeKaart
            key={n.id}
            node={n}
            regions={regions}
            onSaved={(bijgewerkt) =>
              setNodes((huidig) => (huidig ?? []).map((x) => (x.id === bijgewerkt.id ? bijgewerkt : x)))
            }
          />
        ))
      )}
    </div>
  );
}
