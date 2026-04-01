#!/usr/bin/env bash
# 08-setup-dashboards.sh -- Install blackbox_exporter and provision Grafana dashboards
#
# Runs on: the Proxmox host (pushes into obs CT 100)
# Prereq: 03-setup-obs.sh must have already run
#
# Usage:
#   ./08-setup-dashboards.sh               # Push script into CT 100 and run
#   ./08-setup-dashboards.sh --configure   # (internal) Run inside the container
#
# Installs:
#   - blackbox_exporter (HTTP probes for hosts without /metrics)
#   - Blackbox scrape job appended to Prometheus config
#   - Two Grafana dashboards (provisioned as JSON):
#     1. Service Health: green/red tiles for all monitored services
#     2. Host Utilization: CPU and memory per container (via pve_exporter)

set -euo pipefail

CTID=100

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

[[ $EUID -eq 0 ]] || err "Run as root"

# ---------------------------------------------------------------------------
# blackbox_exporter
# ---------------------------------------------------------------------------

install_blackbox_exporter() {
    info "Installing blackbox_exporter"

    # Stop existing process so the binary can be overwritten
    systemctl stop blackbox-exporter 2>/dev/null || true
    local version="0.25.0"
    local arch
    arch=$(dpkg --print-architecture)
    local tarball="blackbox_exporter-${version}.linux-${arch}.tar.gz"
    local url="https://github.com/prometheus/blackbox_exporter/releases/download/v${version}/${tarball}"
    curl -fsSL --connect-timeout 30 --retry 3 --retry-delay 5 "$url" -o "/tmp/${tarball}"
    tar -xzf "/tmp/${tarball}" -C /tmp/
    cp "/tmp/blackbox_exporter-${version}.linux-${arch}/blackbox_exporter" /usr/local/bin/
    rm -rf "/tmp/${tarball}" "/tmp/blackbox_exporter-${version}.linux-${arch}"

    mkdir -p /etc/blackbox_exporter
    cat > /etc/blackbox_exporter/config.yml <<'YAML'
modules:
  http_2xx:
    prober: http
    timeout: 5s
    http:
      valid_http_versions: ["HTTP/1.1", "HTTP/2.0"]
      valid_status_codes: [200]
      follow_redirects: true
      preferred_ip_protocol: ip4
  https_2xx:
    prober: http
    timeout: 5s
    http:
      valid_http_versions: ["HTTP/1.1", "HTTP/2.0"]
      valid_status_codes: [200]
      follow_redirects: true
      preferred_ip_protocol: ip4
      tls_config:
        insecure_skip_verify: true
  tcp_connect:
    prober: tcp
    timeout: 5s
YAML

    cat > /etc/systemd/system/blackbox-exporter.service <<'UNIT'
[Unit]
Description=Blackbox Exporter (HTTP probes)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=nobody
ExecStart=/usr/local/bin/blackbox_exporter --config.file=/etc/blackbox_exporter/config.yml --web.listen-address=127.0.0.1:9115
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable blackbox-exporter
    systemctl start blackbox-exporter
    info "blackbox_exporter installed and started on :9115"
}

# ---------------------------------------------------------------------------
# Append blackbox scrape job to Prometheus config
# ---------------------------------------------------------------------------

