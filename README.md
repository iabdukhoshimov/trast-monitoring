# trast-monitoring

Production monitoring stack for Rocky Linux — Prometheus, Alertmanager, Loki, Grafana, Blackbox Exporter, Node Exporter, Postgres Exporter, MongoDB Exporter.

Alerts are forwarded to Telegram via [telegram-alert-trast](https://github.com/iabdukhoshimov/telegram-alert-trast).

## Architecture

```
Target Servers                    Monitoring Server
──────────────                    ─────────────────
node_exporter   ──scrape──►  Prometheus ──► Alertmanager
postgres_exporter              │                │
mongodb_exporter               │                ▼
alloy (logs) ──push──►  Loki   │         telegram-alertbot
                               │                │
                               ▼                ▼
                            Grafana         Telegram
```

## Deploy — shell scripts (no SSH required)

Use this path when port 22 is blocked between servers.

### 1. Monitoring server

Edit the config section at the top of `install_monitoring.sh`:

```bash
MONITORING_HOST="10.0.0.1"        # this server's IP
CLUSTER_NAME="production"
TARGET_HOSTS=("app1" "app2")      # app server IPs/hostnames
POSTGRES_HOSTS=("app1")           # subset with PostgreSQL
MONGO_HOSTS=("app2")              # subset with MongoDB

GRAFANA_ADMIN_PASSWORD="yourpassword"
GRAFANA_SECRET_KEY="$(openssl rand -base64 32)"
```

Then run:

```bash
bash install_monitoring.sh
```

### 2. Telegram alert bot

```bash
cd /path/to/telegram-alert-trast
bash install_bot.sh

# Fill in real credentials
sudo nano /opt/telegram-alertbot/.env
# BOT_TOKEN=...
# CHAT_IDS=...

sudo systemctl start telegram_alertbot
sudo systemctl status telegram_alertbot
```

### 3. Target servers (app servers)

Edit the config section at the top of `install_exporters.sh`:

```bash
MONITORING_SERVER_IP="10.0.0.1"
POSTGRES_DSN="postgresql://postgres_exporter:password@localhost:5432/postgres?sslmode=disable"
```

Then run on each app server:

```bash
bash install_exporters.sh
```

Script auto-detects PostgreSQL and MongoDB and installs the relevant exporters.

---

## Deploy — Ansible (when port 22 is available)

### Prerequisites

```bash
pip install ansible ansible-lint
ansible-galaxy install -r requirements.yml
```

### Configure

```bash
# Edit inventory
nano inventories/production/hosts.ini

# Fill secrets
nano inventories/production/group_vars/all/vault.yml
ansible-vault encrypt inventories/production/group_vars/all/vault.yml

# Edit group vars if needed
nano inventories/production/group_vars/monitoring/main.yml
```

### Run

```bash
# Monitoring server
ansible-playbook -i inventories/production playbooks/monitoring_server.yml --ask-vault-pass

# Target servers
ansible-playbook -i inventories/production playbooks/target_servers.yml --ask-vault-pass
```

---

## Services and ports

| Service | Port | URL |
|---------|------|-----|
| Grafana | 3000 | `http://server:3000` |
| Prometheus | 9090 | `http://server:9090` |
| Alertmanager | 9093 | `http://server:9093` |
| Loki | 3100 | internal only |
| Node Exporter | 9100 | internal only |
| Postgres Exporter | 9187 | internal only |
| MongoDB Exporter | 9216 | internal only |
| Alloy (logs) | 12345 | internal only |
| Telegram bot | 5001 | localhost only |

## Alert flow

```
Prometheus detects issue
  → fires alert to Alertmanager (port 9093)
  → Alertmanager sends webhook to telegram-alertbot (port 5001)
  → bot formats message in Uzbek/English
  → sends to Telegram chat
```

## Grafana dashboards (auto-imported)

| Dashboard | ID |
|-----------|----|
| Node Exporter Full | 1860 |
| Loki Logs | 13639 |
| PostgreSQL Exporter | 9628 |
| MongoDB Overview | 7353 |

## Security notes

- `vault.yml` must be ansible-vault encrypted before committing real credentials
- Loki, exporters, and telegram-alertbot bind to localhost only
- Grafana, Prometheus, Alertmanager ports are opened in firewalld for internal network only
- Run `openssl rand -base64 32` to generate `GRAFANA_SECRET_KEY`
