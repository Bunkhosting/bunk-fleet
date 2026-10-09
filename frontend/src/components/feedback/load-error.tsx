"use client";

import { AlertTriangle, RotateCw } from "lucide-react";
import { Button } from "@/components/ui/button";

interface LoadErrorProps {
  /** Wat er niet geladen kon worden, in de woorden van de klant. */
  message: string;
  onRetry?: () => void;
}

/**
 * Wat een pagina toont als ophalen mislukt.
 *
 * Bestaat omdat "ophalen mislukt" en "er is niets" hetzelfde scherm gaven: een
 * mislukte saldo-aanvraag liet € 0,00 in het rood zien, een mislukte lijst "je
 * hebt nog geen VPS'en". Een klant die dat leest denkt dat zijn geld of zijn
 * machines weg zijn. Een fout is een eigen toestand en hoort er ook zo uit te
 * zien.
 */
export function LoadError({ message, onRetry }: LoadErrorProps) {
  return (
    <div
      role="alert"
      className="flex flex-col items-start gap-3 rounded-lg border border-destructive/40 bg-destructive/10 p-4 sm:flex-row sm:items-center sm:justify-between"
    >
      <div className="flex items-start gap-3">
        <AlertTriangle className="mt-0.5 h-5 w-5 shrink-0 text-destructive" aria-hidden="true" />
        <p className="text-sm text-foreground">{message}</p>
      </div>
      {onRetry && (
        <Button variant="outline" size="sm" onClick={onRetry} className="gap-2">
          <RotateCw className="h-4 w-4" aria-hidden="true" />
          Opnieuw proberen
        </Button>
      )}
    </div>
  );
}
