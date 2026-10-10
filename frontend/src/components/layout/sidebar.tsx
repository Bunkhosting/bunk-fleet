"use client";

import { useState } from "react";
import Link from "next/link";
import { useRouter, usePathname } from "next/navigation";
import {
  LayoutDashboard,
  Network,
  PlusCircle,
  Shield,
  Users,
  Server,
  ServerCog,
  LogOut,
  Menu,
  ShieldCheck,
  Wallet,
  Receipt,
  CreditCard,
  Activity,
  HardDrive,
  MapPin,
} from "lucide-react";
import { Button } from "@/components/ui/button";
import { Separator } from "@/components/ui/separator";
import {
  Sheet,
  SheetContent,
  SheetTrigger,
  SheetTitle,
} from "@/components/ui/sheet";
import { cn } from "@/lib/utils";
import { authApi, parseApiError } from "@/lib/api";
import { useToast } from "@/components/ui/use-toast";
import type { User } from "@/lib/types";

interface SidebarProps {
  user: User;
}

interface NavItem {
  label: string;
  href: string;
  icon: React.ElementType;
}

const mainNavItems: NavItem[] = [
  { label: "Dashboard", href: "/dashboard", icon: LayoutDashboard },
  { label: "Mijn VPS'en", href: "/dashboard/vps", icon: Server },
  { label: "Nieuwe VPS", href: "/dashboard/vps/new", icon: PlusCircle },
  { label: "Beveiliging", href: "/dashboard/beveiliging", icon: ShieldCheck },
];

// Alleen zichtbaar voor wie echt een node bezit (`owns_nodes` is een
// bestaanscheck op eigenaarschap, geen rol). Onderaan het menu, want dit is
// bijzaak: vrijwel iedereen die inlogt is klant en niet operator, en wie wel
// hardware beheert weet waar hij moet zijn.
const nodeNavItems: NavItem[] = [
  { label: "Mijn nodes", href: "/dashboard/nodes", icon: HardDrive },
];

const billingNavItems: NavItem[] = [
  { label: "Tegoed", href: "/dashboard/billing", icon: Wallet },
];

const adminNavItems: NavItem[] = [
  { label: "Beheer", href: "/dashboard/beheer", icon: Shield },
  { label: "Gebruikers", href: "/dashboard/beheer/users", icon: Users },
  { label: "VPS-beheer", href: "/dashboard/beheer/vps", icon: ServerCog },
  { label: "Nodes", href: "/dashboard/beheer/nodes", icon: Network },
  { label: "Locaties", href: "/dashboard/beheer/regios", icon: MapPin },
  { label: "Omzet & btw", href: "/dashboard/beheer/omzet", icon: Receipt },
  { label: "Abonnementen", href: "/dashboard/beheer/abonnementen", icon: CreditCard },
  { label: "Activiteit", href: "/dashboard/beheer/activiteit", icon: Activity },
];

const allNavItems = [...mainNavItems, ...nodeNavItems, ...billingNavItems, ...adminNavItems];

function isActive(itemHref: string, pathname: string): boolean {
  if (pathname === itemHref) return true;
  if (!pathname.startsWith(itemHref + "/")) return false;
  return !allNavItems.some(
    (other) =>
      other.href !== itemHref &&
      other.href.length > itemHref.length &&
      pathname.startsWith(other.href)
  );
}

function NavLink({ item, pathname, badge }: { item: NavItem; pathname: string; badge?: boolean }) {
  const active = isActive(item.href, pathname);

  return (
    <Link
      href={item.href}
      className={cn(
        "flex items-center gap-3 rounded-md px-3 py-2 text-sm font-medium transition-colors",
        active
          ? "bg-primary text-primary-foreground"
          : "text-muted-foreground hover:bg-accent hover:text-accent-foreground"
      )}
    >
      <item.icon className="h-4 w-4 shrink-0" />
      <span className="flex-1">{item.label}</span>
      {badge && (
        <span className="h-2 w-2 rounded-full bg-orange-500 shrink-0" />
      )}
    </Link>
  );
}

