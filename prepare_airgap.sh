#!/usr/bin/env bash
# ==============================================================================
# prepare_airgap.sh
# Run on an internet-connected machine.
# Downloads binaries, splits into paste-able chunks for air-gapped servers.
#
# Usage:
#   bash prepare_airgap.sh                    # amd64 only
#   bash prepare_airgap.sh --arch arm64
#   bash prepare_airgap.sh --arch all
#   bash prepare_airgap.sh --lines 50000      # lines per chunk (default: 50000)
# ==============================================================================
set -euo pipefail

ARCHES=("amd64")
CHUNK_LINES=50000
OUT_DIR="airgap_output"

while [[ $# -gt 0 ]]; do
  case $1 in
    --arch)  [[ "$2" == "all" ]] && ARCHES=(amd64 arm64) || ARCHES=("$2"); shift 2 ;;
    --lines) CHUNK_LINES="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

NODE_EXPORTER_VERSION="1.11.0"
ALLOY_VERSION="1.16.1"
POSTGRES_EXPORTER_VERSION="0.16.0"
MONGODB_EXPORTER_VERSION="0.40.0"

TMPDIR_WORK=$(mktemp -d)
trap 'rm -rf "$TMPDIR_WORK"' EXIT

GREEN='\033[0;32m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
die()  { echo -e "\033[0;31m[✗]${NC} $*" >&2; exit 1; }

command -v curl   &>/dev/null || die "curl required"
command -v gzip   &>/dev/null || die "gzip required"
command -v base64 &>/dev/null || die "base64 required"
command -v split  &>/dev/null || die "split required"
command -v tar    &>/dev/null || die "tar required"
command -v unzip  &>/dev/null || die "unzip required"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR/chunks"

fetch() {
  local url=$1 dest=$2
  log "Downloading $(basename "$dest")..."
  curl -fsSL --retry 3 --retry-delay 2 "$url" -o "$dest"
}

# Compress + encode binary, write chunks to OUT_DIR/chunks/BLOB_NAME_aa/ab/ac...
# Returns number of chunks written
make_chunks() {
  local binary=$1    # path to binary
  local blob_name=$2 # e.g. node_exporter_amd64

  log "Encoding ${blob_name}..."
  local encoded_file="$TMPDIR_WORK/${blob_name}.b64"
  gzip -c "$binary" | base64 > "$encoded_file"

  local total_lines
  total_lines=$(wc -l < "$encoded_file")
  local size
  size=$(du -sh "$encoded_file" | cut -f1)
  log "${blob_name}: ${size} base64 (${total_lines} lines → $(( (total_lines + CHUNK_LINES - 1) / CHUNK_LINES )) chunks)"

  split -l "$CHUNK_LINES" -d -a 3 "$encoded_file" "$OUT_DIR/chunks/${blob_name}_"
}

