"use client";

import * as React from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";

interface Vraag {
  titel: string;
  uitleg?: React.ReactNode;
  bevestigLabel: string;
  variant?: "default" | "destructive";
  /** Met een invoerveld: het antwoord is dan de ingevulde tekst (leeg mag), of null bij annuleren. */
  invoer?: { label: string; standaard?: string; placeholder?: string };
}

type Antwoord = boolean | string | null;

/**
 * Een bevestiging of korte vraag in de eigen dialoog van het dashboard, als
 * promise: `if (!(await bevestig({...}))) return;`.
 *
 * Vervangt `window.confirm` en `window.prompt`. Die zagen er per browser anders
 * uit, waren niet te stylen, blokkeerden de hele pagina, en stonden naast de
 * eigen ConfirmDialog -- twee manieren om hetzelfde te vragen. Deze hook laat
 * elke plek in één regel overstappen zonder zijn eigen open/dicht-toestand bij
 * te houden.
 *
 * Geef `dialoog` één keer mee in de JSX van de pagina.
 */
export function useBevestig(): {
  dialoog: React.ReactNode;
  bevestig: (vraag: Vraag & { invoer?: undefined }) => Promise<boolean>;
  vraag: (vraag: Vraag & { invoer: NonNullable<Vraag["invoer"]> }) => Promise<string | null>;
} {
  const [huidig, setHuidig] = React.useState<Vraag | null>(null);
  const [tekst, setTekst] = React.useState("");
  const oplossen = React.useRef<((a: Antwoord) => void) | null>(null);
  const invoerId = React.useId();

  const open = React.useCallback((v: Vraag) => {
    setTekst(v.invoer?.standaard ?? "");
    setHuidig(v);
    return new Promise<Antwoord>((resolve) => {
      oplossen.current = resolve;
    });
  }, []);

  const sluit = (antwoord: Antwoord) => {
    oplossen.current?.(antwoord);
    oplossen.current = null;
    setHuidig(null);
  };

  const bevestigen = () => {
    if (huidig?.invoer) {
      // Leeg is een antwoord (bijvoorbeeld "zonder eigenaar"); alleen
      // annuleren geeft null.
      sluit(tekst.trim());
    } else {
      sluit(true);
    }
  };

  const dialoog = (
    <Dialog
      open={huidig !== null}
      onOpenChange={(o) => {
        if (!o) sluit(huidig?.invoer ? null : false);
      }}
    >
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{huidig?.titel}</DialogTitle>
          {huidig?.uitleg && <DialogDescription>{huidig.uitleg}</DialogDescription>}
        </DialogHeader>
        {huidig?.invoer && (
          <form
            className="space-y-2"
            onSubmit={(e) => {
              e.preventDefault();
              bevestigen();
            }}
          >
            <Label htmlFor={invoerId}>{huidig.invoer.label}</Label>
            <Input
              id={invoerId}
              autoFocus
              value={tekst}
              placeholder={huidig.invoer.placeholder}
              onChange={(e) => setTekst(e.target.value)}
            />
          </form>
        )}
        <DialogFooter>
          <Button variant="outline" onClick={() => sluit(huidig?.invoer ? null : false)}>
            Annuleren
          </Button>
          <Button variant={huidig?.variant ?? "default"} onClick={bevestigen}>
            {huidig?.bevestigLabel}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );

  return {
    dialoog,
    bevestig: open as (v: Vraag) => Promise<boolean>,
    vraag: open as (v: Vraag) => Promise<string | null>,
  };
}
