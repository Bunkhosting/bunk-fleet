"use client";

import { useEffect, useState } from "react";
import { Loader2, Search, Play, Square, Trash2, RefreshCw } from "lucide-react";
import { Card, CardContent } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { useToast } from "@/components/ui/use-toast";
import { AdminGuard } from "@/components/admin/admin-guard";
import { StatusBadge } from "@/components/vps/status-badge";
import { adminApi, parseApiError, vpsStatusFromApi, type AdminVps } from "@/lib/api";


function VpsInner() {
  const { toast } = useToast();
  const [vpses, setVpses] = useState<AdminVps[]>([]);
  const [loading, setLoading] = useState(true);
  const [q, setQ] = useState("");
  const [busy, setBusy] = useState<string | null>(null);

  const load = () =>
    adminApi
      .vpses()
      .then((all) => setVpses(all.filter((v) => v.status !== "deleted")))
      .catch(() => toast({ title: "Fout", description: "Kon VPS'en niet laden.", variant: "destructive" }))
      .finally(() => setLoading(false));

  useEffect(() => {
    load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  async function act(v: AdminVps, kind: "start" | "stop" | "delete") {
    if (kind === "delete" && !window.confirm(`VPS "${v.name}" van ${v.owner_email} definitief verwijderen?`)) return;
    setBusy(v.id);
    try {
      if (kind === "start") await adminApi.vpsStart(v.id);
      else if (kind === "stop") await adminApi.vpsStop(v.id);
      else await adminApi.vpsDelete(v.id);
      toast({ title: "Verzoek ingediend", description: `${v.name}: ${kind}` });
      await load();
    } catch (e) {
      toast({ title: "Mislukt", description: parseApiError(e, "Actie mislukt."), variant: "destructive" });
    } finally {
      setBusy(null);
    }
  }

  const filtered = vpses.filter(
    (v) =>
      v.name.toLowerCase().includes(q.toLowerCase()) ||
      (v.owner_email ?? "").toLowerCase().includes(q.toLowerCase()) ||
      (v.location ?? "").toLowerCase().includes(q.toLowerCase())
  );

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
          <h1 className="text-2xl font-bold tracking-tight">VPS-beheer</h1>
          <p className="text-muted-foreground">{vpses.length} VPS&apos;en over alle klanten.</p>
        </div>
        <Button variant="ghost" size="sm" className="gap-2" onClick={load}>
          <RefreshCw className="h-4 w-4" /> Ververs
        </Button>
      </div>

      <div className="relative max-w-sm">
        <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
        <Input placeholder="Zoek op naam, eigenaar of locatie" value={q} onChange={(e) => setQ(e.target.value)} className="pl-9" />
      </div>

      <Card>
        <CardContent className="p-0">
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead className="border-b text-left text-xs text-muted-foreground">
                <tr>
                  <th className="px-4 py-3">VPS</th>
                  <th className="px-4 py-3">Eigenaar</th>
                  <th className="px-4 py-3">Status</th>
                  <th className="px-4 py-3">Specs</th>
                  <th className="px-4 py-3">Locatie</th>
                  <th className="px-4 py-3"></th>
                </tr>
              </thead>
              <tbody>
                {filtered.map((v) => (
                  <tr key={v.id} className="border-b last:border-0">
                    <td className="px-4 py-3">
                      <div className="font-medium">{v.name}</div>
                      <div className="text-xs text-muted-foreground font-mono">{v.ip_address ?? "—"}</div>
                    </td>
                    <td className="px-4 py-3 text-xs">{v.owner_email ?? "—"}</td>
                    <td className="px-4 py-3">
                      <StatusBadge status={vpsStatusFromApi(v.status)} />
                    </td>
                    <td className="px-4 py-3 text-xs">
                      {v.vcpu} vCPU · {Math.round(v.ram_mb / 1024)} GB · {v.disk_gb} GB
                    </td>
                    <td className="px-4 py-3 text-xs">
                      <div className="font-medium">{v.location ?? v.region ?? "—"}</div>
                      <div className="text-muted-foreground font-mono">{v.node ?? "—"}</div>
                    </td>
                    <td className="px-4 py-3">
                      <div className="flex justify-end gap-1">
                        <Button variant="ghost" size="icon" className="h-8 w-8" disabled={busy === v.id || v.status !== "stopped"} title="Starten" aria-label="Starten" onClick={() => act(v, "start")}>
                          <Play className="h-4 w-4" />
                        </Button>
                        <Button variant="ghost" size="icon" className="h-8 w-8" disabled={busy === v.id || v.status !== "active"} title="Stoppen" aria-label="Stoppen" onClick={() => act(v, "stop")}>
                          <Square className="h-4 w-4" />
                        </Button>
                        <Button variant="ghost" size="icon" className="h-8 w-8 text-destructive" disabled={busy === v.id || v.status === "deleting"} title="Verwijderen" aria-label="Verwijderen" onClick={() => act(v, "delete")}>
                          <Trash2 className="h-4 w-4" />
                        </Button>
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </CardContent>
      </Card>
    </div>
  );
}

export default function AdminVpsPage() {
  return (
    <AdminGuard>
      <VpsInner />
    </AdminGuard>
  );
}
