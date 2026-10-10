"use client";

import { useBevestig } from "@/components/ui/use-bevestig";
import * as React from "react";
import { useSearchParams, useRouter } from "next/navigation";
import { ShieldCheck, ShieldOff, ShieldAlert, Loader2, Copy, Check, KeyRound, Trash2, Plus } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { authApi, parseApiError, toPublicKeyOptions, type Passkey } from "@/lib/api";
import { useUser } from "@/contexts/UserContext";
import { useToast } from "@/components/ui/use-toast";

type SetupStep = "idle" | "scanning" | "confirming" | "disabling";

const UITLEG = [
  {
    term: "Authenticator-app (TOTP)",
    uitleg:
      "Je app maakt elke dertig seconden een nieuwe code. Die heb je naast je wachtwoord nodig om in te loggen, dus met alleen een uitgelekt wachtwoord komt niemand binnen.",
  },
  {
    term: "Passkeys",
    uitleg:
      "In plaats van een wachtwoord tekent je telefoon of laptop het inloggen met een sleutel die het apparaat nooit verlaat. Er valt niets te onderscheppen en niets te phishen, want de sleutel werkt alleen op bunkhosting.nl.",
  },
  {
    term: "Allebei tegelijk kan",
    uitleg:
      "Een passkey vervangt je wachtwoord, TOTP komt er juist bovenop. Wie beide aanzet houdt een tweede manier over als een telefoon kwijtraakt.",
  },
  {
    term: "Automatisch uitloggen",
    uitleg:
      "Een sessie stopt na zeven dagen zonder activiteit, en hoe dan ook na dertig dagen. Dat beperkt hoe lang een gestolen sessie van een meegelezen of achtergelaten apparaat nog bruikbaar is.",
  },
];

