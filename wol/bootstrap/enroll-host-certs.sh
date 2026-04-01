#!/usr/bin/env bash
# enroll-host-certs.sh -- Enroll CA-issued certs for the current host
#
# Runs on: any WOL host that needs CA-issued certificates
# Run order: After step 05 (CA completed and cfssl running)
#
# Detects what services are installed on this host and enrolls the
# appropriate certificates from the cfssl CA. Idempotent: skips
# enrollment if valid certs already exist.
#
# Services detected:
#   - PostgreSQL: enrolls server cert, updates ssl_ca_file, reloads
#   - Promtail: enrolls client cert, copies root CA
#   - Prometheus: enrolls client cert for mTLS scraping of WOL services (obs only)

set -euo pipefail

_LIB="$(dirname "$0")/lib/common.sh"; [[ -f "$_LIB" ]] || _LIB="/root/lib/common.sh"; source "$_LIB" 2>/dev/null || true

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

[[ $EUID -eq 0 ]] || err "Run as root"

# Boot-time secret scrub
rm -f /root/.env.bootstrap

CA_HOST="${CA_HOST:-10.0.0.203}"
CA_PORT="${CA_PORT:-8443}"

# Verify CA is reachable (this script should only run after the CA is up)
curl -sf "http://${CA_HOST}:${CA_PORT}/api/v1/cfssl/health" &>/dev/null \
    || err "cfssl CA not reachable at ${CA_HOST}:${CA_PORT}"

type enroll_cert_from_ca &>/dev/null \
    || err "enroll_cert_from_ca not available (lib/common.sh not loaded)"

HOSTNAME_LABEL=$(hostname)
info "Enrolling certificates for $HOSTNAME_LABEL"

# ---------------------------------------------------------------------------
# PostgreSQL server cert
# ---------------------------------------------------------------------------

enroll_postgres() {
    local pg_version ssl_dir host_ip cn

    # Detect PostgreSQL version
    pg_version=$(pg_lsclusters -h 2>/dev/null | awk '{print $1; exit}') || true
    [[ -n "$pg_version" ]] || return 0

    ssl_dir="/etc/postgresql/${pg_version}/main/ssl"
    [[ -d "$ssl_dir" ]] || return 0

    # Skip if CA-issued cert already exists (check issuer for "WOL")
    if [[ -f "$ssl_dir/server.crt" ]] && \
       openssl x509 -in "$ssl_dir/server.crt" -noout -issuer 2>/dev/null | grep -q "WOL"; then
        info "PostgreSQL already has a CA-issued cert, skipping"
        return
    fi

    # Determine CN and SANs from hostname and IP
    cn="$HOSTNAME_LABEL"
    host_ip=$(hostname -I 2>/dev/null | awk '{print $1}') || true

    info "Enrolling PostgreSQL server cert (CN=$cn)"
    enroll_cert_from_ca "$cn" \
        "$ssl_dir/server.crt" \
        "$ssl_dir/server.key" \
        "server" \
        "$cn" ${host_ip:+"$host_ip"}

    chown postgres:postgres "$ssl_dir/server.key" "$ssl_dir/server.crt"
    copy_root_ca /etc/ssl/wol

    sed -i "s|^#\?ssl_ca_file = .*|ssl_ca_file = '/etc/ssl/wol/root_ca.crt'|" \
        "/etc/postgresql/${pg_version}/main/postgresql.conf"
    systemctl reload postgresql
    info "PostgreSQL server cert enrolled and loaded"
}

# ---------------------------------------------------------------------------
# Promtail client cert
# ---------------------------------------------------------------------------

enroll_promtail() {
    local promtail_etc="/etc/promtail"

    # Only enroll if Promtail is installed
    [[ -d "$promtail_etc" ]] || return 0
    command -v promtail &>/dev/null || [[ -x /usr/local/bin/promtail ]] || return 0

    # Skip if cert already exists
    if [[ -f "$promtail_etc/certs/promtail-client.crt" ]]; then
        info "Promtail already has a client cert, skipping"
        return
    fi

    mkdir -p "$promtail_etc/certs"
    info "Enrolling Promtail client cert"
    enroll_cert_from_ca "promtail" \
        "$promtail_etc/certs/promtail-client.crt" \
        "$promtail_etc/certs/promtail-client.key" \
        "client"
    copy_root_ca "$promtail_etc/certs"

    systemctl enable --now promtail 2>/dev/null || true
    info "Promtail client cert enrolled and service started"
}

# ---------------------------------------------------------------------------
# Prometheus client cert (obs only, for mTLS scraping of WOL services)
# ---------------------------------------------------------------------------

enroll_prometheus() {
    local obs_certs="/etc/obs/certs"

    # Only enroll on hosts that run Prometheus (obs)
    command -v prometheus &>/dev/null || [[ -f /etc/prometheus/prometheus.yml ]] || return 0

    # Skip if cert already exists
    if [[ -f "$obs_certs/prometheus-client.crt" ]]; then
        info "Prometheus already has a client cert, skipping"
        return
    fi

    mkdir -p "$obs_certs"
    info "Enrolling Prometheus client cert"
    enroll_cert_from_ca "prometheus" \
        "$obs_certs/prometheus-client.crt" \
        "$obs_certs/prometheus-client.key" \
        "client"
    copy_root_ca "$obs_certs"

    chown prometheus:prometheus "$obs_certs/prometheus-client.crt" "$obs_certs/prometheus-client.key"
    chmod 644 "$obs_certs/prometheus-client.crt"
    chmod 600 "$obs_certs/prometheus-client.key"

    systemctl reload prometheus 2>/dev/null || systemctl restart prometheus 2>/dev/null || true
    info "Prometheus client cert enrolled and Prometheus reloaded"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

enroll_postgres
enroll_promtail
enroll_prometheus

info "Certificate enrollment complete on $HOSTNAME_LABEL"
