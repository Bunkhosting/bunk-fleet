"use client";

import { PageHeader } from "@/components/layout/page-header";
import { useBevestig } from "@/components/ui/use-bevestig";
import { useCallback, useEffect, useState } from "react";
import { Loader2, MapPin, Plus, RefreshCw, Trash2 } from "lucide-react";
import { Card, CardContent } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Badge } from "@/components/ui/badge";
import { useToast } from "@/components/ui/use-toast";
import { AdminGuard } from "@/components/admin/admin-guard";
import { adminApi, parseApiError, type AdminRegion } from "@/lib/api";

function RegioRij({
  regio,
  busy,
  onOpslaan,
  onSchakel,
  onVerwijderen,
}: {
  regio: AdminRegion;
  busy: boolean;
  onOpslaan: (naam: string, code: string) => void;
  onSchakel: () => void;
  onVerwijderen: () => void;
}) {
  const [naam, setNaam] = useState(regio.name);
  const [code, setCode] = useState(regio.code);

  // Geen effect dat de staat spiegelt: de rij krijgt van de ouder een `key`
  // waar naam en code in zitten, dus React bouwt hem opnieuw op zodra de server
  // iets anders zegt en beginnen deze velden vanzelf bij de nieuwe waarde.

  return (
    <Card>
      <CardContent className="space-y-3 p-4">
        <form
          className="flex flex-wrap items-center gap-3"
          onSubmit={(e) => {
            e.preventDefault();
            onOpslaan(naam, code);
          }}
        >
          <MapPin className="h-4 w-4 shrink-0 text-muted-foreground" />
          <Input
            className="max-w-[16rem]"
            value={naam}
            disabled={busy}
            onChange={(e) => setNaam(e.target.value)}
            aria-label="Naam"
          />
          <Input
            className="max-w-[10rem] font-mono"
            value={code}
            disabled={busy}
            onChange={(e) => setCode(e.target.value)}
            aria-label="Code"
          />
          {/* Niet uitgeschakeld zolang er niets gewijzigd is. Dat leek netjes en
              het is een val: staat de knop uit terwijl jij denkt dat je iets hebt
              veranderd, dan gebeurt er niets en zegt niets waarom. Nu klikt hij
              altijd, en zegt de melding of er iets te doen viel. */}
          <Button
            type="submit"
            size="sm"
            variant="outline"
            disabled={busy || !naam.trim() || !code.trim()}
          >
            {busy ? <Loader2 className="h-4 w-4 animate-spin" /> : "Opslaan"}
          </Button>
          <div className="ml-auto flex items-center gap-2">
            {regio.enabled ? (
              <Badge variant="outline">open</Badge>
            ) : (
              <Badge variant="secondary">gesloten</Badge>
            )}
            <Button variant="ghost" size="sm" disabled={busy} onClick={onSchakel}>
              {regio.enabled ? "Sluiten" : "Openen"}
            </Button>
            {/* Alleen aan te klikken als er geen nodes in staan. De server
                controleert het opnieuw en kijkt strenger -- ook een allang
                verwijderde VPS houdt zijn verwijzing naar deze locatie vast --
                maar een knop die zichtbaar uitstaat scheelt de klik die toch
                niets doet. */}
            <Button
              variant="ghost"
              size="sm"
              className="text-destructive hover:text-destructive"
              disabled={busy || regio.node_count > 0}
              title={
                regio.node_count > 0
                  ? "Er staan nodes in deze locatie"
                  : "Locatie verwijderen"
              }
              onClick={onVerwijderen}
            >
              <Trash2 className="h-4 w-4" />
            </Button>
          </div>
        </form>
        <p className="text-xs text-muted-foreground">
          {regio.node_count === 0
            ? "geen nodes — deze locatie kan niets leveren en staat niet in het bestelscherm"
            : `${regio.node_count} node${regio.node_count === 1 ? "" : "s"}`}
        </p>
      </CardContent>
    </Card>
  );
}

