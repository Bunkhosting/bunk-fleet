"use client";

// xterm CSS must be imported at module level (Next.js processes it at build time)
import "@xterm/xterm/css/xterm.css";

import { useEffect, useRef, useState, useCallback } from "react";
import { useParams, useRouter } from "next/navigation";
import { ArrowLeft, Clipboard, Loader2, WifiOff, Terminal } from "lucide-react";
import { Button } from "@/components/ui/button";
import { vpsApi } from "@/lib/api";
import type { Vps } from "@/lib/types";

function resolveWsBase(): string {
  const explicit =
    process.env.NEXT_PUBLIC_WS_URL ||
    (process.env.NEXT_PUBLIC_API_URL || "").replace(/^http/, "ws");
  if (explicit) return explicit.replace(/\/+$/, "");
  // No env configured: derive a same-origin ws(s) base from the page so we never
  // construct a relative WebSocket URL (which throws SyntaxError at runtime).
  if (typeof window !== "undefined") {
    const proto = window.location.protocol === "https:" ? "wss:" : "ws:";
    return `${proto}//${window.location.host}`;
  }
  return "";
}

type ConnectionState = "connecting" | "open" | "closed" | "error";

export default function VpsTerminalPage() {
  const params = useParams();
  const router = useRouter();
  const id = params.id as string;

  const terminalRef = useRef<HTMLDivElement>(null);
  const xtermRef = useRef<import("@xterm/xterm").Terminal | null>(null);
  const fitRef = useRef<import("@xterm/addon-fit").FitAddon | null>(null);
  const wsRef = useRef<WebSocket | null>(null);
  const resizeObserverRef = useRef<ResizeObserver | null>(null);

  const [vps, setVps] = useState<Vps | null>(null);
  const [connState, setConnState] = useState<ConnectionState>("connecting");
  const [errorMsg, setErrorMsg] = useState<string>("");
  const [pasteHelper, setPasteHelper] = useState(false);
  const [pasteText, setPasteText] = useState("");

  const handlePasteButton = async () => {
    try {
      const text = await navigator.clipboard.readText();
      if (!text) return;
      if (wsRef.current?.readyState === WebSocket.OPEN) {
        wsRef.current.send(new TextEncoder().encode(text));
        xtermRef.current?.focus();
      }
    } catch {
      setPasteHelper(true);
    }
  };

  const sendPasteHelper = () => {
    if (pasteText && wsRef.current?.readyState === WebSocket.OPEN) {
      wsRef.current.send(new TextEncoder().encode(pasteText));
      xtermRef.current?.focus();
    }
    setPasteText("");
    setPasteHelper(false);
  };

  // Fetch VPS info for the header label
  useEffect(() => {
    vpsApi.get(id).then((r) => setVps(r.data)).catch(() => {});
  }, [id]);

  const sendResize = useCallback((cols: number, rows: number) => {
    if (wsRef.current?.readyState === WebSocket.OPEN) {
      wsRef.current.send(JSON.stringify({ type: "resize", cols, rows }));
    }
  }, []);

  useEffect(() => {
    if (!terminalRef.current) return;

    // Dynamically import xterm (it uses browser APIs, not SSR-safe)
    let destroyed = false;

    (async () => {
      const { Terminal } = await import("@xterm/xterm");
      const { FitAddon } = await import("@xterm/addon-fit");

      if (destroyed) return;

      const term = new Terminal({
        cursorBlink: true,
        fontSize: 14,
        fontFamily: '"JetBrains Mono", "Fira Code", "Cascadia Code", monospace',
        theme: {
          background: "#0a0a0a",
          foreground: "#e2e8f0",
          cursor: "#e2e8f0",
          black: "#1a1a2e",
          red: "#ff6b6b",
          green: "#4ecdc4",
          yellow: "#ffe66d",
          blue: "#4d96ff",
          magenta: "#c77dff",
          cyan: "#4ecdc4",
          white: "#e2e8f0",
          brightBlack: "#4a5568",
          brightRed: "#ff6b6b",
          brightGreen: "#4ecdc4",
          brightYellow: "#ffe66d",
          brightBlue: "#4d96ff",
          brightMagenta: "#c77dff",
          brightCyan: "#4ecdc4",
          brightWhite: "#ffffff",
        },
        allowProposedApi: true,
      });

      const fit = new FitAddon();
      term.loadAddon(fit);
      term.open(terminalRef.current!);
      fit.fit();

      xtermRef.current = term;
      fitRef.current = fit;

      // WebSocket connection — bail cleanly if we can't form an absolute URL
      // (new WebSocket("/...") throws and the UI would hang on "Verbinden…").
      const wsBase = resolveWsBase();
      if (!wsBase) {
        term.writeln("\x1b[31mConsole niet beschikbaar: geen server geconfigureerd.\x1b[0m");
        setConnState("error");
        return;
      }
      // Owner-checked console ticket — the WS handshake can't send the bearer
      // header, so the server authorises this connection via a single-use ticket.
      let ticket: string;
      try {
        ({ ticket } = await vpsApi.consoleTicket(id));
      } catch {
        if (destroyed) return;
        term.writeln("\r\n\x1b[31mGeen console-toegang (is de VPS actief?).\x1b[0m");
        setConnState("error");
        return;
      }
      if (destroyed) return;

      const wsUrl = `${wsBase}/ws/console/${id}/?ticket=${encodeURIComponent(ticket)}`;
      const ws = new WebSocket(wsUrl);
      ws.binaryType = "arraybuffer";
      wsRef.current = ws;

      ws.onopen = () => {
        if (destroyed) { ws.close(); return; }
        setConnState("open");
        // Send initial size
        sendResize(term.cols, term.rows);
      };

      ws.onmessage = (event) => {
        if (event.data instanceof ArrayBuffer) {
          term.write(new Uint8Array(event.data));
        } else if (typeof event.data === "string") {
          term.write(event.data);
        }
      };

      ws.onclose = (event) => {
        if (destroyed) return;
        setConnState("closed");
        const msgs: Record<number, string> = {
          4001: "Niet ingelogd.",
          4003: "VPS niet gevonden of geen toegang.",
          4004: "VPS heeft nog geen IP-adres (nog niet klaar).",
          4005: "SSH-verbinding met de VPS mislukt.",
          4006: "SSH host key mismatch – mogelijke beveiligingswaarschuwing.",
          4029: "Maximaal aantal open terminals bereikt (2).",
        };
        setErrorMsg(msgs[event.code] ?? `Verbinding gesloten (code ${event.code}).`);
        term.write("\r\n\r\n\x1b[31m--- Verbinding verbroken ---\x1b[0m\r\n");
      };

      ws.onerror = () => {
        if (destroyed) return;
        setConnState("error");
        setErrorMsg("Kon geen verbinding maken met de server.");
      };

      // xterm → WebSocket
      term.onData((data) => {
        if (ws.readyState === WebSocket.OPEN) {
          ws.send(new TextEncoder().encode(data));
        }
      });

      term.onBinary((data) => {
        if (ws.readyState === WebSocket.OPEN) {
          const bytes = new Uint8Array(data.length);
          for (let i = 0; i < data.length; i++) bytes[i] = data.charCodeAt(i);
          ws.send(bytes);
        }
      });

      // Resize observer
      const resizeObserver = new ResizeObserver(() => {
        fit.fit();
        sendResize(term.cols, term.rows);
      });
      if (terminalRef.current) resizeObserver.observe(terminalRef.current);
      resizeObserverRef.current = resizeObserver;

      return () => {
        resizeObserver.disconnect();
      };
    })();

    return () => {
      destroyed = true;
      resizeObserverRef.current?.disconnect();
      resizeObserverRef.current = null;
      wsRef.current?.close();
      xtermRef.current?.dispose();
      xtermRef.current = null;
      fitRef.current = null;
      wsRef.current = null;
    };
  }, [id, sendResize]);

  return (
    <div className="flex flex-col h-[calc(100vh-4rem)] md:h-screen md:-m-8 md:p-0">
      {/* Toolbar */}
      <div className="flex items-center gap-3 px-4 py-3 border-b bg-card shrink-0">
        <Button
          variant="ghost"
          size="sm"
          onClick={() => router.push(`/dashboard/vps/${id}`)}
          className="gap-2"
        >
          <ArrowLeft className="h-4 w-4" />
          Terug
        </Button>

        <div className="flex items-center gap-2 text-sm font-medium">
          <Terminal className="h-4 w-4 text-muted-foreground" />
          <span>{vps ? (vps.label || `VPS #${vps.id}`) : `VPS #${id}`}</span>
        </div>

        <div className="relative ml-auto flex items-center gap-2">
          <Button
            variant="outline"
            size="sm"
            className="gap-2"
            onClick={handlePasteButton}
            disabled={connState !== "open"}
          >
            <Clipboard className="h-4 w-4" />
            Plakken
          </Button>
          {pasteHelper && (
            <div className="absolute top-full right-0 mt-1 z-20 w-72 rounded-md border bg-card shadow-lg p-3">
              <p className="text-xs text-muted-foreground mb-2">
                Klembord geblokkeerd door browser. Plak hier met Ctrl+V:
              </p>
              <textarea
                autoFocus
                className="w-full h-20 resize-none rounded border bg-background px-2 py-1 font-mono text-sm"
                placeholder="Plak hier…"
                value={pasteText}
                onChange={(e) => setPasteText(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === "Escape") { setPasteHelper(false); setPasteText(""); }
                }}
              />
              <div className="mt-2 flex justify-end gap-2">
                <Button variant="ghost" size="sm"
                  onClick={() => { setPasteHelper(false); setPasteText(""); }}>
                  Annuleren
                </Button>
                <Button size="sm" onClick={sendPasteHelper}>Stuur</Button>
              </div>
            </div>
          )}
        </div>

        <div className="flex items-center gap-2 text-xs text-muted-foreground">
          {connState === "connecting" && (
            <>
              <Loader2 className="h-3 w-3 animate-spin" />
              Verbinden…
            </>
          )}
          {connState === "open" && (
            <span className="flex items-center gap-1.5">
              <span className="h-2 w-2 rounded-full bg-green-500 animate-pulse" />
              Verbonden
            </span>
          )}
          {(connState === "closed" || connState === "error") && (
            <span className="flex items-center gap-1.5 text-destructive-text">
              <WifiOff className="h-3 w-3" />
              {errorMsg || "Verbroken"}
            </span>
          )}
        </div>
      </div>

      {/* Terminal */}
      <div
        ref={terminalRef}
        className="flex-1 min-h-0 bg-[#0a0a0a] p-2"
        style={{ overflow: "hidden" }}
      />
    </div>
  );
}
