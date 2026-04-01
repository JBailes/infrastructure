#!/usr/bin/env bash
# 03-setup-obs.sh -- Set up the observability stack on obs (quad-homed)
#
# Runs on: obs, Debian 13 LXC (quad-homed)
#   eth0 = 192.168.1.100/23 on vmbr0 (Home LAN)
#   eth1 = 10.0.0.100/20 on vmbr1 (WOL prod/shared)
#   eth2 = 10.1.0.100/24 on vmbr2 (ACK private)
#   eth3 = 10.0.1.100/24 on vmbr3 (WOL test)
# CTID: 100 (static, homelab convention)
#
# Installs and configures:
#   - Loki (log aggregation, :3100 on all interfaces)
#   - Prometheus (metrics scraping, :9090)
#   - Alertmanager (alert routing, :9093)
#   - Grafana (dashboards, :80 on external interface)
#   - Promtail (self-monitoring, ships obs own logs to Loki)
#
# Accepts log/metric ingestion from three networks:
#   - WOL (10.0.0.0/20): mTLS with cfssl client certs (tenant: wol)
#   - ACK (10.1.0.0/24): TLS (tenant: ack)
#   - External (192.168.0.0/23): TLS + API key (tenant: proxmox, future external)
#
# mTLS for Loki ingestion uses CA certs (CN=obs server, CN=promtail client).
# External and ACK ingestion uses TLS + tenant header (no mTLS).
# This host does NOT run a SPIRE Agent.
#
# Usage:
#   On Proxmox host: run with no args to create the container
#   Inside container: run with --configure to configure services

set -euo pipefail

_LIB="$(dirname "$0")/lib/common.sh"; [[ -f "$_LIB" ]] || _LIB="/root/lib/common.sh"; source "$_LIB" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Container specification
# ---------------------------------------------------------------------------

CTID=100
HOSTNAME="obs"
LAN_IP="192.168.1.100"
WOL_IP="10.0.0.100"
ACK_IP="10.1.0.100"
WOL_TEST_IP="10.0.1.100"
RAM=2048
CORES=2
DISK=64
PRIVILEGED="no"

CA_IP="10.0.0.203"
CA_PORT="8443"
OBS_ETC="/etc/obs"
OBS_DATA="/var/lib/obs"
INTERNAL_IP="$WOL_IP"
EXTERNAL_IP="$LAN_IP"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

# ---------------------------------------------------------------------------
# Host-side: create the container
# ---------------------------------------------------------------------------

host_main() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    info "Creating obs container (CTID $CTID)"

    create_lxc "$CTID" "$HOSTNAME" "$LAN_IP" "$RAM" "$CORES" "$DISK" "$ROUTER_GW" "$PRIVILEGED" \
        --net1 "name=eth1,bridge=${PRIVATE_BRIDGE},ip=${WOL_IP}/20" \
        --net2 "name=eth2,bridge=${ACK_BRIDGE},ip=${ACK_IP}/24" \
        --net3 "name=eth3,bridge=vmbr3,ip=${WOL_TEST_IP}/24" \
    || { info "Container already exists, deploying config"; }

    pct start "$CTID" 2>/dev/null || true
    sleep 3

    deploy_script "$CTID" "$0"

    info "obs container ready (CTID $CTID)"

    # Deploy Promtail to existing homelab LAN hosts
    deploy_promtail_to_homelab "$script_dir"
}

# ---------------------------------------------------------------------------
# Deploy Promtail to homelab LAN hosts (runs on Proxmox host after obs is up)
# ---------------------------------------------------------------------------

deploy_promtail_to_homelab() {
    local script_dir="$1"
    local promtail_script="$script_dir/04-setup-promtail-lan.sh"

    if [[ ! -f "$promtail_script" ]]; then
        echo "WARN: $promtail_script not found, skipping Promtail deployment" >&2
        return
    fi

    info "Deploying Promtail to homelab LAN hosts"

    # apt-cache (CT 115)
    if pct status 115 &>/dev/null; then
        info "Deploying Promtail to apt-cache (CT 115)"
        deploy_script 115 "$promtail_script"
    else
        echo "WARN: apt-cache (CT 115) not running, skipping" >&2
    fi

    # bittorrent (CT 116)
    if pct status 116 &>/dev/null; then
        info "Deploying Promtail to bittorrent (CT 116)"
        deploy_script 116 "$promtail_script"
    else
        echo "WARN: bittorrent (CT 116) not running, skipping" >&2
    fi

    # vpn-gateway (VM 104, deploy via SSH)
    if qm status 104 &>/dev/null; then
        info "Deploying Promtail to vpn-gateway (VM 104)"
        deploy_script_vm "192.168.1.104" "$promtail_script"
    else
        echo "WARN: vpn-gateway (VM 104) not running, skipping" >&2
    fi

    # nginx-proxy (CT 118)
    if pct status 118 &>/dev/null; then
        info "Deploying Promtail to nginx-proxy (CT 118)"
        deploy_script 118 "$promtail_script"
    else
        echo "WARN: nginx-proxy (CT 118) not running, skipping" >&2
    fi

    # personal-web (CT 117)
    if pct status 117 &>/dev/null; then
        info "Deploying Promtail to personal-web (CT 117)"
        deploy_script 117 "$promtail_script"
    else
        echo "WARN: personal-web (CT 117) not running, skipping" >&2
    fi

    info "Promtail deployment to homelab LAN hosts complete"
}