configure_blackbox_scrape() {
    local prom_cfg="/etc/prometheus/prometheus.yml"

    # Remove existing blackbox config blocks so we always write the latest version
    if grep -q 'job_name: blackbox' "$prom_cfg" 2>/dev/null; then
        info "Removing old blackbox scrape jobs from Prometheus config"
        sed -i '/# Blackbox HTTP probes/,/localhost:9115/d' "$prom_cfg"
        sed -i '/# Blackbox HTTPS probes/,/localhost:9115/d' "$prom_cfg"
        # Clean up any remaining blackbox job fragments
        sed -i '/job_name: blackbox/,/localhost:9115/d' "$prom_cfg"
    fi

    info "Writing blackbox scrape job to Prometheus config"
    cat >> "$prom_cfg" <<'YAML'

  # Blackbox HTTP probes (hosts without /metrics endpoints)
  - job_name: blackbox
    metrics_path: /probe
    params:
      module: [http_2xx]
    static_configs:
      - targets: ['http://10.1.0.247:5000/health']
        labels:
          name: ack-web
      - targets: ['http://10.1.0.248:8000/health']
        labels:
          name: tng-ai
      - targets: ['http://10.1.0.249:8000/health']
        labels:
          name: tngdb
      - targets: ['http://192.168.1.105:32400/identity']
        labels:
          name: plex
      - targets: ['http://192.168.1.108']
        labels:
          name: adguard
      - targets: ['http://192.168.1.109:8096/emby/system/info/public']
        labels:
          name: emby
      - targets: ['http://192.168.1.120:47989/pin/']
        labels:
          name: wolf
      - targets: ['http://192.168.1.120:8080']
        labels:
          name: wolf-den
      - targets: ['http://192.168.1.116:8080']
        labels:
          name: bittorrent
      - targets: ['http://192.168.1.117:3000']
        labels:
          name: personal-web
      - targets: ['http://192.168.1.118/health']
        labels:
          name: nginx-proxy
      - targets: ['http://10.0.0.115:8080/health']
        labels:
          name: apt-cache
      - targets: ['http://10.0.0.204:8080/ready']
        labels:
          name: spire-server
      - targets: ['http://10.0.0.209:5000/health']
        labels:
          name: wol-web
      - targets: ['http://10.0.0.210:8443/health']
        labels:
          name: wol-realm-prod
      - targets: ['http://10.0.1.215:8443/health']
        labels:
          name: wol-realm-test
      - targets: ['http://10.0.0.212:8443/health']
        labels:
          name: wol-ai-prod
      - targets: ['http://10.0.1.217:8443/health']
        labels:
          name: wol-ai-test
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: 'localhost:9115'

  # Blackbox HTTPS probes (self-signed certs, skip TLS verification)
  - job_name: blackbox-https
    metrics_path: /probe
    params:
      module: [https_2xx]
    static_configs:
      - targets: ['https://192.168.1.102:8443']
        labels:
          name: unifi
      - targets: ['https://192.168.1.110:8007']
        labels:
          name: pbs
      - targets: ['https://192.168.1.254']
        labels:
          name: truenas
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: 'localhost:9115'

  # Blackbox TCP probes (network appliances without HTTP endpoints)
  - job_name: blackbox-tcp
    metrics_path: /probe
    params:
      module: [tcp_connect]
    static_configs:
      - targets: ['10.0.0.200:53']
        labels:
          name: wol-gateway-a
      - targets: ['10.0.0.201:53']
        labels:
          name: wol-gateway-b
      - targets: ['10.0.0.208:6969']
        labels:
          name: wol-a
      - targets: ['10.1.0.240:53']
        labels:
          name: ack-gateway
      - targets: ['10.1.0.241:4000']
        labels:
          name: acktng
      - targets: ['10.1.0.242:4000']
        labels:
          name: ack431
      - targets: ['10.1.0.243:4000']
        labels:
          name: ack42
      - targets: ['10.1.0.244:4000']
        labels:
          name: ack41
      - targets: ['10.1.0.245:4000']
        labels:
          name: assault30
      - targets: ['10.1.0.250:4000']
        labels:
          name: ackfuss
      - targets: ['192.168.1.101:2222']
        labels:
          name: deploy
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: 'localhost:9115'
YAML

    if ! systemctl reload prometheus 2>/dev/null; then
        systemctl restart prometheus
    fi
    info "Prometheus reloaded with blackbox scrape job"
}

# ---------------------------------------------------------------------------
# Grafana dashboard provisioning
# ---------------------------------------------------------------------------

