"use client";

import { useCallback, useEffect, useState } from "react";
import Link from "next/link";
import { Loader2, PlusCircle, Server } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { VpsCard } from "@/components/vps/vps-card";
import { LoadError } from "@/components/feedback/load-error";
import { vpsApi } from "@/lib/api";
import type { Vps, VpsStatus } from "@/lib/types";

const TRANSITIONAL_STATUSES: VpsStatus[] = [
  "PENDING",
  "PROVISIONING",
  "DELETING",
];
const POLL_INTERVAL_MS = 10_000;

export default function VpsListPage() {
  const [vpsList, setVpsList] = useState<Vps[]>([]);
  const [loading, setLoading] = useState(true);
  // Alleen relevant zolang er nog nooit een lijst binnenkwam. Mislukt een
  // latere poll, dan blijft de laatste goede lijst staan.
  const [loadFailed, setLoadFailed] = useState(false);

  const fetchVps = useCallback(async () => {
    try {
      const response = await vpsApi.list();
      setVpsList(response.data.results);
      setLoadFailed(false);
    } catch {
      // Een 401 stuurt de layout naar het inlogscherm; al het andere hoort hier
      // zichtbaar te zijn en niet te lezen als "je hebt geen VPS'en".
      setLoadFailed(true);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    // Via een microtask: dan kan een synchrone worp uit fetchVps nooit binnen
    // dezelfde rendercyclus state zetten. Voor de gebruiker onmerkbaar.
    queueMicrotask(fetchVps);
  }, [fetchVps]);

  // Poll zolang er een VPS in een overgangsstatus zit, zodat de lijst
  // automatisch bijwerkt zodra de status verandert.
  const hasTransitional = vpsList.some((vps) =>
    TRANSITIONAL_STATUSES.includes(vps.status)
  );

  useEffect(() => {
    if (!hasTransitional) return;
    const interval = setInterval(fetchVps, POLL_INTERVAL_MS);
    return () => clearInterval(interval);
  }, [hasTransitional, fetchVps]);

  if (loading) {
    return (
      <div className="flex items-center justify-center py-20">
        <Loader2 className="h-8 w-8 animate-spin text-primary" />
      </div>
    );
  }

  if (loadFailed && vpsList.length === 0) {
    return (
      <div className="space-y-6">
        <h1 className="text-3xl font-bold tracking-tight">Mijn VPS&apos;en</h1>
        <LoadError
          message="Je VPS'en konden niet worden opgehaald. Er is niets verloren gegaan; probeer het zo opnieuw."
          onRetry={() => {
            setLoading(true);
            fetchVps();
          }}
        />
      </div>
    );
  }

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-3xl font-bold tracking-tight">Mijn VPS&apos;en</h1>
          <p className="text-muted-foreground">
            Beheer en bekijk al je virtuele servers.
          </p>
        </div>
        <Link href="/dashboard/vps/new">
          <Button>
            <PlusCircle className="mr-2 h-4 w-4" />
            Nieuwe VPS
          </Button>
        </Link>
      </div>

      {vpsList.length > 0 ? (
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          {vpsList.map((vps) => (
            <VpsCard key={vps.id} vps={vps} />
          ))}
        </div>
      ) : (
        <Card>
          <CardContent className="flex flex-col items-center justify-center py-16">
            <Server className="h-12 w-12 text-muted-foreground mb-4" />
            <h3 className="text-lg font-semibold mb-2">Geen VPS&apos;en gevonden</h3>
            <p className="text-muted-foreground mb-6 text-center">
              Je hebt nog geen VPS&apos;en. Vraag je eerste VPS aan!
            </p>
            <Link href="/dashboard/vps/new">
              <Button>
                <PlusCircle className="mr-2 h-4 w-4" />
                Eerste VPS aanvragen
              </Button>
            </Link>
          </CardContent>
        </Card>
      )}
    </div>
  );
}