# ---------------------------------------------------------------------------
# Container-side: configure everything
# ---------------------------------------------------------------------------

configure() {
    [[ $EUID -eq 0 ]] || err "Run as root"

    rm -f /root/.env.bootstrap

    prechecks
    disable_ipv6
    configure_gateway_route
    configure_dns_ntp
    install_packages
    install_loki
    install_prometheus
    install_grafana
    setup_directories
    generate_self_signed_cert
    configure_loki
    configure_prometheus
    configure_alert_rules
    configure_alertmanager
    configure_grafana
    write_systemd_units
    configure_firewall
    start_and_verify
    set_grafana_password
    configure_self_promtail

    cat <<EOF

================================================================
obs observability stack is ready (tri-homed).

Loki:         https://$WOL_IP:3100 (WOL mTLS)
              https://$ACK_IP:3100 (ACK TLS)
              https://$LAN_IP:3100 (external TLS+API key)
Prometheus:   http://$WOL_IP:9090
Alertmanager: http://localhost:9093
Grafana:      http://$LAN_IP

Grafana admin password: /etc/obs/grafana-admin-password

Cert enrollment is automated when CA_FINGERPRINT is set.
1. Enroll Loki server cert (CN=obs, SAN=DNS:obs,IP:$WOL_IP,IP:$LAN_IP,IP:$ACK_IP):
   # Use enroll_cert_from_ca for obs $OBS_ETC/certs/loki-server.crt $OBS_ETC/certs/loki-server.key \\
       --san obs --san $WOL_IP --san $LAN_IP --san $ACK_IP
2. Enroll Prometheus client cert (CN=prometheus):
   # Use enroll_cert_from_ca for prometheus $OBS_ETC/certs/prometheus-client.crt $OBS_ETC/certs/prometheus-client.key
3. Copy root_ca.crt to $OBS_ETC/certs/root_ca.crt
4. Restart Loki: systemctl restart loki
5. Run Promtail setup on all hosts
================================================================
EOF
}

# ---------------------------------------------------------------------------
# Prechecks
# ---------------------------------------------------------------------------

prechecks() {
    info "Running prechecks"
    # CA is optional at bootstrap time (obs is deployed before WOL infra).
    # Cert enrollment happens later when the CA is up.
    if curl -sf "http://$CA_IP:$CA_PORT/api/v1/cfssl/health" &>/dev/null; then
        info "CA reachable at $CA_IP:$CA_PORT"
    else
        echo "NOTE: CA not reachable at $CA_IP:$CA_PORT (expected if WOL is not yet bootstrapped)" >&2
        echo "      Loki will start with a self-signed cert. Enroll a CA cert later." >&2
    fi
    # Gateway is optional (obs may be deployed before WOL gateways)
    if ping -c1 -W2 10.0.0.200 &>/dev/null; then
        info "Gateway reachable"
    else
        echo "NOTE: Gateway not reachable (expected if WOL is not yet bootstrapped)" >&2
    fi
    info "Prechecks passed"
}

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------

install_packages() {
    info "Installing base packages"
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        curl ca-certificates iptables chrony gnupg apt-transport-https python3 jq
}

install_grafana() {
    info "Installing Grafana"
    if ! command -v grafana-server &>/dev/null; then
        curl -fsSL https://apt.grafana.com/gpg.key \
            | gpg --dearmor -o /usr/share/keyrings/grafana.gpg 2>/dev/null || true
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/grafana.gpg] \
https://apt.grafana.com stable main" \
            > /etc/apt/sources.list.d/grafana.list
        apt-get update -qq
        apt-get install -y grafana
    fi
}

