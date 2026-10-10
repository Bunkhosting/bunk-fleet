"use client";

import { PageHeader } from "@/components/layout/page-header";
import { useEffect, useState } from "react";
import Link from "next/link";
import { Loader2, Server, ServerOff, PlusCircle, Wallet } from "lucide-react";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { VpsCard } from "@/components/vps/vps-card";
import { LoadError } from "@/components/feedback/load-error";
import { vpsApi, billingApi } from "@/lib/api";
import { useUser } from "@/contexts/UserContext";
import { formatBalance } from "@/lib/utils";
import type { Vps } from "@/lib/types";

export default function DashboardPage() {
  // The dashboard layout's UserProvider has already fetched /auth/me — reuse it
  // instead of firing a second identical request on every dashboard visit.
  const { user } = useUser();
  const [vpsList, setVpsList] = useState<Vps[]>([]);
  const [balanceCents, setBalanceCents] = useState<number | null>(null);
  const [loading, setLoading] = useState(true);
  const [vpsFailed, setVpsFailed] = useState(false);
  const [poging, setPoging] = useState(0);

  useEffect(() => {
    // Both start now and are awaited separately. Sequentially they cost two
    // round trips for two answers that have nothing to do with each other, and
    // the spinner stayed up for the slower of them. Handled apart rather than
    // with Promise.all so the wallet — which this page can live without — never
    // holds up the list or blanks the page when it fails.
    const vpsRequest = vpsApi.list();
    const walletRequest = billingApi.wallet();

    vpsRequest
      .then((res) => {
        setVpsList(res.data.results);
        setVpsFailed(false);
      })
      .catch(() => {
        // Een 401 stuurt de layout door. Al het andere moet hier zichtbaar
        // zijn: anders staat er "0 VPS'en" en "je hebt nog geen VPS'en".
        setVpsFailed(true);
      })
      .finally(() => setLoading(false));

    walletRequest
      .then((res) => setBalanceCents(res.data.balance_cents))
      .catch(() => {
        // leave balance unknown
      });
  }, [poging]);

  if (loading) {
    return (
      <div className="flex items-center justify-center py-20">
        <Loader2 className="h-8 w-8 animate-spin text-primary" />
      </div>
    );
  }

  const RECENT_VPS_LIMIT = 5;

  const totalVps = vpsList.length;
  const activeVps = vpsList.filter((v) => v.status === "ACTIVE").length;
  const stoppedVps = vpsList.filter((v) => v.status === "STOPPED").length;
  const recentVps = vpsList.slice(0, RECENT_VPS_LIMIT);

  return (
    <div className="space-y-8">
      {/* Welcome */}
      <PageHeader title={<>Welkom terug{user ? `, ${user.name}` : ""}</>} description="Hier is een overzicht van je VPS omgeving." />

      {vpsFailed && (
        <LoadError
          message="Je VPS'en konden niet worden opgehaald. Er is niets verloren gegaan; probeer het zo opnieuw."
          onRetry={() => {
            setLoading(true);
            setPoging((p) => p + 1);
          }}
        />
      )}

      {/* Stats cards */}
      {!vpsFailed && (
      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <Card>
          <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
            <CardTitle className="text-sm font-medium">Totaal VPS&apos;en</CardTitle>
            <Server className="h-4 w-4 text-muted-foreground" />
          </CardHeader>
          <CardContent>
            <div className="text-2xl font-bold">{totalVps}</div>
          </CardContent>
        </Card>
        <Card>
          <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
            <CardTitle className="text-sm font-medium">Actieve VPS&apos;en</CardTitle>
            <Server className="h-4 w-4 text-green-500" />
          </CardHeader>
          <CardContent>
            <div className="text-2xl font-bold text-green-600">{activeVps}</div>
          </CardContent>
        </Card>
        <Card>
          <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
            <CardTitle className="text-sm font-medium">Gestopte VPS&apos;en</CardTitle>
            <ServerOff className="h-4 w-4 text-muted-foreground" />
          </CardHeader>
          <CardContent>
            <div className="text-2xl font-bold">{stoppedVps}</div>
          </CardContent>
        </Card>
        <Link href="/dashboard/billing" className="block">
          <Card className="h-full transition-colors hover:border-primary/50">
            <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
              <CardTitle className="text-sm font-medium">Tegoed</CardTitle>
              <Wallet className="h-4 w-4 text-muted-foreground" />
            </CardHeader>
            <CardContent>
              <div className="text-2xl font-bold">
                {balanceCents === null ? "—" : formatBalance(balanceCents)}
              </div>
              <p className="mt-1 text-xs text-muted-foreground">Opwaarderen →</p>
            </CardContent>
          </Card>
        </Link>
      </div>
      )}

      {/* Recent VPS list */}
      {!vpsFailed && (
      <div className="space-y-4">
        <div className="flex items-center justify-between">
          <h2 className="text-xl font-semibold">Recente VPS&apos;en</h2>
          <Button asChild variant="ghost" size="sm">
            <Link href="/dashboard/vps">
              Bekijk alle VPS&apos;en
            </Link>
          </Button>
        </div>

        {recentVps.length > 0 ? (
          <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
            {recentVps.map((vps) => (
              <VpsCard key={vps.id} vps={vps} />
            ))}
          </div>
        ) : (
          <Card>
            <CardContent className="flex flex-col items-center justify-center py-10">
              <Server className="h-10 w-10 text-muted-foreground mb-4" />
              <p className="text-muted-foreground mb-4">
                Je hebt nog geen VPS&apos;en.
              </p>
              <Button asChild>
                <Link href="/dashboard/vps/new">
                  <PlusCircle className="mr-2 h-4 w-4" />
                  Nieuwe VPS aanvragen
                </Link>
              </Button>
            </CardContent>
          </Card>
        )}
      </div>
      )}

      {/* Quick action */}
      {totalVps > 0 && (
        <div>
          <Button asChild>
            <Link href="/dashboard/vps/new">
              <PlusCircle className="mr-2 h-4 w-4" />
              Nieuwe VPS aanvragen
            </Link>
          </Button>
        </div>
      )}
    </div>
  );
}
