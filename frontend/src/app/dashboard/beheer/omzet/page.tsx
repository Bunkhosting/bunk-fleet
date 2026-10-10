"use client";

import { LoadError } from "@/components/feedback/load-error";
import { PageHeader } from "@/components/layout/page-header";
import { useCallback, useEffect, useState } from "react";
import { Loader2, RefreshCw, Download } from "lucide-react";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { AdminGuard } from "@/components/admin/admin-guard";
import { adminApi, type AdminRevenue, parseApiError } from "@/lib/api";

// Een cel die met =, +, - of @ begint wordt door Excel en LibreOffice als
// formule uitgevoerd, niet als tekst. De klantkolom is een e-mailadres en dat
// mag van de registratie alles zijn zonder spaties -- "=cmd|'/c calc'!A1@x.nl"
// is een geldig adres. Zonder deze regel voert een export dus uit wat een klant
// in zijn adres heeft gezet, op de machine van degene die de boekhouding opent.
// Een apostrof ervoor maakt er tekst van; de aanhalingstekens eromheen zijn
// alleen het CSV-formaat en houden een formule niet tegen.
function cel(waarde: string): string {
  const tekst = String(waarde);
  const veilig = /^[=+\-@\t\r]/.test(tekst) ? `'${tekst}` : tekst;
  return `"${veilig.replace(/"/g, '""')}"`;
}

const euro = (cents: number) =>
  (cents / 100).toLocaleString("nl-NL", { style: "currency", currency: "EUR" });

const datum = (iso: string | null) =>
  iso ? new Date(iso).toLocaleDateString("nl-NL", { day: "2-digit", month: "2-digit", year: "numeric" }) : "—";

function jaarBegin() {
  return `${new Date().getFullYear()}-01-01`;
}

function vandaag() {
  return new Date().toISOString().slice(0, 10);
}