install_loki() {
    info "Installing Loki and Promtail via Grafana APT repo"

    # Grafana repo is already configured by install_grafana(); ensure it exists
    if [[ ! -f /etc/apt/sources.list.d/grafana.list ]]; then
        curl -fsSL https://apt.grafana.com/gpg.key \
            | gpg --dearmor -o /usr/share/keyrings/grafana.gpg 2>/dev/null || true
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/grafana.gpg] \
https://apt.grafana.com stable main" \
            > /etc/apt/sources.list.d/grafana.list
        apt-get update -qq
    fi

    apt-get install -y --no-install-recommends loki promtail
}

install_prometheus() {
    info "Installing Prometheus and Alertmanager"
    local prom_version="3.2.1"
    local am_version="0.28.1"
    local arch
    arch=$(dpkg --print-architecture)

    # Stop running services so binaries can be overwritten
    systemctl stop prometheus 2>/dev/null || true
    systemctl stop alertmanager 2>/dev/null || true

    if [[ ! -x /usr/local/bin/prometheus ]]; then
        local prom_tarball="prometheus-${prom_version}.linux-${arch}.tar.gz"
        local url="https://github.com/prometheus/prometheus/releases/download/v${prom_version}/${prom_tarball}"
        curl -fsSL --connect-timeout 30 --retry 3 --retry-delay 5 "$url" -o "/tmp/${prom_tarball}"
        tar -xzf "/tmp/${prom_tarball}" -C /tmp/
        cp "/tmp/prometheus-${prom_version}.linux-${arch}/prometheus" /usr/local/bin/
        cp "/tmp/prometheus-${prom_version}.linux-${arch}/promtool" /usr/local/bin/
        rm -rf "/tmp/${prom_tarball}" "/tmp/prometheus-${prom_version}.linux-${arch}"
    fi

    if [[ ! -x /usr/local/bin/alertmanager ]]; then
        local am_tarball="alertmanager-${am_version}.linux-${arch}.tar.gz"
        local url="https://github.com/prometheus/alertmanager/releases/download/v${am_version}/${am_tarball}"
        curl -fsSL --connect-timeout 30 --retry 3 --retry-delay 5 "$url" -o "/tmp/${am_tarball}"
        tar -xzf "/tmp/${am_tarball}" -C /tmp/
        cp "/tmp/alertmanager-${am_version}.linux-${arch}/alertmanager" /usr/local/bin/
        cp "/tmp/alertmanager-${am_version}.linux-${arch}/amtool" /usr/local/bin/
        rm -rf "/tmp/${am_tarball}" "/tmp/alertmanager-${am_version}.linux-${arch}"
    fi
}

# ---------------------------------------------------------------------------
# Directory structure
# ---------------------------------------------------------------------------