configure_dashboards() {
    info "Provisioning Grafana dashboards"

    mkdir -p /etc/grafana/provisioning/dashboards
    cat > /etc/grafana/provisioning/dashboards/wol.yml <<'YAML'
apiVersion: 1
providers:
  - name: WOL
    orgId: 1
    folder: ''
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    allowUiUpdates: true
    options:
      path: /var/lib/grafana/dashboards
      foldersFromFilesStructure: false
YAML

    mkdir -p /var/lib/grafana/dashboards

    # ── Dashboard 1: Service Health ───────────────────────────────────────
    #
    # Panel layout:
    #   Row 0:  Homelab Infrastructure (full-width: blackbox probes incl. apt-cache, proxmox)
    #   Row 6:  WOL Shared (full-width: wol-accounts, wol-a, wol-web, spire-server)
    #   Row 10: WOL Prod | WOL Test (side-by-side)
    #   Row 14: ACK Services (full-width)
    #   Row 18: Observability (full-width)
    #
    cat > /var/lib/grafana/dashboards/service-health.json <<'JSON'
{
  "uid": "service-health",
  "title": "Service Health",
  "tags": ["health"],
  "timezone": "browser",
  "refresh": "15s",
  "time": { "from": "now-5m", "to": "now" },
  "templating": { "list": [] },
  "panels": [
    {
      "id": 1,
      "title": "Homelab Infrastructure",
      "type": "stat",
      "gridPos": { "h": 5, "w": 24, "x": 0, "y": 0 },
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "targets": [
        {
          "expr": "probe_success{job=~\"blackbox|blackbox-https\", name!~\"tng-ai|tngdb|ack-web|spire-server|wol-.*\"}",
          "legendFormat": "{{name}}"
        },
        {
          "expr": "probe_success{job=\"blackbox-tcp\", name=\"deploy\"}",
          "legendFormat": "{{name}}"
        },
        {
          "expr": "up{job=\"proxmox\"}",
          "legendFormat": "proxmox"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "mappings": [
            { "options": { "0": { "text": "DOWN", "color": "red" } }, "type": "value" },
            { "options": { "1": { "text": "UP", "color": "green" } }, "type": "value" }
          ],
          "thresholds": {
            "mode": "absolute",
            "steps": [
              { "color": "red", "value": null },
              { "color": "green", "value": 1 }
            ]
          },
          "color": { "mode": "thresholds" }
        }
      },
      "options": {
        "reduceOptions": { "calcs": ["lastNotNull"] },
        "orientation": "auto",
        "textMode": "auto",
        "colorMode": "background",
        "graphMode": "none"
      }
    },
    {
      "id": 2,
      "title": "WOL Shared",
      "type": "stat",
      "gridPos": { "h": 3, "w": 24, "x": 0, "y": 5 },
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "targets": [
        {
          "expr": "up{job=\"wol\", name=\"wol-accounts\"}",
          "legendFormat": "{{name}}"
        },
        {
          "expr": "probe_success{job=\"blackbox-tcp\", name=\"wol-a\"}",
          "legendFormat": "{{name}}"
        },
        {
          "expr": "probe_success{job=\"blackbox\", name=\"wol-web\"}",
          "legendFormat": "{{name}}"
        },
        {
          "expr": "probe_success{job=\"blackbox\", name=\"spire-server\"}",
          "legendFormat": "{{name}}"
        },
        {
          "expr": "up{job=\"postgres\", name=~\"spire-db|wol-accounts-db\"}",
          "legendFormat": "{{name}}"
        },
        {
          "expr": "probe_success{job=\"blackbox-tcp\", name=~\"wol-gateway.*\"}",
          "legendFormat": "{{name}}"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "mappings": [
            { "options": { "0": { "text": "DOWN", "color": "red" } }, "type": "value" },
            { "options": { "1": { "text": "UP", "color": "green" } }, "type": "value" }
          ],
          "thresholds": {
            "mode": "absolute",
            "steps": [
              { "color": "red", "value": null },
              { "color": "green", "value": 1 }
            ]
          },
          "color": { "mode": "thresholds" }
        }
      },
      "options": {
        "reduceOptions": { "calcs": ["lastNotNull"] },
        "orientation": "auto",
        "textMode": "auto",
        "colorMode": "background",
        "graphMode": "none"
      }
    },
    {
      "id": 3,
      "title": "WOL Prod",
      "type": "stat",
      "gridPos": { "h": 3, "w": 12, "x": 0, "y": 8 },
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "targets": [
        {
          "expr": "up{job=\"wol\", name=~\".*-prod\"}",
          "legendFormat": "{{name}}"
        },
        {
          "expr": "up{job=\"postgres\", name=~\".*-prod\"}",
          "legendFormat": "{{name}}"
        },
        {
          "expr": "probe_success{job=\"blackbox\", name=~\".*-prod\"}",
          "legendFormat": "{{name}}"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "mappings": [
            { "options": { "0": { "text": "DOWN", "color": "red" } }, "type": "value" },
            { "options": { "1": { "text": "UP", "color": "green" } }, "type": "value" }
          ],
          "thresholds": {
            "mode": "absolute",
            "steps": [
              { "color": "red", "value": null },
              { "color": "green", "value": 1 }
            ]
          },
          "color": { "mode": "thresholds" }
        }
      },
      "options": {
        "reduceOptions": { "calcs": ["lastNotNull"] },
        "orientation": "auto",
        "textMode": "auto",
        "colorMode": "background",
        "graphMode": "none"
      }
    },
    {
      "id": 4,
      "title": "WOL Test",
      "type": "stat",
      "gridPos": { "h": 3, "w": 12, "x": 12, "y": 8 },
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "targets": [
        {
          "expr": "up{job=\"wol\", name=~\".*-test\"}",
          "legendFormat": "{{name}}"
        },
        {
          "expr": "up{job=\"postgres\", name=~\".*-test\"}",
          "legendFormat": "{{name}}"
        },
        {
          "expr": "probe_success{job=\"blackbox\", name=~\".*-test\"}",
          "legendFormat": "{{name}}"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "mappings": [
            { "options": { "0": { "text": "DOWN", "color": "red" } }, "type": "value" },
            { "options": { "1": { "text": "UP", "color": "green" } }, "type": "value" }
          ],
          "thresholds": {
            "mode": "absolute",
            "steps": [
              { "color": "red", "value": null },
              { "color": "green", "value": 1 }
            ]
          },
          "color": { "mode": "thresholds" }
        }
      },
      "options": {
        "reduceOptions": { "calcs": ["lastNotNull"] },
        "orientation": "auto",
        "textMode": "auto",
        "colorMode": "background",
        "graphMode": "none"
      }
    },
    {
      "id": 5,
      "title": "ACK Services",
      "type": "stat",
      "gridPos": { "h": 3, "w": 24, "x": 0, "y": 11 },
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "targets": [
        {
          "expr": "up{job=\"ack\", name=\"ack-db\"}",
          "legendFormat": "{{name}}"
        },
        {
          "expr": "probe_success{name=~\"ack-web|tng-ai|tngdb\"}",
          "legendFormat": "{{name}}"
        },
        {
          "expr": "probe_success{job=\"blackbox-tcp\", name=~\"acktng|ack431|ack42|ack41|assault30|ackfuss|ack-gateway\"}",
          "legendFormat": "{{name}}"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "mappings": [
            { "options": { "0": { "text": "DOWN", "color": "red" } }, "type": "value" },
            { "options": { "1": { "text": "UP", "color": "green" } }, "type": "value" }
          ],
          "thresholds": {
            "mode": "absolute",
            "steps": [
              { "color": "red", "value": null },
              { "color": "green", "value": 1 }
            ]
          },
          "color": { "mode": "thresholds" }
        }
      },
      "options": {
        "reduceOptions": { "calcs": ["lastNotNull"] },
        "orientation": "auto",
        "textMode": "auto",
        "colorMode": "background",
        "graphMode": "none"
      }
    },
    {
      "id": 6,
      "title": "Observability",
      "type": "stat",
      "gridPos": { "h": 3, "w": 24, "x": 0, "y": 14 },
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "targets": [
        {
          "expr": "up{job=~\"obs-self|obs-loki\", name!=\"\"}",
          "legendFormat": "{{name}}"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "mappings": [
            { "options": { "0": { "text": "DOWN", "color": "red" } }, "type": "value" },
            { "options": { "1": { "text": "UP", "color": "green" } }, "type": "value" }
          ],
          "thresholds": {
            "mode": "absolute",
            "steps": [
              { "color": "red", "value": null },
              { "color": "green", "value": 1 }
            ]
          },
          "color": { "mode": "thresholds" }
        }
      },
      "options": {
        "reduceOptions": { "calcs": ["lastNotNull"] },
        "orientation": "auto",
        "textMode": "auto",
        "colorMode": "background",
        "graphMode": "none"
      }
    }
  ],
  "schemaVersion": 39
}
JSON

    # ── Dashboard 2: Host Utilization ─────────────────────────────────────
    cat > /var/lib/grafana/dashboards/host-utilization.json <<'JSON'
{
  "uid": "host-utilization",
  "title": "Host Utilization",
  "tags": ["utilization"],
  "timezone": "browser",
  "refresh": "30s",
  "time": { "from": "now-1h", "to": "now" },
  "templating": {
    "list": [
      {
        "name": "host",
        "type": "query",
        "datasource": { "type": "prometheus", "uid": "prometheus" },
        "query": "label_values({__name__=~\"pve_guest_info|pve_node_info\"}, name)",
        "includeAll": true,
        "multi": true,
        "current": { "selected": true, "text": "All", "value": "$__all" },
        "refresh": 2
      }
    ]
  },
  "panels": [
    {
      "id": 1,
      "title": "CPU Usage by Host",
      "type": "bargauge",
      "gridPos": { "h": 10, "w": 12, "x": 0, "y": 0 },
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "targets": [
        {
          "expr": "pve_cpu_usage_ratio * 100 * on(id) group_left(name) pve_guest_info{name=~\"$host\"}",
          "legendFormat": "{{name}}"
        },
        {
          "expr": "pve_cpu_usage_ratio{id=\"node/pve\"} * 100 * on(id) group_left(name) pve_node_info{name=~\"$host\"}",
          "legendFormat": "{{name}}"
        },
        {
          "expr": "sum(netdata_system_cpu_percentage_average{dimension!=\"idle\", job=\"truenas\"})",
          "legendFormat": "truenas"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "percent",
          "min": 0,
          "max": 100,
          "thresholds": {
            "mode": "absolute",
            "steps": [
              { "color": "green", "value": null },
              { "color": "yellow", "value": 60 },
              { "color": "red", "value": 85 }
            ]
          },
          "color": { "mode": "thresholds" }
        }
      },
      "options": {
        "reduceOptions": { "calcs": ["lastNotNull"] },
        "orientation": "horizontal",
        "displayMode": "gradient",
        "showUnfilled": true
      }
    },
    {
      "id": 2,
      "title": "Memory Usage by Host",
      "type": "bargauge",
      "gridPos": { "h": 10, "w": 12, "x": 12, "y": 0 },
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "targets": [
        {
          "expr": "(pve_memory_usage_bytes / pve_memory_size_bytes) * 100 * on(id) group_left(name) pve_guest_info{name=~\"$host\"}",
          "legendFormat": "{{name}}"
        },
        {
          "expr": "(pve_memory_usage_bytes{id=\"node/pve\"} / pve_memory_size_bytes{id=\"node/pve\"}) * 100 * on(id) group_left(name) pve_node_info{name=~\"$host\"}",
          "legendFormat": "{{name}}"
        },
        {
          "expr": "netdata_system_ram_MiB_average{dimension=\"used\", job=\"truenas\"} / (netdata_system_ram_MiB_average{dimension=\"used\", job=\"truenas\"} + netdata_system_ram_MiB_average{dimension=\"free\", job=\"truenas\"} + netdata_system_ram_MiB_average{dimension=\"cached\", job=\"truenas\"} + netdata_system_ram_MiB_average{dimension=\"buffers\", job=\"truenas\"}) * 100",
          "legendFormat": "truenas"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "percent",
          "min": 0,
          "max": 100,
          "thresholds": {
            "mode": "absolute",
            "steps": [
              { "color": "green", "value": null },
              { "color": "yellow", "value": 70 },
              { "color": "red", "value": 90 }
            ]
          },
          "color": { "mode": "thresholds" }
        }
      },
      "options": {
        "reduceOptions": { "calcs": ["lastNotNull"] },
        "orientation": "horizontal",
        "displayMode": "gradient",
        "showUnfilled": true
      }
    },
    {
      "id": 3,
      "title": "CPU Over Time",
      "type": "timeseries",
      "gridPos": { "h": 10, "w": 12, "x": 0, "y": 10 },
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "targets": [
        {
          "expr": "pve_cpu_usage_ratio * 100 * on(id) group_left(name) pve_guest_info{name=~\"$host\"}",
          "legendFormat": "{{name}}"
        },
        {
          "expr": "pve_cpu_usage_ratio{id=\"node/pve\"} * 100 * on(id) group_left(name) pve_node_info{name=~\"$host\"}",
          "legendFormat": "{{name}}"
        },
        {
          "expr": "sum(netdata_system_cpu_percentage_average{dimension!=\"idle\", job=\"truenas\"})",
          "legendFormat": "truenas"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "percent",
          "min": 0,
          "custom": {
            "lineWidth": 1,
            "fillOpacity": 10,
            "spanNulls": false,
            "showPoints": "never"
          }
        }
      }
    },
    {
      "id": 4,
      "title": "Memory Over Time",
      "type": "timeseries",
      "gridPos": { "h": 10, "w": 12, "x": 12, "y": 10 },
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "targets": [
        {
          "expr": "pve_memory_usage_bytes * on(id) group_left(name) (pve_guest_info{name=~\"$host\"} > 0) / 1024 / 1024",
          "legendFormat": "{{name}}"
        },
        {
          "expr": "pve_memory_usage_bytes{id=\"node/pve\"} * on(id) group_left(name) (pve_node_info{name=~\"$host\"} > 0) / 1024 / 1024",
          "legendFormat": "{{name}}"
        },
        {
          "expr": "netdata_system_ram_MiB_average{dimension=\"used\", job=\"truenas\"}",
          "legendFormat": "truenas"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "decmbytes",
          "min": 0,
          "custom": {
            "lineWidth": 1,
            "fillOpacity": 10,
            "spanNulls": false,
            "showPoints": "never"
          }
        }
      }
    }
  ],
  "schemaVersion": 39
}
JSON

    chown -R grafana:grafana /var/lib/grafana/dashboards
    systemctl restart grafana-server
    info "Dashboards provisioned: Service Health, Host Utilization"
}

