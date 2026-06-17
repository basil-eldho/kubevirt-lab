# syntax=docker/dockerfile:1

# ── Build stage ───────────────────────────────────────────────────────────────
FROM golang:1.22-alpine AS builder

WORKDIR /src

# Cache dependency downloads separately from source compilation.
COPY go.mod go.sum ./
RUN go mod download

COPY . .

# Build both binaries with optimisations. CGO disabled for a static binary
# that runs in a scratch/distroless image with no libc.
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -ldflags="-s -w" -trimpath -o /out/controller ./cmd/controller && \
    go build -ldflags="-s -w" -trimpath -o /out/api ./cmd/api

# ── Controller image ──────────────────────────────────────────────────────────
FROM gcr.io/distroless/static-debian12 AS controller
COPY --from=builder /out/controller /controller
ENTRYPOINT ["/controller"]

# ── API image ─────────────────────────────────────────────────────────────────
FROM gcr.io/distroless/static-debian12 AS api
COPY --from=builder /out/api /api
ENTRYPOINT ["/api"]
