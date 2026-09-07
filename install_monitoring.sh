#!/usr/bin/env bash
# ==============================================================================
# install_monitoring.sh
# Installs full monitoring stack on the dedicated monitoring server.
# Components: Node Exporter, Prometheus, Alertmanager, Loki,
#             Blackbox Exporter, Grafana
#
# Target OS: Rocky Linux / RHEL / AlmaLinux
# Run as root: sudo bash install_monitoring.sh
# ==============================================================================
set -euo pipefail

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  CONFIGURATION — edit this section before running                          ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

MONITORING_HOST="192.168.88.11"      # This server's IP (used as Prometheus label)
CLUSTER_NAME="production"
RETENTION="30d"
SCRAPE_INTERVAL="15s"

# All target servers monitored by this stack.
# Must match what you put in install_exporters.sh MONITORING_SERVER_IP.
# Add app server IPs here as you deploy exporters on them.
TARGET_HOSTS=()

# Subsets of TARGET_HOSTS running those databases.
POSTGRES_HOSTS=()
MONGO_HOSTS=()

# Port numbers — must match install_exporters.sh defaults.
NODE_EXPORTER_PORT=9100
POSTGRES_EXPORTER_PORT=9187
MONGODB_EXPORTER_PORT=9216
ALLOY_PORT=12345

# Alertmanager webhooks to telegram-alertbot on localhost:5001.
# Configure BOT_TOKEN and CHAT_IDS in /opt/telegram-alertbot/.env
# after running install_bot.sh from the telegram-alertbot directory.

# Grafana
GRAFANA_ADMIN_USER="admin"
GRAFANA_ADMIN_PASSWORD="Trast2026!"
GRAFANA_SECRET_KEY="ApSySlMn+p/BNRWTGu3/rkuXmPPUQAxI/fHJeQhHGGY="
GRAFANA_DOMAIN="localhost"
GRAFANA_PORT=3000

# Dashboards to import from grafana.com (id:revision)
GRAFANA_DASHBOARDS=(
  "1860:37"   # Node Exporter Full
  "13639:2"   # Loki Logs
  "9628:7"    # PostgreSQL Exporter
  "7353:1"    # MongoDB Overview (percona)
)

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  VERSIONS — keep in sync with install_exporters.sh                         ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
NODE_EXPORTER_VERSION="1.11.0"
PROMETHEUS_VERSION="3.11.0"
ALERTMANAGER_VERSION="0.31.1"
LOKI_VERSION="3.7.1"
BLACKBOX_VERSION="0.28.0"
GRAFANA_VERSION="12.4.2"

NODE_EXPORTER_CHECKSUM_AMD64="4f8fbd23b8380b8fb720b125fb9029de261dc5fcd68bfe81ae010c0d32f5f6c3"
NODE_EXPORTER_CHECKSUM_ARM64="cd09ceffd418e91c25365ad008b2baac88fa1743632b71c620829d3d5596b141"
PROMETHEUS_CHECKSUM_AMD64="ff799c3e4c318e17dec14aaaa406a4da328fabb4578336b36d96d893870c3b76"
PROMETHEUS_CHECKSUM_ARM64="4d983175e77161e30b94922c49fdb681cf849439613d24a026bbb8d1ca4e8728"
ALERTMANAGER_CHECKSUM_AMD64="35191cbd9d4f8162458b78dd7e93990cccd246044d9a6f788adb1c66ac3ea07b"
ALERTMANAGER_CHECKSUM_ARM64="266dda88b64318c27847ef9af4ff450fc178c827550a8039420c5ca8657a4a8b"
LOKI_CHECKSUM_AMD64="ef027d63a625d5b74e917b72ae832f187f151e486de15f0515d6af1d6a56aa70"
LOKI_CHECKSUM_ARM64="7cc8c1246fa6466cbcf5c64898ba6e77f5ef20541fb156790eb20d7cd146638c"
BLACKBOX_CHECKSUM_AMD64="caf5d242fb1cf6d5cb678f3f799f22703d4fafea26b03dcbbd7e1f1825e06329"
BLACKBOX_CHECKSUM_ARM64="63312be0983d85e5109710a7dc93df3051157ae581853fa3655d171cc1b2806e"

