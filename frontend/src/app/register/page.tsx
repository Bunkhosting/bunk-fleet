"use client";

import axios from "axios";
import * as React from "react";
import { Loader2, MailCheck, Server } from "lucide-react";
import { Turnstile } from "@marsidev/react-turnstile";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { authApi, parseApiError } from "@/lib/api";
import { useToast } from "@/components/ui/use-toast";


type Veld = "name" | "email" | "password" | "password_confirm";

function VeldFout({ id, tekst }: { id: string; tekst?: string }) {
  if (!tekst) return null;
  return (
    <p id={id} role="alert" className="text-sm text-destructive-text">
      {tekst}
    </p>
  );
}

/** Vertaalt de changeset-fouten van de server naar een melding per veld, of null. */
function veldFoutenUit(err: unknown): Partial<Record<Veld, string>> | null {
  if (!axios.isAxiosError(err)) return null;
  const errors = (err.response?.data as { errors?: Record<string, string[]> } | undefined)?.errors;
  if (!errors || typeof errors !== "object") return null;
  const uit: Partial<Record<Veld, string>> = {};
  if (errors.email) {
    uit.email = errors.email.some((m) => m.includes("taken"))
      ? "Dit e-mailadres is al in gebruik. Log in, of vraag een nieuw wachtwoord aan."
      : "Vul een geldig e-mailadres in.";
  }
  if (errors.password) uit.password = "Je wachtwoord moet tussen de 12 en 72 tekens lang zijn.";
  if (errors.name) uit.name = "Je naam mag hoogstens 100 tekens lang zijn.";
  return Object.keys(uit).length > 0 ? uit : null;
}

