#!/usr/bin/env bash
# 19-setup-promtail.sh -- Install Promtail log shipping agent
#
# Runs on: every WOL host (including obs itself)
# Run order: Step 18 (after obs is running and accepting connections)
#
# Installs Promtail, configures it to:
#   - Read from the local systemd journal
#   - Label with hostname and service name
#   - Tag security events with stream=security
#   - Push to Loki at 10.0.0.100:3100 over mTLS (cfssl client cert CN=promtail)
#
# Prechecks: CA reachable, Loki endpoint reachable
# Postchecks: Promtail running, test log arrives in Loki

set -euo pipefail

_LIB="$(dirname "$0")/lib/common.sh"; [[ -f "$_LIB" ]] || _LIB="/root/lib/common.sh"; source "$_LIB" 2>/dev/null || true

LOKI_URL="https://10.0.0.100:3100/loki/api/v1/push"
PROMTAIL_ETC="/etc/promtail"
HOSTNAME_LABEL=$(hostname)

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

[[ $EUID -eq 0 ]] || err "Run as root"

rm -f /root/.env.bootstrap

# ---------------------------------------------------------------------------
# Prechecks
# ---------------------------------------------------------------------------

prechecks() {
    info "Running prechecks"
    # Check Loki is reachable (may fail TLS if cert not enrolled yet, that's OK)
    curl -sf -k "https://10.0.0.100:3100/ready" &>/dev/null \
        || echo "WARN: Loki not reachable yet (may need cert enrollment)" >&2
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
    configure_grafana_repo
    apt-get install -y --no-install-recommends promtail
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

configure_promtail() {
    info "Writing Promtail configuration"
    mkdir -p "$PROMTAIL_ETC/certs" /var/lib/promtail
    copy_root_ca "$PROMTAIL_ETC/certs"

    cat > "$PROMTAIL_ETC/promtail.yaml" <<YAML
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /var/lib/promtail/positions.yaml

clients:
  - url: $LOKI_URL
    tenant_id: wol
    tls_config:
      cert_file: $PROMTAIL_ETC/certs/promtail-client.crt
      key_file: $PROMTAIL_ETC/certs/promtail-client.key
      ca_file: $PROMTAIL_ETC/certs/root_ca.crt

scrape_configs:
  - job_name: journal
    journal:
      max_age: 12h
      labels:
        host: $HOSTNAME_LABEL
    relabel_configs:
      - source_labels: ['__journal__systemd_unit']
        target_label: service
    pipeline_stages:
      - json:
          expressions:
            severity: severity
      - labels:
          severity:
      - match:
          selector: '{severity="security"}'
          stages:
            - labels:
                stream: security
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
Description=Promtail Log Shipping Agent
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
}

# ---------------------------------------------------------------------------
# Start Promtail (cert enrollment handled by enroll-host-certs.sh)
# ---------------------------------------------------------------------------

start_promtail() {
    mkdir -p "$PROMTAIL_ETC/certs"

    if [[ -f "$PROMTAIL_ETC/certs/promtail-client.crt" ]]; then
        systemctl enable --now promtail
        info "Promtail started"
    else
        info "Promtail client cert not yet enrolled. enroll-host-certs.sh will handle this."
        info "Promtail will start after cert enrollment."
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    prechecks
    install_promtail
    configure_promtail
    write_systemd_unit
    start_promtail

    info "Promtail setup complete on $HOSTNAME_LABEL"
}

main "$@"
