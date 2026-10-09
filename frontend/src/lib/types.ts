export interface User {
  id: string;
  email: string;
  name: string;
  role: "user" | "admin";
  date_joined: string;
  is_active: boolean;
  vps_count?: number;
  totp_enabled: boolean;
  passkeys_enabled: boolean;
  /** Of deze gebruiker hardware beheert; bepaalt of het nodescherm in het menu staat. */
  owns_nodes: boolean;
  /** null until the user clicks the link in their confirmation email. */
  confirmed_at: string | null;
}

export type VpsStatus =
  | "PENDING"
  | "PROVISIONING"
  | "ACTIVE"
  | "STOPPED"
  | "RESTORING"
  | "DELETING"
  | "DELETED"
  | "ERROR";

export type OsChoice =
  | "ubuntu-22.04"
  | "ubuntu-20.04"
  | "debian-12"
  | "debian-11"
  | "centos-9"
  | "alpine-3.19";

export interface VpsPackage {
  id: number;
  name: string;
  cpu_cores: number;
  ram_gb: number;
  disk_gb: number;
  /** Bovengrens op de netwerkkaart van de gast, in megabit per seconde. */
  bandwidth_mbit: number;
  price_monthly: string;
  description: string;
}

export interface Vps {
  id: string;
  label: string;
  package: VpsPackage;
  os: OsChoice;
  status: VpsStatus;
  ip_address: string | null;
  hostname: string | null;
  /**
   * Where this VPS is reachable from the internet. Null when the node it runs
   * on has no public address yet — in which case the browser console is the
   * only way in, and the UI has to say that rather than print the private
   * address as if it were an endpoint.
   */
  public_host: string | null;
  ssh_port: number | null;
  ssh_username: string;
  /** De locatie waar de VPS draait, zoals een mens hem kent ("Eindhoven"). */
  location: string | null;
  vcenter_vm_id: string | null;
  created_at: string;
  updated_at: string;
  owner: string;
  owner_email: string | null;
}

export interface VpsCredentials {
  ip_address: string | null;
  ssh_port: number | null;
  ssh_username: string;
  sudo_password: string | null;
}

export interface BillingOverview {
  open_amount: string;
  open_invoice_count: number;
  monthly_cost: string;
  active_subscriptions: number;
  next_invoice_date: string | null;
}
