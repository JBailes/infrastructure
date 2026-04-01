#!/usr/bin/env bash
# 04-setup-promtail-lan.sh -- Install Promtail log shipping agent on LAN homelab hosts
#
# Runs on: homelab hosts on vmbr0 (apt-cache, vpn-gateway, bittorrent)
# Run order: Deployed by 03-setup-obs.sh after obs is configured
#
# Installs Promtail, configures it to:
#   - Read from the local systemd journal
#   - Label with hostname and service name
#   - Push to Loki at 192.168.1.100:3100 over TLS (tenant: homelab)
#
# LAN hosts do not participate in the WOL PKI, so no mTLS is used.
# TLS with insecure_skip_verify (same pattern as Proxmox host promtail).
#
# Usage:
#   Inside a LAN container/VM: run with --configure
#   From Proxmox: deploy_script <ctid> 05-setup-promtail-lan.sh

set -euo pipefail

LOKI_URL="https://192.168.1.100:3100/loki/api/v1/push"
PROMTAIL_ETC="/etc/promtail"
HOSTNAME_LABEL=$(hostname)

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
    info "Prechecks passed"
}

# ---------------------------------------------------------------------------
# Install Promtail
# ---------------------------------------------------------------------------

install_promtail() {
    if command -v promtail &>/dev/null; then
        info "Promtail already installed"
        return
    fi

    info "Installing Promtail via apt"
    if [[ ! -f /etc/apt/sources.list.d/grafana.list ]]; then
        apt-get install -y --no-install-recommends curl gnupg
        curl -fsSL https://apt.grafana.com/gpg.key \
            | gpg --dearmor -o /usr/share/keyrings/grafana.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
            > /etc/apt/sources.list.d/grafana.list
        apt-get update -qq
    fi
    apt-get install -y --no-install-recommends promtail
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

configure_promtail() {
    info "Writing Promtail configuration"
    mkdir -p "$PROMTAIL_ETC" /var/lib/promtail

    cat > "$PROMTAIL_ETC/promtail.yaml" <<YAML
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /var/lib/promtail/positions.yaml

clients:
  - url: $LOKI_URL
    tenant_id: homelab
    tls_config:
      insecure_skip_verify: true

scrape_configs:
  - job_name: journal
    journal:
      max_age: 12h
      labels:
        host: $HOSTNAME_LABEL
    relabel_configs:
      - source_labels: ['__journal__systemd_unit']
        target_label: service
YAML

    chown -R root:root "$PROMTAIL_ETC"
    chmod 640 "$PROMTAIL_ETC/promtail.yaml"
}

# ---------------------------------------------------------------------------
# Systemd unit
# ---------------------------------------------------------------------------

write_systemd_unit() {
    info "Writing Promtail systemd unit"
    cat > /etc/systemd/system/promtail.service <<EOF
[Unit]
Description=Promtail Log Shipping Agent (Homelab LAN)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/promtail -config.file=$PROMTAIL_ETC/promtail.yaml
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
# Main
# ---------------------------------------------------------------------------

main() {
    prechecks
    install_promtail
    configure_promtail
    write_systemd_unit

    info "Promtail setup complete on $HOSTNAME_LABEL (pushing to Loki at 192.168.1.100:3100, tenant: homelab)"
}

if [[ "${1:-}" == "--configure" ]]; then
    main
else
    main
fi
