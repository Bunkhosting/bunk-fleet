"use client";

import Link from "next/link";
import { Server, Cpu, HardDrive, Globe, MapPin } from "lucide-react";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { StatusBadge } from "@/components/vps/status-badge";
import { getOsLabel } from "@/lib/utils";
import type { Vps } from "@/lib/types";

interface VpsCardProps {
  vps: Vps;
}

export function VpsCard({ vps }: VpsCardProps) {
  // Een echte link en geen div met een klik-handler: zo werkt de kaart met het
  // toetsenbord en een schermlezer, en kun je hem in een nieuw tabblad openen.
  return (
    <Link
      href={`/dashboard/vps/${vps.id}`}
      className="block rounded-lg focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 focus-visible:ring-offset-background"
    >
    <Card className="transition-shadow hover:shadow-md">
      <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
        <CardTitle className="text-base font-semibold flex items-center gap-2">
          <Server className="h-4 w-4 text-muted-foreground" />
          {vps.label || `VPS #${vps.id}`}
        </CardTitle>
        <StatusBadge status={vps.status} />
      </CardHeader>
      <CardContent>
        <div className="grid gap-2 text-sm text-muted-foreground">
          <div className="flex items-center gap-2">
            <Globe className="h-4 w-4" />
            {/* The private address is not an endpoint — it is routable only on
                the machine the VPS runs on. Show what someone can actually
                connect to, or say there is nothing yet. */}
            <span>
              {vps.public_host && vps.ssh_port
                ? `${vps.public_host}:${vps.ssh_port}`
                : "Alleen via de webterminal"}
            </span>
          </div>
          {vps.location && (
            <div className="flex items-center gap-2">
              <MapPin className="h-4 w-4" />
              <span>{vps.location}</span>
            </div>
          )}
          <div className="flex items-center gap-2">
            <HardDrive className="h-4 w-4" />
            <span>{getOsLabel(vps.os)}</span>
          </div>
          <div className="flex items-center gap-2">
            <Cpu className="h-4 w-4" />
            <span>
              {vps.package.name} &mdash; {vps.package.cpu_cores} vCPU, {vps.package.ram_gb} GB RAM
            </span>
          </div>
          {/* Zonder deze regel is "Fout" alles wat er staat, en dan is de eerste
              vraag van een klant niet "wat ging er mis" maar "waar is mijn
              geld". Dat antwoord hoort niet achter een klik te zitten. */}
          {vps.status === "ERROR" && (
            <p className="text-destructive-text">
              Aanmaken is mislukt &mdash; het bedrag staat terug op je tegoed.
            </p>
          )}
        </div>
      </CardContent>
    </Card>
    </Link>
  );
}
