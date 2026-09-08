#!/usr/bin/env bash
# ==============================================================================
# install_exporters.sh
# Installs exporters on a monitored target server.
# Always installs: Node Exporter + Alloy (log shipping)
# Auto-detects:    postgres_exporter (if PostgreSQL found)
#                  mongodb_exporter  (if MongoDB found)
#
# Target OS: Rocky Linux / RHEL / AlmaLinux
# Run as root: sudo bash install_exporters.sh
# ==============================================================================
set -euo pipefail

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  CONFIGURATION — edit before running                                       ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

# IP/hostname of the monitoring server (where install_monitoring.sh was run)
MONITORING_SERVER_IP="192.168.88.11"

# Log shipping mode for Alloy:
#   "docker" — tail container logs via Docker socket
#   "file"   — tail log files from FILE_LOG_PATHS
LOG_SOURCE="docker"

# Paths to tail when LOG_SOURCE=file
FILE_LOG_PATHS=(
  "/var/log/*.log"
  "/var/log/app/*.log"
)

# PostgreSQL DSN for postgres_exporter (used if PostgreSQL is detected).
# Create a dedicated read-only user:
#   CREATE USER postgres_exporter WITH PASSWORD 'secret';
#   GRANT pg_monitor TO postgres_exporter;
POSTGRES_DSN="postgresql://postgres_exporter:CHANGE_ME@localhost:5432/postgres?sslmode=disable"

# MongoDB URI for mongodb_exporter (used if MongoDB is detected).
MONGODB_URI="mongodb://localhost:27017/"

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  VERSIONS — keep in sync with install_monitoring.sh                        ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
NODE_EXPORTER_VERSION="1.11.0"
ALLOY_VERSION="1.16.1"
POSTGRES_EXPORTER_VERSION="0.16.0"
MONGODB_EXPORTER_VERSION="0.40.0"

NODE_EXPORTER_CHECKSUM_AMD64="4f8fbd23b8380b8fb720b125fb9029de261dc5fcd68bfe81ae010c0d32f5f6c3"
NODE_EXPORTER_CHECKSUM_ARM64="cd09ceffd418e91c25365ad008b2baac88fa1743632b71c620829d3d5596b141"
ALLOY_CHECKSUM_AMD64="68fa7b1c75dc701f5bdc5242ce043ddb52f538ede493b7e9fc73226800fbfd3b"
ALLOY_CHECKSUM_ARM64="35d6fbcbbe93e9aab102f1e9c1f853d89730f5eca75afff0b81460eed570c4a5"
POSTGRES_EXPORTER_CHECKSUM_AMD64="5763bd10108e9739e7857377deeb43d2addf07c4c4f4d4c882a08847c15bfd61"
POSTGRES_EXPORTER_CHECKSUM_ARM64="d88c7d663e4d6a914bca71d2c4a684225e2336c20c62cdce215b2970d2a49b72"
# Get MongoDB exporter checksums from:
# https://github.com/percona/mongodb_exporter/releases/tag/v0.40.0
MONGODB_EXPORTER_CHECKSUM_AMD64="PLACEHOLDER_get_from_github_releases"
MONGODB_EXPORTER_CHECKSUM_ARM64="PLACEHOLDER_get_from_github_releases"

# ══════════════════════════════════════════════════════════════════════════════
# INTERNALS
# ══════════════════════════════════════════════════════════════════════════════

