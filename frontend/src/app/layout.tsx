import type { Metadata } from "next";
import localFont from "next/font/local";
import "./globals.css";
import { Toaster } from "@/components/ui/toaster";
import { ObservabilityInit } from "@/components/observability-init";

// Van schijf en niet van Google. `next/font/google` haalt deze bestanden op
// tijdens de BUILD -- in productie gaat er niets naar Google, dat is nagemeten --
// maar daarmee hangt elke uitrol aan het bereikbaar zijn van een derde partij.
// Dat viel om toen de buildcontainer fonts.googleapis.com naar IPv6 oploste en
// daar niet bij kon: een uitrol die stilvalt om een reden die niets met de
// wijziging te maken heeft. Zie fonts/LEESMIJ.md.
//
// Eén bestand per familie: het zijn variabele fonts, dus het hele
// gewichtsbereik zit erin. De acht losse gewichten die Google serveert waren
// byte voor byte hetzelfde bestand.
const inter = localFont({
  src: "./fonts/inter-latin.woff2",
  weight: "400 700",
  display: "swap",
  variable: "--font-inter",
});
const manrope = localFont({
  src: "./fonts/manrope-latin.woff2",
  weight: "400 800",
  display: "swap",
  variable: "--font-manrope",
});

// Every page renders per request. The CSP nonce is minted in middleware, so a
// page prerendered at build time would ship a nonce that no live response
// carries — its scripts would be blocked and the page would come up blank. This
// app is a dashboard behind a session cookie; there was nothing to cache anyway.
export const dynamic = "force-dynamic";

export const metadata: Metadata = {
  title: "Bunk Hosting | VPS Beheer",
  description: "Beheer je virtuele servers via het Bunk Hosting dashboard.",
  icons: { icon: "/favicon.svg" },
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="nl" className="dark">
      <body className={`${inter.variable} ${manrope.variable} font-sans`}>
        <ObservabilityInit />
        {children}
        <Toaster />
      </body>
    </html>
  );
}