function BeveiligingContent() {
  const { dialoog, bevestig, vraag } = useBevestig();
  const { user, refresh } = useUser();
  const { toast } = useToast();
  const searchParams = useSearchParams();
  const router = useRouter();

  const isMfaPrompt = searchParams.get("mfa_setup") === "1";

  const [step, setStep] = React.useState<SetupStep>("idle");
  const [qrDataUrl, setQrDataUrl] = React.useState("");
  const [secret, setSecret] = React.useState("");
  const [code, setCode] = React.useState("");
  const [loading, setLoading] = React.useState(false);
  const [copied, setCopied] = React.useState(false);

  const [huidigWachtwoord, setHuidigWachtwoord] = React.useState("");
  const [nieuwWachtwoord, setNieuwWachtwoord] = React.useState("");
  const [herhaal, setHerhaal] = React.useState("");
  const [pwBezig, setPwBezig] = React.useState(false);

  // Passkeys staan los van TOTP: je kunt er meerdere hebben en ze los kwijtraken,
  // dus ze worden als lijst beheerd in plaats van als één aan/uit-schakelaar.
  const [passkeys, setPasskeys] = React.useState<Passkey[] | null>(null);
  const [passkeyBusy, setPasskeyBusy] = React.useState(false);
  const webauthnAvailable =
    typeof window !== "undefined" && typeof window.PublicKeyCredential !== "undefined";

  const loadPasskeys = React.useCallback(() => {
    authApi.passkey
      .list()
      .then(setPasskeys)
      .catch(() => setPasskeys([]));
  }, []);

  React.useEffect(() => {
    loadPasskeys();
  }, [loadPasskeys]);

  async function addPasskey() {
    const label = await vraag({
      titel: "Passkey toevoegen",
      uitleg: "Geef hem een naam, zodat je hem later herkent.",
      bevestigLabel: "Verder",
      invoer: { label: "Naam", placeholder: "Telefoon of Laptop" },
    });
    if (!label) return;
    setPasskeyBusy(true);
    try {
      const ch = await authApi.passkey.challenge();
      const cred = (await navigator.credentials.create({
        publicKey: toPublicKeyOptions(ch.public_key) as unknown as PublicKeyCredentialCreationOptions,
      })) as PublicKeyCredential | null;
      if (!cred) throw new Error("Geen passkey aangemaakt.");
      await authApi.passkey.register(ch.challenge_id, label, cred);
      toast({ title: "Passkey toegevoegd", description: `"${label}" kan nu gebruikt worden om in te loggen.` });
      loadPasskeys();
      await refresh();
    } catch (err: unknown) {
      // De browser gooit een DOMException als de gebruiker annuleert of als de
      // authenticator al geregistreerd is; dat is geen serverfout.
      const msg =
        err instanceof DOMException
          ? err.name === "NotAllowedError"
            ? "Geannuleerd of geen toestemming gegeven."
            : err.name === "InvalidStateError"
              ? "Deze authenticator is al geregistreerd."
              : err.message
          : parseApiError(err, "Passkey toevoegen mislukt.");
      toast({ variant: "destructive", title: "Passkey niet toegevoegd", description: msg });
    } finally {
      setPasskeyBusy(false);
    }
  }

  async function removePasskey(pk: Passkey) {
    const ok = await bevestig({
      titel: `Passkey "${pk.label}" verwijderen?`,
      uitleg: "Je kunt er daarna niet meer mee inloggen.",
      bevestigLabel: "Verwijderen",
      variant: "destructive",
    });
    if (!ok) return;
    try {
      await authApi.passkey.remove(pk.id);
      toast({ title: "Passkey verwijderd" });
      loadPasskeys();
      await refresh();
    } catch (err: unknown) {
      toast({ variant: "destructive", title: "Verwijderen mislukt", description: parseApiError(err, "Probeer het opnieuw.") });
    }
  }

  const startSetup = React.useCallback(async () => {
    setLoading(true);
    try {
      const res = await authApi.totp.setup();
      setQrDataUrl(res.data.qr_data_url);
      setSecret(res.data.secret);
      setStep("scanning");
    } catch (err) {
      toast({
        variant: "destructive",
        title: "Fout",
        description: parseApiError(err, "Kon TOTP-setup niet starten."),
      });
    } finally {
      setLoading(false);
    }
  }, [toast]);

  // Auto-start setup wanneer de gebruiker via de MFA-prompt is doorgestuurd.
  // Via een microtask: startSetup zet meteen loading, en dat synchroon doen in
  // een effect kost een extra rendercyclus.
  React.useEffect(() => {
    if (isMfaPrompt && user && !user.totp_enabled && step === "idle") {
      queueMicrotask(startSetup);
    }
  }, [isMfaPrompt, user, step, startSetup]);

  async function confirmSetup(e: React.FormEvent) {
    e.preventDefault();
    setLoading(true);
    try {
      await authApi.totp.confirm(code);
      await refresh();
      setStep("idle");
      setCode("");
      setQrDataUrl("");
      setSecret("");
      toast({ title: "TOTP ingeschakeld", description: "Je account is nu beveiligd met een authenticator-app." });
      if (isMfaPrompt) {
        router.push("/dashboard");
      }
    } catch (err) {
      toast({
        variant: "destructive",
        title: "Ongeldige code",
        description: parseApiError(err, "De ingevoerde code klopt niet. Probeer opnieuw."),
      });
      setCode("");
    } finally {
      setLoading(false);
    }
  }

  async function disableTotp(e: React.FormEvent) {
    e.preventDefault();
    setLoading(true);
    try {
      await authApi.totp.disable(code);
      await refresh();
      setStep("idle");
      setCode("");
      toast({ title: "TOTP uitgeschakeld", description: "Twee-factor-authenticatie is verwijderd." });
    } catch (err) {
      toast({
        variant: "destructive",
        title: "Ongeldige code",
        description: parseApiError(err, "De ingevoerde code klopt niet."),
      });
      setCode("");
    } finally {
      setLoading(false);
    }
  }

  // Wachtwoord wijzigen. Het huidige moet erbij: een geldige sessie is geen
  // bewijs dat de eigenaar achter het scherm zit. Wie dit doet omdat hij
  // vermoedt dat iemand meekijkt, blijft zelf ingelogd -- de meekijker niet.
  async function wijzigWachtwoord(e: React.FormEvent) {
    e.preventDefault();
    if (nieuwWachtwoord !== herhaal) {
      toast({ title: "De twee nieuwe wachtwoorden zijn niet gelijk", variant: "destructive" });
      return;
    }
    setPwBezig(true);
    try {
      await authApi.changePassword(huidigWachtwoord, nieuwWachtwoord);
      setHuidigWachtwoord("");
      setNieuwWachtwoord("");
      setHerhaal("");
      toast({
        title: "Wachtwoord gewijzigd",
        description: "Je blijft hier ingelogd; alle andere sessies zijn uitgelogd.",
      });
    } catch (err) {
      toast({
        title: "Niet gewijzigd",
        description: parseApiError(err, "Klopt je huidige wachtwoord?"),
        variant: "destructive",
      });
    } finally {
      setPwBezig(false);
    }
  }

  function copySecret() {
    navigator.clipboard.writeText(secret).catch(() => undefined);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  }

  if (!user) return null;

  return (
    <>
      {dialoog}
    <div className="max-w-2xl space-y-6">
      <div>
        <h1 className="text-2xl font-display font-bold">Beveiliging</h1>
        <p className="text-muted-foreground mt-1">Kies hoe je inlogt: een authenticator-app, een passkey, of allebei.</p>
      </div>

      {/* Wachtwoord wijzigen */}
      <form onSubmit={wijzigWachtwoord} className="card-gradient-border rounded-xl p-6 bg-card space-y-4">
        <div className="flex items-center gap-3">
          <KeyRound className="h-8 w-8 text-muted-foreground shrink-0" />
          <div>
            <p className="font-semibold">Wachtwoord</p>
            <p className="text-sm text-muted-foreground">
              Je huidige wachtwoord hoort erbij: een open sessie is geen bewijs dat jij het bent.
              Na het wijzigen worden al je andere sessies uitgelogd, deze niet.
            </p>
          </div>
        </div>
        <div className="grid gap-3 sm:grid-cols-3">
          <div className="space-y-1">
            <Label htmlFor="huidig">Huidig wachtwoord</Label>
            <Input
              id="huidig"
              type="password"
              autoComplete="current-password"
              value={huidigWachtwoord}
              onChange={(e) => setHuidigWachtwoord(e.target.value)}
            />
          </div>
          <div className="space-y-1">
            <Label htmlFor="nieuw">Nieuw wachtwoord</Label>
            <Input
              id="nieuw"
              type="password"
              autoComplete="new-password"
              value={nieuwWachtwoord}
              onChange={(e) => setNieuwWachtwoord(e.target.value)}
            />
          </div>
          <div className="space-y-1">
            <Label htmlFor="herhaal">Nogmaals</Label>
            <Input
              id="herhaal"
              type="password"
              autoComplete="new-password"
              value={herhaal}
              onChange={(e) => setHerhaal(e.target.value)}
            />
          </div>
        </div>
        <Button
          type="submit"
          disabled={pwBezig || !huidigWachtwoord || !nieuwWachtwoord || !herhaal}
          className="w-full sm:w-auto"
        >
          {pwBezig && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
          Wachtwoord wijzigen
        </Button>
      </form>

      {/* MFA-prompt banner — alleen zichtbaar na eerste inlog zonder TOTP */}
      {isMfaPrompt && !user.totp_enabled && (
        <div className="flex items-start gap-3 rounded-xl border border-primary/30 bg-primary/5 p-4">
          <ShieldAlert className="h-5 w-5 text-primary shrink-0 mt-0.5" />
          <div>
            <p className="font-semibold text-sm">Beveilig je account met een authenticator-app</p>
            <p className="text-sm text-muted-foreground mt-0.5">
              Scan de QR-code hieronder met Google Authenticator, Authy of een andere TOTP-app.
              Hierna heb je naast je wachtwoord altijd een unieke code nodig om in te loggen.
            </p>
          </div>
        </div>
      )}

      {/* TOTP status kaart */}
      <div className="card-gradient-border rounded-xl p-6 bg-card space-y-4">
        <div className="flex items-start justify-between gap-4">
          <div className="flex items-center gap-3">
            {user.totp_enabled ? (
              <ShieldCheck className="h-8 w-8 text-green-500 shrink-0" />
            ) : (
              <ShieldOff className="h-8 w-8 text-muted-foreground shrink-0" />
            )}
            <div>
              <p className="font-semibold">Authenticator-app (TOTP)</p>
              <p className="text-sm text-muted-foreground">
                {user.totp_enabled
                  ? "Actief, je account is beveiligd met een authenticator-app."
                  : "Niet actief. Schakel dit in voor extra beveiliging."}
              </p>
            </div>
          </div>
          <span className={`text-xs font-medium px-2 py-1 rounded-full shrink-0 ${
            user.totp_enabled
              ? "bg-green-500/10 text-green-500"
              : "bg-muted text-muted-foreground"
          }`}>
            {user.totp_enabled ? "Ingeschakeld" : "Uitgeschakeld"}
          </span>
        </div>

        {/* Stap: idle — knoppen tonen */}
        {step === "idle" && (
          <>
            {!user.totp_enabled ? (
              <Button onClick={startSetup} disabled={loading} className="w-full sm:w-auto">
                {loading && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
                TOTP inschakelen
              </Button>
            ) : (
              <Button
                variant="destructive"
                onClick={() => { setStep("disabling"); setCode(""); }}
                className="w-full sm:w-auto"
              >
                TOTP uitschakelen
              </Button>
            )}
          </>
        )}

        {/* Stap: QR-code scannen */}
        {step === "scanning" && (
          <div className="space-y-4">
            <p className="text-sm text-muted-foreground">
              Scan de QR-code met je authenticator-app (Google Authenticator, Authy, Bitwarden, etc.).
            </p>

            {qrDataUrl && (
              <div className="flex justify-center">
                {/* eslint-disable-next-line @next/next/no-img-element */}
                <img src={qrDataUrl} alt="TOTP QR-code" className="w-48 h-48 rounded-lg" />
              </div>
            )}

            <div className="space-y-1">
              <p className="text-xs text-muted-foreground">
                Kun je de QR-code niet scannen? Voer deze sleutel handmatig in:
              </p>
              <div className="flex items-center gap-2">
                <code className="flex-1 bg-muted rounded px-3 py-2 text-xs font-mono break-all">
                  {secret}
                </code>
                <Button
                  type="button"
                  variant="outline"
                  size="sm"
                  onClick={copySecret}
                  aria-label={copied ? "Gekopieerd" : "Sleutel kopiëren"}
                  title="Sleutel kopiëren"
                >
                  {copied ? <Check className="h-4 w-4" /> : <Copy className="h-4 w-4" />}
                </Button>
              </div>
            </div>

            <Button onClick={() => setStep("confirming")} className="w-full">
              Volgende: code bevestigen
            </Button>
            <Button
              variant="ghost"
              className="w-full"
              onClick={() => {
                setStep("idle");
                setCode("");
                if (isMfaPrompt) router.push("/dashboard");
              }}
            >
              {isMfaPrompt ? "Overslaan, later instellen" : "Annuleren"}
            </Button>
          </div>
        )}

        {/* Stap: code bevestigen */}
        {step === "confirming" && (
          <form onSubmit={confirmSetup} className="space-y-4">
            <p className="text-sm text-muted-foreground">
              Voer de 6-cijferige code in die je authenticator-app nu toont om de setup te bevestigen.
            </p>
            <div className="space-y-2">
              <Label htmlFor="confirm-code">Bevestigingscode</Label>
              <Input
                id="confirm-code"
                type="text"
                inputMode="numeric"
                maxLength={6}
                placeholder="123456"
                value={code}
                onChange={(e) => setCode(e.target.value.replace(/\D/g, ""))}
                required
                autoFocus
                autoComplete="one-time-code"
                className="bg-background/60 text-center tracking-widest text-lg"
              />
            </div>
            <Button type="submit" className="w-full" disabled={loading || code.length !== 6}>
              {loading && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
              Bevestigen &amp; activeren
            </Button>
            <Button type="button" variant="ghost" className="w-full" onClick={() => setStep("scanning")} disabled={loading}>
              Terug naar QR-code
            </Button>
          </form>
        )}

        {/* Stap: uitschakelen */}
        {step === "disabling" && (
          <form onSubmit={disableTotp} className="space-y-4">
            <p className="text-sm text-muted-foreground">
              Voer een huidige authenticator-code in om TOTP uit te schakelen.
            </p>
            <div className="space-y-2">
              <Label htmlFor="disable-code">Authenticator-code</Label>
              <Input
                id="disable-code"
                type="text"
                inputMode="numeric"
                maxLength={6}
                placeholder="123456"
                value={code}
                onChange={(e) => setCode(e.target.value.replace(/\D/g, ""))}
                required
                autoFocus
                autoComplete="one-time-code"
                className="bg-background/60 text-center tracking-widest text-lg"
              />
            </div>
            <Button type="submit" variant="destructive" className="w-full" disabled={loading || code.length !== 6}>
              {loading && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
              TOTP uitschakelen
            </Button>
            <Button type="button" variant="ghost" className="w-full" onClick={() => { setStep("idle"); setCode(""); }} disabled={loading}>
              Annuleren
            </Button>
          </form>
        )}
      </div>

      {/* Passkeys */}
      <div className="card-gradient-border rounded-xl p-6 bg-card space-y-4">
        <div className="flex items-start justify-between gap-4">
          <div className="flex items-center gap-3">
            <KeyRound className={`h-8 w-8 shrink-0 ${passkeys?.length ? "text-green-500" : "text-muted-foreground"}`} />
            <div>
              <p className="font-semibold">Passkeys</p>
              <p className="text-sm text-muted-foreground">
                Inloggen met je vingerafdruk, gezicht of een hardwaresleutel. Werkt naast of in
                plaats van de authenticator-app.
              </p>
            </div>
          </div>
          <span
            className={`text-xs font-medium px-2 py-1 rounded-full shrink-0 ${
              passkeys?.length ? "bg-green-500/10 text-green-500" : "bg-muted text-muted-foreground"
            }`}
          >
            {passkeys === null ? "…" : passkeys.length ? `${passkeys.length} actief` : "Geen"}
          </span>
        </div>

        {!webauthnAvailable ? (
          <p className="text-sm text-muted-foreground">Deze browser ondersteunt geen passkeys.</p>
        ) : (
          <>
            {passkeys && passkeys.length > 0 && (
              <ul className="divide-y rounded-lg border">
                {passkeys.map((pk) => (
                  <li key={pk.id} className="flex items-center justify-between gap-3 px-3 py-2 text-sm">
                    <div>
                      <p className="font-medium">{pk.label}</p>
                      <p className="text-xs text-muted-foreground">
                        Toegevoegd {new Date(pk.created_at).toLocaleDateString("nl-NL")}
                        {pk.last_used_at
                          ? ` · laatst gebruikt ${new Date(pk.last_used_at).toLocaleDateString("nl-NL")}`
                          : " · nog niet gebruikt"}
                      </p>
                    </div>
                    <Button
                      variant="ghost"
                      size="sm"
                      onClick={() => removePasskey(pk)}
                      title="Verwijderen"
                      aria-label={`Passkey ${pk.label} verwijderen`}
                    >
                      <Trash2 className="h-4 w-4" />
                    </Button>
                  </li>
                ))}
              </ul>
            )}
            <Button onClick={addPasskey} disabled={passkeyBusy} className="w-full sm:w-auto">
              {passkeyBusy ? <Loader2 className="mr-2 h-4 w-4 animate-spin" /> : <Plus className="mr-2 h-4 w-4" />}
              Passkey toevoegen
            </Button>
          </>
        )}
      </div>

      {/* Uitleg staat onder de opties, niet ertussen: tekst tussen twee kaarten
          breekt de rij en laat het lijken alsof hij bij de onderste hoort. */}
      <dl className="space-y-4 rounded-xl border bg-muted/30 p-6 text-sm">
        {UITLEG.map((item) => (
          <div key={item.term}>
            <dt className="font-medium text-foreground">{item.term}</dt>
            <dd className="mt-1 text-muted-foreground">{item.uitleg}</dd>
          </div>
        ))}
      </dl>
    </div>
    </>
  );
}

export default function BeveiligingPage() {
  return (
    <React.Suspense fallback={null}>
      <BeveiligingContent />
    </React.Suspense>
  );
}
