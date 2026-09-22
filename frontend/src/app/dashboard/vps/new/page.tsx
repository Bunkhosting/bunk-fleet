"use client";

import { useEffect, useRef, useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { Loader2, Check, Wallet, AlertCircle } from "lucide-react";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { useToast } from "@/components/ui/use-toast";
import { packagesApi, vpsApi, billingApi, regionsApi, parseApiError } from "@/lib/api";
import type { BunkRegion } from "@/lib/api";
import { cn, formatEuro, formatBalance, formatBandbreedte } from "@/lib/utils";
import type { VpsPackage } from "@/lib/types";

export default function NewVpsPage() {
  const router = useRouter();
  const { toast } = useToast();

  const [packages, setPackages] = useState<VpsPackage[]>([]);
  const [loading, setLoading] = useState(true);
  const [submitting, setSubmitting] = useState(false);

  const [selectedPackageId, setSelectedPackageId] = useState<number | null>(null);
  const [label, setLabel] = useState("");
  const [balanceCents, setBalanceCents] = useState<number | null>(null);
  const [regions, setRegions] = useState<BunkRegion[]>([]);
  const [deliveryConsent, setDeliveryConsent] = useState(false);
  // "" is automatic: no region is sent and Bunk places on the emptiest machine.
  const [regionCode, setRegionCode] = useState("");

  useEffect(() => {
    // Three answers this page needs and none of them depends on another, so
    // they go out together instead of in a queue. Each is handled on its own:
    // only the catalog can stop this page from being usable, and it is the only
    // one whose failure the customer is told about.
    const packagesRequest = packagesApi.list();
    const walletRequest = billingApi.wallet();
    const regionsRequest = regionsApi.list();

    packagesRequest
      .then((res) => setPackages(res.data.results))
      .catch(() =>
        toast({
          title: "Fout",
          description: "Kon pakketten niet laden.",
          variant: "destructive",
        }),
      )
      .finally(() => setLoading(false));

    walletRequest
      .then((res) => setBalanceCents(res.data.balance_cents))
      .catch(() => {
        // balance is a nice-to-have here; ignore failures
      });

    regionsRequest.then(setRegions).catch(() => {
      // No list means no choice to offer; automatic placement still works.
    });
  }, [toast]);

  // Eén sleutel per bestelling, niet per klik.
  //
  // De klik is al afgeschermd: de knop staat uit zolang het verzoek loopt. Wat
  // niet afgeschermd was, is het geval waarvoor `ControlPlane.Idempotency`
  // bestaat -- de verbinding valt weg vlak voordat het antwoord terugkomt, de
  // klant leest "kon VPS niet aanvragen", klikt opnieuw, en de eerste
  // bestelling was gelukt. Twee VPS'en, twee afschrijvingen, en hij ziet het
  // pas op zijn rekening. Die beveiliging stond klaar in het control plane en
  // werd door niemand aangeroepen, want dit scherm stuurde geen sleutel.
  //
  // De sleutel blijft staan zolang dit scherm open is, dus een herhaling na een
  // mislukking krijgt dezelfde. Lukt het wel, dan gaat de klant naar de
  // VPS-lijst en begint een volgende bestelling met een nieuw scherm en dus een
  // nieuwe sleutel -- iemand die bewust twee keer hetzelfde bestelt krijgt er
  // dus ook twee.
  const sleutel = useRef<string | null>(null);

  const bestelSleutel = () => {
    if (!sleutel.current) {
      sleutel.current =
        typeof crypto !== "undefined" && typeof crypto.randomUUID === "function"
          ? crypto.randomUUID()
          : `bestelling-${Date.now()}-${Math.random().toString(36).slice(2)}`;
    }
    return sleutel.current;
  };

  const handleSubmit = async () => {
    if (!selectedPackageId) {
      toast({
        title: "Selecteer een pakket",
        description: "Kies een VPS pakket om verder te gaan.",
        variant: "destructive",
      });
      return;
    }

    if (!deliveryConsent) {
      toast({
        title: "Bevestig de directe levering",
        description:
          "Zet het vinkje zodat we je VPS meteen mogen aanmaken. Zonder dat kunnen we niet bestellen.",
        variant: "destructive",
      });
      return;
    }

    setSubmitting(true);
    try {
      await vpsApi.create({
        package_id: selectedPackageId,
        os: "ubuntu-22.04",
        label: label || undefined,
        region_code: regionCode || undefined,
        immediate_delivery_consent: true,
        idempotency_key: bestelSleutel(),
      });
      toast({
        title: "Gelukt!",
        description: "VPS aanvraag ingediend!",
      });
      router.push("/dashboard/vps");
    } catch (error: unknown) {
      toast({
        title: "Fout bij aanvragen",
        description: parseApiError(error, "Kon VPS niet aanvragen. Probeer het opnieuw."),
        variant: "destructive",
      });
    } finally {
      setSubmitting(false);
    }
  };

  if (loading) {
    return (
      <div className="flex items-center justify-center py-20">
        <Loader2 className="h-8 w-8 animate-spin text-primary" />
      </div>
    );
  }

  return (
    <div className="mx-auto max-w-4xl space-y-8">
      <div>
        <h1 className="text-3xl font-bold tracking-tight">Nieuwe VPS Aanvragen</h1>
        <p className="text-muted-foreground">
          Kies een pakket en geef je VPS optioneel een naam.
        </p>
      </div>

      {/* Pakket kiezen */}
      <div className="space-y-4">
        <h2 className="text-xl font-semibold">Kies een pakket</h2>
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          {packages.map((pkg) => (
            <Card
              key={pkg.id}
              className={cn(
                "cursor-pointer transition-all",
                selectedPackageId === pkg.id
                  ? "border-primary ring-2 ring-primary"
                  : "hover:border-primary/50"
              )}
              onClick={() => setSelectedPackageId(pkg.id)}
            >
              <CardHeader className="pb-3">
                <div className="flex items-center justify-between">
                  <CardTitle className="text-lg">{pkg.name}</CardTitle>
                  {selectedPackageId === pkg.id && (
                    <Check className="h-5 w-5 text-primary" />
                  )}
                </div>
                <CardDescription>{pkg.description}</CardDescription>
              </CardHeader>
              <CardContent>
                <div className="space-y-1 text-sm">
                  <p>{pkg.cpu_cores} vCPU</p>
                  <p>{pkg.ram_gb} GB RAM</p>
                  <p>{pkg.disk_gb} GB NVMe opslag</p>
                  <p>{formatBandbreedte(pkg.bandwidth_mbit)} netwerk</p>
                </div>
                <p className="mt-3 text-lg font-bold text-primary">
                  {formatEuro(pkg.price_monthly)}/maand
                </p>
              </CardContent>
            </Card>
          ))}
        </div>
      </div>

      {/* Locatie.
          Dit blok stond er alleen bij twee of meer locaties, met als gedachte
          "een keuze van één is geen keuze". Dat klopt voor de keuze en niet voor
          de vraag: wie een server bestelt wil wéten waar hij komt te staan, ook
          als er niets te kiezen valt. */}
      <div className="space-y-4">
        <h2 className="text-xl font-semibold">Locatie</h2>

        {regions.length === 0 && (
          <p className="max-w-sm text-sm text-muted-foreground">
            Er is op dit moment geen locatie met vrije capaciteit. Bestellen lukt
            pas als er weer ruimte is.
          </p>
        )}

        {regions.length === 1 && (
          <div className="max-w-sm space-y-1 text-sm">
            <p>
              Je VPS draait in <span className="font-medium">{regions[0].name}</span>.
            </p>
            <p className="text-xs text-muted-foreground">
              Dat is op dit moment de enige locatie met vrije capaciteit.
            </p>
          </div>
        )}

        {regions.length > 1 && (
          <div className="max-w-sm space-y-2">
            <Label htmlFor="region">Waar moet je VPS draaien?</Label>
            <select
              id="region"
              value={regionCode}
              onChange={(e) => setRegionCode(e.target.value)}
              className="flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm ring-offset-background focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2"
            >
              <option value="">Automatisch (meeste ruimte)</option>
              {regions.map((region) => (
                <option key={region.id} value={region.code}>
                  {region.name}
                </option>
              ))}
            </select>
            <p className="text-xs text-muted-foreground">
              Laat dit op automatisch staan als je geen voorkeur hebt — je VPS
              komt dan op de machine met de meeste vrije capaciteit.
            </p>
          </div>
        )}
      </div>

      {/* Naam */}
      <div className="space-y-4">
        <h2 className="text-xl font-semibold">Naam (optioneel)</h2>
        <div className="max-w-sm space-y-2">
          <Label htmlFor="label">Naam voor je VPS</Label>
          <Input
            id="label"
            placeholder="bijv. webserver of mijn-database"
            value={label}
            onChange={(e) => setLabel(e.target.value.replace(/\s+/g, "-"))}
          />
          <p className="text-xs text-muted-foreground">
            Alleen letters, cijfers, koppeltekens en underscores. Geen spaties.
          </p>
        </div>
      </div>

      {/* Betaling */}
      {(() => {
        const pkg = packages.find((p) => p.id === selectedPackageId);
        const priceCents = pkg
          ? Math.round(parseFloat(pkg.price_monthly) * 100)
          : null;
        const insufficient =
          priceCents !== null &&
          balanceCents !== null &&
          balanceCents < priceCents;
        return (
          <Card className={insufficient ? "border-destructive/50" : ""}>
            <CardHeader className="pb-3">
              <CardTitle className="flex items-center gap-2 text-lg">
                <Wallet className="h-5 w-5" />
                Betaling
              </CardTitle>
              <CardDescription>
                Het maandbedrag van je pakket wordt eenmalig van je tegoed
                afgeschreven zodra de VPS wordt aangemaakt.
              </CardDescription>
            </CardHeader>
            <CardContent className="space-y-2 text-sm">
              <div className="flex justify-between">
                <span className="text-muted-foreground">Kosten voor dit pakket</span>
                <span className="font-medium">
                  {pkg ? formatEuro(pkg.price_monthly) : "—"}
                </span>
              </div>
              <div className="flex justify-between">
                <span className="text-muted-foreground">Huidig tegoed</span>
                <span className="font-medium">
                  {balanceCents === null ? "—" : formatBalance(balanceCents)}
                </span>
              </div>
              {insufficient && (
                <div className="flex items-start gap-2 rounded-md bg-destructive/10 px-3 py-2 text-destructive">
                  <AlertCircle className="mt-0.5 h-4 w-4 shrink-0" />
                  <span>
                    Je tegoed is niet toereikend.{" "}
                    <Link
                      href="/dashboard/billing"
                      className="font-medium underline underline-offset-2"
                    >
                      Waardeer eerst je tegoed op
                    </Link>{" "}
                    om deze VPS aan te maken.
                  </span>
                </div>
              )}
            </CardContent>
          </Card>
        );
      })()}

      {/* Herroepingsrecht: een VPS staat binnen twee minuten te draaien, dus zonder
          deze bevestiging loopt er veertien dagen bedenktijd over een dienst die
          al geleverd is. De control plane weigert de bestelling zonder. */}
      <label className="flex items-start gap-3 rounded-lg border bg-muted/30 p-4 text-sm">
        <input
          type="checkbox"
          checked={deliveryConsent}
          onChange={(e) => setDeliveryConsent(e.target.checked)}
          disabled={submitting}
          className="mt-0.5 h-4 w-4 shrink-0 accent-primary"
        />
        <span className="leading-relaxed text-muted-foreground">
          Ik wil dat mijn VPS <strong className="text-foreground">direct</strong> wordt aangemaakt en
          begrijp dat ik daarmee mijn herroepingsrecht verlies zodra hij draait. Niet-verbruikt
          tegoed kan ik wel terugvragen &mdash; zie de{" "}
          <a
            href="https://bunkhosting.nl/voorwaarden.html#voorwaarden"
            target="_blank"
            rel="noreferrer"
            className="font-medium underline underline-offset-2"
          >
            voorwaarden
          </a>
          .
        </span>
      </label>

      {/* Submit */}
      <div className="flex gap-4">
        <Button onClick={handleSubmit} disabled={submitting || !deliveryConsent}>
          {submitting && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
          VPS Aanvragen
        </Button>
        <Button
          variant="outline"
          onClick={() => router.push("/dashboard/vps")}
          disabled={submitting}
        >
          Annuleren
        </Button>
      </div>
    </div>
  );
}
