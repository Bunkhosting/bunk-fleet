"use client";

import { PageHeader } from "@/components/layout/page-header";
import { useCallback, useEffect, useState } from "react";
import { Loader2, RefreshCw } from "lucide-react";
import { Card, CardContent } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { useToast } from "@/components/ui/use-toast";
import { AdminGuard } from "@/components/admin/admin-guard";
import { useNieuwste } from "@/hooks/use-nieuwste";
import { adminApi, type AdminCommand } from "@/lib/api";

const FILTERS = [
  { key: "", label: "Alles" },
  { key: "failed", label: "Mislukt" },
  { key: "pending", label: "In de wacht" },
  { key: "done", label: "Klaar" },
] as const;

const KLEUR: Record<string, "default" | "secondary" | "destructive" | "outline"> = {
  done: "outline",
  failed: "destructive",
  pending: "secondary",
  delivered: "default",
};

const wanneer = (iso: string) =>
  new Date(iso).toLocaleString("nl-NL", { dateStyle: "short", timeStyle: "medium" });

function ActiviteitInner() {
  const { toast } = useToast();
  const [commands, setCommands] = useState<AdminCommand[] | null>(null);
  const [filter, setFilter] = useState<string>("");
  const [loading, setLoading] = useState(true);
  const nieuwste = useNieuwste();

  const load = useCallback(
    // Geen setLoading hier: loading begint op true en een synchrone setState in
    // een effect kost een extra rendercyclus. De knoppen hieronder zetten hem,
    // want dan staat er al een tabel op het scherm die vervangen wordt.
    (status: string) => {
      // Snel van filter wisselen: alleen het laatste antwoord telt.
      const isNieuwste = nieuwste();
      adminApi
        .commands(status || undefined)
        .then((c) => {
          if (isNieuwste()) setCommands(c);
        })
        .catch(() => {
          if (isNieuwste())
            toast({ title: "Fout", description: "Kon de activiteit niet laden.", variant: "destructive" });
        })
        .finally(() => {
          if (isNieuwste()) setLoading(false);
        });
    },
    [toast, nieuwste],
  );

  useEffect(() => load(filter), [load, filter]);

  return (
    <div className="space-y-6">
      <PageHeader title="Activiteit" description="Wat de fleet heeft gedaan. Bij een mislukking staat hier de reden, niet alleen het aantal.">
        <div className="flex flex-wrap items-center gap-2">
          {FILTERS.map((f) => (
            <Button
              key={f.key}
              variant={filter === f.key ? "default" : "outline"}
              size="sm"
              onClick={() => {
                setLoading(true);
                setFilter(f.key);
              }}
            >
              {f.label}
            </Button>
          ))}
          <Button
            variant="ghost"
            size="sm"
            className="gap-2"
            aria-label="Vernieuwen"
            title="Vernieuwen"
            onClick={() => {
              setLoading(true);
              load(filter);
            }}
          >
            <RefreshCw className="h-4 w-4" aria-hidden="true" />
          </Button>
        </div>
      </PageHeader>

      <Card>
        <CardContent className="p-4">
          {loading || !commands ? (
            <div className="flex justify-center py-12">
              <Loader2 className="h-6 w-6 animate-spin text-primary" />
            </div>
          ) : commands.length === 0 ? (
            <p className="text-sm text-muted-foreground">Niets te zien in deze selectie.</p>
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-b text-left text-muted-foreground">
                    <th className="py-2 pr-4 font-medium">Wanneer</th>
                    <th className="py-2 pr-4 font-medium">Opdracht</th>
                    <th className="py-2 pr-4 font-medium">Status</th>
                    <th className="py-2 pr-4 font-medium">Node</th>
                    <th className="py-2 pr-4 font-medium">VPS</th>
                    <th className="py-2 font-medium">Fout</th>
                  </tr>
                </thead>
                <tbody>
                  {commands.map((c) => (
                    <tr key={c.id} className="border-b last:border-0">
                      <td className="py-2 pr-4 whitespace-nowrap">{wanneer(c.at)}</td>
                      <td className="py-2 pr-4 font-mono text-xs">{c.kind}</td>
                      <td className="py-2 pr-4">
                        <Badge variant={KLEUR[c.status] ?? "outline"}>{c.status}</Badge>
                      </td>
                      <td className="py-2 pr-4">{c.node ?? "—"}</td>
                      <td className="py-2 pr-4">{c.vps_name ?? "—"}</td>
                      <td className="py-2 text-destructive-text">{c.error ?? ""}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </CardContent>
      </Card>
    </div>
  );
}

export default function ActiviteitPagina() {
  return (
    <AdminGuard>
      <ActiviteitInner />
    </AdminGuard>
  );
}
