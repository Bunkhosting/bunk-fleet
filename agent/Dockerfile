# syntax=docker/dockerfile:1

# --- build stage ---------------------------------------------------------
FROM golang:1.26-alpine AS build

WORKDIR /src

# Cache module downloads.
COPY go.mod ./
COPY go.su[m] ./
RUN go mod download

# Build the static binary (stdlib-only, no cgo).
COPY . .
RUN CGO_ENABLED=0 go build -o /bunk-agent ./cmd/bunk-agent

# --- runtime stage -------------------------------------------------------
FROM alpine:3.20

RUN apk add --no-cache ca-certificates \
    && addgroup -S bunk \
    && adduser -S -G bunk bunk \
    && mkdir -p /var/lib/bunk-agent \
    && chown bunk:bunk /var/lib/bunk-agent

COPY --from=build /bunk-agent /usr/local/bin/bunk-agent

USER bunk

ENTRYPOINT ["/usr/local/bin/bunk-agent"]
