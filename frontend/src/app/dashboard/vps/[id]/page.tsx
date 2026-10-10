"use client";

import { usePolling } from "@/hooks/use-polling";
import { useEffect, useState, useCallback } from "react";
import { useParams, useRouter } from "next/navigation";
import Link from "next/link";
import {
  Loader2,
  ArrowLeft,
  Server,
  Cpu,
  HardDrive,
  Globe,
  Terminal,
  Play,
  Square,
  RotateCw,
  Pencil,
  Trash2,
  KeyRound,
  AlertCircle,
} from "lucide-react";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { ConfirmDialog } from "@/components/ui/confirm-dialog";
import { StatusBadge } from "@/components/vps/status-badge";
import { useToast } from "@/components/ui/use-toast";
import { vpsApi, parseApiError } from "@/lib/api";
import type { VpsBackup } from "@/lib/api";
import { formatDate, formatBandbreedte } from "@/lib/utils";
import type { Vps, VpsStatus } from "@/lib/types";

const TRANSITIONAL_STATUSES: VpsStatus[] = [
  "PENDING",
  "PROVISIONING",
  // A restore takes minutes and ends by itself; polling is what turns the page
  // back into a working VPS without the customer reloading it.
  "RESTORING",
  "DELETING",
];
const POLL_INTERVAL_MS = 10_000;
const POST_ACTION_POLL_MS = 60_000;

