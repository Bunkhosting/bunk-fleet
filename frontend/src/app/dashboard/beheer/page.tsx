"use client";

import { PageHeader } from "@/components/layout/page-header";
import { useEffect, useState } from "react";
import Link from "next/link";
import { Users, Server, HardDrive, Wallet, Loader2, ArrowRight } from "lucide-react";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { AdminGuard } from "@/components/admin/admin-guard";
import { adminApi, type AdminStats } from "@/lib/api";
import { formatEuro } from "@/lib/utils";

function Stat({ label, value, sub }: { label: string; value: string | number; sub?: string }) {
  return (
    <div className="rounded-lg border p-4">
      <p className="text-xs text-muted-foreground">{label}</p>
      <p className="text-2xl font-bold">{value}</p>
      {sub && <p className="mt-1 text-xs text-muted-foreground">{sub}</p>}
    </div>
  );
}

function Overview() {
  const [stats, setStats] = useState<AdminStats | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    adminApi
      .stats()
      .then(setStats)
      .catch(() => {})
      .finally(() => setLoading(false));
  }, []);

  if (loading) {
    return (
      <div className="flex justify-center py-20">
        <Loader2 className="h-8 w-8 animate-spin text-primary" />
      </div>
    );
  }

  return (
    <div className="space-y-8">
      <PageHeader title="Beheer" description="Platform-overzicht en beheer.">
        <Button variant="outline" size="sm" asChild>
          <Link href="/dashboard/beheer/metrics">
            Cijfers <ArrowRight className="ml-1 h-4 w-4" />
          </Link>
        </Button>
      </PageHeader>

      {stats && (
        <div className="grid gap-6 lg:grid-cols-2">
          <Card>
            <CardHeader className="flex flex-row items-center justify-between pb-3">
              <CardTitle className="flex items-center gap-2 text-base">
                <Users className="h-4 w-4" /> Gebruikers
              </CardTitle>
              <Button variant="ghost" size="sm" asChild>
                <Link href="/dashboard/beheer/users">Beheren <ArrowRight className="ml-1 h-4 w-4" /></Link>
              </Button>
            </CardHeader>
            <CardContent className="grid grid-cols-2 gap-3 sm:grid-cols-4">
              <Stat label="Totaal" value={stats.users.total} />
              <Stat label="Klanten" value={stats.users.user} />
              <Stat label="Admins" value={stats.users.admin} />
            </CardContent>
          </Card>

          <Card>
            <CardHeader className="flex flex-row items-center justify-between pb-3">
              <CardTitle className="flex items-center gap-2 text-base">
                <Server className="h-4 w-4" /> VPS&apos;en
              </CardTitle>
              <Button variant="ghost" size="sm" asChild>
                <Link href="/dashboard/beheer/vps">Beheren <ArrowRight className="ml-1 h-4 w-4" /></Link>
              </Button>
            </CardHeader>
            <CardContent className="grid grid-cols-2 gap-3 sm:grid-cols-4">
              <Stat label="Totaal" value={stats.vpses.total} />
              <Stat label="Actief" value={stats.vpses.active} />
              <Stat label="Gestopt" value={stats.vpses.stopped} />
              <Stat label="Mislukt" value={stats.vpses.failed} />
            </CardContent>
          </Card>

          <Card>
            <CardHeader className="flex flex-row items-center justify-between pb-3">
              <CardTitle className="flex items-center gap-2 text-base">
                <HardDrive className="h-4 w-4" /> Nodes
              </CardTitle>
              <Button variant="ghost" size="sm" asChild>
                <Link href="/dashboard/beheer/nodes">Bekijken <ArrowRight className="ml-1 h-4 w-4" /></Link>
              </Button>
            </CardHeader>
            <CardContent className="grid grid-cols-2 gap-3 sm:grid-cols-4">
              <Stat label="Totaal" value={stats.nodes.total} />
              <Stat label="Online" value={stats.nodes.online} />
              <Stat label="Datacenter" value={stats.nodes.datacenter} />
              <Stat label="Community" value={stats.nodes.community} />
            </CardContent>
          </Card>

          <Card>
            <CardHeader className="pb-3">
              <CardTitle className="flex items-center gap-2 text-base">
                <Wallet className="h-4 w-4" /> Tegoed (openstaande verplichting)
              </CardTitle>
            </CardHeader>
            <CardContent className="space-y-4">
              <Stat
                label="Totaal klant-tegoed"
                value={formatEuro(stats.credit_outstanding_cents / 100)}
                sub="Som van alle wallet-saldi"
              />
              <div className="space-y-1 border-t pt-3 text-sm">
                <Regel label="Bijgeboekt uit betalingen" cents={stats.credit_breakdown.betaald} />
                <Regel label="Welkomstkrediet" cents={stats.credit_breakdown.weggegeven} />
                <Regel label="Handmatig door een beheerder" cents={stats.credit_breakdown.handmatig} />
                <Regel label="Verbruikt door VPS&apos;en" cents={stats.credit_breakdown.verbruikt} />
                {stats.credit_breakdown.overig !== 0 && (
                  <Regel label="Nog niet ingedeeld" cents={stats.credit_breakdown.overig} />
                )}
              </div>
              {stats.credit_breakdown.verbruikt > 0 && (
                <p className="rounded-md bg-destructive/10 px-3 py-2 text-xs text-destructive-text">
                  Er is meer terugbetaald dan er ooit is afgeschreven. Verbruik hoort een
                  negatief getal te zijn; staat het in de plus, dan is er ergens dubbel
                  terugbetaald.
                </p>
              )}
              <p className="text-xs text-muted-foreground">
                Alleen de eerste regel is geld dat daadwerkelijk is binnengekomen. Handmatige
                boekingen verhogen wel wat een klant kan uitgeven, maar er staat geen betaling
                achter &mdash; ze tellen dan ook niet mee in de omzet of de btw-aangifte.
              </p>
            </CardContent>
          </Card>
        </div>
      )}
    </div>
  );
}

/** Eén bedrag op een label, met het teken dat het in het grootboek heeft. */
function Regel({ label, cents }: { label: string; cents: number }) {
  return (
    <div className="flex justify-between gap-4">
      <span className="text-muted-foreground">{label}</span>
      <span className={cents < 0 ? "font-medium text-muted-foreground" : "font-medium"}>
        {formatEuro(cents / 100)}
      </span>
    </div>
  );
}

export default function AdminOverviewPage() {
  return (
    <AdminGuard>
      <Overview />
    </AdminGuard>
  );
}
