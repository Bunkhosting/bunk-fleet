"use client";

// De foutgrens voor alles buiten het dashboard (inloggen, registreren, een
// nieuw wachtwoord). Zonder deze viel een crash daar door naar global-error,
// met de kop "Bunk Hosting is tijdelijk niet bereikbaar" -- voor één
// formulier dat struikelde. Dezelfde pagina als in het dashboard.
import DashboardError from "./dashboard/error";

export default DashboardError;