export default function VpsDetailPage() {
  const params = useParams();
  const router = useRouter();
  const { toast } = useToast();

  const id = params.id as string;

  const [vps, setVps] = useState<Vps | null>(null);
  const [backups, setBackups] = useState<VpsBackup[]>([]);
  const [backupBezig, setBackupBezig] = useState(false);
  const [restoring, setRestoring] = useState<string | null>(null);
  const [confirmRestore, setConfirmRestore] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [actionLoading, setActionLoading] = useState(false);
  const [stopDialogOpen, setStopDialogOpen] = useState(false);
  const [rebootDialogOpen, setRebootDialogOpen] = useState(false);
  const [hernoemen, setHernoemen] = useState(false);
  const [nieuweNaam, setNieuweNaam] = useState("");
  const [naamBezig, setNaamBezig] = useState(false);
  const [deleteDialogOpen, setDeleteDialogOpen] = useState(false);
  const [pollUntil, setPollUntil] = useState<number | null>(null);

  const fetchVps = useCallback(
    async (silent = false) => {
      try {
        const response = await vpsApi.get(id);
        setVps(response.data);
      } catch {
        if (!silent) {
          toast({
            title: "Fout",
            description: "Kon VPS gegevens niet laden.",
            variant: "destructive",
          });
        }
      } finally {
        setLoading(false);
      }
    },
    [id, toast]
  );

  const fetchBackups = useCallback(async () => {
    try {
      setBackups(await vpsApi.backups(id));
    } catch {
      // Restore points are a panel on a page, not the page: failing to load them
      // should not bury the rest of it under an error.
    }
  }, [id]);

  // Zelf een back-up starten. Het schema draait 's nachts; het moment waarop je
  // er een wilt is vlak vóór iets engs dat je nu gaat doen.
  const backupNu = async () => {
    setBackupBezig(true);
    try {
      await vpsApi.backupNow(id);
      toast({
        title: "Back-up gestart",
        description: "Hij draait op de achtergrond; hieronder zie je wanneer hij klaar is.",
      });
      await fetchBackups();
    } catch (e) {
      toast({
        title: "Niet gestart",
        description: parseApiError(e, "Kon de back-up niet starten."),
        variant: "destructive",
      });
    } finally {
      setBackupBezig(false);
    }
  };

  const restoreBackup = async (backup: VpsBackup) => {
    setRestoring(backup.id);
    setConfirmRestore(null);
    try {
      await vpsApi.restore(id, backup.id);
      toast({
        title: "Terugzetten gestart",
        description:
          "Je VPS is even niet bereikbaar terwijl de schijf wordt teruggezet. " +
          "Zodra dat klaar is komt hij vanzelf terug.",
      });
      await fetchVps(true);
      await fetchBackups();
    } catch (e: unknown) {
      const status = (e as { response?: { status?: number } })?.response?.status;
      toast({
        title: "Terugzetten mislukt",
        description:
          status === 409
            ? "Deze VPS is nu ergens anders mee bezig. Probeer het zo opnieuw."
            : "Kon het terugzetten niet starten.",
        variant: "destructive",
      });
    } finally {
      setRestoring(null);
    }
  };

  useEffect(() => {
    // Zie dashboard/vps/page.tsx: via een microtask, zodat een synchrone worp
    // niet in dezelfde rendercyclus state zet.
    queueMicrotask(() => {
      fetchVps();
      fetchBackups();
    });
  }, [fetchVps, fetchBackups]);

  // Poll zolang de VPS in een overgangsstatus zit, of kort na een
  // start/stop-actie zodat de nieuwe status zichtbaar wordt.
  const isTransitional =
    vps !== null && TRANSITIONAL_STATUSES.includes(vps.status);
  const shouldPoll = isTransitional || pollUntil !== null;

  usePolling(
    () => {
      setPollUntil((until) => (until !== null && Date.now() >= until ? null : until));
      fetchVps(true);
    },
    POLL_INTERVAL_MS,
    shouldPoll,
  );

  const handleStart = async () => {
    setActionLoading(true);
    try {
      await vpsApi.start(id);
      toast({
        title: "Verzoek ingediend",
        description: "De VPS wordt gestart.",
      });
      setPollUntil(Date.now() + POST_ACTION_POLL_MS);
      await fetchVps();
    } catch (error: unknown) {
      toast({
        title: "Fout",
        description: parseApiError(error, "Kon de VPS niet starten."),
        variant: "destructive",
      });
    } finally {
      setActionLoading(false);
    }
  };

  // Hernoemen raakt alleen het label. De naam waaronder de gast op de hypervisor
  // staat blijft wat hij was -- daar herkent de agent zijn machine aan, en die
  // naam is bij het uitrollen vastgelegd.
  const slaNaamOp = async () => {
    const naam = nieuweNaam.trim();
    if (!naam || naam === vps?.label) {
      setHernoemen(false);
      return;
    }
    setNaamBezig(true);
    try {
      await vpsApi.rename(id, naam);
      setHernoemen(false);
      await fetchVps(true);
      toast({ title: "Naam gewijzigd", description: naam });
    } catch (e) {
      toast({
        title: "Niet gewijzigd",
        description: parseApiError(e, "Kon de naam niet wijzigen."),
        variant: "destructive",
      });
    } finally {
      setNaamBezig(false);
    }
  };

  // Herstarten vraagt het besturingssysteem netjes af te sluiten en weer op te
  // komen. De VPS blijft ondertussen ACTIVE: hij is niet uitgezet, en een
  // verzonnen tussenstand zou elke andere knop blokkeren tot de agent terugmeldt.
  const handleReboot = async () => {
    setActionLoading(true);
    try {
      await vpsApi.reboot(id);
      toast({
        title: "Verzoek ingediend",
        description: "De VPS wordt herstart; dat duurt meestal een halve minuut.",
      });
      setRebootDialogOpen(false);
      setPollUntil(Date.now() + POST_ACTION_POLL_MS);
      await fetchVps();
    } catch (e) {
      toast({
        title: "Fout",
        description: parseApiError(e, "Kon de VPS niet herstarten."),
        variant: "destructive",
      });
    } finally {
      setActionLoading(false);
    }
  };

  const handleStop = async () => {
    setActionLoading(true);
    try {
      await vpsApi.stop(id);
      toast({
        title: "Verzoek ingediend",
        description: "De VPS wordt gestopt.",
      });
      setStopDialogOpen(false);
      setPollUntil(Date.now() + POST_ACTION_POLL_MS);
      await fetchVps();
    } catch (error: unknown) {
      toast({
        title: "Fout",
        description: parseApiError(error, "Kon de VPS niet stoppen."),
        variant: "destructive",
      });
    } finally {
      setActionLoading(false);
    }
  };

  const handleDelete = async () => {
    setActionLoading(true);
    try {
      await vpsApi.delete(id);
      toast({
        title: "Verzoek ingediend",
        description: "De VPS wordt verwijderd.",
      });
      setDeleteDialogOpen(false);
      router.push("/dashboard/vps");
    } catch (error: unknown) {
      toast({
        title: "Fout",
        description: parseApiError(error, "Kon de VPS niet verwijderen."),
        variant: "destructive",
      });
    } finally {
      setActionLoading(false);
    }
  };

  if (loading) {
    return (
      <div className="flex items-center justify-center py-20">
        <Loader2 className="h-8 w-8 animate-spin text-primary" />
      </div>
    );
  }

  if (!vps) {
    return (
      <div className="text-center py-20">
        <p className="text-muted-foreground">VPS niet gevonden.</p>
        <Button
          variant="link"
          onClick={() => router.push("/dashboard/vps")}
          className="mt-4"
        >
          Terug naar overzicht
        </Button>
      </div>
    );
  }

  const canStop = vps.status === "ACTIVE";
  const canStart = vps.status === "STOPPED";
  const canDelete = vps.status !== "DELETING" && vps.status !== "DELETED";

  return (
    <div className="mx-auto max-w-4xl space-y-6">
      {/* Back button */}
      <Button
        variant="ghost"
        onClick={() => router.push("/dashboard/vps")}
        className="gap-2"
      >
        <ArrowLeft className="h-4 w-4" />
        Terug naar overzicht
      </Button>

      {/* Header.
          Twee dingen houden de knoppenrij bij elkaar sinds het er vijf zijn
          (terminal, starten, herstarten, stoppen, verwijderen):

          1. De rij staat op een EIGEN regel en niet meer naast de titel. Met
             tekst erbij is hij ongeveer 650px; naast een titel die net zo goed
             een lange zelfgekozen naam kan zijn, past dat op een normale laptop
             niet en vielen ze uiteen over twee rommelige regels.
          2. Onder de sm-grens tonen ze alleen hun icoon. Vijf knoppen mét tekst
             krijg je op een telefoon van 390px nooit naast elkaar; vijf iconen
             wel, met ruimte over. De tekst zit dan in aria-label, dus een
             schermlezer leest nog steeds "Herstarten". */}
      <div className="flex flex-col gap-4">
        <div>
          {hernoemen ? (
            <form
              onSubmit={(e) => {
                e.preventDefault();
                slaNaamOp();
              }}
              className="flex flex-wrap items-center gap-2"
            >
              <Input
                autoFocus
                className="max-w-xs text-lg"
                value={nieuweNaam}
                disabled={naamBezig}
                onChange={(e) => setNieuweNaam(e.target.value)}
                aria-label="Naam van deze VPS"
              />
              <Button type="submit" size="sm" disabled={naamBezig || !nieuweNaam.trim()}>
                {naamBezig ? <Loader2 className="h-4 w-4 animate-spin" /> : "Opslaan"}
              </Button>
              <Button
                type="button"
                size="sm"
                variant="ghost"
                disabled={naamBezig}
                onClick={() => setHernoemen(false)}
              >
                Annuleren
              </Button>
            </form>
          ) : (
            <h1 className="flex flex-wrap items-center gap-2 text-3xl font-bold tracking-tight">
              {vps.label || `VPS #${vps.id}`}
              {vps.status !== "DELETED" && (
                <Button
                  variant="ghost"
                  size="sm"
                  aria-label="Naam wijzigen"
                  onClick={() => {
                    setNieuweNaam(vps.label || "");
                    setHernoemen(true);
                  }}
                >
                  <Pencil className="h-4 w-4" />
                </Button>
              )}
            </h1>
          )}
          <div className="mt-2">
            <StatusBadge status={vps.status} />
          </div>
        </div>

        {/* Action buttons */}
        <div className="flex flex-wrap items-center gap-2 sm:justify-end">
          {/* Terminal button */}
          <Link href={`/dashboard/vps/${id}/terminal`}>
            <Button variant="outline" disabled={vps.status !== "ACTIVE"} aria-label="Terminal">
              <Terminal className="h-4 w-4 sm:mr-2" />
              <span className="hidden sm:inline">Terminal</span>
            </Button>
          </Link>

          {/* Start */}
          {/* Starten zonder bevestiging: er gaat niets verloren, en "weet je het
              zeker?" bij iets onschuldigs leert mensen de vraag weg te klikken
              -- ook bij stoppen en verwijderen, waar hij er wel toe doet. */}
          <Button disabled={!canStart || actionLoading} aria-label="Starten" onClick={handleStart}>
            {actionLoading ? (
              <Loader2 className="h-4 w-4 animate-spin sm:mr-2" />
            ) : (
              <Play className="h-4 w-4 sm:mr-2" />
            )}
            <span className="hidden sm:inline">Starten</span>
          </Button>

          {/* Herstart */}
          <ConfirmDialog
            open={rebootDialogOpen}
            onOpenChange={setRebootDialogOpen}
            trigger={
              <Button
                variant="outline"
                disabled={vps.status !== "ACTIVE" || actionLoading}
                aria-label="Herstarten"
              >
                <RotateCw className="h-4 w-4 sm:mr-2" />
                <span className="hidden sm:inline">Herstarten</span>
              </Button>
            }
            title="VPS herstarten"
            description="Het besturingssysteem wordt gevraagd af te sluiten en komt daarna weer op. Openstaande verbindingen vallen weg."
            confirmLabel="Herstarten"
            onConfirm={handleReboot}
            loading={actionLoading}
          />

          {/* Stop */}
          <ConfirmDialog
            open={stopDialogOpen}
            onOpenChange={setStopDialogOpen}
            trigger={
              <Button variant="outline" disabled={!canStop} aria-label="Stoppen">
                <Square className="h-4 w-4 sm:mr-2" />
                <span className="hidden sm:inline">Stoppen</span>
              </Button>
            }
            title="VPS stoppen"
            description="Weet je zeker dat je deze VPS wilt stoppen? De server wordt uitgeschakeld."
            confirmLabel="Stoppen"
            variant="destructive"
            onConfirm={handleStop}
            loading={actionLoading}
          />

          {/* Delete */}
          <ConfirmDialog
            open={deleteDialogOpen}
            onOpenChange={setDeleteDialogOpen}
            trigger={
              <Button variant="destructive" disabled={!canDelete} aria-label="Verwijderen">
                <Trash2 className="h-4 w-4 sm:mr-2" />
                <span className="hidden sm:inline">Verwijderen</span>
              </Button>
            }
            title="VPS verwijderen"
            description="Weet je zeker dat je deze VPS wilt verwijderen? Dit kan niet ongedaan worden gemaakt. Alle gegevens worden permanent verwijderd."
            confirmLabel="Definitief verwijderen"
            variant="destructive"
            onConfirm={handleDelete}
            loading={actionLoading}
          />
        </div>
      </div>

      {/* Een mislukte aanmaak is het moment waarop een klant zich zorgen maakt
          over zijn geld, en tot nu toe stond hier alleen het woord "Fout" in een
          badge. De terugstorting gebeurt automatisch en in dezelfde transactie
          als het markeren van de mislukking, dus dat kunnen we hier gewoon
          zeggen -- en waar het te controleren valt ook. */}
      {vps.status === "ERROR" && (
        <div className="flex items-start gap-3 rounded-lg border border-destructive/30 bg-destructive/5 p-4 text-sm">
          <AlertCircle className="mt-0.5 h-5 w-5 shrink-0 text-destructive" />
          <div className="space-y-1">
            <p className="font-medium text-destructive-text">Deze VPS kon niet worden aangemaakt.</p>
            <p className="text-muted-foreground">
              Het bedrag is automatisch teruggestort op je tegoed; je vindt de boeking terug op{" "}
              <Link href="/dashboard/billing" className="font-medium underline underline-offset-2">
                je facturatiepagina
              </Link>
              . Je kunt hem hier verwijderen en het gewoon opnieuw proberen. Blijft het misgaan,
              laat het ons dan weten &mdash; dan ligt het aan ons en niet aan jou.
            </p>
          </div>
        </div>
      )}

      {/* Detail cards */}
      <div className="grid gap-6 md:grid-cols-2">
        {/* General info */}
        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2 text-lg">
              <Server className="h-5 w-5" />
              Algemene informatie
            </CardTitle>
          </CardHeader>
          <CardContent className="space-y-3">
            <div className="flex justify-between">
              <span className="text-muted-foreground">Label</span>
              <span className="font-medium">
                {vps.label || `VPS #${vps.id}`}
              </span>
            </div>
            <div className="flex justify-between">
              <span className="text-muted-foreground">Status</span>
              <StatusBadge status={vps.status} />
            </div>
            <div className="flex justify-between">
              <span className="text-muted-foreground">Locatie</span>
              <span className="font-medium">{vps.location ?? "—"}</span>
            </div>
            <div className="flex justify-between">
              <span className="text-muted-foreground">Aangemaakt op</span>
              <span className="font-medium">{formatDate(vps.created_at)}</span>
            </div>
          </CardContent>
        </Card>

        {/* Toegang via webterminal */}
        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2 text-lg">
              <Terminal className="h-5 w-5" />
              Toegang
            </CardTitle>
            <CardDescription>
              Verbind met je VPS via de ingebouwde webterminal.
            </CardDescription>
          </CardHeader>
          <CardContent>
            <Link href={`/dashboard/vps/${vps.id}/terminal`}>
              <Button className="w-full gap-2" disabled={vps.status !== "ACTIVE"}>
                <Terminal className="h-4 w-4" />
                Webterminal openen
              </Button>
            </Link>
          </CardContent>
        </Card>

        {/* Inloggegevens */}
        <Card className="md:col-span-2">
          <CardHeader>
            <CardTitle className="flex items-center gap-2 text-lg">
              <KeyRound className="h-5 w-5" />
              Inloggegevens
            </CardTitle>
            <CardDescription>
              De snelste manier om in te loggen is de webterminal hierboven.
            </CardDescription>
          </CardHeader>
          <CardContent>
            <div className="grid gap-4 sm:grid-cols-3">
              {vps.public_host && vps.ssh_port ? (
                <>
                  <div className="space-y-1">
                    <p className="text-sm text-muted-foreground">Adres</p>
                    <p className="font-medium font-mono">{vps.public_host}</p>
                  </div>
                  <div className="space-y-1">
                    <p className="text-sm text-muted-foreground">Gebruikersnaam</p>
                    <p className="font-medium font-mono">{vps.ssh_username}</p>
                  </div>
                  <div className="space-y-1">
                    <p className="text-sm text-muted-foreground">SSH-poort</p>
                    <p className="font-medium font-mono">{vps.ssh_port}</p>
                  </div>
                  <div className="sm:col-span-3 space-y-1">
                    <p className="text-sm text-muted-foreground">Verbinden</p>
                    <p className="font-medium font-mono break-all">
                      ssh -p {vps.ssh_port} {vps.ssh_username}@{vps.public_host}
                    </p>
                  </div>
                </>
              ) : (
                /* Telling someone their VPS lives at 10.10.0.21 is telling them
                   nothing: that address is only routable on the machine the VPS
                   runs on. Better to say plainly that there is no external
                   endpoint yet than to print one that cannot work. */
                <div className="sm:col-span-3 space-y-1">
                  <p className="text-sm text-muted-foreground">Bereikbaar van buiten</p>
                  <p className="font-medium">
                    Nee. Je bereikt deze VPS via de webterminal hierboven — die geeft je
                    een volwaardige shell. SSH vanaf je eigen machine staat bewust uit,
                    zodat de VPS niet aan het open internet hangt.
                  </p>
                </div>
              )}
            </div>
          </CardContent>
        </Card>

        {/* Specifications */}
        <Card className="md:col-span-2">
          <CardHeader>
            <CardTitle className="flex items-center gap-2 text-lg">
              <Cpu className="h-5 w-5" />
              Specificaties
            </CardTitle>
          </CardHeader>
          <CardContent>
            <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-5">
              <div className="space-y-1">
                <p className="text-sm text-muted-foreground">Pakket</p>
                <p className="font-medium">{vps.package.name}</p>
              </div>
              <div className="space-y-1">
                <p className="text-sm text-muted-foreground">vCPU</p>
                <div className="flex items-center gap-2">
                  <Cpu className="h-4 w-4 text-muted-foreground" />
                  <p className="font-medium">{vps.package.cpu_cores} cores</p>
                </div>
              </div>
              <div className="space-y-1">
                <p className="text-sm text-muted-foreground">RAM</p>
                <div className="flex items-center gap-2">
                  <HardDrive className="h-4 w-4 text-muted-foreground" />
                  <p className="font-medium">{vps.package.ram_gb} GB</p>
                </div>
              </div>
              <div className="space-y-1">
                <p className="text-sm text-muted-foreground">Opslag</p>
                <div className="flex items-center gap-2">
                  <HardDrive className="h-4 w-4 text-muted-foreground" />
                  <p className="font-medium">{vps.package.disk_gb} GB NVMe</p>
                </div>
              </div>
              <div className="space-y-1">
                <p className="text-sm text-muted-foreground">Bandbreedte</p>
                <div className="flex items-center gap-2">
                  <Globe className="h-4 w-4 text-muted-foreground" />
                  <p className="font-medium">{formatBandbreedte(vps.package.bandwidth_mbit)}</p>
                </div>
              </div>
            </div>
          </CardContent>
        </Card>
        {/* Restore points */}
        <Card className="md:col-span-2">
          <CardHeader>
            <CardTitle className="flex items-center gap-2 text-lg">
              <HardDrive className="h-5 w-5" />
              Back-ups
            </CardTitle>
            <CardDescription>
              Elke nacht wordt een kopie van je schijf gemaakt; de laatste twee
              bewaren we. Ze staan op dezelfde machine als je VPS — genoeg om
              terug te gaan als je zelf iets sloopt, niet om een kapotte machine
              te overleven. Ga je iets doen wat mis kan gaan, maak er dan nu een.
            </CardDescription>
          </CardHeader>
          <CardContent>
            <Button
              variant="outline"
              size="sm"
              className="mb-4 gap-2"
              disabled={backupBezig || vps?.status !== "ACTIVE"}
              onClick={backupNu}
            >
              {backupBezig ? <Loader2 className="h-4 w-4 animate-spin" /> : <HardDrive className="h-4 w-4" />}
              Nu een back-up maken
            </Button>

            {backups.length === 0 ? (
              <p className="text-sm text-muted-foreground">
                Nog geen back-up. De eerste volgt vannacht, of maak er nu zelf een.
              </p>
            ) : (
              <div className="space-y-2">
                {backups.map((b) => (
                  <div
                    key={b.id}
                    className="flex flex-wrap items-center justify-between gap-2 rounded-md border p-3"
                  >
                    <div className="space-y-0.5">
                      <p className="font-medium">
                        {b.finished_at
                          ? formatDate(b.finished_at)
                          : b.started_at
                            ? `Bezig sinds ${formatDate(b.started_at)}`
                            : "In de wachtrij"}
                      </p>
                      <p className="text-xs text-muted-foreground">
                        {b.status === "failed"
                          ? `Mislukt — ${b.error ?? "onbekende fout"}`
                          : b.size_bytes
                            ? `${(b.size_bytes / 1024 ** 3).toFixed(1)} GB`
                            : "—"}
                      </p>
                    </div>
                    {b.status === "done" && (
                      <ConfirmDialog
                        open={confirmRestore === b.id}
                        onOpenChange={(open) => setConfirmRestore(open ? b.id : null)}
                        trigger={
                          <Button
                            variant="outline"
                            size="sm"
                            disabled={
                              restoring !== null ||
                              !(vps.status === "ACTIVE" || vps.status === "STOPPED")
                            }
                          >
                            {restoring === b.id ? (
                              <Loader2 className="h-4 w-4 animate-spin" />
                            ) : (
                              "Terugzetten"
                            )}
                          </Button>
                        }
                        title="Back-up terugzetten?"
                        description={`Je schijf wordt vervangen door de kopie van ${
                          b.finished_at ? formatDate(b.finished_at) : "deze back-up"
                        }. Alles wat je sindsdien hebt veranderd is weg en komt niet terug.`}
                        confirmLabel="Terugzetten"
                        variant="destructive"
                        loading={restoring === b.id}
                        onConfirm={() => restoreBackup(b)}
                      />
                    )}
                  </div>
                ))}
              </div>
            )}
          </CardContent>
        </Card>
      </div>

    </div>
  );
}
