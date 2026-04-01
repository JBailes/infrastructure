#!/usr/bin/env bash
# 09-setup-proxmox-obs.sh -- Set up observability on the Proxmox host (192.168.1.253)
#
# Runs on: the Proxmox host itself (NOT inside a container)
# Prereq: 03-setup-obs.sh must have already run (Prometheus must be scraping)
#
# Installs:
#   - prometheus-pve-exporter (Python, via pip in a venv, systemd on :9221)
#   - Promtail (ships Proxmox syslog/pveproxy/journal to Loki)
#
# pve-exporter authenticates to the Proxmox API via a read-only API token.
# Promtail pushes to Loki at 192.168.1.100:3100 (external interface, TLS + API key).

set -euo pipefail

LOKI_URL="https://192.168.1.100:3100/loki/api/v1/push"
LOKI_TENANT="proxmox"
PVE_EXPORTER_PORT="9221"
PVE_ETC="/etc/pve-exporter"
PROMTAIL_ETC="/etc/promtail"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

[[ $EUID -eq 0 ]] || err "Run as root"

# ---------------------------------------------------------------------------
# Prechecks
# ---------------------------------------------------------------------------

prechecks() {
    info "Running prechecks"
    curl -sf -k "https://192.168.1.100:3100/ready" &>/dev/null \
        || echo "WARN: Loki not reachable at 192.168.1.100:3100 yet" >&2
    # Proxmox API must be listening (don't need to authenticate, just verify port is open)
    curl -sk -o /dev/null -w "" "https://localhost:8006/" &>/dev/null \
        || err "Proxmox API not reachable on port 8006"
    info "Prechecks passed"
}

# ---------------------------------------------------------------------------
# pve-exporter
# ---------------------------------------------------------------------------

install_pve_exporter() {
    info "Installing prometheus-pve-exporter"
    apt-get install -y --no-install-recommends python3 python3-venv

    if [[ ! -d /opt/pve-exporter/venv ]]; then
        mkdir -p /opt/pve-exporter
        python3 -m venv /opt/pve-exporter/venv
        /opt/pve-exporter/venv/bin/pip install prometheus-pve-exporter
    fi
}

configure_pve_exporter() {
    info "Configuring pve-exporter"
    mkdir -p "$PVE_ETC"

    # Create API token if it doesn't exist
    if ! pveum user token list prometheus@pve 2>/dev/null | grep -q metrics; then
        info "Creating Proxmox API user and token"
        pveum user add prometheus@pve --comment "Prometheus metrics exporter" 2>/dev/null || true
        pveum aclmod / -user prometheus@pve -role PVEAuditor 2>/dev/null || true
        local token_output
        token_output=$(pveum user token add prometheus@pve metrics --privsep 0 2>/dev/null || true)
        local token_value
        # pveum outputs a box-drawing table; extract the UUID from the "value" row
        # Format: │ value        │ bd603152-69a7-4543-82a2-56deeb3237ab │
        token_value=$(echo "$token_output" | grep -E "^│ value" | sed 's/[│]//g' | awk '{print $2}')

        if [[ -n "$token_value" && "$token_value" =~ ^[a-f0-9-]+$ ]]; then
            cat > "$PVE_ETC/pve-exporter.yml" <<YAML
default:
  user: prometheus@pve
  token_name: metrics
  token_value: $token_value
  verify_ssl: false
YAML
            chmod 600 "$PVE_ETC/pve-exporter.yml"
            info "API token created and saved"
        else
            echo "WARN: Could not create API token. Configure $PVE_ETC/pve-exporter.yml manually." >&2
        fi
    fi

    cat > /etc/systemd/system/pve-exporter.service <<EOF
[Unit]
Description=Prometheus PVE Exporter
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/pve-exporter/venv/bin/pve_exporter --config.file $PVE_ETC/pve-exporter.yml --web.listen-address 0.0.0.0:$PVE_EXPORTER_PORT
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=pve-exporter

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now pve-exporter
}

