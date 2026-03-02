#!/usr/bin/env bash
# =============================================================
# build-release.sh — Pathfinder Release Package Builder
# =============================================================
# Builds all custom Docker images, exports them to .tar files,
# assembles a self-contained client package, and zips it up.
#
# Usage:
#   ./build-release.sh [version]
#
# Example:
#   ./build-release.sh 1.0.0
#   ./build-release.sh          # defaults to date-based version
# =============================================================

set -e

# ── Config ────────────────────────────────────────────────────
VERSION="${1:-$(date +%Y%m%d-%H%M)}"
PACKAGE_NAME="pathfinder-release-${VERSION}"
OUT_DIR="./release/${PACKAGE_NAME}"
IMAGES_DIR="${OUT_DIR}/images"

IMAGE_API="pathfinder/api:${VERSION}"
IMAGE_UI_ZONELESS="pathfinder/ui-zoneless:${VERSION}"

# ── Colors ────────────────────────────────────────────────────
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${BLUE}[build]${NC} $*"; }
ok()   { echo -e "${GREEN}[ok]${NC} $*"; }
warn() { echo -e "${YELLOW}[warn]${NC} $*"; }

# ── Step 1: Build images ───────────────────────────────────────
log "Building Docker images for version ${VERSION}..."

log "  → pathfinder-api"
docker build -t "${IMAGE_API}" ./PathfinderApi

log "  → pathfinder-ui-zoneless"
docker build -t "${IMAGE_UI_ZONELESS}" ./pathfinder-ui-zoneless

ok "All images built."

# ── Step 2: Prepare output directory ──────────────────────────
log "Creating release directory: ${OUT_DIR}"
rm -rf "${OUT_DIR}"
mkdir -p "${IMAGES_DIR}"

# ── Step 3: Save images to tar ────────────────────────────────
log "Saving images to tar files (this may take a moment)..."

log "  → images/pathfinder-api.tar"
docker save "${IMAGE_API}" -o "${IMAGES_DIR}/pathfinder-api.tar"

log "  → images/pathfinder-ui-zoneless.tar"
docker save "${IMAGE_UI_ZONELESS}" -o "${IMAGES_DIR}/pathfinder-ui-zoneless.tar"

ok "Images saved."

# ── Step 4: Copy supporting files ─────────────────────────────
log "Copying config and documentation..."

# otel-collector config (volume-mounted by the collector container)
cp otel-collector-config.yaml "${OUT_DIR}/otel-collector-config.yaml"

# env template for the client
cp .env.example "${OUT_DIR}/.env.example"

# Observability docs
cp OBSERVABILITY.md "${OUT_DIR}/OBSERVABILITY.md"

# ── Step 5: Write client docker-compose.yml ───────────────────
log "Writing docker-compose.yml (image refs, no build context)..."

cat > "${OUT_DIR}/docker-compose.yml" << COMPOSE
# Pathfinder — Client Release ${VERSION}
# ─────────────────────────────────────────────────────────────
# 1. Copy .env.example to .env and fill in your values.
# 2. Run ./start.sh  (first time — loads images + starts stack)
# 3. Or: docker compose up -d  (after images are already loaded)

services:

  jaeger:
    image: jaegertracing/all-in-one:latest
    container_name: pathfinder-jaeger
    ports:
      - "16686:16686"
    environment:
      - COLLECTOR_OTLP_ENABLED=true
    restart: unless-stopped
    networks:
      - pathfinder-network
    healthcheck:
      test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost:16686"]
      interval: 15s
      timeout: 5s
      retries: 5

  otel-collector:
    image: otel/opentelemetry-collector-contrib:latest
    container_name: pathfinder-otel-collector
    volumes:
      - ./otel-collector-config.yaml:/etc/otelcol-contrib/config.yaml
    ports:
      - "4319:4317"
      - "4320:4318"
    environment:
      - CUSTOM_CONSUMER_ENDPOINT=\${CUSTOM_CONSUMER_ENDPOINT}
    depends_on:
      jaeger:
        condition: service_healthy
    restart: unless-stopped
    networks:
      - pathfinder-network

  pathfinder-api:
    image: ${IMAGE_API}
    container_name: pathfinder-api
    ports:
      - "5215:8080"
    environment:
      - OTEL_SERVICE_NAME=\${DOTNET_SERVICE_NAME}
      - OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4317
      - OTEL_EXPORTER_OTLP_PROTOCOL=grpc
      - OTEL_TRACES_EXPORTER=otlp
      - OTEL_METRICS_EXPORTER=none
      - OTEL_LOGS_EXPORTER=none
      - OTEL_DOTNET_AUTO_TRACES_ADDITIONAL_SOURCES=PathfinderApi
    depends_on:
      otel-collector:
        condition: service_started
    restart: unless-stopped
    networks:
      - pathfinder-network

  pathfinder-ui-zoneless:
    image: ${IMAGE_UI_ZONELESS}
    container_name: pathfinder-ui-zoneless
    ports:
      - "4200:80"
    environment:
      - API_URL=\${API_URL}
      - OTEL_URL=\${OTEL_COLLECTOR_HTTP_URL}
    depends_on:
      - pathfinder-api
    restart: unless-stopped
    networks:
      - pathfinder-network

