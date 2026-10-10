"use client";

import * as React from "react";
import Link from "next/link";
import { Loader2, ArrowLeft, Server, MailCheck } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { authApi, parseApiError } from "@/lib/api";

export default function ForgotPasswordPage() {
  const [email, setEmail] = React.useState("");
  const [loading, setLoading] = React.useState(false);
  const [submitted, setSubmitted] = React.useState(false);
  const [fout, setFout] = React.useState<string | null>(null);


  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setFout(null);
    setLoading(true);
    try {
      await authApi.requestPasswordReset(email);
      setSubmitted(true);
    } catch (err: unknown) {
      // De server antwoordt voor elk adres hetzelfde (200), bestaand of niet;
      // daar zit de bescherming tegen het aftasten van accounts. Een fout hier
      // is dus nooit "dit adres bestaat niet" maar een storing of een rem, en
      // die verzwijgen liet iemand wachten op een mail die nooit kwam.
      setFout(parseApiError(err, "Het versturen is niet gelukt. Probeer het zo opnieuw."));
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
          <Link href="/login" className="text-sm text-muted-foreground hover:text-foreground transition-colors inline-flex min-h-11 items-center gap-1">
            <ArrowLeft className="h-4 w-4" />
            Terug naar inloggen
          </Link>
        </div>
      </header>

      <main className="relative z-10 flex-1 flex items-center justify-center py-12 px-4 pt-28">
        <div className="w-full max-w-md">
          <div className="text-center mb-8">
            <h1 className="text-3xl font-display font-bold mb-2">Wachtwoord vergeten</h1>
            <p className="text-muted-foreground">
              Voer je e-mailadres in om een resetlink te ontvangen.
            </p>
          </div>

          <div className="card-gradient-border rounded-xl p-6 bg-card">
            {submitted ? (
              <div className="text-center py-4">
                <div className="w-12 h-12 rounded-full bg-accent/10 flex items-center justify-center mx-auto mb-4">
                  <MailCheck className="h-6 w-6 text-accent" />
                </div>
                <h2 className="text-lg font-semibold mb-2">Check je inbox</h2>
                <p className="text-sm text-muted-foreground mb-6">
                  Als er een account bestaat met dit e-mailadres, ontvang je binnen enkele minuten een resetlink.
                </p>
                <Button asChild variant="outline" className="w-full">
                  <Link href="/login">Terug naar inloggen</Link>
                </Button>
              </div>
            ) : (
              <form onSubmit={handleSubmit} className="space-y-4">
                <div className="space-y-2">
                  <Label htmlFor="email">E-mailadres</Label>
                  <Input
                    id="email"
                    type="email"
                    placeholder="naam@voorbeeld.nl"
                    value={email}
                    onChange={(e) => setEmail(e.target.value)}
                    required
                    disabled={loading}
                    className="bg-background/60 border-border/60 focus:border-primary/60"
                  />
                </div>
                {fout && (
                  <p role="alert" className="text-sm text-destructive-text">
                    {fout}
                  </p>
                )}
                <Button type="submit" className="w-full py-5" disabled={loading}>
                  {loading && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
                  Resetlink versturen
                </Button>
              </form>
            )}
          </div>
        </div>
      </main>
    </div>
  );
}