function SidebarContent({ user }: SidebarProps) {
  const router = useRouter();
  const pathname = usePathname();

  const { toast } = useToast();

  const handleLogout = async () => {
    try {
      await authApi.logout();
    } catch (err: unknown) {
      // Alleen een 401 betekent "al uitgelogd". Bij een storing staat het
      // sessiecookie er nog (het is HttpOnly, de browser kan het niet zelf
      // weggooien), en stuurde de middleware /login gewoon terug naar het
      // dashboard: wie op een gedeelde computer uitlogde, bleef ingelogd
      // zonder het te weten.
      const status = (err as { response?: { status?: number } })?.response?.status;
      if (status !== 401) {
        toast({
          title: "Uitloggen is niet gelukt",
          description: parseApiError(err, "Je bent nog ingelogd. Probeer het opnieuw."),
          variant: "destructive",
        });
        return;
      }
    }
    router.push("/login");
  };

  return (
    <div className="flex h-full flex-col">
      {/* Logo */}
      <div className="px-4 py-6">
        <Link href="/dashboard" className="flex items-center gap-3">
          <Server className="h-6 w-6 text-accent" />
          <span className="text-lg font-headline font-black tracking-tighter text-foreground uppercase">
            BUNK HOSTING
          </span>
        </Link>
      </div>

      <Separator />

      {/* Scrollable nav area */}
      <nav className="flex-1 overflow-y-auto space-y-1 px-3 py-4">
        <p className="mb-2 px-3 text-xs font-semibold uppercase tracking-wider text-muted-foreground">
          Menu
        </p>
        {mainNavItems.map((item) => (
          <NavLink
            key={item.href}
            item={item}
            pathname={pathname}
            badge={item.href === "/dashboard/beveiliging" && !user.totp_enabled}
          />
        ))}

        <Separator className="my-4" />
        <p className="mb-2 px-3 text-xs font-semibold uppercase tracking-wider text-muted-foreground">
          Betalingen
        </p>
        {billingNavItems.map((item) => (
          <NavLink key={item.href} item={item} pathname={pathname} />
        ))}

        {user.role === "admin" && (
          <>
            <Separator className="my-4" />
            <p className="mb-2 px-3 text-xs font-semibold uppercase tracking-wider text-muted-foreground">
              Beheer
            </p>
            {adminNavItems.map((item) => (
              <NavLink key={item.href} item={item} pathname={pathname} />
            ))}
          </>
        )}

        {user.owns_nodes && (
          <>
            <Separator className="my-4" />
            <p className="mb-2 px-3 text-xs font-semibold uppercase tracking-wider text-muted-foreground">
              Hardware
            </p>
            {nodeNavItems.map((item) => (
              <NavLink key={item.href} item={item} pathname={pathname} />
            ))}
          </>
        )}
      </nav>

      <Separator />

      {/* Bodem: gebruiker + uitloggen */}
      <div className="px-3 py-4 space-y-1">
        <div className="px-3 pt-2">
          <p className="text-sm font-medium">{user.name}</p>
          <p className="text-xs text-muted-foreground">{user.email}</p>
        </div>
        <Button
          variant="ghost"
          className="w-full justify-start gap-3 text-muted-foreground hover:text-foreground"
          onClick={handleLogout}
        >
          <LogOut className="h-4 w-4" />
          Uitloggen
        </Button>
      </div>
    </div>
  );
}

export function Sidebar({ user }: SidebarProps) {
  const [open, setOpen] = useState(false);

  return (
    <>
      {/* Desktop sidebar */}
      <aside className="hidden md:flex md:w-64 md:flex-col md:fixed md:inset-y-0 border-r bg-card z-20">
        <SidebarContent user={user} />
      </aside>

      {/* Mobile hamburger button */}
      <div className="sticky top-0 z-40 flex items-center gap-4 border-b bg-background px-4 py-3 md:hidden">
        <Sheet open={open} onOpenChange={setOpen}>
          <SheetTrigger asChild>
            <Button variant="ghost" size="icon">
              <Menu className="h-5 w-5" />
              <span className="sr-only">Menu openen</span>
            </Button>
          </SheetTrigger>
          <SheetContent side="left" className="w-64 p-0">
            <SheetTitle className="sr-only">Navigatie</SheetTitle>
            <div onClick={() => setOpen(false)}>
              <SidebarContent user={user} />
            </div>
          </SheetContent>
        </Sheet>
        <Link href="/dashboard" className="flex items-center gap-3">
          <Server className="h-6 w-6 text-accent" />
          <span className="text-lg font-headline font-black tracking-tighter text-foreground uppercase">
            BUNK HOSTING
          </span>
        </Link>
      </div>
    </>
  );
}
