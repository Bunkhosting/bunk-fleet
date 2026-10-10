"use client";

import * as React from "react";
import { AlertTriangle, RefreshCw } from "lucide-react";
import { Button } from "@/components/ui/button";
import { reportClientError } from "@/lib/observability";

interface DashboardErrorProps {
  error: Error & { digest?: string };
  reset: () => void;
}

/**
 * React error-boundary voor /dashboard routes (Next 14 App Router conventie).
 *
 * Voorheen toonde een crash in een child component een wit scherm — zonder
 * stack, zonder herstelmogelijkheid en zonder backend-signaal. Deze boundary:
 *
 *  1. Toont een duidelijke UI met een "Probeer opnieuw"-knop (`reset()`).
 *  2. Logt de error naar de browserconsole (Sentry/observability komt later).
 *  3. Geeft de `digest` weer zodat de gebruiker bij support kan referen.
 *
 * Een toekomstige observability-laag stuurt deze error via
 * POST /api/v1/observability/client-errors/ naar Wazuh.
 */
export default function DashboardError({ error, reset }: DashboardErrorProps) {
  React.useEffect(() => {
    console.error("[dashboard error boundary]", error);
    reportClientError(error.message, {
      stack: error.stack,
      digest: error.digest,
    });
  }, [error]);

  return (
    <div className="flex min-h-[60vh] flex-col items-center justify-center gap-6 px-6 text-center">
      <AlertTriangle className="h-12 w-12 text-destructive" />
      <div className="space-y-2">
        <h1 className="text-2xl font-display font-bold">Er ging iets mis</h1>
        <p className="max-w-md text-sm text-muted-foreground">
          Er is een onverwachte fout opgetreden bij het laden van deze pagina.
          Er is niets verloren gegaan. Probeer het opnieuw; blijft het probleem
          bestaan, mail dan support@bunkhosting.nl
          {error.digest ? " en vermeld de referentie hieronder." : "."}
        </p>
        {error.digest && (
          <p className="font-mono text-xs text-muted-foreground">
            ref: {error.digest}
          </p>
        )}
      </div>
      <Button onClick={reset} variant="default">
        <RefreshCw className="mr-2 h-4 w-4" />
        Probeer opnieuw
      </Button>
    </div>
  );
}