networks:
  pathfinder-network:
    driver: bridge
COMPOSE

ok "docker-compose.yml written."

# ── Step 6: Write client start.sh ─────────────────────────────
log "Writing start.sh..."

cat > "${OUT_DIR}/start.sh" << 'STARTSH'
#!/usr/bin/env bash
# Pathfinder — First-time startup script
# Loads Docker images from this package and starts the stack.

set -e
GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
log() { echo -e "${BLUE}[start]${NC} $*"; }
ok()  { echo -e "${GREEN}[ok]${NC} $*"; }

# Require .env
if [ ! -f ".env" ]; then
  echo ""
  echo "  ❌ No .env file found!"
  echo "  Copy .env.example to .env and fill in your values:"
  echo ""
  echo "    cp .env.example .env && nano .env"
  echo ""
  exit 1
fi

log "Loading Docker images..."
for tar in images/*.tar; do
  log "  → $tar"
  docker load -i "$tar"
done
ok "Images loaded."

log "Starting stack..."
docker compose up -d

echo ""
ok "Stack is up!"
echo ""
echo "  Jaeger UI:          http://localhost:16686"
echo "  Angular UI:         http://localhost:4200"
echo "  API:                http://localhost:5215/api/health"
echo ""
echo "  Collector gRPC (custom app input): localhost:4319"
echo "  Collector HTTP (browser OTLP):     http://localhost:4320"
echo ""
STARTSH

chmod +x "${OUT_DIR}/start.sh"
ok "start.sh written."

# ── Step 7: Write client README ───────────────────────────────
log "Writing README.md..."

cat > "${OUT_DIR}/README.md" << README
# Pathfinder — Release ${VERSION}

## First-time Setup

### 1. Configure your environment

\`\`\`bash
cp .env.example .env
\`\`\`

Edit \`.env\`:

| Variable | Description | Example |
|---|---|---|
| \`API_URL\` | Backend API URL (must be reachable from browser) | \`http://YOUR_SERVER:5215/api\` |
| \`OTEL_COLLECTOR_HTTP_URL\` | OTel Collector HTTP (must be reachable from browser) | \`http://YOUR_SERVER:4320/v1/traces\` |
| \`DOTNET_SERVICE_NAME\` | Service name in Jaeger | \`pathfinder-api\` |
| \`CUSTOM_CONSUMER_ENDPOINT\` | Where collector sends **full traces** to your app (gRPC) | \`YOUR_APP_HOST:4317\` |

### 2. Start

\`\`\`bash
./start.sh
\`\`\`

This loads all Docker images and starts the stack.
After the first run, use \`docker compose up -d\` / \`docker compose down\` directly.

---

## Services

| Service | Port | URL |
|---|---|---|
| Angular UI | 4200 | http://localhost:4200 |
| .NET API | 5215 | http://localhost:5215/api/health |
| Jaeger UI | 16686 | http://localhost:16686 |
| OTel Collector gRPC | 4319 | \`host:4319\` |
| OTel Collector HTTP | 4320 | \`http://host:4320/v1/traces\` |

---

## Connecting Your Custom App

The collector pushes **full, complete traces** to \`CUSTOM_CONSUMER_ENDPOINT\` via gRPC OTLP.
Your app must expose an OTLP gRPC receiver on that port.

Traces are delivered after a **10-second window** to ensure all spans are collected.

---

## Useful Commands

\`\`\`bash
# Check running containers
docker compose ps

# Tail collector logs
docker logs -f pathfinder-otel-collector

# Restart after .env change
docker compose restart

# Stop everything
docker compose down
\`\`\`

See \`OBSERVABILITY.md\` for the full architecture and troubleshooting guide.
README

ok "README.md written."

# ── Step 8: Zip the package ────────────────────────────────────
log "Zipping release package..."
cd release
zip -r "${PACKAGE_NAME}.zip" "${PACKAGE_NAME}/"
cd ..

ZIPFILE="./release/${PACKAGE_NAME}.zip"
ZIPSIZE=$(du -sh "${ZIPFILE}" | cut -f1)

echo ""
ok "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
ok " Release package ready!"
ok "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  📦 File: ${ZIPFILE}"
echo "  📏 Size: ${ZIPSIZE}"
echo ""
echo "  Contents:"
echo "    ├── images/pathfinder-api.tar"
echo "    ├── images/pathfinder-ui-zoneless.tar"
echo "    ├── docker-compose.yml"
echo "    ├── otel-collector-config.yaml"
echo "    ├── .env.example"
echo "    ├── start.sh"
echo "    └── README.md"
echo ""
echo "  Share: ${ZIPFILE}"
echo ""
warn "Jaeger and otel-collector images are pulled from Docker Hub"
warn "on the client machine — no need to bundle them (public images)."
echo ""
