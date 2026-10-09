#!/bin/bash
# Builds the control-plane image with the worker agent binary bundled into its
# static dir (served at /dist/bunk-worker for the install wizard). Run before
# deploy-prod.sh:  bash build-prod.sh && bash deploy-prod.sh
set -euo pipefail
# De map waar deze scripts en de broncode staan. Overschrijfbaar zodat een
# GitHub Actions-runner ze vanuit zijn eigen checkout kan draaien; standaard de
# map waar dit script zelf in staat, zodat een handmatige aanroep vanaf /opt
# blijft werken zoals hij deed.
ROOT="${BUNK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

echo "=== 1/2 building worker agent binary (linux/amd64, static) ==="
mkdir -p "$ROOT/control_plane/priv/static/dist"
# Persist the Go module + build cache across runs. This is a plain `docker run`,
# not a layered build, so without a volume every invocation re-downloads govmomi
# and x/crypto and recompiles the world — about a minute of pure waste per build.
docker volume create bunk-gocache >/dev/null 2>&1 || true

# De versie wordt in de binary gestempeld en via de heartbeat gemeld, zodat het
# dashboard kan laten zien welke node op welke build draait. Zonder dit is de
# enige manier om dat te weten in een gestripte binary naar logregels zoeken.
AGENT_VERSION="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo onbekend)"
if [ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]; then
  # Een build van een vuile werkboom is niet die commit. Dat liever zeggen dan
  # een node laten rapporteren dat hij op iets draait wat nergens staat.
  AGENT_VERSION="${AGENT_VERSION}-vuil"
fi
echo "agent-versie: $AGENT_VERSION"
# Ook voor de control plane: hij leest hieraan af welke nodes nog achterlopen.
printf %s "$AGENT_VERSION" > "$ROOT/.build-version"

docker run --rm \
  -v "$ROOT/agent":/src \
  -v "$ROOT/control_plane/priv/static/dist":/out \
  -v bunk-gocache:/gocache \
  -e GOMODCACHE=/gocache/mod -e GOCACHE=/gocache/build \
  -e AGENT_VERSION="$AGENT_VERSION" \
  -w /src golang:1.26-alpine \
  sh -c 'CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-s -w -X main.version=$AGENT_VERSION" -o /out/bunk-worker ./cmd/bunk-agent \
    && cd /out && sha256sum bunk-worker > bunk-worker.sha256'
ls -la "$ROOT/control_plane/priv/static/dist/bunk-worker" "$ROOT/control_plane/priv/static/dist/bunk-worker.sha256"
cat "$ROOT/control_plane/priv/static/dist/bunk-worker.sha256"

echo "=== 2/2 building control-plane image ==="
docker build -t bunk-fleet-cp:latest "$ROOT/control_plane"
echo "BUILT bunk-fleet-cp:latest (worker binary bundled at /dist/bunk-worker)"
