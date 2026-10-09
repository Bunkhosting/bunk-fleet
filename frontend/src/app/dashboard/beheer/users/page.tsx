"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { Loader2, Search, Plus, Trash2 } from "lucide-react";
import { Card, CardContent } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Badge } from "@/components/ui/badge";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { useToast } from "@/components/ui/use-toast";
import { AdminGuard } from "@/components/admin/admin-guard";
import { adminApi, parseApiError, type AdminUser } from "@/lib/api";
import { formatBalance } from "@/lib/utils";

const ROLES = ["user", "admin"] as const;
const ROL_LABEL: Record<(typeof ROLES)[number], string> = { user: "Klant", admin: "Beheerder" };

function UsersInner() {
  const { toast } = useToast();
  const [users, setUsers] = useState<AdminUser[]>([]);
  const [loading, setLoading] = useState(true);
  const [q, setQ] = useState("");
  const [busy, setBusy] = useState<string | null>(null);
  const [toonVerwijderd, setToonVerwijderd] = useState(false);

  const load = () =>
    adminApi
      .users()
      .then(setUsers)
      .catch(() => toast({ title: "Fout", description: "Kon gebruikers niet laden.", variant: "destructive" }))
      .finally(() => setLoading(false));

  useEffect(() => {
    load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  async function changeRole(u: AdminUser, role: "user" | "admin") {
    if (role === u.role) return;
    // Beheerder maken geeft toegang tot elk account, elke VPS en de knop die
    // tegoed bijboekt. Dat hoort geen misklik in een tabelrij te kunnen zijn,
    // dus hier wel een bevestiging -- de andere kant op niet.
    if (
      role === "admin" &&
      !window.confirm(
        `${u.email} beheerder maken?\n\nDeze persoon kan dan elk account en elke VPS zien en ` +
          "beheren, en tegoed bijboeken."
      )
    ) {
      return;
    }
    setBusy(u.id);
    try {
      await adminApi.setRole(u.id, role);
      setUsers((prev) => prev.map((x) => (x.id === u.id ? { ...x, role } : x)));
      toast({ title: "Rol gewijzigd", description: `${u.email} → ${ROL_LABEL[role]}` });
    } catch (e) {
      toast({ title: "Mislukt", description: parseApiError(e, "Kon rol niet wijzigen."), variant: "destructive" });
    } finally {
      setBusy(null);
    }
  }

  // Verwijderen doet twee verschillende dingen, en dat hoort vooraf te staan in
  // plaats van achteraf te blijken. Een account waar geld aan te pas is gekomen
  // wordt geanonimiseerd: de persoonsgegevens gaan eruit, de facturen en het
  // grootboek blijven staan omdat die administratie zeven jaar bewaard moet
  // blijven en de btw-aangifte erop rust.
  async function removeUser(u: AdminUser) {
    const bevestigd = window.confirm(
      `Account ${u.email} verwijderen?\n\n` +
        "Heeft deze gebruiker ooit betaald, dan blijven de facturen en het grootboek staan " +
        "en worden alleen de persoonsgegevens gewist. Zonder betaalgeschiedenis wordt het " +
        "account echt verwijderd.\n\nDraait er nog een VPS, dan lukt het niet: ruim die eerst op.",
    );
    if (!bevestigd) return;

    setBusy(u.id);
    try {
      const uitkomst = await adminApi.deleteUser(u.id);
      if (uitkomst === "deleted") {
        setUsers((prev) => prev.filter((x) => x.id !== u.id));
      } else {
        // Het account blijft bestaan met een vervangend adres; opnieuw laden
        // toont dat in plaats van de oude gegevens te laten staan.
        load();
      }
      toast({
        title: uitkomst === "deleted" ? "Account verwijderd" : "Account geanonimiseerd",
        description:
          uitkomst === "deleted"
            ? "Er was geen administratie om te bewaren."
            : "De persoonsgegevens zijn gewist; de facturen en het grootboek blijven staan.",
      });
    } catch (e) {
      toast({
        title: "Niet verwijderd",
        description: parseApiError(e, "Controleer of er nog een VPS van deze gebruiker draait."),
        variant: "destructive",
      });
    } finally {
      setBusy(null);
    }
  }

  async function addCredit(u: AdminUser) {
    const input = window.prompt(`Tegoed aanpassen voor ${u.email} (in euro, bijv. 10 of -5):`, "10");
    if (input === null) return;
    const euros = Number(input.replace(",", "."));
    if (!Number.isFinite(euros) || euros === 0) {
      toast({ title: "Ongeldig bedrag", variant: "destructive" });
      return;
    }
    setBusy(u.id);
    try {
      const res = await adminApi.addCredit(u.id, Math.round(euros * 100));
      setUsers((prev) => prev.map((x) => (x.id === u.id ? { ...x, balance_cents: res.data.balance_cents } : x)));
      toast({ title: "Tegoed aangepast", description: `${u.email}: ${formatBalance(res.data.balance_cents)}` });
    } catch (e) {
      toast({ title: "Mislukt", description: parseApiError(e, "Kon tegoed niet aanpassen."), variant: "destructive" });
    } finally {
      setBusy(null);
    }
  }

  // Een verwijderd account blijft bestaan als er een administratie aan hangt: de
  // persoonsgegevens gaan eruit, de facturen en het grootboek blijven staan. Het
  // hoort dus niet tussen de gewone gebruikers te staan -- wie op verwijderen
  // klikt en het ding daarna nog in de lijst ziet, concludeert terecht dat het
  // niet gelukt is.
  const filtered = users
    .filter((u) => toonVerwijderd || !u.anonymised_at)
    .filter(
      (u) =>
        u.email.toLowerCase().includes(q.toLowerCase()) ||
        u.name.toLowerCase().includes(q.toLowerCase()),
    );

  const aantalVerwijderd = users.filter((u) => u.anonymised_at).length;

  if (loading) {
    return (
      <div className="flex justify-center py-20">
        <Loader2 className="h-8 w-8 animate-spin text-primary" />
      </div>
    );
  }

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold tracking-tight">Gebruikers</h1>
        <p className="text-muted-foreground">
          {users.length - aantalVerwijderd} accounts — rol wijzigen en tegoed aanpassen.
        </p>
      </div>

      <div className="flex flex-wrap items-center gap-3">
        <div className="relative max-w-sm flex-1">
          <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
          <Input placeholder="Zoek op e-mail of naam" value={q} onChange={(e) => setQ(e.target.value)} className="pl-9" />
        </div>
        {aantalVerwijderd > 0 && (
          // Verwijderde accounts staan er nog omdat hun administratie bewaard
          // moet blijven. Ze staan standaard niet in de lijst, maar ze verbergen
          // zonder te zeggen dat ze er zijn zou een ander soort onwaarheid zijn.
          <Button variant="ghost" size="sm" onClick={() => setToonVerwijderd((v) => !v)}>
            {toonVerwijderd
              ? `Verberg ${aantalVerwijderd} verwijderd${aantalVerwijderd === 1 ? "" : "e"}`
              : `Toon ${aantalVerwijderd} verwijderd${aantalVerwijderd === 1 ? "" : "e"}`}
          </Button>
        )}
      </div>

      <Card>
        <CardContent className="p-0">
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead className="border-b text-left text-xs text-muted-foreground">
                <tr>
                  <th className="px-4 py-3">Gebruiker</th>
                  <th className="px-4 py-3">Rol</th>
                  <th className="px-4 py-3">VPS&apos;en</th>
                  <th className="px-4 py-3">Tegoed</th>
                  <th className="px-4 py-3">2FA</th>
                  <th className="px-4 py-3"></th>
                </tr>
              </thead>
              <tbody>
                {filtered.map((u) => (
                  <tr key={u.id} className="border-b last:border-0">
                    <td className="px-4 py-3">
                      {/* Doorklikken naar alles wat er over deze klant bekend is:
                          VPS'en, abonnementen, opwaarderingen en grootboek. */}
                      <Link
                        href={`/dashboard/beheer/users/${u.id}`}
                        className="block hover:underline"
                      >
                        <div className="font-medium">
                          {u.anonymised_at ? "Verwijderde gebruiker" : u.name || "—"}
                        </div>
                        <div className="text-xs text-muted-foreground">
                          {u.anonymised_at
                            ? `verwijderd op ${new Date(u.anonymised_at).toLocaleDateString("nl-NL")} — administratie bewaard`
                            : u.email}
                        </div>
                      </Link>
                    </td>
                    <td className="px-4 py-3">
                      <Select value={u.role} onValueChange={(v) => changeRole(u, v as "user" | "admin")}>
                        <SelectTrigger className="h-8 w-32" aria-label={`Rol van ${u.email}`}><SelectValue /></SelectTrigger>
                        <SelectContent>
                          {ROLES.map((r) => (
                            <SelectItem key={r} value={r}>{ROL_LABEL[r]}</SelectItem>
                          ))}
                        </SelectContent>
                      </Select>
                    </td>
                    <td className="px-4 py-3">{u.vps_count}</td>
                    <td className="px-4 py-3 font-medium">{formatBalance(u.balance_cents)}</td>
                    <td className="px-4 py-3">
                      {u.two_factor ? <Badge variant="default">aan</Badge> : <Badge variant="secondary">uit</Badge>}
                    </td>
                    <td className="px-4 py-3 text-right">
                      <div className="flex items-center justify-end gap-2">
                        <Button variant="outline" size="sm" disabled={busy === u.id} onClick={() => addCredit(u)}>
                          {busy === u.id ? <Loader2 className="h-4 w-4 animate-spin" /> : <Plus className="mr-1 h-4 w-4" />}
                          Tegoed
                        </Button>
                        <Button
                          variant="ghost"
                          size="sm"
                          className="h-8 w-8 p-0 text-destructive hover:text-destructive"
                          title="Account verwijderen" aria-label="Account verwijderen"
                          disabled={busy === u.id}
                          onClick={() => removeUser(u)}
                        >
                          <Trash2 className="h-4 w-4" />
                        </Button>
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </CardContent>
      </Card>
    </div>
  );
}

export default function AdminUsersPage() {
  return (
    <AdminGuard>
      <UsersInner />
    </AdminGuard>
  );
}
