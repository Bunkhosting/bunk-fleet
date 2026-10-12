/**
 * Vertaalt wat de browser gooit tijdens een passkey-ceremonie naar een korte
 * Nederlandse zin.
 *
 * navigator.credentials.create() en .get() falen met een DOMException waarvan
 * de tekst Engels is en per browser verschilt ("The operation either timed out
 * or was not allowed. See: https://www.w3.org/TR/webauthn-2/..."). Die tekst
 * hoort nooit bij de klant: alleen de naam van de exception telt, en wat we
 * niet kennen krijgt een algemene zin.
 *
 * Geeft null als de fout geen DOMException is. Dan kwam hij van onze API of
 * van onze eigen code, en hoort parseApiError hem te vertalen.
 */
export type PasskeyCeremonie = "registreren" | "inloggen";

export interface PasskeyFout {
  /**
   * De klant brak de ceremonie zelf af, of liet hem verlopen. Geen fout om luid
   * te melden: een rustige melding is genoeg.
   */
  geannuleerd: boolean;
  melding: string;
}

const ALGEMEEN: Record<PasskeyCeremonie, string> = {
  registreren: "Passkey toevoegen is niet gelukt. Probeer het opnieuw.",
  inloggen: "Inloggen met je passkey is niet gelukt. Probeer het opnieuw of gebruik je authenticator-code.",
};

export function passkeyFout(err: unknown, ceremonie: PasskeyCeremonie): PasskeyFout | null {
  if (typeof DOMException === "undefined" || !(err instanceof DOMException)) return null;

  switch (err.name) {
    // Chrome en Safari gooien dit bij annuleren, bij een time-out en als er op
    // dit apparaat geen passkey is die past. Ze maken bewust geen onderscheid.
    case "NotAllowedError":
      return { geannuleerd: true, melding: "Geannuleerd, of de tijd om te bevestigen is verstreken." };
    case "AbortError":
      return { geannuleerd: true, melding: "Geannuleerd." };
    case "InvalidStateError":
      return {
        geannuleerd: false,
        melding:
          ceremonie === "registreren"
            ? "Deze passkey staat al op je account."
            : "Deze passkey kan hier niet worden gebruikt.",
      };
    case "SecurityError":
      return {
        geannuleerd: false,
        melding: "Je browser staat passkeys op deze pagina niet toe. Controleer of je op het juiste adres zit.",
      };
    case "NotSupportedError":
      return { geannuleerd: false, melding: "Je browser of apparaat ondersteunt deze passkey niet." };
    case "ConstraintError":
      return {
        geannuleerd: false,
        melding: "Je apparaat kan de passkey niet ontgrendelen. Stel een pincode, vingerafdruk of gezicht in.",
      };
    default:
      return { geannuleerd: false, melding: ALGEMEEN[ceremonie] };
  }
}
