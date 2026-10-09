"use client";

import { useEffect, useState } from "react";
import {
  Wallet as WalletIcon,
  Info,
  ArrowUpRight,
  ArrowDownRight,
  Loader2,
  AlertCircle,
} from "lucide-react";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Badge } from "@/components/ui/badge";
import { billingApi, parseApiError, type Wallet } from "@/lib/api";
import { useToast } from "@/components/ui/use-toast";
import { formatEuro, formatDateLong, formatBalance } from "@/lib/utils";
import { LoadError } from "@/components/feedback/load-error";

const PRESET_EUROS = [5, 10, 25, 50];
const MIN_EUROS = 5;
const MAX_EUROS = 1000;

// Friendly Dutch labels for the ledger `kind` column.
const KIND_LABELS: Record<string, string> = {
  signup_bonus: "Welkomstkrediet",
  topup: "Tegoed opgewaardeerd",
  admin_topup: "Tegoed bijgeschreven",
  vps_charge: "VPS aangemaakt",
  vps_refund: "Terugbetaling",
};

function euroFromCents(cents: number): string {
  return formatEuro(cents / 100);
}

export default function TegoedPage() {
  const { toast } = useToast();
  const [wallet, setWallet] = useState<Wallet | null>(null);
  const [loading, setLoading] = useState(true);
  const [loadFailed, setLoadFailed] = useState(false);
  const [poging, setPoging] = useState(0);
  const [amount, setAmount] = useState<string>("10");
  const [submitting, setSubmitting] = useState(false);

  useEffect(() => {
    async function load() {
      try {
        const res = await billingApi.wallet();
        setWallet(res.data);
        setLoadFailed(false);
      } catch {
        // Geen toast en geen saldo van nul: een mislukte aanvraag is geen leeg
        // tegoed, en een klant die € 0,00 in het rood ziet staan denkt dat zijn
        // geld weg is.
        setLoadFailed(true);
      } finally {
        setLoading(false);
      }
    }
    load();
  }, [poging]);

  const handleTopup = async () => {
    const euros = Number(amount.replace(",", "."));
    if (!Number.isFinite(euros) || euros < MIN_EUROS || euros > MAX_EUROS) {
      toast({
        title: "Ongeldig bedrag",
        description: `Kies een bedrag tussen € ${MIN_EUROS} en € ${MAX_EUROS}.`,
        variant: "destructive",
      });
      return;
    }
    setSubmitting(true);
    try {
      const { checkout_url } = await billingApi.topup(Math.round(euros * 100));
      // Hand off to Mollie's hosted checkout.
      window.location.href = checkout_url;
    } catch (error: unknown) {
      toast({
        title: "Opwaarderen mislukt",
        description: parseApiError(
          error,
          "Kon de betaling niet starten. Probeer het later opnieuw."
        ),
        variant: "destructive",
      });
      setSubmitting(false);
    }
  };

  if (loading) {
    return (
      <div className="flex justify-center py-20">
        <Loader2 className="h-8 w-8 animate-spin text-primary" />
      </div>
    );
  }

  if (loadFailed || !wallet) {
    return (
      <div className="space-y-6">
        <h1 className="text-2xl font-bold tracking-tight">Tegoed</h1>
        <LoadError
          message="Je tegoed kon niet worden opgehaald. Je saldo is niet veranderd; probeer het zo opnieuw."
          onRetry={() => {
            setLoading(true);
            setPoging((p) => p + 1);
          }}
        />
      </div>
    );
  }

  const balance = wallet.balance_cents;
  const lowBalance = balance < 500;

  return (
    <div className="space-y-8">
      <div>
        <h1 className="text-2xl font-bold tracking-tight">Tegoed</h1>
        <p className="text-muted-foreground">
          Je saldo, opwaarderen en een overzicht van je transacties.
        </p>
      </div>

      {/* Hoe werkt betalen? */}
      <div className="flex items-start gap-3 rounded-lg border bg-muted/40 px-4 py-3">
        <Info className="mt-0.5 h-4 w-4 shrink-0 text-muted-foreground" />
        <div className="text-sm text-muted-foreground">
          <span className="font-medium text-foreground">Zo werkt betalen bij Bunk.</span>{" "}
          Je betaalt vooraf met tegoed. Wanneer je een VPS aanmaakt, wordt het
          maandbedrag van het gekozen pakket eenmalig van je tegoed afgeschreven.
          Is je tegoed te laag, dan kun je geen nieuwe VPS aanmaken — je bestaande
          servers blijven gewoon draaien. Opwaarderen kan hieronder, veilig via
          iDEAL of Bancontact.
        </div>
      </div>

      {/* Saldo + opwaarderen */}
      <div className="grid gap-6 lg:grid-cols-3">
        {/* Saldo */}
        <Card className="lg:col-span-1">
          <CardHeader className="flex flex-row items-center justify-between pb-2">
            <CardTitle className="text-sm font-medium text-muted-foreground">
              Huidig tegoed
            </CardTitle>
            <WalletIcon className="h-4 w-4 text-muted-foreground" />
          </CardHeader>
          <CardContent>
            <p
              className={`text-4xl font-bold ${
                lowBalance ? "text-destructive" : "text-primary"
              }`}
            >
              {formatBalance(balance)}
            </p>
            {lowBalance && (
              <p className="mt-2 flex items-center gap-1.5 text-xs text-destructive">
                <AlertCircle className="h-3.5 w-3.5" />
                Je tegoed is laag. Waardeer op om een VPS te kunnen aanmaken.
              </p>
            )}
          </CardContent>
        </Card>

        {/* Opwaarderen */}
        <Card className="lg:col-span-2">
          <CardHeader className="pb-3">
            <CardTitle className="text-lg">Tegoed opwaarderen</CardTitle>
          </CardHeader>
          <CardContent className="space-y-4">
            <div className="flex flex-wrap gap-2">
              {PRESET_EUROS.map((v) => (
                <Button
                  key={v}
                  type="button"
                  variant={Number(amount) === v ? "default" : "outline"}
                  size="sm"
                  onClick={() => setAmount(String(v))}
                  disabled={submitting}
                >
                  € {v}
                </Button>
              ))}
            </div>
            <div className="flex items-end gap-3">
              <div className="space-y-1">
                <label
                  htmlFor="topup-amount"
                  className="text-xs text-muted-foreground"
                >
                  Bedrag (€ {MIN_EUROS} – € {MAX_EUROS})
                </label>
                <Input
                  id="topup-amount"
                  type="number"
                  min={MIN_EUROS}
                  max={MAX_EUROS}
                  step="1"
                  value={amount}
                  onChange={(e) => setAmount(e.target.value)}
                  disabled={submitting}
                  className="w-32"
                />
              </div>
              <Button onClick={handleTopup} disabled={submitting}>
                {submitting && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
                Opwaarderen
              </Button>
            </div>
            <p className="text-xs text-muted-foreground">
              Je wordt doorgestuurd naar de beveiligde betaalpagina van Mollie.
              Na een geslaagde betaling staat je tegoed er binnen enkele
              seconden op.
            </p>
          </CardContent>
        </Card>
      </div>

      {/* Transacties */}
      <Card>
        <CardHeader>
          <CardTitle>Transacties</CardTitle>
        </CardHeader>
        <CardContent>
          {!wallet || wallet.entries.length === 0 ? (
            <p className="py-6 text-center text-sm text-muted-foreground">
              Nog geen transacties. Je transacties verschijnen hier zodra je
              tegoed opwaardeert of een VPS aanmaakt.
            </p>
          ) : (
            <div className="space-y-2">
              {wallet.entries.map((e, i) => {
                const credit = e.amount_cents >= 0;
                return (
                  <div
                    key={i}
                    className="flex items-center justify-between rounded-lg border px-4 py-3"
                  >
                    <div className="flex items-center gap-3">
                      <span
                        className={`flex h-8 w-8 items-center justify-center rounded-full ${
                          credit
                            ? "bg-green-500/10 text-green-600"
                            : "bg-muted text-muted-foreground"
                        }`}
                      >
                        {credit ? (
                          <ArrowUpRight className="h-4 w-4" />
                        ) : (
                          <ArrowDownRight className="h-4 w-4" />
                        )}
                      </span>
                      <div className="space-y-0.5">
                        <p className="text-sm font-medium">
                          {KIND_LABELS[e.kind] ?? e.description ?? e.kind}
                        </p>
                        <p className="text-xs text-muted-foreground">
                          {formatDateLong(e.inserted_at)}
                        </p>
                      </div>
                    </div>
                    <p
                      className={`text-sm font-semibold ${
                        credit ? "text-green-600" : "text-foreground"
                      }`}
                    >
                      {credit ? "+" : "−"}
                      {euroFromCents(Math.abs(e.amount_cents))}
                    </p>
                  </div>
                );
              })}
            </div>
          )}
        </CardContent>
      </Card>

      {/* Openstaande top-ups */}
      {wallet && wallet.topups.some((t) => t.status === "pending") && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Lopende betalingen</CardTitle>
          </CardHeader>
          <CardContent className="space-y-2">
            {wallet.topups
              .filter((t) => t.status === "pending")
              .map((t) => (
                <div
                  key={t.reference}
                  className="flex items-center justify-between rounded-lg border px-4 py-3"
                >
                  <div className="space-y-0.5">
                    <p className="text-sm font-medium">
                      {euroFromCents(t.amount_cents)}
                    </p>
                    <p className="text-xs text-muted-foreground">
                      {formatDateLong(t.inserted_at)}
                    </p>
                  </div>
                  <Badge variant="secondary">In afwachting</Badge>
                </div>
              ))}
          </CardContent>
        </Card>
      )}
    </div>
  );
}