setup_directories() {
    info "Creating directory structure"
    mkdir -p \
        "$OBS_ETC/certs" \
        "$OBS_DATA/loki" \
        "$OBS_DATA/prometheus" \
        "$OBS_DATA/alertmanager" \
        /etc/prometheus/rules.d

    # Loki and Prometheus run as dedicated users
    for svc in loki prometheus alertmanager; do
        id -u "$svc" &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin "$svc"
    done
    chown loki:loki "$OBS_DATA/loki"
    chown prometheus:prometheus "$OBS_DATA/prometheus"
    chown alertmanager:alertmanager "$OBS_DATA/alertmanager"

    copy_root_ca "$OBS_ETC/certs" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Self-signed Loki server cert (replaced by CA cert when CA is available)
# ---------------------------------------------------------------------------

generate_self_signed_cert() {
    if [[ -f "$OBS_ETC/certs/loki-server.crt" ]]; then
        info "Loki server cert already exists, skipping"
        return
    fi

    info "Generating self-signed Loki server certificate"
    openssl req -new -x509 \
        -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
        -keyout "$OBS_ETC/certs/loki-server.key" \
        -out "$OBS_ETC/certs/loki-server.crt" \
        -days 365 \
        -nodes \
        -subj "/CN=obs/O=WOL Infrastructure" \
        -addext "subjectAltName=DNS:obs,IP:$WOL_IP,IP:$LAN_IP,IP:$ACK_IP"

    chmod 600 "$OBS_ETC/certs/loki-server.key"
    chown loki:loki "$OBS_ETC/certs/loki-server.key" "$OBS_ETC/certs/loki-server.crt"

    # Create a placeholder root_ca.crt if it doesn't exist (Loki config references it).
    # Use the self-signed cert as a stand-in until the real root CA is distributed.
    if [[ ! -f "$OBS_ETC/certs/root_ca.crt" ]]; then
        cp "$OBS_ETC/certs/loki-server.crt" "$OBS_ETC/certs/root_ca.crt"
        chown loki:loki "$OBS_ETC/certs/root_ca.crt"
    fi
}

# ---------------------------------------------------------------------------
# Loki configuration
# ---------------------------------------------------------------------------

configure_loki() {
    info "Writing Loki configuration"
    cat > "$OBS_ETC/loki.yaml" <<YAML
auth_enabled: true

server:
  http_listen_port: 3100
  http_tls_config:
    cert_file: $OBS_ETC/certs/loki-server.crt
    key_file: $OBS_ETC/certs/loki-server.key
    client_ca_file: $OBS_ETC/certs/root_ca.crt
    client_auth_type: RequestClientCert

common:
  path_prefix: $OBS_DATA/loki
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory

schema_config:
  configs:
    - from: "2026-01-01"
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

storage_config:
  filesystem:
    directory: $OBS_DATA/loki/chunks

limits_config:
  retention_period: 720h
  per_stream_rate_limit: 3MB
  per_stream_rate_limit_burst: 15MB

compactor:
  working_directory: $OBS_DATA/loki/compactor
  delete_request_store: filesystem
  retention_enabled: true
  retention_delete_delay: 2h
  retention_delete_worker_count: 10
YAML
    chown loki:loki "$OBS_ETC/loki.yaml"
}

# ---------------------------------------------------------------------------
# Prometheus configuration
# ---------------------------------------------------------------------------

configure_prometheus() {
    info "Writing Prometheus configuration"
    cat > /etc/prometheus/prometheus.yml <<YAML
global:
  scrape_interval: 15s
  evaluation_interval: 15s

rule_files:
  - /etc/prometheus/rules.d/*.yml

alerting:
  alertmanagers:
    - static_configs:
        - targets: ['localhost:9093']

scrape_configs:
  # WOL internal services (plain HTTP on private network, mTLS deferred to SPIRE rollout)
  - job_name: wol
    scheme: http
    # Only services with prometheus-net /metrics endpoint.
    # wol-web, wol-realm, spire-server use blackbox /health probes.
    # wol-a and wol-ai will be added when they expose /metrics.
    static_configs:
      - targets: ['10.0.0.207:8443']
        labels:
          name: wol-accounts
      - targets: ['10.0.0.211:8443']
        labels:
          name: wol-world-prod
      - targets: ['10.0.1.216:8443']
        labels:
          name: wol-world-test
    metrics_path: /metrics
    sample_limit: 5000

  # Database hosts (postgres_exporter, plain HTTP on private network)
  - job_name: postgres
    scheme: http
    static_configs:
      - targets: ['10.0.0.202:9187']
        labels:
          name: spire-db
      - targets: ['10.0.0.206:9187']
        labels:
          name: wol-accounts-db
      - targets: ['10.0.0.213:9187']
        labels:
          name: wol-world-db-prod
      - targets: ['10.0.0.214:9187']
        labels:
          name: wol-realm-db-prod
      - targets: ['10.0.1.218:9187']
        labels:
          name: wol-world-db-test
      - targets: ['10.0.1.219:9187']
        labels:
          name: wol-realm-db-test
    sample_limit: 5000

  # SPIRE Server removed from direct scrape (gRPC on :8081, no /metrics endpoint).
  # Monitored via blackbox HTTP probe on :8080/ready instead (see 08-setup-dashboards.sh).

  # ACK hosts (plaintext, isolated network)
  - job_name: ack
    scheme: http
    static_configs:
      - targets: ['10.1.0.246:9187']
        labels:
          name: ack-db
    relabel_configs:
      - target_label: network
        replacement: ack
    sample_limit: 5000

  # Proxmox host (pve-exporter, external network)
  # Do not add a "name" target label here; pve_exporter metrics carry their
  # own "name" label (container/VM hostnames) used by the Host Utilization
  # dashboard.  The dashboard uses job="proxmox" to identify this target.
  - job_name: proxmox
    scheme: http
    metrics_path: /pve
    params:
      target: ['localhost']
      module: ['default']
    static_configs:
      - targets: ['192.168.1.253:9221']

  # Self-monitoring (local Prometheus and Alertmanager, plain HTTP)
  - job_name: obs-self
    static_configs:
      - targets: ['localhost:9090']
        labels:
          name: prometheus
      - targets: ['localhost:9093']
        labels:
          name: alertmanager

  # Self-monitoring Loki (HTTPS; TLS verify skipped for localhost)
  - job_name: obs-loki
    scheme: https
    tls_config:
      insecure_skip_verify: true
    static_configs:
      - targets: ['localhost:3100']
        labels:
          name: loki

  # TrueNAS SCALE (NetData app, Prometheus exporter)
  - job_name: truenas
    scheme: http
    metrics_path: /api/v1/allmetrics
    params:
      format: ['prometheus']
    static_configs:
      - targets: ['192.168.1.254:20489']
        labels:
          name: truenas

  # External services (192.168.0.0/23, TLS required)
  - job_name: external
    scheme: https
    tls_config:
      insecure_skip_verify: false
    file_sd_configs:
      - files: ['/etc/prometheus/external-targets.yml']
    relabel_configs:
      - target_label: network
        replacement: external
    sample_limit: 5000
YAML

    # Empty external targets file
    [[ -f /etc/prometheus/external-targets.yml ]] || echo "[]" > /etc/prometheus/external-targets.yml

    chown prometheus:prometheus /etc/prometheus/prometheus.yml
}

# ---------------------------------------------------------------------------
# Alert rules
# ---------------------------------------------------------------------------

configure_alert_rules() {
    info "Writing Prometheus alert rules"
    cat > /etc/prometheus/rules.d/wol-alerts.yml <<'YAML'
groups:
  - name: wol-infrastructure
    rules:
      - alert: ServiceDown
        expr: up == 0
        for: 30s
        labels:
          severity: critical
        annotations:
          summary: "{{ $labels.instance }} is down"

      - alert: CertRenewalFailed
        expr: increase(cert_renewal_failures_total[5m]) > 0
        labels:
          severity: critical
        annotations:
          summary: "Certificate renewal failed on {{ $labels.instance }}"

      - alert: CertExpiringSoon
        expr: cert_not_after_seconds - time() < 7200
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Certificate on {{ $labels.instance }} expires in < 2 hours"

      - alert: ClockSkewHigh
        expr: abs(ntp_offset_seconds) > 15
        for: 1m
        labels:
          severity: warning
        annotations:
          summary: "NTP offset > 15s on {{ $labels.instance }}"

      - alert: ClockSkewCritical
        expr: abs(ntp_offset_seconds) > 30
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "NTP offset > 30s on {{ $labels.instance }}"

      - alert: SpireAgentUnhealthy
        expr: spire_agent_health != 1
        for: 60s
        labels:
          severity: critical
        annotations:
          summary: "SPIRE Agent unhealthy on {{ $labels.instance }}"

      - alert: SpireServerUnhealthy
        expr: spire_server_health != 1
        for: 30s
        labels:
          severity: critical
        annotations:
          summary: "SPIRE Server unhealthy"

      - alert: HighErrorRate
        expr: sum(rate(http_requests_total{status=~"5.."}[5m])) by (instance) / sum(rate(http_requests_total[5m])) by (instance) > 0.05
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "HTTP 5xx rate > 5% on {{ $labels.instance }}"

      - alert: DBConnectionExhausted
        expr: pg_stat_activity_count / pg_settings_max_connections > 0.8
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "DB connections > 80% on {{ $labels.instance }}"

      - alert: DiskSpaceLow
        expr: node_filesystem_avail_bytes / node_filesystem_size_bytes < 0.15
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Disk space < 15% on {{ $labels.instance }}"

      - alert: AuthDeniedSpike
        expr: rate(auth_denied_total[1m]) > 5
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "Auth denied rate > 5/min on {{ $labels.instance }}"

      - alert: CardinalityBudgetExceeded
        expr: scrape_samples_scraped > 4000
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Scrape cardinality > 4000 on {{ $labels.instance }} (hard cap 5000)"

      - alert: DependencyDown
        expr: dependency_up == 0
        for: 30s
        labels:
          severity: critical
        annotations:
          summary: "{{ $labels.instance }} cannot reach dependency {{ $labels.dependency }}"

  - name: proxmox
    rules:
      - alert: ProxmoxHostCpuHigh
        expr: pve_cpu_usage_ratio{id="node/pve"} > 0.9
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Proxmox host CPU > 90%"

      - alert: ProxmoxHostMemoryHigh
        expr: pve_memory_usage_bytes / pve_memory_size_bytes > 0.9
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Proxmox host memory > 90%"

      - alert: ProxmoxStorageLow
        expr: pve_disk_usage_bytes / pve_disk_size_bytes > 0.85
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Proxmox storage > 85% used"

      - alert: ProxmoxGuestDown
        expr: pve_up{id=~"lxc/.*|qemu/.*"} == 0
        for: 60s
        labels:
          severity: critical
        annotations:
          summary: "Proxmox guest {{ $labels.id }} is down"
YAML
    chown prometheus:prometheus /etc/prometheus/rules.d/wol-alerts.yml
}

# ---------------------------------------------------------------------------
# Alertmanager configuration
# ---------------------------------------------------------------------------

configure_alertmanager() {
    info "Writing Alertmanager configuration"
    mkdir -p /etc/alertmanager
    cat > /etc/alertmanager/alertmanager.yml <<YAML
global:
  resolve_timeout: 5m

route:
  receiver: default
  group_by: ['alertname', 'severity']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  routes:
    - receiver: critical
      match:
        severity: critical
      repeat_interval: 15m
    - receiver: warning
      match:
        severity: warning
      repeat_interval: 1h

receivers:
  - name: default
  - name: critical
    # webhook_configs:
    #   - url: 'https://your-webhook-endpoint'
    #     send_resolved: true
  - name: warning
YAML
    chown alertmanager:alertmanager /etc/alertmanager/alertmanager.yml
}

# ---------------------------------------------------------------------------
# Grafana configuration
# ---------------------------------------------------------------------------

configure_grafana() {
    info "Configuring Grafana datasources"
    mkdir -p /etc/grafana/provisioning/datasources

    cat > /etc/grafana/provisioning/datasources/wol.yml <<YAML
apiVersion: 1
datasources:
  - name: Prometheus
    uid: prometheus
    type: prometheus
    access: proxy
    url: http://localhost:9090
    isDefault: true
    editable: false

  - name: Loki (WOL)
    type: loki
    access: proxy
    url: https://localhost:3100
    editable: false
    jsonData:
      httpHeaderName1: X-Scope-OrgID
      tlsSkipVerify: true
    secureJsonData:
      httpHeaderValue1: wol

  - name: Loki (ACK)
    type: loki
    access: proxy
    url: https://localhost:3100
    editable: false
    jsonData:
      httpHeaderName1: X-Scope-OrgID
      tlsSkipVerify: true
    secureJsonData:
      httpHeaderValue1: ack

  - name: Loki (Homelab)
    type: loki
    access: proxy
    url: https://localhost:3100
    editable: false
    jsonData:
      httpHeaderName1: X-Scope-OrgID
      tlsSkipVerify: true
    secureJsonData:
      httpHeaderValue1: homelab

  - name: Loki (Proxmox)
    type: loki
    access: proxy
    url: https://localhost:3100
    editable: false
    jsonData:
      httpHeaderName1: X-Scope-OrgID
      tlsSkipVerify: true
    secureJsonData:
      httpHeaderValue1: proxmox
YAML

    # Bind Grafana to external interface (stays on port 3000 internally,
    # iptables redirects port 80 -> 3000 so no privileged port binding needed)
    sed -i "s/^;http_addr =.*/http_addr = $EXTERNAL_IP/" /etc/grafana/grafana.ini 2>/dev/null || true
    sed -i "s/^http_addr =.*/http_addr = $EXTERNAL_IP/" /etc/grafana/grafana.ini 2>/dev/null || true

    # Remove any stale port 80 config or capabilities drop-in from prior runs
    sed -i "s/^http_port = 80/http_port = 3000/" /etc/grafana/grafana.ini 2>/dev/null || true
    rm -rf /etc/systemd/system/grafana-server.service.d
    systemctl daemon-reload

    # Disable anonymous access
    sed -i 's/^;enabled = false/enabled = false/' /etc/grafana/grafana.ini 2>/dev/null || true
}

set_grafana_password() {
    # Generate and set Grafana admin password
    local pw_file="/etc/obs/grafana-admin-password"
    if [[ -f "$pw_file" ]]; then
        info "Grafana admin password already set"
        return
    fi

    # Wait for Grafana to be ready (check port 3000 directly; port 80
    # redirect via PREROUTING NAT only applies to external traffic)
    local attempts=0
    while ! curl -sf "http://$EXTERNAL_IP:3000/api/health" &>/dev/null; do
        attempts=$((attempts + 1))
        [[ $attempts -gt 30 ]] && { warn "Grafana not ready, skipping password setup"; return; }
        sleep 2
    done

    local password
    password=$(openssl rand -base64 24)
    grafana-cli admin reset-admin-password "$password" &>/dev/null || { warn "Failed to set Grafana password"; return; }
    echo "$password" > "$pw_file"
    chmod 600 "$pw_file"
    info "Grafana admin password set and saved to $pw_file"
}

# ---------------------------------------------------------------------------
# Systemd units
# ---------------------------------------------------------------------------

write_systemd_units() {
    info "Writing systemd units"

    cat > /etc/systemd/system/loki.service <<EOF
[Unit]
Description=Loki Log Aggregation
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=loki
ExecStart=/usr/bin/loki -config.file=$OBS_ETC/loki.yaml
Restart=always
RestartSec=2
LimitNOFILE=65536
StandardOutput=journal
StandardError=journal
SyslogIdentifier=loki

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/prometheus.service <<EOF
[Unit]
Description=Prometheus Metrics
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=prometheus
ExecStart=/usr/local/bin/prometheus \\
    --config.file=/etc/prometheus/prometheus.yml \\
    --storage.tsdb.path=$OBS_DATA/prometheus \\
    --storage.tsdb.retention.time=15d \\
    --web.listen-address=0.0.0.0:9090 \\
    --web.enable-lifecycle
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=2
LimitNOFILE=65536
StandardOutput=journal
StandardError=journal
SyslogIdentifier=prometheus

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/alertmanager.service <<EOF
[Unit]
Description=Alertmanager
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=alertmanager
ExecStart=/usr/local/bin/alertmanager \\
    --config.file=/etc/alertmanager/alertmanager.yml \\
    --storage.path=$OBS_DATA/alertmanager \\
    --web.listen-address=127.0.0.1:9093
Restart=always
RestartSec=2
StandardOutput=journal
StandardError=journal
SyslogIdentifier=alertmanager

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
}

# ---------------------------------------------------------------------------
# Promtail for obs itself (ships obs logs to local Loki)
# ---------------------------------------------------------------------------

configure_self_promtail() {
    info "Configuring Promtail for obs self-monitoring"
    local promtail_etc="/etc/promtail"
    mkdir -p "$promtail_etc" /var/lib/promtail

    cat > "$promtail_etc/promtail.yaml" <<YAML
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /var/lib/promtail/positions.yaml

clients:
  - url: https://localhost:3100/loki/api/v1/push
    tenant_id: homelab
    tls_config:
      insecure_skip_verify: true

scrape_configs:
  - job_name: journal
    journal:
      max_age: 12h
      labels:
        host: obs
    relabel_configs:
      - source_labels: ['__journal__systemd_unit']
        target_label: service
YAML

    chmod 640 "$promtail_etc/promtail.yaml"

    cat > /etc/systemd/system/promtail.service <<EOF
[Unit]
Description=Promtail Log Shipping Agent (obs self-monitoring)
After=loki.service
Wants=loki.service

[Service]
Type=simple
ExecStart=/usr/bin/promtail -config.file=$promtail_etc/promtail.yaml
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
    info "Promtail running (pushing to local Loki, tenant: homelab)"
}

# ---------------------------------------------------------------------------
# Network and firewall
# ---------------------------------------------------------------------------

disable_ipv6() {
    cat > /etc/sysctl.d/99-disable-ipv6.conf <<SYSCTL
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
SYSCTL
    sysctl -p /etc/sysctl.d/99-disable-ipv6.conf
}

configure_gateway_route() {
    # obs is on the LAN (eth0, default route via 192.168.1.1 from LXC creation).
    # ECMP route through WOL gateways is added only if they are reachable,
    # for WOL-network connectivity. If gateways are not up yet (obs deployed
    # before WOL), the LAN default route is sufficient for internet/apt.
    if ping -c1 -W2 10.0.0.200 &>/dev/null; then
        ip route del default 2>/dev/null || true
        ip route add default nexthop via 10.0.0.200 nexthop via 10.0.0.201
        info "ECMP default route set via WOL gateways"
    else
        info "WOL gateways not reachable, keeping LAN default route (192.168.1.1)"
    fi
}

configure_dns_ntp() {
    # Use WOL gateways for DNS/NTP if reachable, otherwise use the home router.
    if ping -c1 -W2 10.0.0.200 &>/dev/null; then
        cat > /etc/resolv.conf <<RESOLV
nameserver 10.0.0.200
nameserver 10.0.0.201
RESOLV
        info "DNS set to WOL gateways"
    else
        cat > /etc/resolv.conf <<RESOLV
nameserver 192.168.1.1
RESOLV
        info "DNS set to home router (WOL gateways not yet reachable)"
    fi
    if command -v chronyc &>/dev/null; then
        cat > /etc/chrony/chrony.conf <<CHRONY
server 10.0.0.200 iburst prefer
server 10.0.0.201 iburst prefer
server 192.168.1.1 iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
CHRONY
        systemctl restart chrony 2>/dev/null || true
        info "NTP configured (WOL gateways preferred, home router fallback)"
    fi
}

configure_firewall() {
    info "Configuring firewall (quad-homed, iptables)"

    # Flush existing rules
    iptables -F INPUT 2>/dev/null || true
    iptables -F FORWARD 2>/dev/null || true
    iptables -t nat -F PREROUTING 2>/dev/null || true

    # Default policy: drop incoming, allow outgoing
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT ACCEPT

    # Allow established connections and loopback
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A INPUT -i lo -j ACCEPT

    # WOL interface (eth1, 10.0.0.0/20): SSH, Loki (mTLS), Prometheus
    iptables -A INPUT -s 10.0.0.0/20 -p tcp --dport 22 -j ACCEPT
    iptables -A INPUT -s 10.0.0.0/20 -p tcp --dport 3100 -j ACCEPT
    iptables -A INPUT -s 10.0.0.0/20 -p tcp --dport 9090 -j ACCEPT

    # ACK interface (eth2, 10.1.0.0/24): Loki (TLS), Prometheus
    iptables -A INPUT -s 10.1.0.0/24 -p tcp --dport 3100 -j ACCEPT
    iptables -A INPUT -s 10.1.0.0/24 -p tcp --dport 9090 -j ACCEPT

    # WOL test interface (eth3, 10.0.1.0/24): SSH, Loki (mTLS), Prometheus
    iptables -A INPUT -s 10.0.1.0/24 -p tcp --dport 22 -j ACCEPT
    iptables -A INPUT -s 10.0.1.0/24 -p tcp --dport 3100 -j ACCEPT
    iptables -A INPUT -s 10.0.1.0/24 -p tcp --dport 9090 -j ACCEPT

    # LAN interface (eth0, 192.168.0.0/23): Grafana (80 redirected to 3000), Loki, Prometheus
    iptables -A INPUT -s 192.168.0.0/23 -p tcp --dport 80 -j ACCEPT
    iptables -A INPUT -s 192.168.0.0/23 -p tcp --dport 3000 -j ACCEPT
    iptables -A INPUT -s 192.168.0.0/23 -p tcp --dport 3100 -j ACCEPT
    iptables -A INPUT -s 192.168.0.0/23 -p tcp --dport 9090 -j ACCEPT

    # Port 80 -> 3000 redirect for Grafana (avoids privileged port binding)
    iptables -t nat -A PREROUTING -d "$EXTERNAL_IP" -p tcp --dport 80 -j REDIRECT --to-port 3000

    # Persist rules across reboots
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
    iptables -t nat -S >> /etc/iptables/rules.v4 2>/dev/null || true

    # Restore on boot via a simple systemd oneshot
    cat > /etc/systemd/system/iptables-restore.service <<EOF
[Unit]
Description=Restore iptables rules
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore /etc/iptables/rules.v4

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable iptables-restore

    info "Firewall configured (iptables)"
}

# ---------------------------------------------------------------------------
# Start services and postchecks
# ---------------------------------------------------------------------------

start_and_verify() {
    info "Starting observability services"
    # Enable all services, then restart to pick up config changes.
    # Grafana may already be running from APT install with default config
    # (port 3000). Restart ensures it picks up port 80 and the bind address.
    systemctl enable loki prometheus alertmanager grafana-server
    systemctl restart loki prometheus alertmanager grafana-server

    info "Running postchecks (waiting for services to start)"
    local failed=0

    # Loki and Grafana can be slow on first start
    sleep 8

    if curl -sf -k "https://localhost:3100/ready" &>/dev/null; then
        info "Loki: OK"
    else
        echo "WARN: Loki not ready yet (may need cert enrollment first)" >&2
        failed=1
    fi

    if curl -sf "http://localhost:9090/-/healthy" &>/dev/null; then
        info "Prometheus: OK"
    else
        echo "FAIL: Prometheus not healthy" >&2
        failed=1
    fi

    if curl -sf "http://localhost:9093/-/healthy" &>/dev/null; then
        info "Alertmanager: OK"
    else
        echo "FAIL: Alertmanager not healthy" >&2
        failed=1
    fi

    if curl -sf "http://$EXTERNAL_IP:3000/api/health" &>/dev/null; then
        info "Grafana: OK (port 3000, redirected from :80)"
    else
        echo "WARN: Grafana not ready on external interface" >&2
        failed=1
    fi

    if [[ $failed -ne 0 ]]; then
        echo "WARN: Some postchecks failed. Loki may need cert enrollment before it can accept connections."
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if [[ "${1:-}" == "--configure" ]]; then
    configure
else
    host_main
fi