function RegiosInner() {
  const { dialoog, bevestig } = useBevestig();
  const { toast } = useToast();
  const [regions, setRegions] = useState<AdminRegion[] | null>(null);
  const [code, setCode] = useState("");
  const [naam, setNaam] = useState("");
  const [busy, setBusy] = useState<string | null>(null);

  const laden = useCallback(() => {
    adminApi
      .regions()
      .then(setRegions)
      .catch(() => {
        setRegions([]);
        toast({ title: "Fout", description: "Kon de locaties niet laden.", variant: "destructive" });
      });
  }, [toast]);

  useEffect(() => laden(), [laden]);

  const aanmaken = async () => {
    if (!code.trim() || !naam.trim()) {
      toast({ title: "Vul een code en een naam in", variant: "destructive" });
      return;
    }
    setBusy("nieuw");
    try {
      await adminApi.createRegion(code.trim(), naam.trim());
      setCode("");
      setNaam("");
      laden();
      toast({
        title: "Locatie aangemaakt",
        description: "Hij verschijnt in het bestelscherm zodra er een node in staat.",
      });
    } catch (e) {
      toast({
        title: "Niet aangemaakt",
        description: parseApiError(e, "Bestaat die code al?"),
        variant: "destructive",
      });
    } finally {
      setBusy(null);
    }
  };

  // Naam en code zijn allebei te wijzigen. Nodes en VPS'en verwijzen naar de
  // regio op id, dus er breekt geen koppeling -- wat breekt is een script van
  // een operator waar de oude code met de hand in staat. Vandaar de waarschuwing
  // bij het opslaan en niet erna.
  const opslaan = async (r: AdminRegion, naam: string, code: string) => {
    const nieuweNaam = naam.trim();
    const nieuweCode = code.trim().toLowerCase();
    if (!nieuweNaam || !nieuweCode) {
      toast({ title: "Naam en code zijn allebei nodig", variant: "destructive" });
      return;
    }

    // Vergelijken met dezelfde bewerking aan beide kanten. Stond er ooit een
    // hoofdletter of een spatie in de opgeslagen code, dan verschilde hij altijd
    // van wat jij intypt -- en dan vroeg het scherm bij élke naamswijziging om
    // de codewijziging te bevestigen. Wie daar "nee" zegt, ziet niets gebeuren
    // en heeft geen idee waarom.
    const huidigeCode = (r.code ?? "").trim().toLowerCase();
    const huidigeNaam = (r.name ?? "").trim();

    if (nieuweNaam === huidigeNaam && nieuweCode === huidigeCode) {
      toast({ title: "Niets gewijzigd", description: "Naam en code staan al zo." });
      return;
    }

    if (
      nieuweCode !== huidigeCode &&
      !(await bevestig({
        titel: `Code van "${r.name}" wijzigen naar ${nieuweCode}?`,
        uitleg:
          "Bestaande nodes en VPS'en blijven werken; die verwijzen niet op code. " +
          `Wat wél breekt is een script of instructie waar ${r.code} met de hand in staat.`,
        bevestigLabel: "Wijzigen",
      }))
    ) {
      return;
    }

    setBusy(r.id);
    try {
      const bij = await adminApi.updateRegion(r.id, { name: nieuweNaam, code: nieuweCode });
      setRegions((huidig) => (huidig ?? []).map((x) => (x.id === r.id ? { ...x, ...bij } : x)));
      toast({ title: "Opgeslagen", description: `${bij.name} (${bij.code})` });
    } catch (e) {
      toast({
        title: "Niet opgeslagen",
        description: parseApiError(e, "Kon de locatie niet wijzigen."),
        variant: "destructive",
      });
    } finally {
      setBusy(null);
    }
  };

  const zetAan = async (r: AdminRegion, enabled: boolean) => {
    setBusy(r.id);
    try {
      const bij = await adminApi.updateRegion(r.id, { enabled });
      setRegions((huidig) => (huidig ?? []).map((x) => (x.id === r.id ? { ...x, ...bij } : x)));
      toast({
        title: enabled ? "Locatie open" : "Locatie gesloten",
        description: enabled
          ? "Er kunnen weer nieuwe VPS'en geplaatst worden."
          : "Wat er draait blijft draaien; er komt niets nieuws bij.",
      });
    } catch (e) {
      toast({ title: "Mislukt", description: parseApiError(e, "Kon de locatie niet wijzigen."), variant: "destructive" });
    } finally {
      setBusy(null);
    }
  };

  const verwijderen = async (r: AdminRegion) => {
    const ok = await bevestig({
      titel: `Locatie "${r.name}" verwijderen?`,
      uitleg: "Dit kan alleen als er nooit iets in heeft gedraaid.",
      bevestigLabel: "Verwijderen",
      variant: "destructive",
    });
    if (!ok) {
      return;
    }

    setBusy(r.id);
    try {
      await adminApi.deleteRegion(r.id);
      setRegions((huidig) => (huidig ?? []).filter((x) => x.id !== r.id));
      toast({ title: "Locatie verwijderd", description: `"${r.name}" bestaat niet meer.` });
    } catch (e) {
      toast({
        title: "Kan niet verwijderen",
        description: parseApiError(e, "Kon de locatie niet verwijderen."),
        variant: "destructive",
      });
    } finally {
      setBusy(null);
    }
  };

  if (regions === null) {
    return (
      <div className="flex justify-center py-20">
        <Loader2 className="h-8 w-8 animate-spin text-primary" />
      </div>
    );
  }

  return (
    <>
      {dialoog}
    <div className="space-y-6">
      <PageHeader title="Locaties" description={<>Waar klanten hun VPS kunnen laten draaien. Een node hoort bij één locatie; de eigenaar van die node bepaalt welke.</>}>
        <Button variant="ghost" size="sm" className="gap-2" onClick={laden}>
          <RefreshCw className="h-4 w-4" /> Vernieuwen
        </Button>
      </PageHeader>

      <Card>
        <CardContent className="space-y-4 p-6">
          <h2 className="text-sm font-medium">Nieuwe locatie</h2>
          <div className="grid gap-4 sm:grid-cols-[1fr_2fr_auto] sm:items-end">
            <div className="space-y-1">
              <Label htmlFor="code">Code</Label>
              <Input id="code" placeholder="nl-2" value={code} onChange={(e) => setCode(e.target.value)} />
              <p className="text-xs text-muted-foreground">kort, blijvend — hij staat in bestellingen</p>
            </div>
            <div className="space-y-1">
              <Label htmlFor="naam">Naam</Label>
              <Input id="naam" placeholder="Amsterdam" value={naam} onChange={(e) => setNaam(e.target.value)} />
              <p className="text-xs text-muted-foreground">wat de klant ziet</p>
            </div>
            <Button className="gap-2" disabled={busy === "nieuw"} onClick={aanmaken}>
              {busy === "nieuw" ? <Loader2 className="h-4 w-4 animate-spin" /> : <Plus className="h-4 w-4" />}
              Aanmaken
            </Button>
          </div>
        </CardContent>
      </Card>

      <div className="space-y-3">
        {regions.map((r) => (
          <RegioRij
            // Naam en code zitten in de sleutel: verandert er iets aan de
            // serverkant, dan is dit een andere rij en beginnen de invoervelden
            // bij de nieuwe waarde in plaats van bij wat er ooit stond.
            key={`${r.id}:${r.name}:${r.code}`}
            regio={r}
            busy={busy === r.id}
            onOpslaan={(naam, code) => opslaan(r, naam, code)}
            onSchakel={() => zetAan(r, !r.enabled)}
            onVerwijderen={() => verwijderen(r)}
          />
        ))}
      </div>

      <p className="text-xs text-muted-foreground">
        Sluiten is geen verwijderen: de VPS&apos;en die er draaien blijven draaien en blijven
        bereikbaar. Er worden alleen geen nieuwe meer geplaatst, ook niet wanneer een klant
        &ldquo;automatisch&rdquo; kiest.
      </p>
    </div>
    </>
  );
}

export default function RegiosPagina() {
  return (
    <AdminGuard>
      <RegiosInner />
    </AdminGuard>
  );
}