ARCH_RAW=$(uname -m)
[[ "$ARCH_RAW" == "aarch64" ]] && ARCH="arm64" || ARCH="amd64"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }
step() { echo -e "\n${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n${BOLD}   $*${NC}\n${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

[[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0"

# ── Pre-flight checks ─────────────────────────────────────────────────────────
preflight() {
  local missing=()
  for cmd in curl tar sha256sum systemctl useradd install ss; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  [[ ${#missing[@]} -eq 0 ]] || die "Missing required tools: ${missing[*]}"
  log "Pre-flight OK"
}

# ── Helpers ───────────────────────────────────────────────────────────────────

create_user() {
  id "$1" &>/dev/null || useradd --system --no-create-home --shell /sbin/nologin "$1"
}

download_verify() {
  local url=$1 dest=$2 expected=$3
  [[ "$expected" != PLACEHOLDER* ]] || \
    die "Checksum not set for $(basename "$dest"). Get it from the GitHub releases page."
  log "Downloading $(basename "$dest")..."
  curl -fsSL --retry 3 --retry-delay 2 "$url" -o "$dest"
  local actual
  actual=$(sha256sum "$dest" | awk '{print $1}')
  [[ "$actual" == "$expected" ]] || \
    die "Checksum mismatch for $(basename "$dest")\n  expected: $expected\n  got:      $actual"
}

open_port() {
  local port=$1
  if command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${port}/tcp" &>/dev/null
    firewall-cmd --reload &>/dev/null
    log "firewalld: opened ${port}/tcp"
  fi
}

svc_enable() {
  systemctl daemon-reload
  systemctl enable --now "$1"
  log "$1 enabled and started"
}

already_installed() {
  local binary=$1 version=$2
  "$binary" --version 2>&1 | grep -qF "$version" 2>/dev/null
}

# Detect database presence by checking: active systemd service OR open port
has_postgres() {
  systemctl is-active --quiet postgresql      2>/dev/null && return 0
  systemctl is-active --quiet "postgresql-*" 2>/dev/null && return 0
  ss -tlnp 2>/dev/null | grep -q ':5432 '    && return 0
  return 1
}

has_mongodb() {
  systemctl is-active --quiet mongod 2>/dev/null && return 0
  ss -tlnp 2>/dev/null | grep -q ':27017 '   && return 0
  return 1
}

# ── Node Exporter ─────────────────────────────────────────────────────────────

install_node_exporter() {
  step "Node Exporter ${NODE_EXPORTER_VERSION}"

  if already_installed /usr/local/bin/node_exporter "$NODE_EXPORTER_VERSION"; then
    log "Already at ${NODE_EXPORTER_VERSION}, skipping"
  else
    local archive="node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}.tar.gz"
    local csum_var="NODE_EXPORTER_CHECKSUM_${ARCH^^}"
    download_verify \
      "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/${archive}" \
      "/tmp/${archive}" "${!csum_var}"
    tar -xzf "/tmp/${archive}" -C /tmp
    install -o root -g root -m 0755 \
      "/tmp/node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}/node_exporter" \
      /usr/local/bin/node_exporter
    rm -rf "/tmp/${archive}" "/tmp/node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}"
  fi

  create_user node_exporter

  cat > /etc/systemd/system/node_exporter.service << 'UNIT'
[Unit]
Description=Node Exporter
After=network-online.target
Wants=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT

  svc_enable node_exporter
  open_port 9100
}

# ── Alloy ─────────────────────────────────────────────────────────────────────

install_alloy() {
  step "Alloy ${ALLOY_VERSION} (log shipping to ${MONITORING_SERVER_IP})"

  if already_installed /usr/local/bin/alloy "$ALLOY_VERSION"; then
    log "Already at ${ALLOY_VERSION}, skipping"
  else
    local archive="alloy-linux-${ARCH}.zip"
    local csum_var="ALLOY_CHECKSUM_${ARCH^^}"
    download_verify \
      "https://github.com/grafana/alloy/releases/download/v${ALLOY_VERSION}/${archive}" \
      "/tmp/${archive}" "${!csum_var}"
    command -v unzip &>/dev/null || dnf install -y -q unzip
    unzip -o "/tmp/${archive}" "alloy-linux-${ARCH}" -d /tmp
    install -o root -g root -m 0755 "/tmp/alloy-linux-${ARCH}" /usr/local/bin/alloy
    rm -f "/tmp/${archive}" "/tmp/alloy-linux-${ARCH}"
  fi

  create_user alloy
  install -d -o alloy -g alloy -m 0755 /etc/alloy /var/lib/alloy

  _write_alloy_config

  # Docker mode needs group membership to read the socket
  if [[ "$LOG_SOURCE" == "docker" ]] && getent group docker &>/dev/null; then
    usermod -aG docker alloy
    log "Added alloy to docker group"
  fi

  cat > /etc/systemd/system/alloy.service << 'UNIT'
[Unit]
Description=Grafana Alloy
After=network-online.target
Wants=network-online.target

[Service]
User=alloy
Group=alloy
Type=simple
ExecStart=/usr/local/bin/alloy run /etc/alloy/config.alloy --storage.path=/var/lib/alloy
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT

  svc_enable alloy
  open_port 12345
}

_write_alloy_config() {
  local hostname loki_url
  hostname=$(hostname -f)
  loki_url="http://${MONITORING_SERVER_IP}:3100/loki/api/v1/push"

  log "Writing Alloy config (log_source=${LOG_SOURCE})..."

  # Journal block always present
  cat > /etc/alloy/config.alloy << EOF
// Alloy config — generated by install_exporters.sh
// Host: ${hostname} | Loki: ${loki_url}

// ── Journal logs (always shipped) ────────────────────────────────────────────
loki.source.journal "journal" {
  forward_to    = [loki.write.default.receiver]
  relabel_rules = loki.relabel.journal.rules
  labels = {
    host = "${hostname}",
    job  = "journal",
  }
}

loki.relabel "journal" {
  forward_to = []
  rule {
    source_labels = ["__journal__systemd_unit"]
    target_label  = "unit"
  }
  rule {
    source_labels = ["__journal__priority_keyword"]
    target_label  = "level"
  }
}

EOF

  if [[ "$LOG_SOURCE" == "docker" ]]; then
    cat >> /etc/alloy/config.alloy << EOF
// ── Docker container logs ─────────────────────────────────────────────────────
discovery.docker "containers" {
  host = "unix:///var/run/docker.sock"
}

loki.source.docker "docker_logs" {
  host          = "unix:///var/run/docker.sock"
  targets       = discovery.docker.containers.targets
  forward_to    = [loki.write.default.receiver]
  relabel_rules = loki.relabel.docker.rules
}

loki.relabel "docker" {
  forward_to = []
  rule {
    source_labels = ["__meta_docker_container_name"]
    regex         = "/(.*)"
    target_label  = "container"
  }
  rule {
    source_labels = ["__meta_docker_container_image"]
    target_label  = "image"
  }
  rule {
    replacement  = "${hostname}"
    target_label = "host"
  }
}

EOF
  else
    # Build River array literal from FILE_LOG_PATHS
    local path_entries=""
    for p in "${FILE_LOG_PATHS[@]}"; do
      path_entries+="{\"__path__\" = \"${p}\", \"host\" = \"${hostname}\", \"job\" = \"file\"},"$'\n    '
    done

    cat >> /etc/alloy/config.alloy << EOF
// ── File-based log collection ─────────────────────────────────────────────────
local.file_match "app_logs" {
  path_targets = [
    ${path_entries}]
}

loki.source.file "file_logs" {
  targets    = local.file_match.app_logs.targets
  forward_to = [loki.write.default.receiver]
}

EOF
  fi

  cat >> /etc/alloy/config.alloy << EOF
// ── Loki write endpoint ───────────────────────────────────────────────────────
loki.write "default" {
  endpoint {
    url = "${loki_url}"
  }
}
EOF

  chown alloy:alloy /etc/alloy/config.alloy
}

# ── PostgreSQL Exporter ───────────────────────────────────────────────────────

install_postgres_exporter() {
  step "postgres_exporter ${POSTGRES_EXPORTER_VERSION}"

  if already_installed /usr/local/bin/postgres_exporter "$POSTGRES_EXPORTER_VERSION"; then
    log "Already at ${POSTGRES_EXPORTER_VERSION}, skipping"
  else
    local archive="postgres_exporter-${POSTGRES_EXPORTER_VERSION}.linux-${ARCH}.tar.gz"
    local csum_var="POSTGRES_EXPORTER_CHECKSUM_${ARCH^^}"
    download_verify \
      "https://github.com/prometheus-community/postgres_exporter/releases/download/v${POSTGRES_EXPORTER_VERSION}/${archive}" \
      "/tmp/${archive}" "${!csum_var}"
    tar -xzf "/tmp/${archive}" -C /tmp
    install -o root -g root -m 0755 \
      "/tmp/postgres_exporter-${POSTGRES_EXPORTER_VERSION}.linux-${ARCH}/postgres_exporter" \
      /usr/local/bin/postgres_exporter
    rm -rf "/tmp/${archive}" "/tmp/postgres_exporter-${POSTGRES_EXPORTER_VERSION}.linux-${ARCH}"
  fi

  create_user postgres_exporter
  install -d -m 0750 /etc/postgres_exporter

  # DSN in env file keeps it out of ps output and systemd journal
  printf 'DATA_SOURCE_NAME=%s\n' "$POSTGRES_DSN" \
    > /etc/postgres_exporter/postgres_exporter.env
  chmod 0600 /etc/postgres_exporter/postgres_exporter.env
  chown postgres_exporter:postgres_exporter /etc/postgres_exporter/postgres_exporter.env

  cat > /etc/systemd/system/postgres_exporter.service << 'UNIT'
[Unit]
Description=PostgreSQL Exporter
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
User=postgres_exporter
Group=postgres_exporter
Type=simple
EnvironmentFile=/etc/postgres_exporter/postgres_exporter.env
ExecStart=/usr/local/bin/postgres_exporter
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT

  svc_enable postgres_exporter
  open_port 9187
}

# ── MongoDB Exporter ──────────────────────────────────────────────────────────

install_mongodb_exporter() {
  step "mongodb_exporter ${MONGODB_EXPORTER_VERSION}"

  if already_installed /usr/local/bin/mongodb_exporter "$MONGODB_EXPORTER_VERSION"; then
    log "Already at ${MONGODB_EXPORTER_VERSION}, skipping"
  else
    local archive="mongodb_exporter-${MONGODB_EXPORTER_VERSION}.linux-${ARCH}.tar.gz"
    local csum_var="MONGODB_EXPORTER_CHECKSUM_${ARCH^^}"
    download_verify \
      "https://github.com/percona/mongodb_exporter/releases/download/v${MONGODB_EXPORTER_VERSION}/${archive}" \
      "/tmp/${archive}" "${!csum_var}"
    tar -xzf "/tmp/${archive}" -C /tmp
    install -o root -g root -m 0755 \
      "/tmp/mongodb_exporter-${MONGODB_EXPORTER_VERSION}.linux-${ARCH}/mongodb_exporter" \
      /usr/local/bin/mongodb_exporter
    rm -rf "/tmp/${archive}" "/tmp/mongodb_exporter-${MONGODB_EXPORTER_VERSION}.linux-${ARCH}"
  fi

  create_user mongodb_exporter
  install -d -m 0750 /etc/mongodb_exporter

  printf 'MONGODB_URI=%s\n' "$MONGODB_URI" \
    > /etc/mongodb_exporter/mongodb_exporter.env
  chmod 0600 /etc/mongodb_exporter/mongodb_exporter.env
  chown mongodb_exporter:mongodb_exporter /etc/mongodb_exporter/mongodb_exporter.env

  cat > /etc/systemd/system/mongodb_exporter.service << 'UNIT'
[Unit]
Description=MongoDB Exporter
After=network-online.target mongod.service
Wants=network-online.target

[Service]
User=mongodb_exporter
Group=mongodb_exporter
Type=simple
EnvironmentFile=/etc/mongodb_exporter/mongodb_exporter.env
ExecStart=/usr/local/bin/mongodb_exporter --collect-all
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT

  svc_enable mongodb_exporter
  open_port 9216
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
  echo -e "${BOLD}"
  echo "╔══════════════════════════════════════════════════╗"
  echo "║   Exporter Installer                             ║"
  echo "║   Rocky Linux / RHEL / AlmaLinux                 ║"
  echo "╚══════════════════════════════════════════════════╝"
  echo -e "${NC}"
  log "Arch: ${ARCH} | Monitoring server: ${MONITORING_SERVER_IP} | Log source: ${LOG_SOURCE}"

  preflight

  install_node_exporter
  install_alloy

  if has_postgres; then
    log "PostgreSQL detected → installing postgres_exporter"
    [[ "$POSTGRES_DSN" != *"CHANGE_ME"* ]] || \
      warn "POSTGRES_DSN contains CHANGE_ME — update before using in production"
    install_postgres_exporter
  else
    log "PostgreSQL not detected — skipping postgres_exporter"
  fi

  if has_mongodb; then
    log "MongoDB detected → installing mongodb_exporter"
    [[ "${MONGODB_EXPORTER_CHECKSUM_AMD64}" != "PLACEHOLDER"* ]] || \
      die "Set MONGODB_EXPORTER_CHECKSUM_${ARCH^^} before running. Get it from:\nhttps://github.com/percona/mongodb_exporter/releases/tag/v${MONGODB_EXPORTER_VERSION}"
    install_mongodb_exporter
  else
    log "MongoDB not detected — skipping mongodb_exporter"
  fi

  local server_ip
  server_ip=$(hostname -I | awk '{print $1}')
  echo ""
  echo -e "${GREEN}Installation complete!${NC}"
  echo ""
  printf "  %-20s http://%s:9100/metrics\n" "Node Exporter:" "$server_ip"
  printf "  %-20s http://%s:12345\n"        "Alloy UI:"      "$server_ip"
  systemctl is-active --quiet postgres_exporter 2>/dev/null && \
    printf "  %-20s http://%s:9187/metrics\n" "PG Exporter:" "$server_ip" || true
  systemctl is-active --quiet mongodb_exporter 2>/dev/null && \
    printf "  %-20s http://%s:9216/metrics\n" "Mongo Exporter:" "$server_ip" || true
  echo ""
  echo "  Logs ship to: http://${MONITORING_SERVER_IP}:3100"
}

main "$@"