# ---------------------------------------------------------------------------
# Container-side: configure everything
# ---------------------------------------------------------------------------

configure() {
    [[ $EUID -eq 0 ]] || err "Run as root"

    info "Setting up Grafana dashboards and blackbox_exporter on obs"
    install_blackbox_exporter
    configure_blackbox_scrape
    configure_dashboards

    cat <<EOF

================================================================
Dashboards provisioned on Grafana:

  1. Service Health  -- green/red tiles for all monitored services
  2. Host Utilization -- CPU and memory per container (pve_exporter)

Blackbox probes added for:
  - tng-ai (10.1.0.248:8000)
  - tngdb (10.1.0.249:8000)
  - plex (192.168.1.105:32400)
  - adguard (192.168.1.108:80)
  - emby (192.168.1.109:8096)
  - wolf (192.168.1.120:47989)
  - wolf-den (192.168.1.120:8080)
  - bittorrent (192.168.1.116:8080)
  - personal-web (192.168.1.117:3000)
  - nginx-proxy (192.168.1.118:80)
  - unifi (192.168.1.102:8443, HTTPS)
  - pbs (192.168.1.110:8007, HTTPS)
  - truenas (192.168.1.254:443, HTTPS)
  - wol-gateway-a (10.0.0.200:53, TCP)
  - wol-gateway-b (10.0.0.201:53, TCP)
  - ack-gateway (10.1.0.240:53, TCP)
  - acktng (10.1.0.241:4000, TCP)
  - ack431 (10.1.0.242:4000, TCP)
  - ack42 (10.1.0.243:4000, TCP)
  - ack41 (10.1.0.244:4000, TCP)
  - assault30 (10.1.0.245:4000, TCP)
  - ackfuss (10.1.0.250:4000, TCP)
  - deploy (192.168.1.101:2222, TCP)

Open Grafana at http://192.168.1.100 to view.
================================================================
EOF
}

# ---------------------------------------------------------------------------
# Host-side: push script into obs container and run
# ---------------------------------------------------------------------------

host_main() {
    info "Deploying 08-setup-dashboards.sh to obs (CT $CTID)"
    pct start "$CTID" 2>/dev/null || true
    sleep 2
    pct push "$CTID" "$0" /root/08-setup-dashboards.sh
    pct exec "$CTID" -- bash /root/08-setup-dashboards.sh --configure
    info "Done"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if [[ "${1:-}" == "--configure" ]]; then
    configure
else
    host_main
fi
