# Bunk Fleet — top-level developer tasks.
#
#   control_plane/  Elixir / Phoenix (OTP app :control_plane)
#   agent/          Go module github.com/Bunk-Hosting/bunk-fleet/agent

CONTROL_PLANE_DIR := control_plane
AGENT_DIR         := agent

.PHONY: all check test build fmt test-control-plane test-agent build-control-plane build-agent fmt-control-plane fmt-agent

all: build

## check: full verification gate (format + compile + tests, both components) in containers.
##        Works without a local Elixir/Go toolchain — unlike the `test` target below.
##        Runs against a throwaway Postgres (bf-test-pg). Run this before pushing.
check:
	bash tools/check.sh

## test: run Elixir and Go test suites
test: test-control-plane test-agent

test-control-plane:
	cd $(CONTROL_PLANE_DIR) && mix deps.get && mix test

test-agent:
	cd $(AGENT_DIR) && go test ./...

## build: compile both components
build: build-control-plane build-agent

build-control-plane:
	cd $(CONTROL_PLANE_DIR) && mix deps.get && mix compile

build-agent:
	cd $(AGENT_DIR) && go build ./...

## fmt: format both codebases
fmt: fmt-control-plane fmt-agent

fmt-control-plane:
	cd $(CONTROL_PLANE_DIR) && mix format

fmt-agent:
	cd $(AGENT_DIR) && go fmt ./...