function OmzetInner() {
  const [data, setData] = useState<AdminRevenue | null>(null);
  const [loading, setLoading] = useState(true);
  const [laadFout, setLaadFout] = useState<string | null>(null);
  const [from, setFrom] = useState(jaarBegin());
  const [to, setTo] = useState(vandaag());

  // Zonder setLoading: die staat al op true bij het openen, en synchroon
  // setState aanroepen in een effect kost een extra rendercyclus. De knop
  // hieronder zet hem wel.
  const load = useCallback(() => {
    adminApi
      .revenue(from, to)
      .then((d) => {
        setData(d);
        setLaadFout(null);
      })
      .catch((err: unknown) => {
        // De cijfers van de vorige periode weg. Ze bleven staan onder de nieuwe
        // datums, en de CSV-knop exporteerde ze ook -- voor een btw-aangifte
        // erger dan geen cijfers.
        setData(null);
        setLaadFout(parseApiError(err, "De omzet kon niet worden opgehaald."));
      })
      .finally(() => setLoading(false));
  }, [from, to]);

  useEffect(() => {
    load();
    // Alleen bij het openen; daarna bepaalt de knop wanneer er geladen wordt,
    // zodat een half ingetypte datum geen verzoek afvuurt.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // De aangifte wordt buiten dit scherm gedaan, dus de regels moeten mee kunnen
  // naar een boekhouding. Puntkomma als scheidingsteken en een komma in de
  // bedragen: dat is wat Excel in een Nederlandse taalinstelling verwacht.
  const exporteer = () => {
    if (!data) return;
    const kop = ["Factuurnummer", "Datum", "Klant", "Excl. btw", "Btw", "Incl. btw", "Mollie-id"];
    const regels = data.invoices.map((r) => [
      r.reference,
      datum(r.paid_at),
      r.customer,
      (r.net_cents / 100).toFixed(2).replace(".", ","),
      (r.vat_cents / 100).toFixed(2).replace(".", ","),
      (r.gross_cents / 100).toFixed(2).replace(".", ","),
      r.mollie_payment_id ?? "",
    ]);
    const csv = [kop, ...regels].map((r) => r.map(cel).join(";")).join("\r\n");
    const url = URL.createObjectURL(new Blob(["﻿" + csv], { type: "text/csv;charset=utf-8" }));
    const a = document.createElement("a");
    a.href = url;
    a.download = `bunk-omzet-${data.from}-tot-${data.to}.csv`;
    a.click();
    URL.revokeObjectURL(url);
  };

  return (
    <div className="space-y-6">
      <PageHeader title={<>Omzet &amp; btw</>} description="Wat er in de periode is ontvangen, met de btw eruit gerekend.">
        <div className="flex flex-wrap items-end gap-2">
          <div>
            <label className="text-xs text-muted-foreground">Van</label>
            <Input type="date" value={from} onChange={(e) => setFrom(e.target.value)} className="w-40" />
          </div>
          <div>
            <label className="text-xs text-muted-foreground">Tot en met</label>
            <Input type="date" value={to} onChange={(e) => setTo(e.target.value)} className="w-40" />
          </div>
          <Button
            variant="ghost"
            size="sm"
            className="gap-2"
            onClick={() => {
              setLoading(true);
              load();
            }}
          >
            <RefreshCw className="h-4 w-4" /> Toon
          </Button>
          <Button size="sm" className="gap-2" onClick={exporteer} disabled={!data?.invoices.length}>
            <Download className="h-4 w-4" /> CSV
          </Button>
        </div>
      </PageHeader>

      {laadFout && !loading ? (
        <LoadError
          message={laadFout}
          onRetry={() => {
            setLoading(true);
            load();
          }}
        />
      ) : loading || !data ? (
        <div className="flex justify-center py-20">
          <Loader2 className="h-8 w-8 animate-spin text-primary" />
        </div>
      ) : (
        <>
          <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
            {[
              { label: "Ontvangen (incl. btw)", value: euro(data.total.gross_cents) },
              { label: "Omzet (excl. btw)", value: euro(data.total.net_cents) },
              { label: `Af te dragen btw (${data.vat_percentage}%)`, value: euro(data.total.vat_cents) },
              { label: "Betalingen", value: String(data.total.payments) },
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
              <CardTitle className="text-base">Per kwartaal</CardTitle>
            </CardHeader>
            <CardContent>
              {data.quarters.length === 0 ? (
                <p className="text-sm text-muted-foreground">Geen betalingen in deze periode.</p>
              ) : (
                <div className="overflow-x-auto">
                  <table className="w-full text-sm">
                    <thead>
                      <tr className="border-b text-left text-muted-foreground">
                        <th className="py-2 pr-4 font-medium">Kwartaal</th>
                        <th className="py-2 pr-4 text-right font-medium">Betalingen</th>
                        <th className="py-2 pr-4 text-right font-medium">Excl. btw</th>
                        <th className="py-2 pr-4 text-right font-medium">Btw</th>
                        <th className="py-2 text-right font-medium">Incl. btw</th>
                      </tr>
                    </thead>
                    <tbody className="tabular-nums">
                      {data.quarters.map((q) => (
                        <tr key={q.label} className="border-b last:border-0">
                          <td className="py-2 pr-4 font-medium">{q.label}</td>
                          <td className="py-2 pr-4 text-right">{q.payments}</td>
                          <td className="py-2 pr-4 text-right">{euro(q.net_cents)}</td>
                          <td className="py-2 pr-4 text-right">{euro(q.vat_cents)}</td>
                          <td className="py-2 text-right">{euro(q.gross_cents)}</td>
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
              <CardTitle className="text-base">Facturen ({data.invoices.length})</CardTitle>
            </CardHeader>
            <CardContent>
              {data.invoices.length === 0 ? (
                <p className="text-sm text-muted-foreground">Geen facturen in deze periode.</p>
              ) : (
                <div className="overflow-x-auto">
                  <table className="w-full text-sm">
                    <thead>
                      <tr className="border-b text-left text-muted-foreground">
                        <th className="py-2 pr-4 font-medium">Factuurnummer</th>
                        <th className="py-2 pr-4 font-medium">Datum</th>
                        <th className="py-2 pr-4 font-medium">Klant</th>
                        <th className="py-2 pr-4 text-right font-medium">Excl. btw</th>
                        <th className="py-2 pr-4 text-right font-medium">Btw</th>
                        <th className="py-2 pr-4 text-right font-medium">Incl. btw</th>
                        <th className="py-2 font-medium">Bron</th>
                      </tr>
                    </thead>
                    <tbody className="tabular-nums">
                      {data.invoices.map((r) => (
                        <tr key={r.reference} className="border-b last:border-0">
                          <td className="py-2 pr-4 font-mono text-xs">{r.reference}</td>
                          <td className="py-2 pr-4">{datum(r.paid_at)}</td>
                          <td className="py-2 pr-4">{r.customer}</td>
                          <td className="py-2 pr-4 text-right">{euro(r.net_cents)}</td>
                          <td className="py-2 pr-4 text-right">{euro(r.vat_cents)}</td>
                          <td className="py-2 pr-4 text-right">{euro(r.gross_cents)}</td>
                          <td className="py-2 text-xs text-muted-foreground">
                            {r.paid_via === "mollie" ? "Mollie" : "Mollie (voor registratie)"}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
            </CardContent>
          </Card>

          {data.excluded.length > 0 && (
            <Card className="border-amber-500/40">
              <CardHeader>
                <CardTitle className="text-base">
                  Niet meegeteld ({data.excluded.length})
                </CardTitle>
              </CardHeader>
              <CardContent>
                <p className="mb-3 text-sm text-muted-foreground">
                  Deze bedragen zijn wel bijgeschreven op een tegoed, maar tellen niet als omzet.
                  Ze staan hier omdat uitsluiten zonder tonen hetzelfde is als verbergen: zo is het
                  verschil tussen je bankafschriften en je aangifte te verklaren.
                </p>
                <div className="overflow-x-auto">
                  <table className="w-full text-sm">
                    <thead>
                      <tr className="border-b text-left text-muted-foreground">
                        <th className="py-2 pr-4 font-medium">Referentie</th>
                        <th className="py-2 pr-4 font-medium">Datum</th>
                        <th className="py-2 pr-4 font-medium">Klant</th>
                        <th className="py-2 pr-4 text-right font-medium">Bedrag</th>
                        <th className="py-2 font-medium">Waarom niet</th>
                      </tr>
                    </thead>
                    <tbody className="tabular-nums">
                      {data.excluded.map((r) => (
                        <tr key={r.reference} className="border-b last:border-0">
                          <td className="py-2 pr-4 font-mono text-xs">{r.reference}</td>
                          <td className="py-2 pr-4">{datum(r.paid_at)}</td>
                          <td className="py-2 pr-4">{r.customer}</td>
                          <td className="py-2 pr-4 text-right">{euro(r.gross_cents)}</td>
                          <td className="py-2 text-xs text-muted-foreground">{r.reason}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              </CardContent>
            </Card>
          )}

          <p className="text-xs text-muted-foreground">
            De omzet hangt aan de betaalde opwaardering, niet aan het verbruik: tegoed bij Bunk is
            maar voor één dienst met één btw-tarief in te wisselen en is daarmee belast op het moment
            dat het wordt gekocht. Weggegeven tegoed telt niet mee — daar is niets voor betaald. De
            btw wordt per betaling afgerond en daarna opgeteld, zodat dit overzicht optelt tot wat er
            op de facturen staat. Alleen betalingen die de betaalprovider zelf heeft bevestigd
            tellen mee: een opwaardering die met de hand op betaald is gezet staat hierboven onder
            &ldquo;niet meegeteld&rdquo;.
          </p>
        </>
      )}
    </div>
  );
}

export default function OmzetPage() {
  return (
    <AdminGuard>
      <OmzetInner />
    </AdminGuard>
  );
}
