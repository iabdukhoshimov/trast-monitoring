#!/usr/bin/env bash
# ==============================================================================
# push_to_harbor.sh
# Downloads exporter binaries and pushes them as Docker images to Harbor.
# Run once from an internet-connected machine with Docker + Harbor access.
#
# Usage:
#   bash push_to_harbor.sh
#   bash push_to_harbor.sh --arch amd64
# ==============================================================================
set -euo pipefail

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  CONFIGURATION                                                             ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
HARBOR_URL="harbor.trustbank.uz"
HARBOR_PROJECT="trastpay-v2"
HARBOR_USER="${HARBOR_USER:-trastbank\$ci-cd-robot}"

ARCHES=("amd64" "arm64")

# Keep in sync with install_exporters.sh
NODE_EXPORTER_VERSION="1.11.0"
ALLOY_VERSION="1.16.1"
POSTGRES_EXPORTER_VERSION="0.16.0"
MONGODB_EXPORTER_VERSION="0.40.0"

# ══════════════════════════════════════════════════════════════════════════════

while [[ $# -gt 0 ]]; do
  case $1 in
    --arch) ARCHES=("$2"); shift 2 ;;
    --harbor) HARBOR_URL="$2"; shift 2 ;;
    --project) HARBOR_PROJECT="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# Support non-interactive login via env var (never hardcode in script)
# Usage: HARBOR_PASSWORD=xxx bash push_to_harbor.sh
if [[ -n "${HARBOR_PASSWORD:-}" ]]; then
  echo "$HARBOR_PASSWORD" | docker login "$HARBOR_URL" -u "$HARBOR_USER" --password-stdin
fi

TMPDIR_WORK=$(mktemp -d)
trap 'rm -rf "$TMPDIR_WORK"' EXIT

GREEN='\033[0;32m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
die()  { echo -e "\033[0;31m[✗]${NC} $*" >&2; exit 1; }
step() { echo -e "\n${BOLD}━━━ $* ━━━${NC}"; }

command -v docker &>/dev/null || die "docker required"
command -v curl   &>/dev/null || die "curl required"

fetch() {
  local url=$1 dest=$2
  log "Downloading $(basename "$dest")..."
  curl -fsSL --retry 3 --retry-delay 2 "$url" -o "$dest"
}

# Build a scratch image with one binary and push it
build_and_push() {
  local binary=$1     # local path to binary
  local name=$2       # image name  e.g. node-exporter
  local version=$3    # e.g. 1.11.0
  local arch=$4       # amd64 | arm64

  local tag="${HARBOR_URL}/${HARBOR_PROJECT}/${name}:${version}-${arch}"
  local bin_name
  bin_name=$(basename "$binary")

  log "Building ${tag}..."

  # FROM scratch + COPY works cross-arch without QEMU (no RUN instructions)
  local ctx="$TMPDIR_WORK/ctx_${name}_${arch}"
  mkdir -p "$ctx"
  cp "$binary" "$ctx/${bin_name}"

  cat > "$ctx/Dockerfile" << EOF
FROM scratch
COPY ${bin_name} /${bin_name}
EOF

  docker build --platform "linux/${arch}" -t "$tag" "$ctx"
  docker push "$tag"
  docker rmi "$tag" &>/dev/null || true

  log "Pushed: ${tag}"
}

# ── Login ──────────────────────────────────────────────────────────────────────
step "Harbor login"
if [[ -z "${HARBOR_PASSWORD:-}" ]]; then
  docker login "$HARBOR_URL" -u "$HARBOR_USER" || die "Harbor login failed"
fi

# ── Download + push ────────────────────────────────────────────────────────────
for ARCH in "${ARCHES[@]}"; do
  step "arch: ${ARCH}"

  # node_exporter
  NE_ARCHIVE="node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}.tar.gz"
  fetch "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/${NE_ARCHIVE}" \
        "$TMPDIR_WORK/$NE_ARCHIVE"
  tar -xzf "$TMPDIR_WORK/$NE_ARCHIVE" -C "$TMPDIR_WORK"
  build_and_push \
    "$TMPDIR_WORK/node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}/node_exporter" \
    "node-exporter" "$NODE_EXPORTER_VERSION" "$ARCH"

  # alloy
  ALLOY_ARCHIVE="alloy-linux-${ARCH}.zip"
  fetch "https://github.com/grafana/alloy/releases/download/v${ALLOY_VERSION}/${ALLOY_ARCHIVE}" \
        "$TMPDIR_WORK/$ALLOY_ARCHIVE"
  unzip -o "$TMPDIR_WORK/$ALLOY_ARCHIVE" "alloy-linux-${ARCH}" -d "$TMPDIR_WORK" >/dev/null
  build_and_push \
    "$TMPDIR_WORK/alloy-linux-${ARCH}" \
    "alloy" "$ALLOY_VERSION" "$ARCH"

  # postgres_exporter
  PG_ARCHIVE="postgres_exporter-${POSTGRES_EXPORTER_VERSION}.linux-${ARCH}.tar.gz"
  fetch "https://github.com/prometheus-community/postgres_exporter/releases/download/v${POSTGRES_EXPORTER_VERSION}/${PG_ARCHIVE}" \
        "$TMPDIR_WORK/$PG_ARCHIVE"
  tar -xzf "$TMPDIR_WORK/$PG_ARCHIVE" -C "$TMPDIR_WORK"
  build_and_push \
    "$TMPDIR_WORK/postgres_exporter-${POSTGRES_EXPORTER_VERSION}.linux-${ARCH}/postgres_exporter" \
    "postgres-exporter" "$POSTGRES_EXPORTER_VERSION" "$ARCH"

  # mongodb_exporter (optional)
  MG_ARCHIVE="mongodb_exporter-${MONGODB_EXPORTER_VERSION}.linux-${ARCH}.tar.gz"
  if curl -fsSL --retry 2 \
       "https://github.com/percona/mongodb_exporter/releases/download/v${MONGODB_EXPORTER_VERSION}/${MG_ARCHIVE}" \
       -o "$TMPDIR_WORK/$MG_ARCHIVE" 2>/dev/null; then
    tar -xzf "$TMPDIR_WORK/$MG_ARCHIVE" -C "$TMPDIR_WORK"
    MG_BINARY=$(find "$TMPDIR_WORK" -name "mongodb_exporter" -type f | head -1)
    [[ -n "$MG_BINARY" ]] && \
      build_and_push "$MG_BINARY" "mongodb-exporter" "$MONGODB_EXPORTER_VERSION" "$ARCH"
  else
    log "Warning: mongodb_exporter download failed — skipping"
  fi
done

echo ""
echo -e "${BOLD}Done! Images in Harbor:${NC}"
echo "  ${HARBOR_URL}/${HARBOR_PROJECT}/node-exporter:${NODE_EXPORTER_VERSION}-{amd64,arm64}"
echo "  ${HARBOR_URL}/${HARBOR_PROJECT}/alloy:${ALLOY_VERSION}-{amd64,arm64}"
echo "  ${HARBOR_URL}/${HARBOR_PROJECT}/postgres-exporter:${POSTGRES_EXPORTER_VERSION}-{amd64,arm64}"
echo "  ${HARBOR_URL}/${HARBOR_PROJECT}/mongodb-exporter:${MONGODB_EXPORTER_VERSION}-{amd64,arm64}"
