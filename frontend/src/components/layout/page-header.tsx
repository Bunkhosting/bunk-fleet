import * as React from "react";

/**
 * De kop van een dashboardpagina: titel, een regel uitleg, en rechts de knoppen.
 *
 * Elke pagina bouwde dit zelf, en dat liep uiteen: de ene titel 3xl, de andere
 * 2xl of in het display-lettertype, en een deel van de rijen liep op een
 * telefoon over de rand omdat de knoppen niet naar een tweede regel mochten.
 * Hier staat het één keer: op een smal scherm komen de knoppen onder de titel.
 */
export function PageHeader({
  title,
  description,
  children,
}: {
  title: React.ReactNode;
  description?: React.ReactNode;
  /** Knoppen of filters rechts van de titel. */
  children?: React.ReactNode;
}) {
  return (
    <div className="flex flex-col gap-4 sm:flex-row sm:flex-wrap sm:items-end sm:justify-between">
      <div className="min-w-0">
        <h1 className="break-words text-2xl font-bold tracking-tight sm:text-3xl">{title}</h1>
        {description && <p className="mt-1 text-muted-foreground">{description}</p>}
      </div>
      {children && <div className="flex flex-wrap items-center gap-2">{children}</div>}
    </div>
  );
}