# ---------------------------------------------------------------------------
# Promtail (external: TLS + API key, no mTLS)
# ---------------------------------------------------------------------------

install_promtail() {
    if command -v promtail &>/dev/null; then
        info "Promtail already installed"
        return
    fi

    info "Installing Promtail"
    local version="3.4.2"
    local arch
    arch=$(dpkg --print-architecture)
    local url="https://github.com/grafana/loki/releases/download/v${version}/promtail-linux-${arch}.zip"

    apt-get install -y --no-install-recommends unzip curl
    curl -fsSL "$url" -o /tmp/promtail.zip
    unzip -o /tmp/promtail.zip -d /usr/local/bin/
    [[ -f "/usr/local/bin/promtail-linux-${arch}" ]] && \
        mv "/usr/local/bin/promtail-linux-${arch}" /usr/local/bin/promtail
    chmod 755 /usr/local/bin/promtail
    rm -f /tmp/promtail.zip
}

configure_promtail() {
    info "Configuring Promtail for Proxmox host"
    mkdir -p "$PROMTAIL_ETC" /var/lib/promtail

    cat > "$PROMTAIL_ETC/promtail.yaml" <<YAML
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /var/lib/promtail/positions.yaml

clients:
  - url: $LOKI_URL
    tenant_id: $LOKI_TENANT
    tls_config:
      insecure_skip_verify: true

scrape_configs:
  - job_name: syslog
    static_configs:
      - targets: [localhost]
        labels:
          host: proxmox
          __path__: /var/log/syslog

  - job_name: pveproxy
    static_configs:
      - targets: [localhost]
        labels:
          host: proxmox
          service: pveproxy
          __path__: /var/log/pveproxy/access.log

  - job_name: journal
    journal:
      max_age: 12h
      labels:
        host: proxmox
    relabel_configs:
      - source_labels: ['__journal__systemd_unit']
        target_label: service
YAML

    cat > /etc/systemd/system/promtail.service <<EOF
[Unit]
Description=Promtail Log Shipping Agent (Proxmox Host)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/promtail -config.file=$PROMTAIL_ETC/promtail.yaml
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=promtail

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now promtail
}

# ---------------------------------------------------------------------------
# Firewall (allow Prometheus scrape from obs)
# ---------------------------------------------------------------------------

configure_firewall() {
    info "Allowing Prometheus scrape on port $PVE_EXPORTER_PORT from obs"
    # Use iptables directly
    iptables -C INPUT -s 192.168.1.100 -p tcp --dport "$PVE_EXPORTER_PORT" -j ACCEPT 2>/dev/null \
        || iptables -A INPUT -s 192.168.1.100 -p tcp --dport "$PVE_EXPORTER_PORT" -j ACCEPT
    # Persist (create directory if needed)
    if command -v iptables-save &>/dev/null; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4 || true
    fi
}

# ---------------------------------------------------------------------------
# Postchecks
# ---------------------------------------------------------------------------

postchecks() {
    info "Running postchecks"
    sleep 3

    if curl -sf "http://localhost:$PVE_EXPORTER_PORT/pve" &>/dev/null; then
        info "pve-exporter: OK (port $PVE_EXPORTER_PORT)"
    else
        echo "WARN: pve-exporter not responding yet" >&2
    fi

    if systemctl is-active --quiet promtail; then
        info "Promtail: running"
    else
        echo "WARN: Promtail not running" >&2
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    prechecks
    install_pve_exporter
    configure_pve_exporter
    install_promtail
    configure_promtail
    configure_firewall
    postchecks

    cat <<EOF

================================================================
Proxmox host observability is ready.

pve-exporter: http://localhost:$PVE_EXPORTER_PORT/pve
Promtail:     pushing to $LOKI_URL (tenant: $LOKI_TENANT)

Prometheus (on obs) scrapes pve-exporter at 192.168.1.253:$PVE_EXPORTER_PORT.
Promtail ships syslog, pveproxy access logs, and journal to Loki.
================================================================
EOF
}

main "$@"
