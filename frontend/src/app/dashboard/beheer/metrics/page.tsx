"use client";

import { PageHeader } from "@/components/layout/page-header";
import * as React from "react";
import { Activity, Cpu, HardDrive, Loader2, MemoryStick, ShieldCheck } from "lucide-react";
import { AdminGuard } from "@/components/admin/admin-guard";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { adminApi, type AdminMetrics } from "@/lib/api";
import { useToast } from "@/components/ui/use-toast";

/** Percentage in use, for a bar that reads "how full is this". */
function usedPct(total: number, available: number): number {
  if (!total) return 0;
  return Math.round(((total - available) / total) * 100);
}

/** Red once it is nearly full — the point at which the next VPS will not fit. */
function barColour(pct: number): string {
  if (pct >= 90) return "bg-destructive";
  if (pct >= 75) return "bg-yellow-500";
  return "bg-primary";
}

function Meter({ label, total, available, unit }: {
  label: string;
  total: number;
  available: number;
  unit: string;
}) {
  const pct = usedPct(total, available);
  return (
    <div className="space-y-1">
      <div className="flex items-baseline justify-between text-sm">
        <span className="text-muted-foreground">{label}</span>
        <span className="font-mono">
          {total - available} / {total} {unit}
        </span>
      </div>
      <div className="h-2 w-full overflow-hidden rounded-full bg-muted">
        <div className={`h-full ${barColour(pct)}`} style={{ width: `${pct}%` }} />
      </div>
    </div>
  );
}

function heartbeatLabel(seconds: number | null): string {
  if (seconds === null) return "nooit";
  if (seconds < 90) return `${seconds}s geleden`;
  if (seconds < 3600) return `${Math.round(seconds / 60)} min geleden`;
  return `${Math.round(seconds / 3600)} uur geleden`;
}

