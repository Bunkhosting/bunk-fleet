import Link from "next/link";
import { Button } from "@/components/ui/button";

export default function NotFound() {
  return (
    <div className="min-h-screen flex flex-col items-center justify-center gap-4">
      <h1 className="text-6xl font-bold text-primary-text">404</h1>
      <h2 className="text-2xl font-semibold">Pagina niet gevonden</h2>
      <p className="text-muted-foreground">
        De pagina die je zoekt bestaat niet.
      </p>
      <Button asChild className="mt-4">
        <Link href="/dashboard">Terug naar dashboard</Link>
      </Button>
    </div>
  );
}
