"use client";

import * as React from "react";
import Link from "next/link";
import { useSearchParams, useRouter } from "next/navigation";
import { Loader2, CheckCircle, XCircle, Server } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import axios from "axios";
import { authApi, parseApiError } from "@/lib/api";

function ResetPasswordContent() {
  const searchParams = useSearchParams();
  const router = useRouter();
  const token = searchParams.get("token") ?? "";

  const [password, setPassword] = React.useState("");
  const [passwordConfirm, setPasswordConfirm] = React.useState("");
  const [loading, setLoading] = React.useState(false);
  // Een ontbrekend token is bij het renderen al bekend; dat hoort in de
  // begintoestand en niet in een effect, dat een extra rendercyclus kost.
  const [status, setStatus] = React.useState<"form" | "success" | "error">(
    token ? "form" : "error",
  );
  const [errorMessage, setErrorMessage] = React.useState(
    token ? "" : "Geen resettoken gevonden in de link. Vraag een nieuwe resetlink aan.",
  );
  // Een fout die de gebruiker zelf kan herstellen (tikfout in de bevestiging,
  // te kort wachtwoord) hoort bij het formulier. Alleen een dode link is een
  // eindstation; eerder kreeg je bij elke fout "vraag een nieuwe link aan",
  // terwijl de link nog gewoon werkte.
  const [veldFout, setVeldFout] = React.useState<{ veld: "password" | "password_confirm"; tekst: string } | null>(
    null,
  );

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (password !== passwordConfirm) {
      setVeldFout({ veld: "password_confirm", tekst: "De twee wachtwoorden zijn niet gelijk." });
      return;
    }
    setVeldFout(null);
    setLoading(true);
    try {
      await authApi.confirmPasswordReset(token, password, passwordConfirm);
      setStatus("success");
      setTimeout(() => router.push("/login"), 3000);
    } catch (err: unknown) {
      const data = axios.isAxiosError(err) ? err.response?.data : undefined;
      if (data && typeof data === "object" && "errors" in data && data.errors?.password) {
        // De server zegt dit in het Engels; de regel zelf is bekend.
        setVeldFout({ veld: "password", tekst: "Je wachtwoord moet tussen de 12 en 72 tekens lang zijn." });
      } else {
        setErrorMessage(parseApiError(err, "De resetlink is ongeldig of verlopen. Vraag een nieuwe aan."));
        setStatus("error");
      }
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="min-h-screen flex flex-col bg-background bg-dot-grid">
      <div className="fixed inset-0 pointer-events-none overflow-hidden z-0">
        <div className="absolute top-[-15%] right-[-12%] w-[55%] h-[55%] rounded-full bg-primary/15 blur-[120px] animate-glow" />
        <div className="absolute bottom-[-20%] left-[-10%] w-[45%] h-[45%] rounded-full bg-accent/10 blur-[100px] animate-glow-slow" />
      </div>

      <header className="fixed top-0 w-full z-50 bg-background/80 backdrop-blur-xl border-b border-outline-variant/10">
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
            <h1 className="text-3xl font-display font-bold mb-2">Nieuw wachtwoord</h1>
            <p className="text-muted-foreground">Kies een sterk wachtwoord voor je account.</p>
          </div>

          <div className="card-gradient-border rounded-xl p-6 bg-card">
            {status === "success" && (
              <div className="text-center py-4">
                <CheckCircle className="h-12 w-12 text-green-500 mx-auto mb-4" />
                <h2 className="text-lg font-semibold mb-2">Wachtwoord gewijzigd!</h2>
                <p className="text-sm text-muted-foreground">Je wordt doorgestuurd naar de inlogpagina…</p>
              </div>
            )}

            {status === "error" && (
              <div className="text-center py-4">
                <XCircle className="h-12 w-12 text-destructive mx-auto mb-4" />
                <h2 className="text-lg font-semibold mb-2">Mislukt</h2>
                <p className="text-sm text-muted-foreground mb-6">{errorMessage}</p>
                <Button asChild variant="outline" className="w-full">
                  <Link href="/forgot-password">Nieuwe resetlink aanvragen</Link>
                </Button>
              </div>
            )}

            {status === "form" && (
              <form onSubmit={handleSubmit} className="space-y-4">
                <div className="space-y-2">
                  <Label htmlFor="password">Nieuw wachtwoord</Label>
                  <Input
                    id="password"
                    type="password"
                    placeholder="••••••••"
                    value={password}
                    onChange={(e) => setPassword(e.target.value)}
                    required
                    minLength={12}
                    maxLength={72}
                    aria-invalid={veldFout?.veld === "password" || undefined}
                    aria-describedby={veldFout?.veld === "password" ? "password-fout password-eis" : "password-eis"}
                    disabled={loading}
                    className="bg-background/60 border-border/60 focus:border-primary/60"
                  />
                  <p id="password-eis" className="text-xs text-muted-foreground">
                    Minimaal 12 tekens.
                  </p>
                  {veldFout?.veld === "password" && (
                    <p id="password-fout" role="alert" className="text-sm text-destructive-text">
                      {veldFout.tekst}
                    </p>
                  )}
                </div>
                <div className="space-y-2">
                  <Label htmlFor="password_confirm">Wachtwoord bevestigen</Label>
                  <Input
                    id="password_confirm"
                    type="password"
                    placeholder="••••••••"
                    value={passwordConfirm}
                    onChange={(e) => setPasswordConfirm(e.target.value)}
                    required
                    aria-invalid={veldFout?.veld === "password_confirm" || undefined}
                    aria-describedby={veldFout?.veld === "password_confirm" ? "bevestig-fout" : undefined}
                    disabled={loading}
                    className="bg-background/60 border-border/60 focus:border-primary/60"
                  />
                  {veldFout?.veld === "password_confirm" && (
                    <p id="bevestig-fout" role="alert" className="text-sm text-destructive-text">
                      {veldFout.tekst}
                    </p>
                  )}
                </div>
                <Button type="submit" className="w-full py-5" disabled={loading}>
                  {loading && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
                  Wachtwoord opslaan
                </Button>
              </form>
            )}
          </div>
        </div>
      </main>
    </div>
  );
}

export default function ResetPasswordPage() {
  return (
    <React.Suspense fallback={null}>
      <ResetPasswordContent />
    </React.Suspense>
  );
}
