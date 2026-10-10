"use client";

import { useCallback, useRef } from "react";

/**
 * Laat alleen het antwoord van het laatst gestarte verzoek de pagina bijwerken.
 *
 * Twee verzoeken naar hetzelfde komen niet per se in volgorde terug. Klik je op
 * de activiteitenpagina snel van "Alles" naar "Mislukt", dan kan het trage
 * antwoord op "Alles" als laatste binnenkomen en de lijst onder het filter
 * "Mislukt" vullen. Op de VPS-pagina kan een peiling die al liep vóór een klik
 * op Start na het verse antwoord binnenkomen en de oude status terugzetten.
 *
 * Gebruik:
 *
 *     const nieuwste = useNieuwste();
 *     const laad = async () => {
 *       const isNieuwste = nieuwste();
 *       const data = await api.iets();
 *       if (isNieuwste()) setData(data);
 *     };
 */
export function useNieuwste(): () => () => boolean {
  const teller = useRef(0);
  return useCallback(() => {
    const mijn = ++teller.current;
    return () => mijn === teller.current;
  }, []);
}