# ══════════════════════════════════════════════════════════════════════════════
# INTERNALS — nothing to edit below
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
  for cmd in curl tar sha256sum systemctl useradd install; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  [[ ${#missing[@]} -eq 0 ]] || die "Missing required tools: ${missing[*]}"
  command -v unzip &>/dev/null || dnf install -y -q unzip   # needed for loki
  log "Pre-flight OK"
}

# ── Helpers ───────────────────────────────────────────────────────────────────

create_user() {
  id "$1" &>/dev/null || useradd --system --no-create-home --shell /sbin/nologin "$1"
}

download_verify() {
  local url=$1 dest=$2 expected=$3
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
  open_port "$NODE_EXPORTER_PORT"
}

# ── Prometheus ────────────────────────────────────────────────────────────────

install_prometheus() {
  step "Prometheus ${PROMETHEUS_VERSION}"

  if already_installed /usr/local/bin/prometheus "$PROMETHEUS_VERSION"; then
    log "Already at ${PROMETHEUS_VERSION}, skipping"
  else
    local archive="prometheus-${PROMETHEUS_VERSION}.linux-${ARCH}.tar.gz"
    local csum_var="PROMETHEUS_CHECKSUM_${ARCH^^}"
    download_verify \
      "https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/${archive}" \
      "/tmp/${archive}" "${!csum_var}"
    tar -xzf "/tmp/${archive}" -C /tmp
    install -o root -g root -m 0755 \
      "/tmp/prometheus-${PROMETHEUS_VERSION}.linux-${ARCH}/prometheus" /usr/local/bin/prometheus
    install -o root -g root -m 0755 \
      "/tmp/prometheus-${PROMETHEUS_VERSION}.linux-${ARCH}/promtool" /usr/local/bin/promtool
    rm -rf "/tmp/${archive}" "/tmp/prometheus-${PROMETHEUS_VERSION}.linux-${ARCH}"
  fi

  create_user prometheus
  install -d -o prometheus -g prometheus -m 0755 \
    /etc/prometheus /etc/prometheus/rules /var/lib/prometheus

  _write_prometheus_yml
  _write_alerting_rules
  _write_recording_rules

  cat > /etc/systemd/system/prometheus.service << UNIT
[Unit]
Description=Prometheus
After=network-online.target
Wants=network-online.target

[Service]
User=prometheus
Group=prometheus
Type=simple
ExecStart=/usr/local/bin/prometheus \\
  --config.file=/etc/prometheus/prometheus.yml \\
  --storage.tsdb.path=/var/lib/prometheus \\
  --storage.tsdb.retention.time=${RETENTION} \\
  --web.enable-lifecycle
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT

  svc_enable prometheus
  open_port 9090
}

_write_prometheus_yml() {
  log "Writing prometheus.yml..."
  local tmp=/tmp/prometheus.yml.$$

  cat > "$tmp" << EOF
global:
  scrape_interval: ${SCRAPE_INTERVAL}
  evaluation_interval: ${SCRAPE_INTERVAL}
  external_labels:
    cluster: "${CLUSTER_NAME}"
    env: production

rule_files:
  - /etc/prometheus/rules/*.yml

alerting:
  alertmanagers:
    - static_configs:
        - targets: ["localhost:9093"]

scrape_configs:

  - job_name: prometheus
    static_configs:
      - targets: ["localhost:9090"]

  - job_name: alertmanager
    static_configs:
      - targets: ["localhost:9093"]

  - job_name: loki
    static_configs:
      - targets: ["localhost:3100"]

  - job_name: blackbox_exporter
    static_configs:
      - targets: ["localhost:9115"]

  - job_name: node_exporter
    static_configs:
      - targets: ["localhost:${NODE_EXPORTER_PORT}"]
        labels:
          instance: "${MONITORING_HOST}"
EOF

  for host in "${TARGET_HOSTS[@]}"; do
    printf '      - targets: ["%s:%s"]\n        labels:\n          instance: "%s"\n' \
      "$host" "$NODE_EXPORTER_PORT" "$host" >> "$tmp"
  done

  cat >> "$tmp" << EOF

  - job_name: alloy
    static_configs:
EOF
  for host in "${TARGET_HOSTS[@]}"; do
    printf '      - targets: ["%s:%s"]\n        labels:\n          instance: "%s"\n' \
      "$host" "$ALLOY_PORT" "$host" >> "$tmp"
  done

  if [[ ${#POSTGRES_HOSTS[@]} -gt 0 ]]; then
    cat >> "$tmp" << EOF

  - job_name: postgres_exporter
    static_configs:
EOF
    for host in "${POSTGRES_HOSTS[@]}"; do
      printf '      - targets: ["%s:%s"]\n        labels:\n          instance: "%s"\n' \
        "$host" "$POSTGRES_EXPORTER_PORT" "$host" >> "$tmp"
    done
  fi

  if [[ ${#MONGO_HOSTS[@]} -gt 0 ]]; then
    cat >> "$tmp" << EOF

  - job_name: mongodb_exporter
    static_configs:
EOF
    for host in "${MONGO_HOSTS[@]}"; do
      printf '      - targets: ["%s:%s"]\n        labels:\n          instance: "%s"\n' \
        "$host" "$MONGODB_EXPORTER_PORT" "$host" >> "$tmp"
    done
  fi

  cat >> "$tmp" << 'EOF'

  - job_name: blackbox_http
    metrics_path: /probe
    static_configs:
      - targets:
          - "http://localhost:9090/-/healthy"
          - "http://localhost:9093/-/healthy"
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: "localhost:9115"

  - job_name: blackbox_tcp
    metrics_path: /probe
    params:
      module: [tcp_connect]
    static_configs:
      - targets:
          - "localhost:9090"
          - "localhost:9093"
          - "localhost:3000"
          - "localhost:3100"
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: "localhost:9115"
EOF

  promtool check config "$tmp" || die "prometheus.yml validation failed"
  install -o prometheus -g prometheus -m 0644 "$tmp" /etc/prometheus/prometheus.yml
  rm -f "$tmp"
}

_write_alerting_rules() {
  log "Writing alerting_rules.yml..."
  local tmp=/tmp/alerting_rules.yml.$$

  # Single-quoted heredoc: {{ }} go template syntax passes through unchanged.
  cat > "$tmp" << 'EOF'
groups:

  - name: instance_health
    rules:
      - alert: InstanceDown
        expr: up == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "{{ $labels.instance }} serveri ishlamayapti"
          description: "{{ $labels.job }} {{ $labels.instance }} serverida 2 daqiqadan beri javob bermayapti."

      - alert: HighCpuUsage
        expr: instance:node_cpu_utilisation:rate5m > 85
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "{{ $labels.instance }} serverida CPU yuklanishi yuqori"
          description: "CPU yuklanishi {{ printf \"%.1f\" $value }}% (chegara 85%)."

      - alert: HighMemoryUsage
        expr: instance:node_memory_utilisation:ratio * 100 > 85
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "{{ $labels.instance }} serverida xotira yuklanishi yuqori"
          description: "Xotira yuklanishi {{ printf \"%.1f\" $value }}% (chegara 85%)."

      - alert: DiskSpaceLow
        expr: >
          (1 - (node_filesystem_avail_bytes{fstype!~"tmpfs|devtmpfs"} /
          node_filesystem_size_bytes)) * 100 > 85
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "{{ $labels.instance }} serverida disk joyi kam"
          description: "{{ $labels.mountpoint }} {{ printf \"%.1f\" $value }}% to'lgan."

      - alert: DiskSpaceCritical
        expr: >
          (1 - (node_filesystem_avail_bytes{fstype!~"tmpfs|devtmpfs"} /
          node_filesystem_size_bytes)) * 100 > 95
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "{{ $labels.instance }} serverida disk joyi kritik darajada kam"
          description: "{{ $labels.mountpoint }} {{ printf \"%.1f\" $value }}% to'lgan — zudlik bilan harakat qiling."

      - alert: NodeHighLoadAverage
        expr: node_load1 / on(instance) count by(instance) (node_cpu_seconds_total{mode="idle"}) > 1.5
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "{{ $labels.instance }} serverida yuklama yuqori"
          description: "1 daqiqalik o'rtacha yuklama CPU sonidan {{ printf \"%.2f\" $value }} barobar yuqori."

      - alert: NodeOOMKillDetected
        expr: increase(node_vmstat_oom_kill[5m]) > 0
        for: 0m
        labels:
          severity: critical
        annotations:
          summary: "{{ $labels.instance }} serverida OOM kill aniqlandi"
          description: "{{ $labels.instance }} serverida so'nggi 5 daqiqada OOM killer ishga tushdi."

      - alert: NodeSystemdServiceFailed
        expr: node_systemd_unit_state{state="failed"} == 1
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "{{ $labels.instance }} serverida systemd xizmati ishlamay qoldi"
          description: "{{ $labels.name }} xizmati xato holatda."

  - name: postgres_health
    rules:
      - alert: PostgresDown
        expr: pg_up == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "{{ $labels.instance }} serverida PostgreSQL ishlamayapti"
          description: "{{ $labels.instance }} serverida postgres_exporter ulanolmayapti."

      - alert: PostgresTooManyConnections
        expr: pg_stat_database_numbackends / pg_settings_max_connections * 100 > 80
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "{{ $labels.instance }} serverida PostgreSQL ulanishlar soni ko'p"
          description: "max_connections ning {{ printf \"%.0f\" $value }}% ishlatilmoqda."

      - alert: PostgresDeadlocks
        expr: increase(pg_stat_database_deadlocks[5m]) > 0
        for: 0m
        labels:
          severity: warning
        annotations:
          summary: "{{ $labels.instance }} serverida PostgreSQL deadlock aniqlandi"
          description: "So'nggi 5 daqiqada {{ $value }} ta deadlock aniqlandi."

      - alert: PostgresLongRunningQueries
        expr: pg_stat_activity_max_tx_duration{state!="idle"} > 300
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "{{ $labels.instance }} serverida uzoq davom etayotgan so'rov"
          description: "So'rov {{ printf \"%.0f\" $value }} soniyadan beri ishlayapti."

  - name: mongodb_health
    rules:
      - alert: MongoDBDown
        expr: mongodb_up == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "{{ $labels.instance }} serverida MongoDB ishlamayapti"
          description: "{{ $labels.instance }} serverida mongodb_exporter ulanolmayapti."

      - alert: MongoDBTooManyConnections
        expr: mongodb_connections{state="current"} / mongodb_connections{state="available"} * 100 > 80
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "{{ $labels.instance }} serverida MongoDB ulanishlar soni ko'p"
          description: "Mavjud ulanishlarning {{ printf \"%.0f\" $value }}% ishlatilmoqda."

      - alert: MongoDBReplicationLag
        expr: >
          mongodb_mongod_replset_member_optime_date{state="PRIMARY"} -
          on(set) group_right
          mongodb_mongod_replset_member_optime_date{state="SECONDARY"} > 10
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "{{ $labels.instance }} serverida MongoDB replikatsiya kechikishi"
          description: "Kechikish {{ printf \"%.0f\" $value }} soniya (chegara 10 soniya)."

  - name: blackbox_probes
    rules:
      - alert: ProbeFailed
        expr: probe_success == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "Probe muvaffaqiyatsiz: {{ $labels.instance }}"
          description: "{{ $labels.instance }} manzili javob bermayapti."

      - alert: ProbeSlowHttp
        expr: probe_http_duration_seconds > 2
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Sekin HTTP javob: {{ $labels.instance }}"
          description: "Javob vaqti {{ printf \"%.2f\" $value }} soniya (chegara 2 soniya)."

      - alert: ProbeSslCertExpiringSoon
        expr: probe_ssl_earliest_cert_expiry - time() < 86400 * 14
        for: 0m
        labels:
          severity: warning
        annotations:
          summary: "SSL sertifikat muddati tugayapti: {{ $labels.instance }}"
          description: "{{ printf \"%.0f\" ($value / 86400) }} kun ichida muddati tugaydi."

      - alert: ProbeSslCertExpiryImminent
        expr: probe_ssl_earliest_cert_expiry - time() < 86400 * 3
        for: 0m
        labels:
          severity: critical
        annotations:
          summary: "SSL sertifikat muddati kritik darajada yaqin: {{ $labels.instance }}"
          description: "{{ printf \"%.0f\" ($value / 86400) }} kun ichida muddati tugaydi — zudlik bilan yangilang."

  - name: prometheus_health
    rules:
      - alert: Watchdog
        expr: vector(1)
        for: 0m
        labels:
          severity: none
        annotations:
          summary: "Ogohlantirishlar tizimi ishlayapti"
          description: "Prometheus → Alertmanager → Telegram zanjiri ishlayotganini tasdiqlaydi."

      - alert: PrometheusConfigReloadFailed
        expr: prometheus_config_last_reload_successful == 0
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Prometheus konfiguratsiyasi qayta yuklanmadi"
          description: "{{ $labels.instance }} serverida oxirgi qayta yuklash muvaffaqiyatsiz tugadi."

      - alert: LokiDown
        expr: up{job="loki"} == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "Loki ishlamayapti"
          description: "Loki log yig'ish xizmati javob bermayapti — loglar pipeline'i buzilgan."
EOF

  promtool check rules "$tmp" || die "alerting_rules.yml validation failed"
  install -o prometheus -g prometheus -m 0644 "$tmp" /etc/prometheus/rules/alerting_rules.yml
  rm -f "$tmp"
}

_write_recording_rules() {
  log "Writing recording_rules.yml..."
  local tmp=/tmp/recording_rules.yml.$$

  cat > "$tmp" << 'EOF'
groups:
  - name: node_recording
    rules:
      - record: instance:node_cpu_utilisation:rate5m
        expr: 100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

      - record: instance:node_memory_utilisation:ratio
        expr: 1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)

      - record: instance:node_filesystem_avail:ratio
        expr: min by(instance) (node_filesystem_avail_bytes{fstype!~"tmpfs|devtmpfs"} / node_filesystem_size_bytes)

      - record: instance:node_network_receive_bytes:rate5m
        expr: rate(node_network_receive_bytes_total{device!="lo"}[5m])

      - record: instance:node_network_transmit_bytes:rate5m
        expr: rate(node_network_transmit_bytes_total{device!="lo"}[5m])
EOF

  promtool check rules "$tmp" || die "recording_rules.yml validation failed"
  install -o prometheus -g prometheus -m 0644 "$tmp" /etc/prometheus/rules/recording_rules.yml
  rm -f "$tmp"
}

# ── Alertmanager ──────────────────────────────────────────────────────────────

install_alertmanager() {
  step "Alertmanager ${ALERTMANAGER_VERSION}"

  if already_installed /usr/local/bin/alertmanager "$ALERTMANAGER_VERSION"; then
    log "Already at ${ALERTMANAGER_VERSION}, skipping"
  else
    local archive="alertmanager-${ALERTMANAGER_VERSION}.linux-${ARCH}.tar.gz"
    local csum_var="ALERTMANAGER_CHECKSUM_${ARCH^^}"
    download_verify \
      "https://github.com/prometheus/alertmanager/releases/download/v${ALERTMANAGER_VERSION}/${archive}" \
      "/tmp/${archive}" "${!csum_var}"
    tar -xzf "/tmp/${archive}" -C /tmp
    install -o root -g root -m 0755 \
      "/tmp/alertmanager-${ALERTMANAGER_VERSION}.linux-${ARCH}/alertmanager" /usr/local/bin/alertmanager
    install -o root -g root -m 0755 \
      "/tmp/alertmanager-${ALERTMANAGER_VERSION}.linux-${ARCH}/amtool" /usr/local/bin/amtool
    rm -rf "/tmp/${archive}" "/tmp/alertmanager-${ALERTMANAGER_VERSION}.linux-${ARCH}"
  fi

  create_user alertmanager
  install -d -o alertmanager -g alertmanager -m 0755 /etc/alertmanager /var/lib/alertmanager

  # Alertmanager sends to telegram-alertbot (runs on localhost:5001).
  # Formatting is handled by the bot — alertmanager.yml stays clean.
  cat > /etc/alertmanager/alertmanager.yml << 'EOF'
global:
  resolve_timeout: 5m

route:
  group_by: ['alertname', 'instance', 'severity']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  receiver: telegram-bot

  routes:
    - matchers:
        - alertname="Watchdog"
      receiver: blackhole

receivers:
  - name: telegram-bot
    webhook_configs:
      - url: "http://127.0.0.1:5001/alert"
        send_resolved: true

  - name: blackhole

inhibit_rules:
  - source_matchers:
      - severity="critical"
    target_matchers:
      - severity="warning"
    equal:
      - instance
EOF

  cat > /etc/systemd/system/alertmanager.service << 'UNIT'
[Unit]
Description=Alertmanager
After=network-online.target
Wants=network-online.target

[Service]
User=alertmanager
Group=alertmanager
Type=simple
ExecStart=/usr/local/bin/alertmanager \
  --config.file=/etc/alertmanager/alertmanager.yml \
  --storage.path=/var/lib/alertmanager
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT

  svc_enable alertmanager
  open_port 9093
}

# ── Loki ──────────────────────────────────────────────────────────────────────

install_loki() {
  step "Loki ${LOKI_VERSION}"

  if already_installed /usr/local/bin/loki "$LOKI_VERSION"; then
    log "Already at ${LOKI_VERSION}, skipping"
  else
    local archive="loki-linux-${ARCH}.zip"
    local csum_var="LOKI_CHECKSUM_${ARCH^^}"
    download_verify \
      "https://github.com/grafana/loki/releases/download/v${LOKI_VERSION}/${archive}" \
      "/tmp/${archive}" "${!csum_var}"
    command -v unzip &>/dev/null || dnf install -y -q unzip
    unzip -o "/tmp/${archive}" "loki-linux-${ARCH}" -d /tmp
    install -o root -g root -m 0755 "/tmp/loki-linux-${ARCH}" /usr/local/bin/loki
    rm -f "/tmp/${archive}" "/tmp/loki-linux-${ARCH}"
  fi

  create_user loki
  install -d -o loki -g loki -m 0755 /etc/loki /var/lib/loki

  cat > /etc/loki/loki.yml << EOF
auth_enabled: false

server:
  http_listen_port: 3100
  grpc_listen_port: 9096
  log_level: warn

common:
  instance_addr: 127.0.0.1
  path_prefix: /var/lib/loki
  storage:
    filesystem:
      chunks_directory: /var/lib/loki/chunks
      rules_directory: /var/lib/loki/rules
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory

query_range:
  results_cache:
    cache:
      embedded_cache:
        enabled: true
        max_size_mb: 100

schema_config:
  configs:
    - from: 2020-10-24
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

ruler:
  alertmanager_url: http://localhost:9093

compactor:
  working_directory: /var/lib/loki/compactor
  delete_request_store: filesystem

limits_config:
  retention_period: ${RETENTION}
  ingestion_rate_mb: 16
  ingestion_burst_size_mb: 32
  max_query_series: 5000
  max_query_parallelism: 4
EOF

  cat > /etc/systemd/system/loki.service << 'UNIT'
[Unit]
Description=Loki
After=network-online.target
Wants=network-online.target

[Service]
User=loki
Group=loki
Type=simple
ExecStart=/usr/local/bin/loki --config.file=/etc/loki/loki.yml
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT

  svc_enable loki
  open_port 3100
}

# ── Blackbox Exporter ─────────────────────────────────────────────────────────

install_blackbox() {
  step "Blackbox Exporter ${BLACKBOX_VERSION}"

  if already_installed /usr/local/bin/blackbox_exporter "$BLACKBOX_VERSION"; then
    log "Already at ${BLACKBOX_VERSION}, skipping"
  else
    local archive="blackbox_exporter-${BLACKBOX_VERSION}.linux-${ARCH}.tar.gz"
    local csum_var="BLACKBOX_CHECKSUM_${ARCH^^}"
    download_verify \
      "https://github.com/prometheus/blackbox_exporter/releases/download/v${BLACKBOX_VERSION}/${archive}" \
      "/tmp/${archive}" "${!csum_var}"
    tar -xzf "/tmp/${archive}" -C /tmp
    install -o root -g root -m 0755 \
      "/tmp/blackbox_exporter-${BLACKBOX_VERSION}.linux-${ARCH}/blackbox_exporter" \
      /usr/local/bin/blackbox_exporter
    rm -rf "/tmp/${archive}" "/tmp/blackbox_exporter-${BLACKBOX_VERSION}.linux-${ARCH}"
  fi

  create_user blackbox_exporter
  install -d -o blackbox_exporter -g blackbox_exporter -m 0755 /etc/blackbox_exporter

  cat > /etc/blackbox_exporter/blackbox.yml << 'EOF'
modules:
  http_2xx:
    prober: http
    timeout: 5s
    http:
      valid_status_codes: [200]
      follow_redirects: true
      preferred_ip_protocol: ip4

  http_2xx_or_401:
    prober: http
    timeout: 5s
    http:
      valid_status_codes: [200, 401]
      follow_redirects: true
      preferred_ip_protocol: ip4

  http_2xx_insecure:
    prober: http
    timeout: 5s
    http:
      valid_status_codes: [200]
      tls_config:
        insecure_skip_verify: true

  tcp_connect:
    prober: tcp
    timeout: 5s

  icmp:
    prober: icmp
    timeout: 5s
EOF

  # CAP_NET_RAW needed for ICMP probes
  cat > /etc/systemd/system/blackbox_exporter.service << 'UNIT'
[Unit]
Description=Blackbox Exporter
After=network-online.target
Wants=network-online.target

[Service]
User=blackbox_exporter
Group=blackbox_exporter
Type=simple
ExecStart=/usr/local/bin/blackbox_exporter --config.file=/etc/blackbox_exporter/blackbox.yml
Restart=on-failure
RestartSec=5s
AmbientCapabilities=CAP_NET_RAW

[Install]
WantedBy=multi-user.target
UNIT

  svc_enable blackbox_exporter
  open_port 9115
}

# ── Grafana ───────────────────────────────────────────────────────────────────

install_grafana() {
  step "Grafana ${GRAFANA_VERSION}"

  if rpm -q grafana &>/dev/null && rpm -q grafana | grep -qF "$GRAFANA_VERSION"; then
    log "Already at ${GRAFANA_VERSION}, skipping"
  else
    local rpm_arch="x86_64"
    [[ "$ARCH" == "arm64" ]] && rpm_arch="aarch64"
    local rpm_file="grafana-${GRAFANA_VERSION}-1.${rpm_arch}.rpm"
    log "Downloading Grafana RPM..."
    curl -fsSL --retry 3 \
      "https://dl.grafana.com/oss/release/${rpm_file}" \
      -o "/tmp/${rpm_file}"
    dnf install -y "/tmp/${rpm_file}"
    rm -f "/tmp/${rpm_file}"
  fi

  _configure_grafana
  systemctl daemon-reload
  systemctl enable --now grafana-server
  open_port "$GRAFANA_PORT"
  log "grafana-server enabled and started"

  _import_grafana_dashboards
}

_configure_grafana() {
  log "Configuring grafana.ini..."
  local ini=/etc/grafana/grafana.ini

  # Patch in-place — RPM ships the full ini with commented defaults.
  sed -i "s|^;\\?admin_user =.*|admin_user = ${GRAFANA_ADMIN_USER}|"       "$ini"
  sed -i "s|^;\\?admin_password =.*|admin_password = ${GRAFANA_ADMIN_PASSWORD}|" "$ini"
  sed -i "s|^;\\?secret_key =.*|secret_key = ${GRAFANA_SECRET_KEY}|"       "$ini"
  sed -i "s|^;\\?domain =.*|domain = ${GRAFANA_DOMAIN}|"                   "$ini"

  install -d -m 0755 \
    /etc/grafana/provisioning/datasources \
    /etc/grafana/provisioning/dashboards

  cat > /etc/grafana/provisioning/datasources/datasources.yml << 'EOF'
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    uid: prometheus
    access: proxy
    url: http://localhost:9090
    isDefault: true
    jsonData:
      timeInterval: "15s"
      httpMethod: POST
    editable: false

  - name: Loki
    type: loki
    uid: loki
    access: proxy
    url: http://localhost:3100
    jsonData:
      maxLines: 1000
    editable: false
EOF

  chown -R grafana:grafana /etc/grafana/provisioning 2>/dev/null || true
}

_import_grafana_dashboards() {
  [[ ${#GRAFANA_DASHBOARDS[@]} -gt 0 ]] || return 0

  log "Waiting for Grafana API to be ready..."
  local i=0
  until curl -sf "http://localhost:${GRAFANA_PORT}/api/health" &>/dev/null; do
    i=$((i + 1))
    [[ $i -lt 30 ]] || die "Grafana not ready after 150s"
    sleep 5
  done

  for entry in "${GRAFANA_DASHBOARDS[@]}"; do
    local dash_id="${entry%%:*}"
    local dash_rev="${entry##*:}"
    log "Importing dashboard ${dash_id} rev ${dash_rev}..."

    curl -fsSL \
      "https://grafana.com/api/dashboards/${dash_id}/revisions/${dash_rev}/download" \
      -o "/tmp/dash_${dash_id}.json"

    local body
    body=$(cat "/tmp/dash_${dash_id}.json")

    curl -sf \
      -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}" \
      -H "Content-Type: application/json" \
      "http://localhost:${GRAFANA_PORT}/api/dashboards/import" \
      -d "{
        \"dashboard\": ${body},
        \"overwrite\": true,
        \"inputs\": [
          {\"name\":\"DS_PROMETHEUS\",             \"type\":\"datasource\",\"pluginId\":\"prometheus\",\"value\":\"prometheus\"},
          {\"name\":\"DS_LOKI\",                   \"type\":\"datasource\",\"pluginId\":\"loki\",      \"value\":\"loki\"},
          {\"name\":\"DS_GRAFANA_LOKI_DATASOURCE\",\"type\":\"datasource\",\"pluginId\":\"loki\",      \"value\":\"loki\"}
        ],
        \"folderId\": 0
      }" > /dev/null

    rm -f "/tmp/dash_${dash_id}.json"
    log "  Dashboard ${dash_id} imported"
  done
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
  echo -e "${BOLD}"
  echo "╔══════════════════════════════════════════════════╗"
  echo "║   Monitoring Stack Installer                     ║"
  echo "║   Rocky Linux / RHEL / AlmaLinux                 ║"
  echo "╚══════════════════════════════════════════════════╝"
  echo -e "${NC}"
  log "Arch: ${ARCH} | Cluster: ${CLUSTER_NAME} | Targets: ${#TARGET_HOSTS[@]}"

  preflight

  warn "After this completes, run install_bot.sh from the telegram-alertbot directory"
  [[ "$GRAFANA_ADMIN_PASSWORD" != "CHANGE_ME" ]] || \
    warn "GRAFANA_ADMIN_PASSWORD is default — change before exposing to network"

  install_node_exporter
  install_prometheus
  install_alertmanager
  install_loki
  install_blackbox
  install_grafana

  local server_ip
  server_ip=$(hostname -I | awk '{print $1}')
  echo ""
  echo -e "${GREEN}Installation complete!${NC}"
  echo ""
  printf "  %-16s http://%s:9090\n"  "Prometheus:"   "$server_ip"
  printf "  %-16s http://%s:9093\n"  "Alertmanager:" "$server_ip"
  printf "  %-16s http://%s:3100\n"  "Loki:"         "$server_ip"
  printf "  %-16s http://%s:9115\n"  "Blackbox:"     "$server_ip"
  printf "  %-16s http://%s:%s\n"    "Grafana:"      "$server_ip" "$GRAFANA_PORT"
  echo "  Grafana login: ${GRAFANA_ADMIN_USER} / ${GRAFANA_ADMIN_PASSWORD}"
}

main "$@"