# Generate paste shell scripts for all chunks of a blob
gen_paste_scripts() {
  local blob_name=$1  # e.g. node_exporter_amd64
  local step_prefix=$2 # e.g. 01

  local chunks=( "$OUT_DIR/chunks/${blob_name}_"* )
  local total=${#chunks[@]}
  local i=1

  for chunk_file in "${chunks[@]}"; do
    local seq
    seq=$(printf "%03d" "$i")
    local out_script="${OUT_DIR}/step_${step_prefix}_${blob_name}_${seq}.sh"

    if [[ $i -eq 1 ]]; then
      # First chunk: overwrite
      cat > "$out_script" << SHEOF
#!/usr/bin/env bash
# Chunk ${i}/${total} of ${blob_name}
# Paste this entire file into the server terminal
cat > /tmp/blob_${blob_name}.b64 << 'BLOBEOF'
SHEOF
    else
      # Subsequent chunks: append
      cat > "$out_script" << SHEOF
#!/usr/bin/env bash
# Chunk ${i}/${total} of ${blob_name}
# Paste this entire file into the server terminal
cat >> /tmp/blob_${blob_name}.b64 << 'BLOBEOF'
SHEOF
    fi

    cat "$chunk_file" >> "$out_script"
    echo "BLOBEOF" >> "$out_script"

    i=$(( i + 1 ))
  done

  echo "$total"
}

STEP=1
declare -A BINARY_CHUNKS  # blob_name -> chunk count

for ARCH in "${ARCHES[@]}"; do
  log "━━━ arch: ${ARCH} ━━━"

  # ── node_exporter ────────────────────────────────────────────────────────────
  NE_ARCHIVE="node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}.tar.gz"
  fetch "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/${NE_ARCHIVE}" \
        "$TMPDIR_WORK/$NE_ARCHIVE"
  tar -xzf "$TMPDIR_WORK/$NE_ARCHIVE" -C "$TMPDIR_WORK"
  NE_BINARY="$TMPDIR_WORK/node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}/node_exporter"
  make_chunks "$NE_BINARY" "node_exporter_${ARCH}"
  STEP_PAD=$(printf "%02d" "$STEP")
  COUNT=$(gen_paste_scripts "node_exporter_${ARCH}" "$STEP_PAD")
  BINARY_CHUNKS["node_exporter_${ARCH}"]=$COUNT
  STEP=$(( STEP + 1 ))

  # ── alloy ────────────────────────────────────────────────────────────────────
  ALLOY_ARCHIVE="alloy-linux-${ARCH}.zip"
  fetch "https://github.com/grafana/alloy/releases/download/v${ALLOY_VERSION}/${ALLOY_ARCHIVE}" \
        "$TMPDIR_WORK/$ALLOY_ARCHIVE"
  unzip -o "$TMPDIR_WORK/$ALLOY_ARCHIVE" "alloy-linux-${ARCH}" -d "$TMPDIR_WORK" >/dev/null
  make_chunks "$TMPDIR_WORK/alloy-linux-${ARCH}" "alloy_${ARCH}"
  STEP_PAD=$(printf "%02d" "$STEP")
  COUNT=$(gen_paste_scripts "alloy_${ARCH}" "$STEP_PAD")
  BINARY_CHUNKS["alloy_${ARCH}"]=$COUNT
  STEP=$(( STEP + 1 ))

  # ── postgres_exporter ────────────────────────────────────────────────────────
  PG_ARCHIVE="postgres_exporter-${POSTGRES_EXPORTER_VERSION}.linux-${ARCH}.tar.gz"
  fetch "https://github.com/prometheus-community/postgres_exporter/releases/download/v${POSTGRES_EXPORTER_VERSION}/${PG_ARCHIVE}" \
        "$TMPDIR_WORK/$PG_ARCHIVE"
  tar -xzf "$TMPDIR_WORK/$PG_ARCHIVE" -C "$TMPDIR_WORK"
  PG_BINARY="$TMPDIR_WORK/postgres_exporter-${POSTGRES_EXPORTER_VERSION}.linux-${ARCH}/postgres_exporter"
  make_chunks "$PG_BINARY" "postgres_exporter_${ARCH}"
  STEP_PAD=$(printf "%02d" "$STEP")
  COUNT=$(gen_paste_scripts "postgres_exporter_${ARCH}" "$STEP_PAD")
  BINARY_CHUNKS["postgres_exporter_${ARCH}"]=$COUNT
  STEP=$(( STEP + 1 ))

  # ── mongodb_exporter (optional) ──────────────────────────────────────────────
  MG_ARCHIVE="mongodb_exporter-${MONGODB_EXPORTER_VERSION}.linux-${ARCH}.tar.gz"
  if curl -fsSL --retry 2 \
       "https://github.com/percona/mongodb_exporter/releases/download/v${MONGODB_EXPORTER_VERSION}/${MG_ARCHIVE}" \
       -o "$TMPDIR_WORK/$MG_ARCHIVE" 2>/dev/null; then
    tar -xzf "$TMPDIR_WORK/$MG_ARCHIVE" -C "$TMPDIR_WORK"
    # percona uses different dir structure — find the binary
    MG_BINARY=$(find "$TMPDIR_WORK" -name "mongodb_exporter" -type f | head -1)
    if [[ -n "$MG_BINARY" ]]; then
      make_chunks "$MG_BINARY" "mongodb_exporter_${ARCH}"
      STEP_PAD=$(printf "%02d" "$STEP")
      COUNT=$(gen_paste_scripts "mongodb_exporter_${ARCH}" "$STEP_PAD")
      BINARY_CHUNKS["mongodb_exporter_${ARCH}"]=$COUNT
      STEP=$(( STEP + 1 ))
    fi
  else
    log "Warning: mongodb_exporter download failed — skipping"
  fi
done

# ── Generate the installer script ─────────────────────────────────────────────
log "Writing installer script..."

cat > "$OUT_DIR/step_00_PASTE_FIRST_installer.sh" << 'INSTALLER_WRAPPER'
#!/usr/bin/env bash
# ============================================================
# STEP 0 — Paste this FIRST into the server terminal
# Creates /tmp/install_exporters.sh on the server
# ============================================================
cat > /tmp/install_exporters.sh << 'ENDOFSCRIPT'
INSTALLER_WRAPPER

cat >> "$OUT_DIR/step_00_PASTE_FIRST_installer.sh" << 'INSTALLER_BODY'
#!/usr/bin/env bash
# ==============================================================================
# install_exporters.sh (air-gap mode) — generated by prepare_airgap.sh
# Expects blob files in /tmp/blob_BINARY_ARCH.b64 (assembled from paste chunks)
# ==============================================================================
set -euo pipefail

# ── CONFIGURATION ─────────────────────────────────────────────────────────────
MONITORING_SERVER_IP="192.168.88.11"
LOG_SOURCE="docker"
FILE_LOG_PATHS=(
  "/var/log/*.log"
  "/var/log/app/*.log"
)
POSTGRES_DSN="postgresql://postgres_exporter:CHANGE_ME@localhost:5432/postgres?sslmode=disable"
MONGODB_URI="mongodb://localhost:27017/"

# ── INTERNALS ─────────────────────────────────────────────────────────────────
ARCH_RAW=$(uname -m)
[[ "$ARCH_RAW" == "aarch64" ]] && ARCH="arm64" || ARCH="amd64"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }
step() { echo -e "\n${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n${BOLD}   $*${NC}\n${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

[[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0"

preflight() {
  local missing=()
  for cmd in gzip base64 tar systemctl useradd install ss; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  [[ ${#missing[@]} -eq 0 ]] || die "Missing: ${missing[*]}"
  log "Pre-flight OK | arch=${ARCH}"
}

create_user() {
  id "$1" &>/dev/null || useradd --system --no-create-home --shell /sbin/nologin "$1"
}

# Decode gzip+base64 blob file → install binary
install_from_blob() {
  local blob_name=$1 dest=$2
  local blob_file="/tmp/blob_${blob_name}_${ARCH}.b64"
  [[ -f "$blob_file" ]] || die "Blob not found: ${blob_file}\nDid you paste all chunks for ${blob_name}_${ARCH}?"
  log "Installing $(basename "$dest") from blob..."
  base64 -d < "$blob_file" | gzip -d > "$dest"
  chmod 0755 "$dest"
  rm -f "$blob_file"
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
  step "Node Exporter"
  install_from_blob "node_exporter" /usr/local/bin/node_exporter
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
  step "Alloy (log shipping to ${MONITORING_SERVER_IP})"
  install_from_blob "alloy" /usr/local/bin/alloy
  create_user alloy
  install -d -o alloy -g alloy -m 0755 /etc/alloy /var/lib/alloy
  _write_alloy_config

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

  cat > /etc/alloy/config.alloy << EOF
// Alloy config — generated by install_exporters.sh (airgap)
// Host: ${hostname} | Loki: ${loki_url}

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
    local path_entries=""
    for p in "${FILE_LOG_PATHS[@]}"; do
      path_entries+="{\"__path__\" = \"${p}\", \"host\" = \"${hostname}\", \"job\" = \"file\"},"$'\n    '
    done
    cat >> /etc/alloy/config.alloy << EOF
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
  step "postgres_exporter"
  install_from_blob "postgres_exporter" /usr/local/bin/postgres_exporter
  create_user postgres_exporter
  install -d -m 0750 /etc/postgres_exporter

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
  step "mongodb_exporter"
  install_from_blob "mongodb_exporter" /usr/local/bin/mongodb_exporter
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
  echo "║   Exporter Installer (AIR-GAP)                   ║"
  echo "║   Rocky / RHEL / AlmaLinux / Ubuntu              ║"
  echo "╚══════════════════════════════════════════════════╝"
  echo -e "${NC}"
  log "Arch: ${ARCH} | Monitoring: ${MONITORING_SERVER_IP} | Logs: ${LOG_SOURCE}"

  preflight
  install_node_exporter
  install_alloy

  if has_postgres; then
    log "PostgreSQL detected → installing postgres_exporter"
    [[ "$POSTGRES_DSN" != *"CHANGE_ME"* ]] || \
      warn "POSTGRES_DSN contains CHANGE_ME — update before production"
    install_postgres_exporter
  else
    log "PostgreSQL not detected — skipping"
  fi

  if has_mongodb; then
    local blob_file="/tmp/blob_mongodb_exporter_${ARCH}.b64"
    if [[ -f "$blob_file" ]]; then
      log "MongoDB detected → installing mongodb_exporter"
      install_mongodb_exporter
    else
      warn "MongoDB detected but no mongodb_exporter blob found — skipping"
    fi
  else
    log "MongoDB not detected — skipping"
  fi

  local server_ip
  server_ip=$(hostname -I | awk '{print $1}')
  echo ""
  echo -e "${GREEN}Installation complete!${NC}"
  echo ""
  printf "  %-22s http://%s:9100/metrics\n" "Node Exporter:" "$server_ip"
  printf "  %-22s http://%s:12345\n"        "Alloy UI:"      "$server_ip"
  systemctl is-active --quiet postgres_exporter 2>/dev/null && \
    printf "  %-22s http://%s:9187/metrics\n" "PG Exporter:"   "$server_ip" || true
  systemctl is-active --quiet mongodb_exporter  2>/dev/null && \
    printf "  %-22s http://%s:9216/metrics\n" "Mongo Exporter:" "$server_ip" || true
  echo ""
  echo "  Logs → http://${MONITORING_SERVER_IP}:3100"
}

main "$@"
INSTALLER_BODY

echo "ENDOFSCRIPT" >> "$OUT_DIR/step_00_PASTE_FIRST_installer.sh"
echo 'chmod +x /tmp/install_exporters.sh' >> "$OUT_DIR/step_00_PASTE_FIRST_installer.sh"
echo 'echo "[+] Installer saved to /tmp/install_exporters.sh"' >> "$OUT_DIR/step_00_PASTE_FIRST_installer.sh"

# ── Generate final run script ─────────────────────────────────────────────────
cat > "$OUT_DIR/step_99_RUN_LAST.sh" << 'RUNSCRIPT'
#!/usr/bin/env bash
# ============================================================
# FINAL STEP — Paste this LAST to run the installer
# ============================================================
sudo bash /tmp/install_exporters.sh
RUNSCRIPT

# ── Print summary ─────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  Generated: ${OUT_DIR}/${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Paste order on air-gapped server:"
echo "  1. step_00_PASTE_FIRST_installer.sh   ← creates /tmp/install_exporters.sh"

STEP_NUM=2
for key in $(echo "${!BINARY_CHUNKS[@]}" | tr ' ' '\n' | sort); do
  COUNT=${BINARY_CHUNKS[$key]}
  echo "  ${STEP_NUM}. ${key}: ${COUNT} chunk(s) to paste"
  STEP_NUM=$(( STEP_NUM + 1 ))
done

echo "  ${STEP_NUM}. step_99_RUN_LAST.sh                ← runs the installer"
echo ""
echo "  Total paste operations: $(ls "$OUT_DIR"/*.sh | wc -l)"
echo ""
ls -lh "$OUT_DIR"/*.sh | awk '{print "  "$NF, $5}'
echo ""
