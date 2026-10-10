"use client";

import { PageHeader } from "@/components/layout/page-header";
import { useCallback, useEffect, useState } from "react";
import Link from "next/link";
import { Loader2, RefreshCw, AlertTriangle } from "lucide-react";
import { Card, CardContent } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { useToast } from "@/components/ui/use-toast";
import { AdminGuard } from "@/components/admin/admin-guard";
import { adminApi, type AdminSubscription } from "@/lib/api";

const dag = (iso: string | null) => (iso ? new Date(iso).toLocaleDateString("nl-NL") : "—");

function AbonnementenInner() {
  const { toast } = useToast();
  const [data, setData] = useState<{
    subscriptions: AdminSubscription[];
    active: number;
    past_due: number;
    monthly_total: string;
  } | null>(null);
  const [loading, setLoading] = useState(true);

  // setLoading staat bewust niet hier: loading begint al op true, en een
  // synchrone setState in een effect kost een extra rendercyclus. De
  // verversknop zet hem wel, want dan staat er al iets op het scherm.
  const load = useCallback(() => {
    adminApi
      .subscriptions()
      .then(setData)
      .catch(() =>
        toast({ title: "Fout", description: "Kon abonnementen niet laden.", variant: "destructive" }),
      )
      .finally(() => setLoading(false));
  }, [toast]);

  useEffect(load, [load]);

  if (loading || !data) {
    return (
      <div className="flex justify-center py-20">
        <Loader2 className="h-8 w-8 animate-spin text-primary" />
      </div>
    );
  }

  return (
    <div className="space-y-6">
      <PageHeader title="Abonnementen" description="Wat er loopt, en wat er niet meer geïnd wordt.">
        <Button
          variant="ghost"
          size="sm"
          className="gap-2"
          onClick={() => {
            setLoading(true);
            load();
          }}
        >
          <RefreshCw className="h-4 w-4" /> Ververs
        </Button>
      </PageHeader>

      <div className="grid gap-4 sm:grid-cols-3">
        {[
          { label: "Actief", value: String(data.active) },
          { label: "Achterstallig", value: String(data.past_due), alarm: data.past_due > 0 },
          { label: "Per maand", value: `€ ${data.monthly_total}` },
        ].map((k) => (
          <Card key={k.label} className={k.alarm ? "border-destructive/50" : undefined}>
            <CardContent className="p-4">
              <p className="text-xs uppercase tracking-wide text-muted-foreground">{k.label}</p>
              <p
                className={`mt-1 text-2xl font-bold tabular-nums ${k.alarm ? "text-destructive-text" : ""}`}
              >
                {k.value}
              </p>
            </CardContent>
          </Card>
        ))}
      </div>

      {data.past_due > 0 && (
        <div className="flex items-start gap-3 rounded-lg border border-destructive/40 bg-destructive/5 p-4 text-sm">
          <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0 text-destructive" />
          <p className="text-muted-foreground">
            {data.past_due} abonnement{data.past_due === 1 ? "" : "en"} kon niet worden afgeschreven.
            De bijbehorende VPS&apos;en zijn opgeschort; de klant denkt waarschijnlijk dat zijn server
            stuk is. Na dertig dagen worden ze definitief verwijderd.
          </p>
        </div>
      )}

      <Card>
        <CardContent className="p-4">
          {data.subscriptions.length === 0 ? (
            <p className="text-sm text-muted-foreground">Er lopen geen abonnementen.</p>
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-b text-left text-muted-foreground">
                    <th className="py-2 pr-4 font-medium">VPS</th>
                    <th className="py-2 pr-4 font-medium">Status</th>
                    <th className="py-2 pr-4 text-right font-medium">Per maand</th>
                    <th className="py-2 pr-4 font-medium">Volgende afschrijving</th>
                    <th className="py-2 font-medium">Nieuwe poging</th>
                  </tr>
                </thead>
                <tbody>
                  {data.subscriptions.map((s) => (
                    <tr key={s.id} className="border-b last:border-0">
                      <td className="py-2 pr-4">
                        {s.vps_id ? (
                          <Link
                            href={`/dashboard/beheer/vps`}
                            className="hover:underline"
                          >
                            {s.vps_name ?? s.vps_id.slice(0, 8)}
                          </Link>
                        ) : (
                          "—"
                        )}
                      </td>
                      <td className="py-2 pr-4">
                        <Badge variant={s.status === "past_due" ? "destructive" : "outline"}>
                          {s.status}
                        </Badge>
                      </td>
                      <td className="py-2 pr-4 text-right tabular-nums">
                        {s.price_monthly ? `€ ${s.price_monthly}` : "—"}
                      </td>
                      <td className="py-2 pr-4">{dag(s.next_billing_date)}</td>
                      <td className="py-2">{dag(s.retry_at)}</td>
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

export default function AbonnementenPagina() {
  return (
    <AdminGuard>
      <AbonnementenInner />
    </AdminGuard>
  );
}
