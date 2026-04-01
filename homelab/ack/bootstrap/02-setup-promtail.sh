#!/usr/bin/env bash
# 02-setup-promtail.sh -- Install Promtail log shipping agent on ACK hosts
#
# Runs on: every ACK host (gateway + MUD servers on vmbr2)
# Run order: After homelab/bootstrap/03-setup-obs.sh (obs must be running)
#
# Installs Promtail, configures it to:
#   - Read from the local systemd journal
#   - Label with hostname and service name
#   - Push to Loki at 10.1.0.100:3100 over TLS (tenant: ack)
#
# ACK hosts do not participate in the WOL PKI, so no mTLS is used.
# TLS with insecure_skip_verify (same pattern as Proxmox host promtail).
# Deployed by pve-setup-ack.sh or manually via pct push/exec.
#
# Usage:
#   Inside an ACK container: run with --configure
#   From Proxmox: deploy_script <ctid> 02-setup-promtail.sh

set -euo pipefail

LOKI_URL="https://10.1.0.100:3100/loki/api/v1/push"
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
    # Check Loki is reachable (may fail TLS if cert not enrolled yet, that's OK)
    curl -sf -k "https://10.1.0.100:3100/ready" &>/dev/null \
        || echo "WARN: Loki not reachable at 10.1.0.100:3100 yet" >&2
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
    tenant_id: ack
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
Description=Promtail Log Shipping Agent (ACK)
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

    info "Promtail setup complete on $HOSTNAME_LABEL (pushing to Loki at 10.1.0.100:3100, tenant: ack)"
}

if [[ "${1:-}" == "--configure" ]]; then
    main
else
    main
fi
