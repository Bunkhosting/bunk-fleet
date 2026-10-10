"use client";

import { useCallback, useEffect, useState } from "react";
import { useParams, useRouter } from "next/navigation";
import { Loader2, ArrowLeft, ShieldCheck, KeyRound, Mail } from "lucide-react";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { StatusBadge } from "@/components/vps/status-badge";
import { useToast } from "@/components/ui/use-toast";
import { AdminGuard } from "@/components/admin/admin-guard";
import { adminApi, type AdminUserDetail, vpsStatusFromApi } from "@/lib/api";
import { isOnbeperktTegoed } from "@/lib/utils";

const euro = (cents: number) =>
  (cents / 100).toLocaleString("nl-NL", { style: "currency", currency: "EUR" });

const datum = (iso: string | null) =>
  iso ? new Date(iso).toLocaleString("nl-NL", { dateStyle: "short", timeStyle: "short" }) : "—";

const dag = (iso: string | null) =>
  iso ? new Date(iso).toLocaleDateString("nl-NL") : "—";

function KlantDetail() {
  const { id } = useParams<{ id: string }>();
  const router = useRouter();
  const { toast } = useToast();
  const [data, setData] = useState<AdminUserDetail | null>(null);
  const [loading, setLoading] = useState(true);

  // Zie abonnementen/page.tsx: loading begint op true, dus geen synchrone
  // setState in het effect.
  const load = useCallback(() => {
    adminApi
      .userDetail(id)
      .then(setData)
      .catch(() =>
        toast({ title: "Fout", description: "Kon deze klant niet laden.", variant: "destructive" }),
      )
      .finally(() => setLoading(false));
  }, [id, toast]);

  useEffect(load, [load]);

  if (loading || !data) {
    return (
      <div className="flex justify-center py-20">
        <Loader2 className="h-8 w-8 animate-spin text-primary" />
      </div>
    );
  }

  const u = data.user;

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <Button variant="ghost" size="sm" className="mb-2 gap-2 px-0" onClick={() => router.push("/dashboard/beheer/users")}>
            <ArrowLeft className="h-4 w-4" /> Terug naar gebruikers
          </Button>
          <h1 className="text-2xl font-bold tracking-tight">{u.email}</h1>
          <p className="text-muted-foreground">
            {u.name || "geen naam"} · klant sinds {dag(u.created_at)}
          </p>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <Badge variant={u.role === "admin" ? "default" : "outline"}>{u.role}</Badge>
          <Badge variant={u.confirmed ? "outline" : "destructive"} className="gap-1">
            <Mail className="h-3 w-3" /> {u.confirmed ? "bevestigd" : "niet bevestigd"}
          </Badge>
          {u.totp_enabled && (
            <Badge variant="outline" className="gap-1">
              <ShieldCheck className="h-3 w-3" /> TOTP
            </Badge>
          )}
          {u.passkeys > 0 && (
            <Badge variant="outline" className="gap-1">
              <KeyRound className="h-3 w-3" /> {u.passkeys} passkey{u.passkeys === 1 ? "" : "s"}
            </Badge>
          )}
        </div>
      </div>

      <div className="grid gap-4 sm:grid-cols-3">
        {[
          {
            label: "Tegoed",
            value: isOnbeperktTegoed(data.balance_cents)
              ? `Unlimited (${euro(data.balance_cents)})`
              : euro(data.balance_cents),
          },
          { label: "VPS'en", value: String(data.vpses.length) },
          {
            label: "Actieve abonnementen",
            value: String(data.subscriptions.filter((s) => s.status === "active").length),
          },
        ].map((k) => (
          <Card key={k.label}>
            <CardContent className="p-4">
              <p className="text-xs uppercase tracking-wide text-muted-foreground">{k.label}</p>
              <p className="mt-1 text-2xl font-bold tabular-nums">{k.value}</p>
            </CardContent>
          </Card>
        ))}
      </div>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">VPS&apos;en ({data.vpses.length})</CardTitle>
        </CardHeader>
        <CardContent>
          {data.vpses.length === 0 ? (
            <p className="text-sm text-muted-foreground">Deze klant heeft geen VPS&apos;en.</p>
          ) : (
            <ul className="divide-y rounded-lg border">
              {data.vpses.map((v) => (
                <li key={v.id} className="flex items-center justify-between gap-3 px-3 py-2 text-sm">
                  <div>
                    <p className="font-medium">{v.name}</p>
                    <p className="text-xs text-muted-foreground">
                      {v.vcpu} vCPU · {v.ram_mb} MB · {v.disk_gb} GB
                    </p>
                  </div>
                  <StatusBadge status={vpsStatusFromApi(v.status)} />
                </li>
              ))}
            </ul>
          )}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Abonnementen</CardTitle>
        </CardHeader>
        <CardContent>
          {data.subscriptions.length === 0 ? (
            <p className="text-sm text-muted-foreground">Geen abonnementen.</p>
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-b text-left text-muted-foreground">
                    <th className="py-2 pr-4 font-medium">VPS</th>
                    <th className="py-2 pr-4 font-medium">Status</th>
                    <th className="py-2 pr-4 text-right font-medium">Per maand</th>
                    <th className="py-2 font-medium">Volgende afschrijving</th>
                  </tr>
                </thead>
                <tbody>
                  {data.subscriptions.map((s) => (
                    <tr key={s.id} className="border-b last:border-0">
                      <td className="py-2 pr-4">{s.vps_name ?? "—"}</td>
                      <td className="py-2 pr-4">
                        <Badge variant={s.status === "past_due" ? "destructive" : "outline"}>
                          {s.status}
                        </Badge>
                      </td>
                      <td className="py-2 pr-4 text-right tabular-nums">
                        {s.price_monthly ? `€ ${s.price_monthly}` : "—"}
                      </td>
                      <td className="py-2">{dag(s.next_billing_date)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Opwaarderingen</CardTitle>
        </CardHeader>
        <CardContent>
          {data.topups.length === 0 ? (
            <p className="text-sm text-muted-foreground">Nog geen opwaarderingen.</p>
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-b text-left text-muted-foreground">
                    <th className="py-2 pr-4 font-medium">Referentie</th>
                    <th className="py-2 pr-4 text-right font-medium">Bedrag</th>
                    <th className="py-2 pr-4 font-medium">Status</th>
                    <th className="py-2 font-medium">Betaald</th>
                  </tr>
                </thead>
                <tbody>
                  {data.topups.map((t) => (
                    <tr key={t.id} className="border-b last:border-0">
                      <td className="py-2 pr-4 font-mono text-xs">
                        {t.reference}
                        {!t.via_provider && (
                          <span className="ml-2 text-muted-foreground">(handmatig)</span>
                        )}
                      </td>
                      <td className="py-2 pr-4 text-right tabular-nums">{euro(t.amount_cents)}</td>
                      <td className="py-2 pr-4">{t.status}</td>
                      <td className="py-2">{datum(t.paid_at)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Grootboek (laatste {data.ledger.length})</CardTitle>
        </CardHeader>
        <CardContent>
          {data.ledger.length === 0 ? (
            <p className="text-sm text-muted-foreground">Geen boekingen.</p>
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-b text-left text-muted-foreground">
                    <th className="py-2 pr-4 font-medium">Wanneer</th>
                    <th className="py-2 pr-4 font-medium">Soort</th>
                    <th className="py-2 pr-4 font-medium">Omschrijving</th>
                    <th className="py-2 text-right font-medium">Bedrag</th>
                  </tr>
                </thead>
                <tbody>
                  {data.ledger.map((e) => (
                    <tr key={e.id} className="border-b last:border-0">
                      <td className="py-2 pr-4 whitespace-nowrap">{datum(e.at)}</td>
                      <td className="py-2 pr-4 font-mono text-xs">{e.kind}</td>
                      <td className="py-2 pr-4 text-muted-foreground">{e.description ?? "—"}</td>
                      <td
                        className={`py-2 text-right tabular-nums ${e.amount_cents < 0 ? "text-destructive-text" : ""}`}
                      >
                        {euro(e.amount_cents)}
                      </td>
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

export default function KlantDetailPagina() {
  return (
    <AdminGuard>
      <KlantDetail />
    </AdminGuard>
  );
}
