defmodule ControlPlaneWeb.WorkerInstallController do
  @moduledoc """
  Serves the interactive bunk-worker install wizard (`curl … | bash`).

  The wizard runs on any Linux machine that can reach the node's Proxmox or ESXi
  API over the network. Running it on the Proxmox host itself is the better
  choice where that is possible: only there can the agent build the customer
  network (bridge, gateway, NAT) from the subnet the control plane assigns, so
  the operator does not have to get an IP plan right by hand. Elsewhere — a
  separate VM, or ESXi, which has no Linux host to configure — the operator
  declares the network they already run and owns it.
  """
  use ControlPlaneWeb, :controller

  # De updater staat als losse bestanden in priv/agent-update/ zodat hij te
  # lezen en te testen is zonder een shellscript uit een Elixir-string te moeten
  # pellen. Ze worden hier bij het compileren ingelezen; @external_resource zorgt
  # dat een wijziging eraan deze module opnieuw laat compileren.
  #
  # In priv/ en niet ergens boven de app: de gate en het productie-image bouwen
  # alleen control_plane/, dus een pad daarbuiten bestaat in de container niet.
  @update_dir Path.join([__DIR__, "..", "..", "..", "priv", "agent-update"])
  @update_script_path Path.expand(Path.join(@update_dir, "bunk-agent-update"))
  @update_service_path Path.expand(Path.join(@update_dir, "bunk-agent-update.service"))
  @update_timer_path Path.expand(Path.join(@update_dir, "bunk-agent-update.timer"))

  @external_resource @update_script_path
  @external_resource @update_service_path
  @external_resource @update_timer_path

  @update_script File.read!(@update_script_path)
  @update_service File.read!(@update_service_path)
  @update_timer File.read!(@update_timer_path)

  @doc """
  De updater als los script, voor een node die al draait.

  `curl -fsSL <cp>/agent-update.sh | sh` zet het script, de service en de timer
  neer en draait de controle meteen één keer. Nodes die met de huidige
  `install.sh` zijn opgezet hebben dit al.
  """
  def update_bootstrap(conn, _params) do
    conn
    |> put_resp_content_type("text/x-shellscript")
    |> send_resp(200, bootstrap())
  end

  defp bootstrap do
    """
    #!/bin/sh
    set -eu
    [ "$(id -u)" = "0" ] || { echo "Dit moet als root."; exit 1; }

    cat > /usr/local/bin/bunk-agent-update <<'UPD'
    #{@update_script}
    UPD
    chmod +x /usr/local/bin/bunk-agent-update

    cat > /etc/systemd/system/bunk-agent-update.service <<'UPDSVC'
    #{@update_service}
    UPDSVC

    cat > /etc/systemd/system/bunk-agent-update.timer <<'UPDTMR'
    #{@update_timer}
    UPDTMR

    systemctl daemon-reload
    systemctl enable --now bunk-agent-update.timer
    echo "Automatische updates staan aan. Nu eenmalig controleren..."
    /usr/local/bin/bunk-agent-update || true
    """
  end

  def script(conn, _params) do
    cp = Application.get_env(:control_plane, :public_url) || request_base(conn)

    conn
    |> put_resp_content_type("text/x-shellscript")
    |> send_resp(200, render_script(cp))
  end

  defp request_base(%{scheme: scheme, host: host, port: port}) do
    p = if port in [80, 443], do: "", else: ":#{port}"
    "#{scheme}://#{host}#{p}"
  end

  @doc """
  Bouwt het installatiescript op voor een control plane op `cp`.

  Publiek omdat het script buiten een request gecontroleerd moet kunnen worden:
  het is shell die uit een Elixir-string wordt samengesteld, dus de compiler
  zegt er niets over en een typefout komt anders pas boven water op de machine
  van een operator, halverwege een installatie als root. CI rendert het hiermee
  en haalt het door `bash -n`.
  """
  @spec render_script(String.t()) :: String.t()
  def render_script(cp) do
    template_id = Application.get_env(:control_plane, :default_template_id, 9000)

    """
    #!/usr/bin/env bash
    # bunk-worker installer. Run on a Linux machine that can reach your Proxmox
    # OR ESXi API over the network. On Proxmox, running it on the host itself
    # lets the agent set up the customer network for you; anywhere else you
    # declare the network you already run.
    set -euo pipefail
    CP="#{cp}"
    TOKEN=""
    HYP=""
    OWNER=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --token) TOKEN="$2"; shift 2;;
        --token=*) TOKEN="${1#*=}"; shift;;
        --owner) OWNER="$2"; shift 2;;
        --owner=*) OWNER="${1#*=}"; shift;;
        --hypervisor) HYP="$2"; shift 2;;
        --hypervisor=*) HYP="${1#*=}"; shift;;
        *) shift;;
      esac
    done

    bold() { printf "\\033[1m%s\\033[0m\\n" "$1"; }

    # Zero-touch ESXi template: if the chosen template VM doesn't exist yet, pull
    # VMware's own CLI (govc) and import Ubuntu's cloud OVA (cloud-init +
    # open-vm-tools ready) as a template. Best-effort — a failure is reported but
    # doesn't abort the agent install.
    ensure_esxi_template() {
      export GOVC_URL="$ESXI_URL" GOVC_USERNAME="$ESXI_USER" GOVC_PASSWORD="$ESXI_PASS"
      [ "$ESXI_INSECURE" = "true" ] && export GOVC_INSECURE=1
      [ -n "$ESXI_DC" ] && export GOVC_DATACENTER="$ESXI_DC"
      if ! command -v govc >/dev/null 2>&1; then
        echo "-> govc (VMware CLI) ophalen..."
        install -d -m 755 /usr/local/bin
        gtmp="$(mktemp)"
        curl -fsSL https://github.com/vmware/govmomi/releases/latest/download/govc_Linux_x86_64.tar.gz -o "$gtmp" || { echo "!! govc-download mislukt (schijf vol of geen netwerk? check: df -h /)"; rm -f "$gtmp"; return 1; }
        tar -xzf "$gtmp" -C /usr/local/bin govc || { echo "!! govc uitpakken mislukt"; rm -f "$gtmp"; return 1; }
        rm -f "$gtmp"
        chmod +x /usr/local/bin/govc
      fi
      if govc vm.info "$ESXI_TMPL" >/dev/null 2>&1; then
        echo "-> Template '$ESXI_TMPL' bestaat al — geen actie nodig."
        return 0
      fi
      echo "-> Template '$ESXI_TMPL' ontbreekt; Ubuntu cloud-OVA importeren (kan enkele minuten duren)..."
      ova="https://cloud-images.ubuntu.com/releases/22.04/release/ubuntu-22.04-server-cloudimg-amd64.ova"
      args="-name=$ESXI_TMPL"
      [ -n "$ESXI_DC" ] && args="$args -dc=$ESXI_DC"
      [ -n "$ESXI_DS" ] && args="$args -ds=$ESXI_DS"
      [ -n "$ESXI_RP" ] && args="$args -pool=$ESXI_RP"
      [ -n "$ESXI_FOLDER" ] && args="$args -folder=$ESXI_FOLDER"
      if govc import.ova $args "$ova" && govc vm.markastemplate "$ESXI_TMPL"; then
        echo "-> Template '$ESXI_TMPL' aangemaakt en klaar voor gebruik."
      else
        echo "!! Kon de template niet automatisch aanmaken (check datastore/resource-pool/netwerk/rechten)."
        echo "   De agent draait wel, maar kan pas VPS'en aanmaken zodra er een cloud-init template bestaat."
          return 1
      fi
    }

    # Zero-touch Proxmox template. Een node zonder template schrijft zich vrolijk
    # in en gaat op groen, waarna elke bestelling faalt op "clone template" --
    # de meest gemelde storing bij een nieuwe node. Bestaat het VMID nog niet,
    # dan halen we Ubuntu's officiele cloud-image op en maken er een template van.
    #
    # Alleen op de Proxmox-host zelf: importeren gaat via qm, dat lokale toegang
    # tot de opslag nodig heeft. Over de API alleen kan dit niet. Best-effort,
    # net als de ESXi-kant: mislukt het, dan een melding en de agent gaat door.
    ensure_proxmox_template() {
      if ! command -v qm >/dev/null 2>&1; then
        echo "!! qm niet gevonden -- dit is de Proxmox-host zelf niet."
        echo "   Maak de template met de hand aan op de host, met VMID $PX_TMPL_ID."
        return 1
      fi
      if qm config "$PX_TMPL_ID" >/dev/null 2>&1; then
        echo "-> Template $PX_TMPL_ID bestaat al -- geen actie nodig."
        return 0
      fi
      # Opslag eerst controleren, voordat er honderden MB's binnengehaald worden
      # die daarna toch nergens heen kunnen.
      if ! pvesm status --storage "$PX_TMPL_STORE" >/dev/null 2>&1; then
        echo "!! Opslag '$PX_TMPL_STORE' bestaat niet op deze node. Beschikbaar:"
        pvesm status 2>/dev/null | awk 'NR > 1 { print "   - " $1 }'
        return 1
      fi
      echo "-> Template $PX_TMPL_ID ontbreekt; Ubuntu cloud-image ophalen (kan enkele minuten duren)..."
      base="https://cloud-images.ubuntu.com/releases/22.04/release"
      imgname="ubuntu-22.04-server-cloudimg-amd64.img"
      itmp="$(mktemp)" || { echo "!! Kon geen tijdelijk bestand maken (schijf vol? check: df -h /)"; return 1; }
      # Ubuntu publiceert SHA256SUMS naast het image; dezelfde controle als op de
      # binary hieronder, en de enige manier om een afgekapte download te zien
      # voordat er een kapotte template uit rolt.
      expected="$(curl -fsSL "$base/SHA256SUMS" 2>/dev/null | awk -v f="$imgname" '$2 == f || $2 == "*" f { print $1 }')" || expected=""
      if ! curl -fsSL "$base/$imgname" -o "$itmp"; then
        echo "!! Download van het cloud-image mislukt (geen netwerk of schijf vol? check: df -h /)"
        rm -f "$itmp"; return 1
      fi
      if [ -n "$expected" ]; then
        actual="$(sha256sum "$itmp" | awk '{ print $1 }')"
        if [ "$expected" != "$actual" ]; then
          echo "!! Checksum-mismatch op het cloud-image (verwacht $expected, kreeg $actual)."
          echo "!! Er wordt GEEN template aangemaakt."
          rm -f "$itmp"; return 1
        fi
        echo "   checksum OK ($actual)"
      else
        echo "   (geen SHA256SUMS op te halen -- integriteitscontrole overgeslagen)"
      fi
      # De VPS'en krijgen hun eigen net0 van de agent; de bridge hier is alleen
      # wat de template zelf draagt voor het geval de agent er geen meestuurt.
      tbridge="${VPS_BRIDGE:-vmbr0}"
      # --agent enabled=1 is niet optioneel: de agent leest het IP van een VPS via
      # de qemu-guest-agent, en Ubuntu's cloud-image heeft die aan boord. Staat de
      # schakelaar uit, dan draait de VPS wel maar blijft het IP-veld leeg.
      # scsihw en de rest zijn gelijkgetrokken met de template die in deze vloot
      # al draait, zodat node twee niet subtiel anders is dan node een.
      if qm create "$PX_TMPL_ID" --name bunk-ubuntu-2204 --ostype l26 --memory 2048 --cores 2 --agent enabled=1 --scsihw virtio-scsi-pci --net0 "virtio,bridge=$tbridge" >/dev/null &&
         qm importdisk "$PX_TMPL_ID" "$itmp" "$PX_TMPL_STORE" >/dev/null; then
        rm -f "$itmp"
      else
        echo "!! Aanmaken of importeren mislukt (rechten, of opslag '$PX_TMPL_STORE' vol?)."
        rm -f "$itmp"
        qm destroy "$PX_TMPL_ID" --purge >/dev/null 2>&1 || true
        return 1
      fi
      # Het volume-id uit de config lezen in plaats van het te construeren: op
      # LVM/ZFS heet het vm-ID-disk-0, op een directory-opslag ID/vm-ID-disk-0.raw.
      imported="$(qm config "$PX_TMPL_ID" | awk -F ': ' '/^unused[0-9]+:/ { print $2; exit }')"
      if [ -z "$imported" ]; then
        echo "!! De geimporteerde schijf is niet terug te vinden in de VM-config."
        qm destroy "$PX_TMPL_ID" --purge >/dev/null 2>&1 || true
        return 1
      fi
      # scsi0 en een cloud-init-drive zijn geen smaak: de agent vergroot scsi0 bij
      # het uitrollen en zet ipconfig0/ciuser/sshkeys, wat zonder cloud-init-drive
      # nergens landt.
      if qm set "$PX_TMPL_ID" --scsi0 "$imported" >/dev/null &&
         qm set "$PX_TMPL_ID" --ide2 "$PX_TMPL_STORE:cloudinit" >/dev/null &&
         qm set "$PX_TMPL_ID" --boot order=scsi0 --serial0 socket --vga serial0 >/dev/null &&
         qm template "$PX_TMPL_ID" >/dev/null; then
        echo "-> Template $PX_TMPL_ID aangemaakt en klaar voor gebruik."
      else
        echo "!! Kon de template niet afmaken (check rechten en de opslag '$PX_TMPL_STORE')."
        echo "   De agent draait wel, maar kan pas VPS'en aanmaken zodra er een template bestaat."
        # Opruimen, anders staat er een halve VM met dit VMID en slaat een
        # volgende installatie de template-stap over omdat hij "al bestaat".
        qm destroy "$PX_TMPL_ID" --purge >/dev/null 2>&1 || true
        return 1
      fi
    }

    bold "== Bunk Worker installatie =="
    echo "Control plane: $CP"
    echo "Deze worker draait op DEZE Linux-machine en praat met je Proxmox- of"
    echo "ESXi-API over het netwerk. Draai je hem op de Proxmox-host zelf, dan"
    echo "kan Bunk ook het klantnetwerk voor je opzetten."
    echo

    [ -z "$TOKEN" ] && read -r -p "Enroll-token (uit de portal): " TOKEN </dev/tty
    [ -z "$TOKEN" ] && { echo "Een enroll-token is verplicht."; exit 1; }

    # Wie deze node gaat beheren. Alleen dat account mag de instellingen ervan
    # wijzigen in het dashboard, dus dit is geen administratief veld maar de
    # sleutel tot het beheer van deze machine.
    echo
    echo "Beheerder van deze node:"
    echo "  Alleen dit account kan straks de instellingen van deze node wijzigen"
    echo "  in het dashboard. Gebruik het e-mailadres waarmee je op Bunk inlogt."
    [ -z "$OWNER" ] && read -r -p "  E-mailadres: " OWNER </dev/tty
    case "$OWNER" in
      "") echo "  (leeg gelaten -- de node komt op naam van wie het token maakte)";;
      *@*) : ;;
      *) echo "  !! '$OWNER' ziet er niet uit als een e-mailadres; het wordt wel doorgegeven."
         echo "     Klopt het niet, dan wijst een beheerder de node later toe.";;
    esac

    [ -z "$HYP" ] && read -r -p "Hypervisor (proxmox/esxi) [proxmox]: " HYP </dev/tty
    HYP="${HYP:-proxmox}"
    # Normalise so "ESXi", " esxi ", "vSphere", "PVE" etc. all match.
    HYP="$(printf '%s' "$HYP" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    case "$HYP" in pve) HYP=proxmox;; vmware|vsphere|vcenter) HYP=esxi;; esac
    PXHOST=""; PXNODE=""; PXTID=""; PXSEC=""; VSSL=false; PXFP=""
    ESXI_URL=""; ESXI_USER=""; ESXI_PASS=""; ESXI_INSECURE=false; ESXI_DC=""; ESXI_DS=""; ESXI_RP=""; ESXI_FOLDER=""; ESXI_TMPL=""
    if [ "$HYP" = "proxmox" ]; then
      read -r -p "Proxmox API host (https://IP:8006): " PXHOST </dev/tty
      # Repareer wat een mens intypt. De ESXi-tak hieronder deed dit al; hier
      # ontbrak het, en de twee vormen die daardoor doorkwamen waren niet te
      # herkennen aan de fout die eruit kwam. "https:10.0.0.5:8006" -- de twee
      # schuine strepen vergeten -- geeft bij elke aanroep "http: no Host in
      # request URL", en dat stond dan in het dashboard als de reden waarom de
      # node zijn hypervisor niet kon bevragen.
      case "$PXHOST" in
        https://*|http://*) : ;;
        https:*) PXHOST="https://${PXHOST#https:}" ;;
        http:*)  PXHOST="http://${PXHOST#http:}" ;;
        *)       PXHOST="https://$PXHOST" ;;
      esac
      PXHOST="${PXHOST%/}"
      # Geen poort erbij? De API luistert op 8006.
      case "${PXHOST#*://}" in *:*) : ;; *) PXHOST="$PXHOST:8006" ;; esac
      echo "   -> gebruik API: $PXHOST"
      read -r -p "Proxmox node-naam (bv. pve): " PXNODE </dev/tty
      read -r -p "Proxmox API token-id (user@realm!tokenid): " PXTID </dev/tty
      read -r -s -p "Proxmox API token-secret: " PXSEC </dev/tty; echo

      # TLS. Een API-token voor Proxmox is root-equivalent: wie het verkeer
      # ernaartoe kan onderscheppen heeft elke VM op die node. Verificatie moet
      # dus aan staan.
      #
      # Alleen: een verse Proxmox draait op een zelfondertekend certificaat. De
      # ketencontrole kan daar per definitie niet op slagen ("certificate signed
      # by unknown authority"), en het enige antwoord dat overbleef was
      # verificatie helemaal uitzetten. Daarom pinnen we in plaats daarvan de
      # vingerafdruk: dat heeft geen CA nodig en merkt nog steeds wanneer er
      # iemand anders op dat adres antwoordt.
      #
      # De vingerafdruk komt van de verbinding zelf. Draait dit op de
      # Proxmox-machine, dan ligt het echte certificaat ernaast en vergelijken
      # we ermee -- klopt het, dan hoeft er niets gevraagd te worden.
      PXFP=""
      PXHP="${PXHOST#*://}"; PXHP="${PXHP%%/*}"
      if command -v openssl >/dev/null 2>&1; then
        PXFP=$(echo | openssl s_client -connect "$PXHP" -servername "${PXHP%%:*}" 2>/dev/null \
          | openssl x509 -noout -fingerprint -sha256 2>/dev/null \
          | sed -e 's/.*=//' -e 's/://g' | tr 'A-Z' 'a-z')
      fi
      if [ -n "$PXFP" ]; then
        PXLOCAL=""
        if [ -r /etc/pve/local/pve-ssl.pem ]; then
          PXLOCAL=$(openssl x509 -in /etc/pve/local/pve-ssl.pem -noout -fingerprint -sha256 2>/dev/null \
            | sed -e 's/.*=//' -e 's/://g' | tr 'A-Z' 'a-z')
        fi
        if [ -n "$PXLOCAL" ] && [ "$PXLOCAL" = "$PXFP" ]; then
          echo "   -> certificaat komt overeen met dat van deze Proxmox; vastgezet."
        else
          echo
          echo "  Certificaat van $PXHP:"
          echo "    SHA-256: $PXFP"
          echo "  Vergelijk dit met wat Proxmox zelf toont onder Node -> Certificates,"
          echo "  of met: openssl x509 -in /etc/pve/local/pve-ssl.pem -noout -fingerprint -sha256"
          read -r -p "  Hoort deze vingerafdruk bij jouw node? (J/n): " FPOK </dev/tty
          case "$FPOK" in n|N) PXFP="" ;; esac
        fi
      fi
      if [ -n "$PXFP" ]; then
        VSSL=true
      else
        echo
        echo "  Geen vingerafdruk om vast te zetten."
        echo "  Verifieer het TLS-certificaat van de Proxmox-API? Zeg alleen NEE bij een"
        echo "  zelfondertekend certificaat op een netwerk dat je vertrouwt: zonder"
        echo "  verificatie kan iemand tussen deze machine en Proxmox het API-token"
        echo "  meelezen, en dat token is root op die node."
        read -r -p "  Verifiëren? (J/n): " VS </dev/tty
        case "$VS" in n|N) VSSL=false;; *) VSSL=true;; esac
      fi
    elif [ "$HYP" = "esxi" ]; then
      read -r -p "vSphere/ESXi adres (bv. 192.168.1.50 of vcenter.school.nl): " ESXI_URL </dev/tty
      # Accept a bare IP/hostname: add the scheme + /sdk path govmomi expects,
      # so "192.168.1.50" becomes "https://192.168.1.50/sdk" (fixes the common
      # "unsupported protocol scheme" error from leaving those off).
      case "$ESXI_URL" in http://*|https://*) : ;; *) ESXI_URL="https://$ESXI_URL" ;; esac
      case "$ESXI_URL" in */sdk|*/sdk/) : ;; *) ESXI_URL="${ESXI_URL%/}/sdk" ;; esac
      echo "   -> gebruik URL: $ESXI_URL"
      read -r -p "Gebruiker (bv. administrator@vsphere.local): " ESXI_USER </dev/tty
      read -r -s -p "Wachtwoord: " ESXI_PASS </dev/tty; echo
      # Zie de opmerking bij Proxmox hierboven: standaard aan, bewust uitzetten.
      echo
      echo "  TLS-certificaat van vSphere/ESXi verifiëren?"
      echo "  Zeg alleen NEE bij een zelfondertekend certificaat op een vertrouwd netwerk:"
      echo "  zonder verificatie kan iemand ertussen je beheerderswachtwoord meelezen."
      read -r -p "  Verifiëren? (J/n): " VS </dev/tty
      case "$VS" in n|N) ESXI_INSECURE=true;; *) ESXI_INSECURE=false;; esac
      # Datacenter/folder matter on vCenter (multiple of each); on a standalone
      # ESXi host leave them empty and the default is used.
      read -r -p "Datacenter (vCenter; leeg = standaard/losse ESXi-host): " ESXI_DC </dev/tty
      read -r -p "Datastore (leeg = standaard): " ESXI_DS </dev/tty
      read -r -p "Resource pool of cluster (leeg = standaard): " ESXI_RP </dev/tty
      read -r -p "VM-folder (leeg = standaard): " ESXI_FOLDER </dev/tty
      read -r -p "Template-VM naam (leeg = automatisch aanmaken): " ESXI_TMPL </dev/tty
      ESXI_TMPL="${ESXI_TMPL:-bunk-ubuntu-2204}"
    else
      echo "Onbekende hypervisor: $HYP"; exit 1
    fi
    echo
    echo "Hoeveel van deze machine gaat naar de VPS-pool? (leeg = alles)"
    read -r -p "  vCPU-cores: " OFFER_VCPU </dev/tty
    read -r -p "  RAM in MB:  " OFFER_RAM </dev/tty
    read -r -p "  Disk in GB: " OFFER_DISK </dev/tty

    echo
    echo "Netwerk voor de VPS'en op deze node:"
    # Two ways to run this. On the Proxmox host itself the agent can build the
    # customer network (bridge + gateway + NAT) from the subnet the control plane
    # assigns, and the operator is asked nothing beyond a bridge name. Anywhere
    # else -- the agent on a separate VM, or ESXi, where there is no Linux host to
    # configure -- the operator owns the network and declares it here.
    #
    # Bridge/VLAN are Proxmox-only concepts (the Proxmox provider forces the NIC
    # bridge + 802.1q tag). On ESXi a VM's network is a *port group* and the
    # clone inherits it from the template, so we neither ask nor pass it there.
    VPS_BRIDGE=""
    VPS_VLAN=0
    VPS_GW=""; VPS_CIDR=""; VPS_RSTART=""; VPS_REND=""
    MANAGE_NET=false

    ON_PVE_HOST=false
    [ "$HYP" = "proxmox" ] && [ -d /etc/pve ] && [ -x /usr/sbin/qm ] && ON_PVE_HOST=true

    if [ "$ON_PVE_HOST" = "true" ]; then
      echo "  Deze machine is de Proxmox-host zelf."
      echo "  Bunk kan het klantnetwerk dan zelf opzetten: een eigen subnet per node,"
      echo "  een gateway op een bestaande bridge, en uitgaand verkeer via jouw uplink."
      echo "  Zeg NEE als er al een router (bv. een OPNsense/OpenWrt-VM) de gateway"
      echo "  van dat netwerk beheert -- twee machines op hetzelfde adres breekt het."
      read -r -p "  Netwerk door Bunk laten beheren? (j/N): " MN </dev/tty
      case "$MN" in j|J|y|Y) MANAGE_NET=true;; *) MANAGE_NET=false;; esac
    fi

    if [ "$MANAGE_NET" = "true" ]; then
      echo "  De bridge moet al bestaan (Proxmox > Node > Network > Create > Linux Bridge)."
      read -r -p "  Bridge voor VPS-verkeer [vmbr2]: " VPS_BRIDGE </dev/tty
      VPS_BRIDGE="${VPS_BRIDGE:-vmbr2}"
      if ! ip link show "$VPS_BRIDGE" >/dev/null 2>&1; then
        echo "  !! $VPS_BRIDGE bestaat nog niet op deze machine. Maak hem eerst aan;"
        echo "     de agent draait wel, maar zet het netwerk pas op als de bridge er is."
      fi
      read -r -p "  VLAN-tag (0 = geen VLAN): " VPS_VLAN </dev/tty; VPS_VLAN="${VPS_VLAN:-0}"
      echo "  -> Het subnet wordt toegewezen door de control plane; je hoeft zelf"
      echo "     geen gateway of IP-range op te geven."
    else
      if [ "$HYP" = "proxmox" ]; then
        read -r -p "  Bridge (bv. vmbr0; leeg = van de template overnemen): " VPS_BRIDGE </dev/tty
        read -r -p "  VLAN-tag (0 = geen VLAN): " VPS_VLAN </dev/tty; VPS_VLAN="${VPS_VLAN:-0}"
      else
        echo "  VPS'en gebruiken de port group / netwerk-adapter van de template."
      fi
      echo "  Je beheert het netwerk zelf. Geef op welk subnet de VPS'en krijgen --"
      echo "  de gateway hieronder moet echt bestaan en verkeer doorlaten."
      read -r -p "  Gateway voor VPS'en (bv. 192.168.1.1): " VPS_GW </dev/tty
      read -r -p "  Subnet-prefix (bv. 24): " VPS_CIDR </dev/tty
      read -r -p "  Eerste bruikbare IP (bv. 192.168.1.100): " VPS_RSTART </dev/tty
      read -r -p "  Laatste bruikbare IP (bv. 192.168.1.150): " VPS_REND </dev/tty
    fi

    # SDN.Use op de bridge. Sinds Proxmox 8.1 valt een gewone Linux-bridge onder
    # de SDN-rechten: een token met alle VM-rechten van de wereld mag nog steeds
    # geen kaart aan vmbr2 hangen zonder SDN.Use op /sdn/zones/localnetwork.
    #
    # Dat merk je niet bij het inschrijven en ook niet aan de capaciteit -- de
    # node staat groen en meldt ruimte. Het komt pas naar boven bij de eerste
    # bestelling, als "clone template 9000: status 403: Permission check failed
    # (/sdn/zones/localnetwork/vmbr2, SDN.Use)", en dan is er al een klant die
    # wacht. Daarom hier, waar we root op de machine zijn en het token kennen.
    if [ "$ON_PVE_HOST" = "true" ] && [ -n "$VPS_BRIDGE" ] && [ -n "$PXTID" ] && command -v pveum >/dev/null 2>&1; then
      echo
      echo "  Proxmox 8.1+ eist SDN.Use op de bridge voordat een token er een VM aan"
      echo "  mag hangen. Zonder dat recht schrijft deze node zich netjes in, meldt"
      echo "  capaciteit, en weigert pas de eerste bestelling met een 403."
      read -r -p "  Dat recht nu toekennen aan $PXTID? (J/n): " SDNOK </dev/tty
      case "$SDNOK" in
        n|N)
          echo "  -> Overgeslagen. Draai dit zelf voordat je bestellingen verwacht:"
          echo "     pveum acl modify /sdn/zones/localnetwork --roles PVESDNUser --tokens '$PXTID'"
          ;;
        *)
          # PVESDNUser levert Proxmox zelf mee (SDN.Audit + SDN.Use). Een eigen
          # rol aanmaken deed hetzelfde, maar dan als tweede ding dat op elke
          # node apart bestaat en bij een upgrade uit de pas kan lopen.
          if pveum acl modify /sdn/zones/localnetwork --roles PVESDNUser --tokens "$PXTID" >/dev/null 2>&1; then
            echo "  -> SDN.Use toegekend op /sdn/zones/localnetwork."
          else
            echo "  !! Toekennen lukte niet. Draai dit zelf:"
            echo "     pveum acl modify /sdn/zones/localnetwork --roles PVESDNUser --tokens '$PXTID'"
          fi
          ;;
      esac
    fi

    # Het VMID komt uit de control plane: dat is het template dat bij een
    # bestelling wordt meegestuurd wanneer een pakket er zelf geen noemt. Een
    # ander nummer hier zou een node opleveren die groen staat en niets kan.
    PX_TMPL_ID="#{template_id}"
    PX_TMPL_STORE=""
    VMID_MIN=""
    VMID_MAX=""
    if [ "$HYP" = "proxmox" ]; then
      echo
      echo "Nummers voor de VPS'en op deze node:"
      echo "  Proxmox geeft standaard het laagste vrije nummer vanaf 100, dus klant-VPS'en"
      echo "  komen tussen je eigen machines te staan. Geef een blok dat van Bunk is."
      read -r -p "  Laagste VMID [2000]: " VMID_MIN </dev/tty
      VMID_MIN="${VMID_MIN:-2000}"
      read -r -p "  Hoogste VMID [2999]: " VMID_MAX </dev/tty
      VMID_MAX="${VMID_MAX:-2999}"
      # Een bereik dat het template-nummer bevat zou de agent zijn eigen bron
      # laten overschrijven zodra hij daar aankomt.
      if [ "$PX_TMPL_ID" -ge "$VMID_MIN" ] 2>/dev/null && [ "$PX_TMPL_ID" -le "$VMID_MAX" ] 2>/dev/null; then
        echo "  !! $PX_TMPL_ID is de template en valt binnen $VMID_MIN-$VMID_MAX."
        echo "     Kies een bereik dat hem niet bevat, anders overschrijft de agent zijn eigen template."
        read -r -p "  Laagste VMID: " VMID_MIN </dev/tty
        read -r -p "  Hoogste VMID: " VMID_MAX </dev/tty
      fi
    fi

    if [ "$ON_PVE_HOST" = "true" ]; then
      echo
      echo "Template voor nieuwe VPS'en:"
      if qm config "$PX_TMPL_ID" >/dev/null 2>&1; then
        echo "  Template $PX_TMPL_ID staat er al."
      else
        echo "  Er is nog geen template met VMID $PX_TMPL_ID op deze node. Zonder"
        echo "  template schrijft de node zich wel in, maar mislukt elke bestelling."
        read -r -p "  Nu aanmaken uit Ubuntu's cloud-image? (J/n): " MT </dev/tty
        case "$MT" in
          n|N)
            echo "  Overgeslagen. Maak hem later met de hand aan, met VMID $PX_TMPL_ID."
            ;;
          *)
            read -r -p "  Opslag voor de template [local-lvm]: " PX_TMPL_STORE </dev/tty
            PX_TMPL_STORE="${PX_TMPL_STORE:-local-lvm}"
            ;;
        esac
      fi
    fi

    echo
    if [ "$HYP" = "esxi" ]; then
      ensure_esxi_template || echo "(template-stap overgeslagen -- zie melding hierboven)"
    elif [ -n "$PX_TMPL_STORE" ]; then
      ensure_proxmox_template || echo "(template-stap overgeslagen -- zie melding hierboven)"
    fi

    echo
    echo "-> bunk-worker binary downloaden..."
    install -d -m 755 /usr/local/bin
    btmp="$(mktemp)"
    curl -fsSL "$CP/dist/bunk-worker" -o "$btmp" || { echo "!! Kon de bunk-worker binary niet wegschrijven — schijf vol? Check met: df -h /"; rm -f "$btmp"; exit 1; }
    # Integriteitscheck: vergelijk met de checksum die naast de binary is
    # gepubliceerd. Vangt afgekapte/corrupte downloads (bv. een verbroken
    # verbinding of proxy-truncatie) vóórdat er iets als root wordt geïnstalleerd.
    expected="$(curl -fsSL "$CP/dist/bunk-worker.sha256" 2>/dev/null | awk '{print $1}')" || expected=""
    if [ -n "$expected" ]; then
      actual="$(sha256sum "$btmp" | awk '{print $1}')"
      if [ "$expected" != "$actual" ]; then
        echo "!! Checksum-mismatch op de gedownloade binary (verwacht $expected, kreeg $actual)."
        echo "!! Download opnieuw of neem contact op — er wordt NIETS geinstalleerd."
        rm -f "$btmp"; exit 1
      fi
      echo "   checksum OK ($actual)"
    else
      echo "   (geen checksum gepubliceerd op $CP/dist/bunk-worker.sha256 — stap overgeslagen)"
    fi
    install -m 755 "$btmp" /usr/local/bin/bunk-worker
    rm -f "$btmp"
    install -d -m 700 /var/lib/bunk-worker

    echo "-> instellingen wegschrijven..."
    # De instellingen staan in een apart bestand met mode 600, niet als
    # Environment=-regels in de unit. Twee redenen, en de tweede is de echte:
    #
    #   1. De unit zelf staat standaard wereldleesbaar in /etc/systemd/system.
    #   2. `systemctl show bunk-worker` toont Environment=-waarden aan ELKE
    #      lokale gebruiker, ook zonder root. Een chmod op de unit helpt daar
    #      niets tegen; de inhoud van een EnvironmentFile komt er niet in.
    #
    # Hierin staan het Proxmox API-token (root-equivalent op die node), het
    # vSphere-wachtwoord en het enroll-token.
    install -d -m 700 /etc/bunk-worker
    umask 077
    cat > /etc/bunk-worker/agent.env <<ENVF
    BUNK_CONTROL_PLANE_URL=$CP
    BUNK_ENROLL_TOKEN=$TOKEN
    BUNK_OWNER_EMAIL=$OWNER
    BUNK_HYPERVISOR=$HYP
    BUNK_PROXMOX_HOST=$PXHOST
    BUNK_PROXMOX_NODE=$PXNODE
    BUNK_PROXMOX_TOKEN_ID=$PXTID
    BUNK_PROXMOX_TOKEN_SECRET=$PXSEC
    BUNK_PROXMOX_VERIFY_SSL=$VSSL
    BUNK_PROXMOX_TLS_FINGERPRINT=${PXFP}
    BUNK_VMID_MIN=${VMID_MIN:-0}
    BUNK_VMID_MAX=${VMID_MAX:-0}
    BUNK_ESXI_URL=${ESXI_URL}
    BUNK_ESXI_USER=${ESXI_USER}
    BUNK_ESXI_PASSWORD=${ESXI_PASS}
    BUNK_ESXI_INSECURE=${ESXI_INSECURE:-false}
    BUNK_ESXI_DATACENTER=${ESXI_DC}
    BUNK_ESXI_DATASTORE=${ESXI_DS}
    BUNK_ESXI_RESOURCE_POOL=${ESXI_RP}
    BUNK_ESXI_FOLDER=${ESXI_FOLDER}
    BUNK_ESXI_TEMPLATE=${ESXI_TMPL}
    BUNK_OFFER_VCPU=${OFFER_VCPU:-0}
    BUNK_OFFER_RAM_MB=${OFFER_RAM:-0}
    BUNK_OFFER_DISK_GB=${OFFER_DISK:-0}
    BUNK_VPS_BRIDGE=${VPS_BRIDGE}
    BUNK_VPS_VLAN=${VPS_VLAN:-0}
    BUNK_VPS_GATEWAY=${VPS_GW}
    BUNK_VPS_CIDR_PREFIX=${VPS_CIDR}
    BUNK_VPS_RANGE_START=${VPS_RSTART}
    BUNK_VPS_RANGE_END=${VPS_REND}
    BUNK_MANAGE_NETWORK=${MANAGE_NET}
    BUNK_STATE_DIR=/var/lib/bunk-worker
    ENVF
    chmod 600 /etc/bunk-worker/agent.env
    umask 022

    echo "-> systemd-service installeren..."
    cat > /etc/systemd/system/bunk-worker.service <<UNIT
    [Unit]
    Description=Bunk Worker agent
    After=network-online.target
    Wants=network-online.target

    [Service]
    EnvironmentFile=/etc/bunk-worker/agent.env
    ExecStart=/usr/local/bin/bunk-worker
    Restart=always
    RestartSec=5

    [Install]
    WantedBy=multi-user.target
    UNIT

    echo "-> automatische updates instellen..."
    cat > /usr/local/bin/bunk-agent-update <<'UPD'
    #{@update_script}
    UPD
    chmod +x /usr/local/bin/bunk-agent-update

    cat > /etc/systemd/system/bunk-agent-update.service <<'UPDSVC'
    #{@update_service}
    UPDSVC

    cat > /etc/systemd/system/bunk-agent-update.timer <<'UPDTMR'
    #{@update_timer}
    UPDTMR

    systemctl daemon-reload
    systemctl enable --now bunk-agent-update.timer
    systemctl enable --now bunk-worker
    sleep 2
    echo
    bold "== Klaar! =="
    echo "Je worker verbindt nu met $CP en biedt capaciteit aan."
    if [ "$MANAGE_NET" = "true" ]; then
      echo "Het klantnetwerk wordt opgezet op $VPS_BRIDGE zodra de node is ingeschreven;"
      echo "welk subnet je kreeg zie je in de logs ('vps network ready')."
    else
      echo "Let op: je beheert het netwerk zelf. VPS'en krijgen gateway $VPS_GW --"
      echo "zonder werkende gateway en NAT hebben ze geen verbinding."
    fi
    echo "Status:  systemctl status bunk-worker"
    echo "Logs:    journalctl -u bunk-worker -f"
    """
  end
end
