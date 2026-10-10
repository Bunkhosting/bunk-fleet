#!/bin/bash
# Full verification gate: format, compile-with-warnings-as-errors and tests for
# both components, all inside containers.
#
# Why containers: the control plane is developed from a box with no Elixir and no
# Go toolchain, so `mix test` on the host is not an option. The top-level Makefile
# targets (test-control-plane etc.) assume a local toolchain and only work where
# one exists; this script is the version that runs anywhere Docker does.
#
# Run this BEFORE pushing. Everything it checks is cheap compared to discovering
# a syntax error part-way through a seven-minute production image build.
#
#   bash tools/check.sh            # everything
#   bash tools/check.sh elixir     # control plane only
#   bash tools/check.sh go         # agent only
#   bash tools/check.sh shell      # de uitrolscripts only
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WHAT="${1:-all}"

# De tests krijgen hun eigen wegwerp-Postgres. Ze draaiden hiervoor tegen de
# database van productie -- weliswaar in control_plane_test en niet in
# control_plane, dus het ging nooit mis -- maar het is één regel configuratie
# verwijderd van wel. En het was zichtbaar: elke gate-ronde zette tientallen
# "duplicate key"-fouten in de log van de productiedatabase, en dat is precies
# de log waarin je straks een échte fout moet terugvinden.
#
# De data staat in tmpfs: sneller, en hij laat niets achter op een schijf die
# toch al aan de krappe kant is.
NET="${BUNK_NET:-bunkfleet}"
TEST_PG="${BUNK_TEST_PG:-bf-test-pg}"
DB_HOST="${BUNK_DB_HOST:-$TEST_PG}"
DB_USER="${BUNK_DB_USER:-bunkfleet}"
# Geen geheim: deze database bestaat alleen zolang de gate draait, staat op een
# intern docker-netwerk en publiceert geen poort.
DB_PASSWORD="${BUNK_DB_PASSWORD:-testtest}"

fail() { echo "FAIL: $*" >&2; exit 1; }

# Zet de wegwerpdatabase op als hij er niet is, en laat hem daarna staan: de
# volgende gate-ronde is dan sneller. `docker rm -f bf-test-pg` is genoeg om
# helemaal schoon te beginnen.
start_test_pg() {
  [ "$DB_HOST" = "$TEST_PG" ] || return 0

  if [ "$(docker inspect -f '{{.State.Running}}' "$TEST_PG" 2>/dev/null)" != "true" ]; then
    docker rm -f "$TEST_PG" >/dev/null 2>&1 || true
    docker run -d --name "$TEST_PG" --network "$NET" \
      --tmpfs /var/lib/postgresql/data:rw,size=512m \
      -e POSTGRES_USER="$DB_USER" -e POSTGRES_PASSWORD="$DB_PASSWORD" \
      -e POSTGRES_DB=control_plane_test \
      postgres:16-alpine >/dev/null || fail "kon de testdatabase niet starten"
    echo "testdatabase $TEST_PG gestart"
  fi

  for _ in $(seq 1 30); do
    docker exec "$TEST_PG" pg_isready -U "$DB_USER" -d control_plane_test >/dev/null 2>&1 && return 0
    sleep 1
  done
  fail "de testdatabase werd niet bereikbaar"
}

# De uitrolscripts zijn productiecode: ze vervangen containers en draaien
# migraties. `bash -n` vangt daar bijna niets van, want de fout die hier ooit een
# uitrol halverwege afbrak -- een commentaarregel middenin een commando met
# regelvervolgen -- is syntactisch volstrekt geldig. Shellcheck heeft daar een
# eigen regel voor (SC1143), en een paar honderd andere.
check_shell() {
  echo "=== shellscripts: shellcheck ==="
  docker run --rm -v "$ROOT":/mnt -w /mnt koalaman/shellcheck-alpine:stable \
    sh -c 'shellcheck -S warning *.sh tools/*.sh provisioning/*/*.sh control_plane/priv/agent-update/bunk-agent-update provisioning/vps-welcome/welcome'
}

check_elixir() {
  start_test_pg
  [ -n "$DB_PASSWORD" ] || fail "BUNK_DB_PASSWORD is required for the Elixir suite"

  echo "=== control plane: format + compile + test ==="
  docker run --rm --network "$NET" \
    -v "$ROOT/control_plane":/app -w /app \
    -e MIX_ENV=test \
    -e DB_HOST="$DB_HOST" -e DB_USER="$DB_USER" -e DB_PASSWORD="$DB_PASSWORD" \
    elixir:1.17-alpine sh -eu -c '
      # mix_audit fetches the advisory database over git; the base image has none.
      apk add --no-cache git >/dev/null
      mix local.hex --force >/dev/null
      mix local.rebar --force >/dev/null
      mix deps.get >/dev/null
      echo "--- mix format --check-formatted ---"
      mix format --check-formatted
      echo "--- mix compile --warnings-as-errors ---"
      mix compile --warnings-as-errors
      echo "--- mix credo --strict ---"
      mix credo --strict
      echo "--- mix deps.audit ---"
      mix deps.audit
      echo "--- mix test ---"
      mix test
    '

  # Dialyzer runs against MIX_ENV=dev (that is where the cached PLT lives) and
  # needs no database. The first run in a fresh checkout builds the PLT and takes
  # a few minutes; after that it is seconds, because priv/plts is inside the
  # mounted tree. CI runs it too — having it here is what stops a type regression
  # from being discovered seven minutes into a production image build.
  echo "--- mix dialyzer ---"
  docker run --rm \
    -v "$ROOT/control_plane":/app -w /app \
    -e MIX_ENV=dev \
    elixir:1.17-alpine sh -eu -c '
      mix local.hex --force >/dev/null
      mix local.rebar --force >/dev/null
      mix deps.get >/dev/null
      mix dialyzer
    '
}

check_go() {
  echo "=== agent: gofmt + vet + test ==="
  docker volume create bunk-gocache >/dev/null 2>&1 || true
  docker run --rm \
    -v "$ROOT/agent":/src -w /src \
    -v bunk-gocache:/gocache \
    -e GOMODCACHE=/gocache/mod -e GOCACHE=/gocache/build \
    golang:1.26-alpine sh -eu -c '
      echo "--- gofmt ---"
      unformatted=$(gofmt -l .)
      [ -z "$unformatted" ] || { echo "unformatted files:"; echo "$unformatted"; exit 1; }
      echo "--- go vet ---"
      go vet ./...
      echo "--- go test ---"
      go test ./...
    '
}

case "$WHAT" in
  all)    check_shell; check_elixir; check_go ;;
  elixir) check_elixir ;;
  go)     check_go ;;
  shell)  check_shell ;;
  *)      fail "unknown target '$WHAT' (expected: all | elixir | go | shell)" ;;
esac

echo "=== ALLES GROEN ==="