export default function MetricsPage() {
  const [metrics, setMetrics] = React.useState<AdminMetrics | null>(null);
  const [loading, setLoading] = React.useState(true);
  const { toast } = useToast();

  React.useEffect(() => {
    adminApi
      .metrics()
      .then(setMetrics)
      .catch(() =>
        toast({
          variant: "destructive",
          title: "Kon de cijfers niet laden",
          description: "Probeer de pagina te verversen.",
        }),
      )
      .finally(() => setLoading(false));
  }, [toast]);

  if (loading) {
    return (
      <div className="flex justify-center py-20">
        <Loader2 className="h-8 w-8 animate-spin text-primary" />
      </div>
    );
  }

  if (!metrics) return null;

  const authTotals = metrics.auth.reduce(
    (acc, d) => ({
      successes: acc.successes + d.successes,
      failures: acc.failures + d.failures,
      registrations: acc.registrations + d.registrations,
      captcha_refusals: acc.captcha_refusals + d.captcha_refusals,
    }),
    { successes: 0, failures: 0, registrations: 0, captcha_refusals: 0 },
  );

  return (
    <AdminGuard>
      <div className="space-y-8">
        <PageHeader title="Cijfers" description="Alles op deze pagina is een totaal. Er staat geen enkele gebruiker in — niet in de inloggegevens, niet in de vlootcijfers — zodat dit overzicht geen persoonlijke gegevens verwerkt." />

        <Card>
          <CardHeader className="pb-3">
            <CardTitle className="flex items-center gap-2 text-base">
              <Cpu className="h-4 w-4" /> Capaciteit per node
            </CardTitle>
          </CardHeader>
          <CardContent className="space-y-6">
            {metrics.nodes.map((node) => (
              <div key={node.name} className="space-y-3">
                <div className="flex flex-wrap items-baseline justify-between gap-2">
                  <p className="font-medium font-mono">{node.name}</p>
                  <p className="text-sm text-muted-foreground">
                    {node.status} · {node.vps_count} VPS ·{" "}
                    {heartbeatLabel(node.seconds_since_heartbeat)}
                  </p>
                </div>
                <Meter label="vCPU" total={node.vcpu.total} available={node.vcpu.available} unit="" />
                <Meter
                  label="Geheugen"
                  total={node.ram_mb.total}
                  available={node.ram_mb.available}
                  unit="MB"
                />
                <Meter
                  label="Schijf"
                  total={node.disk_gb.total}
                  available={node.disk_gb.available}
                  unit="GB"
                />
              </div>
            ))}
            {metrics.nodes.length === 0 && (
              <p className="text-sm text-muted-foreground">Nog geen nodes.</p>
            )}
          </CardContent>
        </Card>

        <div className="grid gap-6 lg:grid-cols-2">
          <Card>
            <CardHeader className="pb-3">
              <CardTitle className="flex items-center gap-2 text-base">
                <ShieldCheck className="h-4 w-4" /> Inloggen, laatste 14 dagen
              </CardTitle>
            </CardHeader>
            <CardContent className="space-y-4">
              <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
                {[
                  ["Geslaagd", authTotals.successes],
                  ["Mislukt", authTotals.failures],
                  ["Nieuw", authTotals.registrations],
                  ["CAPTCHA", authTotals.captcha_refusals],
                ].map(([label, value]) => (
                  <div key={label as string}>
                    <p className="text-2xl font-semibold">{value as number}</p>
                    <p className="text-xs text-muted-foreground">{label as string}</p>
                  </div>
                ))}
              </div>

              <div className="space-y-1">
                {metrics.auth.map((d) => (
                  <div key={d.day} className="flex items-center justify-between text-sm">
                    <span className="font-mono text-muted-foreground">{d.day}</span>
                    <span className="font-mono">
                      {d.successes} ok
                      {d.failures > 0 && (
                        <span className="text-destructive-text"> · {d.failures} mislukt</span>
                      )}
                    </span>
                  </div>
                ))}
                {metrics.auth.length === 0 && (
                  <p className="text-sm text-muted-foreground">Nog niets geteld.</p>
                )}
              </div>

              <div className="border-t pt-3 text-sm text-muted-foreground">
                {metrics.accounts.total} accounts · {metrics.accounts.confirmed} bevestigd ·{" "}
                {metrics.accounts.with_2fa} met 2FA
              </div>
            </CardContent>
          </Card>

          <Card>
            <CardHeader className="pb-3">
              <CardTitle className="flex items-center gap-2 text-base">
                <Activity className="h-4 w-4" /> Opdrachten, laatste 24 uur
              </CardTitle>
            </CardHeader>
            <CardContent>
              {metrics.commands.length === 0 ? (
                <p className="text-sm text-muted-foreground">Niets gedraaid.</p>
              ) : (
                <div className="space-y-1">
                  {metrics.commands.map((c) => (
                    <div
                      key={`${c.kind}-${c.status}`}
                      className="flex items-center justify-between text-sm"
                    >
                      <span className="font-mono">{c.kind}</span>
                      <span
                        className={`font-mono ${c.status === "failed" ? "text-destructive-text" : "text-muted-foreground"}`}
                      >
                        {c.count} {c.status}
                      </span>
                    </div>
                  ))}
                </div>
              )}
            </CardContent>
          </Card>
        </div>

        <Card>
          <CardHeader className="pb-3">
            <CardTitle className="flex items-center gap-2 text-base">
              <HardDrive className="h-4 w-4" /> Back-ups
            </CardTitle>
          </CardHeader>
          <CardContent>
            {metrics.backups.length === 0 ? (
              <p className="text-sm text-muted-foreground">Geen draaiende VPS&apos;en.</p>
            ) : (
              <div className="space-y-1">
                {metrics.backups.map((b) => (
                  <div key={b.name} className="flex items-center justify-between text-sm">
                    <span className="font-mono">{b.name}</span>
                    <span className="font-mono text-muted-foreground">
                      {b.hours_since_success === null ? (
                        <span className="text-destructive-text">nog nooit</span>
                      ) : (
                        <>{b.hours_since_success} uur geleden</>
                      )}
                      {b.failures > 0 && (
                        <span className="text-destructive-text"> · {b.failures} mislukt</span>
                      )}
                    </span>
                  </div>
                ))}
              </div>
            )}
          </CardContent>
        </Card>

        <p className="flex items-center gap-2 text-xs text-muted-foreground">
          <MemoryStick className="h-3 w-3" />
          Geheugen is de bindende bron: een node raakt daar eerder doorheen dan door cores
          of schijf.
        </p>
      </div>
    </AdminGuard>
  );
}
