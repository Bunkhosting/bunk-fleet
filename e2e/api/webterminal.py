"""Kale WebSocket-client voor de Bunk-webterminal.

Geen bibliotheek: de handshake en de framing staan hier, zodat dit overal draait
waar python3 staat. Bedoeld om één opdracht uit te voeren en te lezen wat eruit
komt -- niet om een terminal te zijn.

## Waarom dit bestaat

De webterminal is de enige ingang tot een VPS (geen SSH van buiten, geen
poortdoorverwijzing), en hij had geen enkele geautomatiseerde dekking. Dat is
hoe een storing van één op de zes sessies maandenlang onopgemerkt bleef: de
Playwright-suite komt niet achter het inlogscherm met een xterm, en het
API-harnas sprak alleen HTTP.

## Waarom rechtstreeks naar de container

Een handmatig gebouwde TLS-handshake naar wss://app.bunkhosting.nl wordt door
Cloudflare geweigerd met een 403 -- terecht, hij ziet er niet uit als een
browser. Van binnen het dockernetwerk mag het wel, en daar meet je bovendien de
dienst in plaats van de tunnel. Draai dit dus op de machine waar de control
plane staat; `HOST` en `POORT` wijzen die aan.
"""
import base64, os, socket, struct, sys, time


def _stuur(s, data: bytes, opcode=0x2):
    """Een gemaskeerd frame; een client MOET maskeren (RFC 6455)."""
    kopje = bytearray([0x80 | opcode])
    n = len(data)
    if n < 126:
        kopje.append(0x80 | n)
    elif n < 65536:
        kopje.append(0x80 | 126)
        kopje += struct.pack(">H", n)
    else:
        kopje.append(0x80 | 127)
        kopje += struct.pack(">Q", n)
    masker = os.urandom(4)
    kopje += masker
    s.sendall(bytes(kopje) + bytes(b ^ masker[i % 4] for i, b in enumerate(data)))


def _lees(s, staart: bytes, seconden: float):
    """Alles wat binnen `seconden` binnenkomt, ontdaan van framing."""
    uit = b""
    einde = time.time() + seconden
    s.settimeout(0.5)
    while time.time() < einde:
        try:
            stuk = s.recv(65536)
            if not stuk:
                break
            staart += stuk
        except socket.timeout:
            pass
        while len(staart) >= 2:
            b1, b2 = staart[0], staart[1]
            lengte = b2 & 0x7F
            i = 2
            if lengte == 126:
                if len(staart) < 4:
                    break
                lengte = struct.unpack(">H", staart[2:4])[0]
                i = 4
            elif lengte == 127:
                if len(staart) < 10:
                    break
                lengte = struct.unpack(">Q", staart[2:10])[0]
                i = 10
            if len(staart) < i + lengte:
                break
            lading = staart[i : i + lengte]
            staart = staart[i + lengte :]
            if b1 & 0x0F in (0x1, 0x2):
                uit += lading
            elif b1 & 0x0F == 0x8:
                return uit + b"\n[verbinding gesloten door de server]", staart
    return uit, staart


def sessie(host, poort, pad, opdrachten=(), eerste_wacht=14.0, per_opdracht=8.0):
    """Opent één consolesessie en geeft terug wat er over de lijn kwam.

    Werpt een uitzondering als de WebSocket-handshake niet lukt. Een sessie die
    wél opengaat maar waar de VPS niet achter blijkt te zitten, is GEEN
    uitzondering: het control plane stuurt dan een leesbare uitleg over de lijn,
    en die hoort de aanroeper te zien -- dat is precies het verschil tussen "de
    terminal is stuk" en "deze VPS neemt nog geen SSH aan".
    """
    s = socket.create_connection((host, poort), timeout=20)
    try:
        sleutel = base64.b64encode(os.urandom(16)).decode()
        verzoek = (
            f"GET {pad} HTTP/1.1\r\nHost: app.bunkhosting.nl\r\nUpgrade: websocket\r\n"
            f"Connection: Upgrade\r\nSec-WebSocket-Key: {sleutel}\r\n"
            f"Sec-WebSocket-Version: 13\r\nOrigin: https://app.bunkhosting.nl\r\n\r\n"
        )
        s.sendall(verzoek.encode())

        buf = b""
        while b"\r\n\r\n" not in buf:
            stuk = s.recv(4096)
            if not stuk:
                raise RuntimeError("verbinding dicht tijdens de handshake")
            buf += stuk
        kop, staart = buf.split(b"\r\n\r\n", 1)
        eerste = kop.split(b"\r\n")[0].decode()
        if "101" not in eerste:
            raise RuntimeError(f"geen upgrade: {eerste}")

        uit, staart = _lees(s, staart, eerste_wacht)
        for opdracht in opdrachten:
            _stuur(s, (opdracht + "\n").encode())
            time.sleep(0.4)
            meer, staart = _lees(s, staart, per_opdracht)
            uit += meer
        return uit.decode("utf-8", "replace")
    finally:
        s.close()


if __name__ == "__main__":
    h, p, weg, cmds = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4:]
    print(sessie(h, p, weg, cmds))