function RegisterForm() {
  const { toast } = useToast();

  const [name, setName] = React.useState("");
  const [email, setEmail] = React.useState("");
  const [password, setPassword] = React.useState("");
  const [passwordConfirm, setPasswordConfirm] = React.useState("");
  const [loading, setLoading] = React.useState(false);
  const [done, setDone] = React.useState(false);
  const [turnstileToken, setTurnstileToken] = React.useState<string | null>(null);

  // Fouten die bij één veld horen staan onder dat veld, in het Nederlands. De
  // server geeft Ecto-meldingen in het Engels ("has already been taken"), en
  // die kwamen eerder letterlijk in een melding die na een paar seconden weg was.
  const [veldFouten, setVeldFouten] = React.useState<Partial<Record<Veld, string>>>({});

  const turnstileSiteKey = process.env.NEXT_PUBLIC_TURNSTILE_SITE_KEY;


  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (password !== passwordConfirm) {
      setVeldFouten({ password_confirm: "De twee wachtwoorden zijn niet gelijk." });
      return;
    }
    setVeldFouten({});
    setLoading(true);
    try {
      await authApi.register(
        name,
        email,
        password,
        passwordConfirm,
        turnstileToken || undefined,
      );
      setDone(true);
    } catch (err: unknown) {
      // Backend kan vragen om Turnstile te (her)valideren; reset de widget.
      const data = (err as { response?: { data?: { turnstile_required?: boolean } } })?.response?.data;
      if (data?.turnstile_required) {
        setTurnstileToken(null);
      }
      const perVeld = veldFoutenUit(err);
      if (perVeld) {
        setVeldFouten(perVeld);
        return;
      }
      toast({
        variant: "destructive",
        title: "Registratie mislukt",
        description: parseApiError(err, "Controleer de ingevulde gegevens."),
      });
    } finally {
      setLoading(false);
    }
  }

  return (
    <div className="min-h-screen flex flex-col bg-background bg-dot-grid">
      {/* Ambient glow orbs */}
      <div className="fixed inset-0 pointer-events-none overflow-hidden z-0">
        <div className="absolute top-[-15%] right-[-12%] w-[55%] h-[55%] rounded-full bg-primary/15 blur-[120px] animate-glow" />
        <div className="absolute bottom-[-20%] left-[-10%] w-[45%] h-[45%] rounded-full bg-accent/10 blur-[100px] animate-glow-slow" />
      </div>

      {/* Header */}
      <header className="fixed top-0 w-full z-50 bg-background/80 backdrop-blur-xl border-b border-outline-variant/10 transition-all duration-300">
        <div className="max-w-7xl mx-auto flex justify-between items-center px-6 lg:px-8 h-16 w-full">
          <a href={process.env.NEXT_PUBLIC_WEBSITE_URL || "/"} className="flex items-center gap-3">
            <Server className="h-6 w-6 text-accent" />
            <span className="text-lg font-headline font-black tracking-tighter text-foreground uppercase">BUNK HOSTING</span>
          </a>
        </div>
      </header>

      <main className="relative z-10 flex-1 flex items-center justify-center py-12 px-4 pt-28">
        <div className="w-full max-w-md">
          <div className="text-center mb-8">
            <h1 className="text-3xl font-display font-bold mb-2">
              {done ? "Account aangemaakt" : "Maak een account aan"}
            </h1>
            <p className="text-muted-foreground">
              {done
                ? "Je account is aangemaakt en je bent ingelogd"
                : "Registreer je bij Bunk Hosting"}
            </p>
          </div>

          <div className="card-gradient-border rounded-xl p-6 bg-card">
            {done ? (
              <div className="space-y-5 text-center">
                <div className="flex justify-center">
                  <MailCheck className="h-12 w-12 text-primary" />
                </div>
                <p className="text-sm text-muted-foreground">
                  Welkom bij Bunk Hosting. Je bent automatisch ingelogd en kunt direct aan de slag.
                </p>
                <Button asChild className="w-full py-5">
                  <a href="/dashboard">Naar dashboard</a>
                </Button>
              </div>
            ) : (
              <form onSubmit={handleSubmit} className="space-y-5">
                <div className="space-y-2">
                  <Label htmlFor="name">Naam</Label>
                  <Input
                    id="name"
                    aria-invalid={veldFouten.name ? true : undefined}
                    aria-describedby={veldFouten.name ? "name-fout" : undefined}
                    type="text"
                    placeholder="Jan de Vries"
                    value={name}
                    onChange={(e) => setName(e.target.value)}
                    required
                    disabled={loading}
                    className="bg-background/60 border-border/60 focus:border-primary/60"
                  />
                  <VeldFout id="name-fout" tekst={veldFouten.name} />
                </div>
                <div className="space-y-2">
                  <Label htmlFor="email">E-mailadres</Label>
                  <Input
                    id="email"
                    aria-invalid={veldFouten.email ? true : undefined}
                    aria-describedby={veldFouten.email ? "email-fout" : undefined}
                    type="email"
                    placeholder="naam@voorbeeld.nl"
                    value={email}
                    onChange={(e) => setEmail(e.target.value)}
                    required
                    disabled={loading}
                    className="bg-background/60 border-border/60 focus:border-primary/60"
                  />
                  <VeldFout id="email-fout" tekst={veldFouten.email} />
                </div>
                <div className="space-y-2">
                  <Label htmlFor="password">Wachtwoord</Label>
                  <Input
                    id="password"
                    aria-invalid={veldFouten.password ? true : undefined}
                    type="password"
                    placeholder="••••••••"
                    value={password}
                    onChange={(e) => setPassword(e.target.value)}
                    required
                    /* De server eist twaalf tekens. Dat stond hier nergens, dus
                       je vulde alles in, loste een captcha op, drukte op
                       verzenden -- en kreeg dán pas te horen dat het te kort
                       was, inclusief een nieuwe captcha-ronde. */
                    minLength={12}
                    aria-describedby={veldFouten.password ? "password-fout password-eis" : "password-eis"}
                    disabled={loading}
                    className="bg-background/60 border-border/60 focus:border-primary/60"
                  />
                  <p id="password-eis" className="text-xs text-muted-foreground">
                    Minimaal 12 tekens. Een zin die je onthoudt is veiliger dan een
                    kort wachtwoord met tekens erdoor.
                  </p>
                  <VeldFout id="password-fout" tekst={veldFouten.password} />
                </div>
                <div className="space-y-2">
                  <Label htmlFor="password_confirm">Wachtwoord bevestigen</Label>
                  <Input
                    id="password_confirm"
                    aria-invalid={veldFouten.password_confirm ? true : undefined}
                    aria-describedby={veldFouten.password_confirm ? "password_confirm-fout" : undefined}
                    type="password"
                    placeholder="••••••••"
                    value={passwordConfirm}
                    onChange={(e) => setPasswordConfirm(e.target.value)}
                    required
                    disabled={loading}
                    className="bg-background/60 border-border/60 focus:border-primary/60"
                  />
                  <VeldFout id="password_confirm-fout" tekst={veldFouten.password_confirm} />
                </div>

                <div className="flex justify-center">
                  {turnstileSiteKey ? (
                    <Turnstile
                      siteKey={turnstileSiteKey}
                      onSuccess={(token) => setTurnstileToken(token)}
                      onExpire={() => setTurnstileToken(null)}
                      onError={() => setTurnstileToken(null)}
                    />
                  ) : (
                    <p className="text-sm text-destructive-text">
                      CAPTCHA configuratie ontbreekt. Zet NEXT_PUBLIC_TURNSTILE_SITE_KEY.
                    </p>
                  )}
                </div>

                <Button
                  type="submit"
                  className="w-full py-5"
                  disabled={
                    loading ||
                    !name.trim() ||
                    !email.trim() ||
                    !password ||
                    !passwordConfirm ||
                    (!!turnstileSiteKey && !turnstileToken)
                  }
                >
                  {loading && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
                  Account aanmaken
                </Button>

                <p className="text-center text-sm text-muted-foreground">
                  Al een account?{" "}
                  <a href="/login" className="text-primary-text underline-offset-4 hover:underline">
                    Inloggen
                  </a>
                </p>
              </form>
            )}
          </div>
        </div>
      </main>
    </div>
  );
}

export default function RegisterPage() {
  return (
    <React.Suspense
      fallback={
        <div className="min-h-screen flex items-center justify-center">
          <Loader2 className="h-8 w-8 animate-spin text-primary" />
        </div>
      }
    >
      <RegisterForm />
    </React.Suspense>
  );
}
