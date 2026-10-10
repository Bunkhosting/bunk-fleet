"use client";

import { useEffect, useRef } from "react";

/**
 * Roept `fn` elke `ms` milliseconden aan zolang `aan` waar is -- maar niet
 * zolang het tabblad verborgen is.
 *
 * De VPS-pagina's vroegen elke tien seconden om de status, ook in een tabblad
 * dat niemand bekeek. Een klant met een handvol tabbladen open belastte het
 * control plane zo voor niets. Wordt het tabblad weer zichtbaar, dan wordt er
 * meteen gevraagd, zodat wat er staat niet verouderd is.
 *
 * `fn` mag elke render een nieuwe functie zijn; de laatste wordt gebruikt.
 */
export function usePolling(fn: () => void, ms: number, aan: boolean) {
  const laatste = useRef(fn);
  useEffect(() => {
    laatste.current = fn;
  }, [fn]);

  useEffect(() => {
    if (!aan) return;

    let interval: ReturnType<typeof setInterval> | null = null;
    const start = () => {
      if (interval === null) interval = setInterval(() => laatste.current(), ms);
    };
    const stop = () => {
      if (interval !== null) {
        clearInterval(interval);
        interval = null;
      }
    };
    const zichtbaarheid = () => {
      if (document.hidden) {
        stop();
      } else {
        laatste.current();
        start();
      }
    };

    if (!document.hidden) start();
    document.addEventListener("visibilitychange", zichtbaarheid);
    return () => {
      stop();
      document.removeEventListener("visibilitychange", zichtbaarheid);
    };
  }, [aan, ms]);
}
