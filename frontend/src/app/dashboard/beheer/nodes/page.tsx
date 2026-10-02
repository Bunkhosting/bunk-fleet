"use client";

import { useEffect, useState } from "react";
import { Loader2, RefreshCw, HardDrive, Trash2, Plus, Copy, Check, AlertTriangle } from "lucide-react";
import { Card, CardContent } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { useToast } from "@/components/ui/use-toast";
import { AdminGuard } from "@/components/admin/admin-guard";
import { adminApi, parseApiError, type AdminNode, type AdminRegion } from "@/lib/api";

const STATUS_VARIANT: Record<string, "default" | "secondary" | "destructive" | "outline"> = {
  online: "default",
  offline: "destructive",
  draining: "secondary",
  pending: "outline",
};

function Bar({ used, total }: { used: number | null; total: number | null }) {
  // Nog niets gemeld is iets anders dan nul gemeld. "0/0" leest als een node
  // zonder capaciteit, terwijl het betekent dat hij nog nooit iets heeft gezegd.
  if (total === null || total === 0) {
    return (
      <div className="space-y-1">
        <div className="text-xs text-muted-foreground">nog niet gemeld</div>
        <div className="h-1.5 w-full overflow-hidden rounded-full bg-muted" />
      </div>
    );
  }

  const gebruikt = used ?? 0;
  const pct = Math.min(100, Math.round((gebruikt / total) * 100));
  return (
    <div className="space-y-1">
      <div className="text-xs text-muted-foreground">{gebruikt}/{total}</div>
      <div className="h-1.5 w-full overflow-hidden rounded-full bg-muted">
        <div className="h-full rounded-full bg-primary" style={{ width: `${pct}%` }} />
      </div>
    </div>
  );
}

// MB naar hele GB, met null als null: een node die niets meldt houdt "niets
// gemeld" en wordt geen nul.
const gb = (mb: number | null) => (mb === null ? null : Math.round(mb / 1024));

function NodesInner() {
  const { toast } = useToast();
  const [nodes, setNodes] = useState<AdminNode[]>([]);
  const [loading, setLoading] = useState(true);

  const [removing, setRemoving] = useState<string | null>(null);
  const [draining, setDraining] = useState<string | null>(null);

  // Het enroll-token komt maar één keer terug van de server; er staat alleen een
  // hash van in de database. Daarom blijft het hier in beeld tot de operator het
  // wegklikt, in plaats van na een toast te verdwijnen.
  const [enroll, setEnroll] = useState<{ install: string; expires_at: string } | null>(null);
  const [minting, setMinting] = useState(false);
  const [copied, setCopied] = useState(false);

  // Het token is aan één locatie gebonden, dus die keuze hoort hier te staan en
  // niet impliciet te zijn. Zolang er precies één locatie is mag hij leeg
  // blijven -- dan is er niets te kiezen -- maar zodra er twee zijn is "de
  // eerste de beste" een node die ergens anders staat dan de klant koos.
  const [regios, setRegios] = useState<AdminRegion[]>([]);
  const [regio, setRegio] = useState("");

  useEffect(() => {
    adminApi
      .regions()
      .then((rs) => {
        setRegios(rs);
        if (rs.length === 1) setRegio(rs[0].code);
      })
      .catch(() => setRegios([]));
  }, []);

  const addNode = async () => {
    setMinting(true);
    try {
      const res = await adminApi.createEnrollToken(regio || undefined);
      setEnroll({ install: res.install, expires_at: res.expires_at });
    } catch (e) {
      toast({
        title: "Kon geen token aanmaken",
        description: parseApiError(
          e,
          regios.length === 0
            ? "Maak eerst een locatie aan onder Beheer > Locaties."
            : "Kies de locatie waar deze node komt te staan.",
        ),
        variant: "destructive",
      });
    } finally {
      setMinting(false);
    }
  };

  const copyInstall = async () => {
    if (!enroll) return;
    try {
      await navigator.clipboard.writeText(enroll.install);
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    } catch {
      toast({ title: "Kopiëren lukte niet", description: "Selecteer de regel handmatig." });
    }
  };

  const load = () =>
    adminApi
      .nodes()
      .then(setNodes)
      .catch(() => toast({ title: "Fout", description: "Kon nodes niet laden.", variant: "destructive" }))
      .finally(() => setLoading(false));

  const toggleDrain = async (n: AdminNode) => {
    const closing = n.status !== "draining";
    setDraining(n.id);
    try {
      if (closing) {
        await adminApi.nodeDrain(n.id);
        toast({
          title: "Node afgesloten",
          description: `${n.name} krijgt geen nieuwe VPS'en meer. Wat er draait blijft draaien.`,
        });
      } else {
        await adminApi.nodeResume(n.id);
        toast({ title: "Node weer in gebruik", description: n.name });
      }
      await load();
    } catch (e: unknown) {
      const status = (e as { response?: { status?: number } })?.response?.status;
      toast({
        title: closing ? "Afsluiten mislukt" : "Heropenen mislukt",
        description:
          status === 409
            ? "Deze node is offline — die komt vanzelf terug zodra hij weer meldt."
            : "Kon de status niet wijzigen.",
        variant: "destructive",
      });
    } finally {
      setDraining(null);
    }
  };

  const removeNode = async (n: AdminNode) => {
    if (!window.confirm(`Node "${n.name}" definitief verwijderen uit de fleet?`)) return;
    setRemoving(n.id);
    try {
      await adminApi.nodeDelete(n.id);
      toast({ title: "Node verwijderd", description: n.name });
      setNodes((prev) => prev.filter((x) => x.id !== n.id));
    } catch (e: unknown) {
      const status = (e as { response?: { status?: number } })?.response?.status;
      toast({
        title: "Verwijderen mislukt",
        description:
          status === 409
            ? "Deze node host nog VPS'en — verwijder die eerst."
            : "Kon de node niet verwijderen.",
        variant: "destructive",
      });
    } finally {
      setRemoving(null);
    }
  };

  useEffect(() => {
    load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  if (loading) {
    return (
      <div className="flex justify-center py-20">
        <Loader2 className="h-8 w-8 animate-spin text-primary" />
      </div>
    );
  }

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold tracking-tight">Nodes</h1>
          <p className="text-muted-foreground">{nodes.length} nodes — datacenter (gedeeld) en community.</p>
        </div>
        <div className="flex gap-2">
          <Button variant="ghost" size="sm" className="gap-2" onClick={load}>
            <RefreshCw className="h-4 w-4" /> Ververs
          </Button>
          {regios.length > 1 && (
            <select
              className="h-9 rounded-md border bg-background px-2 text-sm"
              value={regio}
              onChange={(e) => setRegio(e.target.value)}
              aria-label="Locatie voor de nieuwe node"
            >
              <option value="">Kies een locatie…</option>
              {regios.map((r) => (
                <option key={r.id} value={r.code}>
                  {r.name} ({r.code})
                </option>
              ))}
            </select>
          )}
          <Button
            size="sm"
            className="gap-2"
            onClick={addNode}
            disabled={minting || (regios.length > 1 && !regio)}
          >
            {minting ? <Loader2 className="h-4 w-4 animate-spin" /> : <Plus className="h-4 w-4" />}
            Node toevoegen
          </Button>
        </div>
      </div>

      {enroll && (
        <Card className="border-primary/40">
          <CardContent className="space-y-3 p-4">
            <div className="flex items-start justify-between gap-4">
              <div>
                <h2 className="font-semibold">Voer dit uit op de nieuwe machine</h2>
                <p className="text-sm text-muted-foreground">
                  Op de hypervisor zelf, als root. Het token werkt één keer en verloopt{" "}
                  {new Date(enroll.expires_at).toLocaleString("nl-NL")}.
                </p>
              </div>
              <Button variant="ghost" size="sm" onClick={() => setEnroll(null)}>
                Sluiten
              </Button>
            </div>
            <div className="flex items-center gap-2 rounded-md bg-muted p-3">
              <code className="flex-1 overflow-x-auto whitespace-pre text-xs">{enroll.install}</code>
              <Button variant="ghost" size="sm" onClick={copyInstall} className="shrink-0">
                {copied ? <Check className="h-4 w-4" /> : <Copy className="h-4 w-4" />}
              </Button>
            </div>
            <p className="text-xs text-muted-foreground">
              Deze regel is nu het enige exemplaar: de server bewaart alleen een hash. Sluit je dit
              venster, dan maak je een nieuw token aan.
            </p>
          </CardContent>
        </Card>
      )}

      <div className="grid gap-4">
        {nodes.map((n) => {
          // Plaatsing vereist dat zowel de scheduler als de node zelf ruimte
          // ziet, dus het laagste van de twee bepaalt wat er nog verkocht kan
          // worden. Alleen het schedulercijfer tonen geeft een ruimer beeld dan
          // de werkelijkheid toelaat -- en dat is precies het getal waarop je
          // besluit of er een node bij moet.
          const bindend = (sched: number | null, gemeld: number | null) =>
            sched === null ? gemeld : gemeld === null ? sched : Math.min(sched, gemeld);
          const used = (t: number | null, a: number | null) =>
            t === null || a === null ? null : Math.max(0, t - a);
          const vrijVcpu = bindend(n.available_vcpu, n.reported_avail_vcpu);
          const vrijRam = bindend(n.available_ram_mb, n.reported_avail_ram_mb);
          const vrijDisk = bindend(n.available_disk_gb, n.reported_avail_disk_gb);
          const wijktAf =
            n.reported_avail_ram_mb !== null &&
            n.available_ram_mb !== null &&
            n.reported_avail_ram_mb < n.available_ram_mb;
          return (
            <Card key={n.id}>
              <CardContent className="space-y-3 p-4">
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <div className="flex items-center gap-2">
                    <HardDrive className="h-4 w-4 text-muted-foreground" />
                    <span className="font-medium">{n.name}</span>
                    <span className="text-xs text-muted-foreground">
                      {n.region ?? "—"} · {n.cost_centre ?? "geen kostenplaats"}
                    </span>
                    <span className="text-xs text-muted-foreground">
                      {n.owner ? `beheerd door ${n.owner}` : "geen eigenaar"}
                    </span>
                    {/* Draait deze node de huidige agent? Zonder dit is dat alleen
                        te achterhalen door in de binary te zoeken. */}
                    <Badge variant="outline" className="font-mono text-[10px]">
                      {n.agent_version ?? "versie onbekend"}
                    </Badge>
                  </div>
                  <div className="flex items-center gap-2">
                    <Badge variant={STATUS_VARIANT[n.status] ?? "outline"}>{n.status}</Badge>
                    <Button
                      variant="ghost"
                      size="sm"
                      className="h-8 gap-1 px-2 text-xs"
                      title={
                        n.status === "draining"
                          ? "Node weer openstellen voor nieuwe VPS'en"
                          : "Geen nieuwe VPS'en meer plaatsen; wat er draait blijft draaien"
                      }
                      disabled={draining === n.id}
                      onClick={() => toggleDrain(n)}
                    >
                      {draining === n.id ? (
                        <Loader2 className="h-4 w-4 animate-spin" />
                      ) : n.status === "draining" ? (
                        "Heropenen"
                      ) : (
                        "Afsluiten"
                      )}
                    </Button>
                    <Button
                      variant="ghost"
                      size="sm"
                      className="h-8 w-8 p-0 text-destructive hover:text-destructive"
                      title="Node verwijderen"
                      disabled={removing === n.id}
                      onClick={() => removeNode(n)}
                    >
                      {removing === n.id ? (
                        <Loader2 className="h-4 w-4 animate-spin" />
                      ) : (
                        <Trash2 className="h-4 w-4" />
                      )}
                    </Button>
                  </div>
                </div>
                <div className="grid grid-cols-1 gap-3 sm:grid-cols-3">
                  <div>
                    <p className="mb-1 text-xs font-medium">vCPU</p>
                    <Bar used={used(n.total_vcpu, vrijVcpu)} total={n.total_vcpu} />
                  </div>
                  <div>
                    <p className="mb-1 text-xs font-medium">RAM (GB)</p>
                    <Bar used={gb(used(n.total_ram_mb, vrijRam))} total={gb(n.total_ram_mb)} />
                  </div>
                  <div>
                    <p className="mb-1 text-xs font-medium">Schijf (GB)</p>
                    <Bar used={used(n.total_disk_gb, vrijDisk)} total={n.total_disk_gb} />
                  </div>
                </div>
                {n.capacity_error && (
                  // Een node die leeft maar zijn hypervisor niet kan bereiken zag er
                  // vroeger uit als een machine die uit staat. Dit is het verschil.
                  <div className="flex items-start gap-2 rounded-lg border border-amber-500/40 bg-amber-500/5 p-3">
                    <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0 text-amber-500" />
                    <div className="text-xs">
                      <p className="font-medium">Agent draait, maar deze node neemt niets nieuws aan</p>
                      <p className="mt-0.5 break-words text-muted-foreground">{n.capacity_error}</p>
                      <p className="mt-1 text-muted-foreground">
                        Er wordt niets nieuws op deze node geplaatst zolang dit er staat.
                      </p>
                    </div>
                  </div>
                )}
                {n.network_note && (
                  // Een vermoeden, geen vaststelling: de node blijft te bestellen. Het
                  // staat hier omdat een node die zijn eigen VPS'en niet bereikt er van
                  // buiten volkomen gezond uitziet, terwijl de webterminal dichtvalt.
                  <div className="flex items-start gap-2 rounded-lg border border-amber-500/40 bg-amber-500/5 p-3">
                    <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0 text-amber-500" />
                    <div className="text-xs">
                      <p className="font-medium">Het VPS-netwerk van deze node</p>
                      <p className="mt-0.5 break-words text-muted-foreground">{n.network_note}</p>
                      <p className="mt-1 text-muted-foreground">
                        Dit houdt de node niet uit de verkoop. De melding verdwijnt zodra de agent
                        zijn VPS&apos;en weer bereikt.
                      </p>
                    </div>
                  </div>
                )}
                {n.drain_reason && (
                  // Anders staat er alleen "draining" en weet niemand een week
                  // later of hij weer open mag.
                  <div className="flex items-start gap-2 rounded-lg border border-amber-500/40 bg-amber-500/5 p-3">
                    <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0 text-amber-500" />
                    <div className="text-xs">
                      <p className="font-medium">Automatisch afgesloten na een mislukte bestelling</p>
                      <p className="mt-0.5 break-words text-muted-foreground">{n.drain_reason}</p>
                      <p className="mt-1 text-muted-foreground">
                        Los de oorzaak op en klik daarna op Heropenen.
                      </p>
                    </div>
                  </div>
                )}
                {wijktAf && (
                  // De scheduler houdt zijn eigen boekhouding bij en die kan
                  // ruimer staan dan wat er werkelijk vrij is. Dat verschil
                  // hoort zichtbaar te zijn, niet weggemiddeld.
                  <p className="text-xs text-muted-foreground">
                    De node meldt minder vrij dan de scheduler denkt te hebben
                    ({Math.round((n.reported_avail_ram_mb ?? 0) / 1024)} GB tegenover{" "}
                    {Math.round((n.available_ram_mb ?? 0) / 1024)} GB RAM). Er wordt met het laagste
                    gerekend.
                  </p>
                )}
                {wijktAf && (
                  // De scheduler houdt zijn eigen boekhouding bij en die kan
                  // ruimer staan dan wat er werkelijk vrij is. Dat verschil
                  // hoort zichtbaar te zijn, niet weggemiddeld.
                  <p className="text-xs text-muted-foreground">
                    De node meldt minder vrij dan de scheduler denkt te hebben
                    ({Math.round((n.reported_avail_ram_mb ?? 0) / 1024)} GB tegenover{" "}
                    {Math.round((n.available_ram_mb ?? 0) / 1024)} GB RAM). Er wordt met het laagste
                    gerekend.
                  </p>
                )}
                <p className="text-xs text-muted-foreground">
                  Alleen de eigenaar wijzigt de instellingen van deze node, en draagt hem over.
                  Een node zonder eigenaar kun je hier toewijzen.
                </p>
                {n.last_heartbeat_at && (
                  <p className="text-xs text-muted-foreground">
                    Laatste heartbeat: {new Date(n.last_heartbeat_at).toLocaleString("nl-NL")}
                  </p>
                )}
              </CardContent>
            </Card>
          );
        })}
      </div>
    </div>
  );
}

export default function AdminNodesPage() {
  return (
    <AdminGuard>
      <NodesInner />
    </AdminGuard>
  );
}
