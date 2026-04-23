#!/usr/bin/env bash
# 09-setup-deploy.sh -- Set up the deployment container (quad-homed)
#
# Runs on: deploy, Debian 13 LXC (quad-homed)
#   eth0 = 192.168.1.101/23 on vmbr0 (Home LAN, internet-facing SSH)
#   eth1 = 10.0.0.101/20 on vmbr1 (WOL prod)
#   eth2 = 10.1.0.101/24 on vmbr2 (ACK private)
#   eth3 = 10.0.1.101/24 on vmbr3 (WOL test)
# CTID: 101
#
# Provides:
#   - SSH on :2222 (key-only, deploy user only, GitHub IP allowlist)
#   - Full build environment: C, .NET 9, Python 3, Node.js
#   - SSH keypair for outbound deployment to target containers
#   - Dispatch script for GitHub Actions deployments
#   - Promtail log shipping
#
# Usage:
#   ./09-setup-deploy.sh --configure    # Run inside the container

set -euo pipefail

LAN_IP="192.168.1.101"
WOL_IP="10.0.0.101"
ACK_IP="10.1.0.101"
WOL_TEST_IP="10.0.1.101"
SSH_PORT="2222"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

# ---------------------------------------------------------------------------
# Container-side: configure everything
# ---------------------------------------------------------------------------

configure() {
    [[ $EUID -eq 0 ]] || err "Run as root"

    disable_ipv6
    configure_dns
    install_packages
    install_dotnet
    install_node
    setup_deploy_user
    configure_sshd
    setup_github_ipset
    configure_firewall
    setup_dispatch
    setup_deploy_ssh_key
    setup_poll_deploy

    cat <<EOF

================================================================
deploy container is ready (quad-homed).

LAN:      $LAN_IP (eth0, internet-facing SSH on :$SSH_PORT)
WOL prod: $WOL_IP (eth1)
ACK:      $ACK_IP (eth2)
WOL test: $WOL_TEST_IP (eth3)

SSH:      Port $SSH_PORT, deploy user only, key-only auth
          GitHub Actions IPs allowlisted via ipset
          LAN + private networks allowed

Build:    C (gcc, lua, libpq), .NET 9, Python 3, Node.js

Next steps:
  1. Add GitHub deploy key to ~deploy/.ssh/authorized_keys
  2. Configure router port forward: external :$SSH_PORT -> $LAN_IP:$SSH_PORT
  3. Add deploy user + SSH key to target containers
  4. Add deploy.sh scripts to each repo
================================================================
EOF
}

# ---------------------------------------------------------------------------
# Disable IPv6
# ---------------------------------------------------------------------------

disable_ipv6() {
    info "Disabling IPv6"
    cat > /etc/sysctl.d/99-disable-ipv6.conf <<SYSCTL
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
SYSCTL
    sysctl -p /etc/sysctl.d/99-disable-ipv6.conf
}

# ---------------------------------------------------------------------------
# DNS (use router on LAN)
# ---------------------------------------------------------------------------

configure_dns() {
    info "Configuring DNS resolver"
    cat > /etc/resolv.conf <<RESOLV
nameserver 192.168.1.1
RESOLV
}

# ---------------------------------------------------------------------------
# Build tool packages
# ---------------------------------------------------------------------------

install_packages() {
    info "Installing build tools and system packages"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        build-essential gcc make \
        libcrypt-dev zlib1g-dev libssl-dev libpq-dev liblua5.4-dev pkg-config \
        python3 python3-pip python3-venv \
        git openssh-client openssh-server \
        curl ca-certificates sudo \
        iptables ipset \
        jq cron rsync
    info "Build tools installed"
}

# ---------------------------------------------------------------------------
# .NET 9 SDK
# ---------------------------------------------------------------------------

install_dotnet() {
    if command -v dotnet &>/dev/null && dotnet --list-sdks 2>/dev/null | grep -q "^9\."; then
        info ".NET 9 SDK already installed"
        return
    fi

    info "Installing .NET 9 SDK"
    local script="/tmp/dotnet-install.sh"
    if [[ ! -f "$script" ]]; then
        curl -fsSL https://dot.net/v1/dotnet-install.sh -o "$script"
        chmod +x "$script"
    fi

    local dotnet_root="/usr/local/dotnet"
    bash "$script" --channel 9.0 --install-dir "$dotnet_root"
    ln -sf "$dotnet_root/dotnet" /usr/local/bin/dotnet
    info ".NET 9 SDK installed"
}

# ---------------------------------------------------------------------------
# Node.js (via nodesource or system package)
# ---------------------------------------------------------------------------

install_node() {
    if command -v node &>/dev/null; then
        info "Node.js already installed"
        return
    fi

    info "Installing Node.js"
    apt-get install -y --no-install-recommends nodejs npm
    info "Node.js installed"
}

# ---------------------------------------------------------------------------
# Deploy user
# ---------------------------------------------------------------------------

setup_deploy_user() {
    if id deploy &>/dev/null; then
        info "Deploy user already exists"
        return
    fi

    info "Creating deploy user"
    useradd --system --create-home --shell /bin/bash deploy
    mkdir -p /home/deploy/.ssh
    chmod 700 /home/deploy/.ssh
    touch /home/deploy/.ssh/authorized_keys
    chmod 600 /home/deploy/.ssh/authorized_keys
    chown -R deploy:deploy /home/deploy/.ssh

    # Deploy workspace
    mkdir -p /opt/deploy/repos /var/log/deploy
    chown -R deploy:deploy /opt/deploy /var/log/deploy

    info "Deploy user created"
}

# ---------------------------------------------------------------------------
# SSH server configuration
# ---------------------------------------------------------------------------

configure_sshd() {
    info "Configuring sshd (port $SSH_PORT, key-only, deploy user only)"

    cat > /etc/ssh/sshd_config.d/deploy.conf <<SSHD
Port $SSH_PORT
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
AllowUsers deploy
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
SSHD

    # Disable default port 22
    if grep -q "^Port 22$" /etc/ssh/sshd_config 2>/dev/null; then
        sed -i 's/^Port 22$/# Port 22  # disabled, using deploy.conf/' /etc/ssh/sshd_config
    fi

    systemctl restart sshd
    info "sshd configured on port $SSH_PORT"
}

# ---------------------------------------------------------------------------
# GitHub Actions IP allowlist (ipset + cron refresh)
# ---------------------------------------------------------------------------

setup_github_ipset() {
    info "Setting up GitHub Actions IP allowlist"

    # Create the refresh script
    cat > /opt/deploy/refresh-github-ips.sh <<'REFRESH'
#!/usr/bin/env bash
# Refresh the github-actions ipset from GitHub's /meta API.
# Called by cron daily. Preserves existing set if API is unreachable.

set -euo pipefail

IPSET_NAME="github-actions"
META_URL="https://api.github.com/meta"
TMP="/tmp/github-ips.json"

# Fetch GitHub metadata
if ! curl -sf --connect-timeout 10 "$META_URL" -o "$TMP" 2>/dev/null; then
    echo "$(date): GitHub API unreachable, keeping existing ipset" >> /var/log/deploy/github-ips.log
    exit 0
fi

# Extract "actions" CIDR ranges (IPv4 only)
CIDRS=$(jq -r '.actions[]' "$TMP" 2>/dev/null | grep -v ':')

if [[ -z "$CIDRS" ]]; then
    echo "$(date): No CIDRs found, keeping existing ipset" >> /var/log/deploy/github-ips.log
    rm -f "$TMP"
    exit 0
fi

# Create a temporary ipset, swap it in atomically
ipset create "${IPSET_NAME}-new" hash:net -exist
ipset flush "${IPSET_NAME}-new"

while IFS= read -r cidr; do
    ipset add "${IPSET_NAME}-new" "$cidr" -exist
done <<< "$CIDRS"

ipset swap "${IPSET_NAME}-new" "$IPSET_NAME" 2>/dev/null || {
    # First run: main set doesn't exist yet
    ipset rename "${IPSET_NAME}-new" "$IPSET_NAME"
}
ipset destroy "${IPSET_NAME}-new" 2>/dev/null || true

COUNT=$(ipset list "$IPSET_NAME" | grep -c "^[0-9]" || echo 0)
echo "$(date): Updated $IPSET_NAME with $COUNT CIDRs" >> /var/log/deploy/github-ips.log
rm -f "$TMP"
REFRESH

    chmod +x /opt/deploy/refresh-github-ips.sh

    # Create the initial ipset
    ipset create github-actions hash:net -exist

    # Run initial population
    /opt/deploy/refresh-github-ips.sh || info "WARNING: initial GitHub IP fetch failed, ipset empty until cron runs"

    # Cron job: refresh daily at 03:00
    cat > /etc/cron.d/github-ips <<CRON
0 3 * * * root /opt/deploy/refresh-github-ips.sh
CRON

    info "GitHub Actions ipset configured (refreshed daily at 03:00)"
}

# ---------------------------------------------------------------------------
# Firewall (iptables)
# ---------------------------------------------------------------------------

configure_firewall() {
    info "Configuring firewall"

    iptables -F INPUT 2>/dev/null || true

    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT ACCEPT

    # Established connections + loopback
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A INPUT -i lo -j ACCEPT

    # SSH on :$SSH_PORT from GitHub Actions IP ranges (eth0 only)
    iptables -A INPUT -i eth0 -p tcp --dport "$SSH_PORT" \
        -m set --match-set github-actions src -j ACCEPT

    # SSH on :$SSH_PORT from LAN (operator access)
    iptables -A INPUT -i eth0 -s 192.168.1.0/23 -p tcp --dport "$SSH_PORT" -j ACCEPT

    # SSH from private networks (operator access)
    iptables -A INPUT -s 10.0.0.0/20 -p tcp --dport "$SSH_PORT" -j ACCEPT
    iptables -A INPUT -s 10.0.1.0/24 -p tcp --dport "$SSH_PORT" -j ACCEPT
    iptables -A INPUT -s 10.1.0.0/24 -p tcp --dport "$SSH_PORT" -j ACCEPT

    # Persist rules
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4

    # Restore on boot
    if [[ ! -f /etc/systemd/system/iptables-restore.service ]]; then
        cat > /etc/systemd/system/iptables-restore.service <<'UNIT'
[Unit]
Description=Restore iptables rules
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c '/sbin/ipset restore < /etc/iptables/ipset.save 2>/dev/null || true; /sbin/iptables-restore /etc/iptables/rules.v4'

[Install]
WantedBy=multi-user.target
UNIT
        systemctl daemon-reload
        systemctl enable iptables-restore
    fi

    # Save ipset for restore on boot
    ipset save > /etc/iptables/ipset.save

    info "Firewall configured (SSH :$SSH_PORT from GitHub IPs + LAN + private networks)"
}

# ---------------------------------------------------------------------------
# Dispatch script
# ---------------------------------------------------------------------------

setup_dispatch() {
    info "Creating dispatch script"

    cat > /opt/deploy/dispatch.sh <<'DISPATCH'
#!/usr/bin/env bash
# dispatch.sh -- Entry point for deployments.
#
# Called two ways:
#   1. Via SSH command= restriction (GitHub Actions sets SSH_ORIGINAL_COMMAND)
#   2. Directly by poll-deploy.sh (sets REPO/REF as env vars)

set -euo pipefail

LOG_DIR="/var/log/deploy"
REPO_DIR="/opt/deploy/repos"

eval "$SSH_ORIGINAL_COMMAND" 2>/dev/null || true

REPO="${REPO:-}"
REF="${REF:-main}"

if [[ -z "$REPO" ]]; then
    echo "ERROR: REPO not set" >&2
    exit 1
fi

REPO_NAME="${REPO##*/}"
REPO_PATH="$REPO_DIR/$REPO_NAME"
LOG_FILE="$LOG_DIR/${REPO_NAME}.log"

ALLOWED_REPOS=(
    "JBailes/wol-docs"
    "JBailes/wol"
    "JBailes/wol-realm"
    "JBailes/wol-accounts"
    "JBailes/wol-world"
    "JBailes/wol-ai"
    "JBailes/wol-client"
    "ackmudhistoricalarchive/web"
    "JBailes/web-personal"
    "ackmudhistoricalarchive/tng-ai"
    "ackmudhistoricalarchive/acktng"
    "ackmudhistoricalarchive/tngdb"
    "ackmudhistoricalarchive/ackmud431"
    "ackmudhistoricalarchive/ackmud42"
    "ackmudhistoricalarchive/ackmud41"
    "ackmudhistoricalarchive/Assault3.0"
)

ALLOWED=0
for allowed in "${ALLOWED_REPOS[@]}"; do
    [[ "$REPO" == "$allowed" ]] && ALLOWED=1 && break
done

if [[ "$ALLOWED" -eq 0 ]]; then
    echo "ERROR: $REPO is not in the deployment allowlist" >&2
    exit 1
fi

# Private repos use per-repo SSH host aliases (see ~/.ssh/config)
declare -A SSH_HOSTS=(
    ["JBailes/wol-realm"]="github-wol-realm"
    ["JBailes/wol-accounts"]="github-wol-accounts"
    ["JBailes/wol-world"]="github-wol-world"
    ["JBailes/wol-ai"]="github-wol-ai"
    ["JBailes/wol-client"]="github-wol-client"
    ["ackmudhistoricalarchive/tng-ai"]="HTTPS"
)

GIT_HOST="${SSH_HOSTS[$REPO]:-github.com}"
if [[ "$GIT_HOST" == "HTTPS" ]]; then
    CLONE_URL="https://github.com/${REPO}.git"
else
    CLONE_URL="git@${GIT_HOST}:${REPO}.git"
fi

echo "$(date): Deploying $REPO @ $REF" | tee -a "$LOG_FILE"

if [[ -d "$REPO_PATH/.git" ]]; then
    cd "$REPO_PATH"
    git remote set-url origin "$CLONE_URL"
    git fetch origin 2>&1 | tee -a "$LOG_FILE"
else
    git clone "$CLONE_URL" "$REPO_PATH" 2>&1 | tee -a "$LOG_FILE"
    cd "$REPO_PATH"
fi

git checkout "$REF" 2>&1 | tee -a "$LOG_FILE"

if [[ -x "deploy.sh" ]]; then
    echo "$(date): Running deploy.sh" | tee -a "$LOG_FILE"
    ./deploy.sh 2>&1 | tee -a "$LOG_FILE"
    echo "$(date): Deploy complete" | tee -a "$LOG_FILE"
else
    echo "$(date): No deploy.sh found, clone/checkout only" | tee -a "$LOG_FILE"
fi
DISPATCH

    chmod +x /opt/deploy/dispatch.sh
    chown deploy:deploy /opt/deploy/dispatch.sh

    info "Dispatch script created at /opt/deploy/dispatch.sh"
}

# ---------------------------------------------------------------------------
# SSH keypair for outbound deployment connections
# ---------------------------------------------------------------------------

setup_deploy_ssh_key() {
    info "Setting up SSH keys for outbound connections"

    # Main key for target container deployments
    local key_file="/home/deploy/.ssh/id_ed25519"
    if [[ ! -f "$key_file" ]]; then
        sudo -u deploy ssh-keygen -t ed25519 -f "$key_file" -N "" -C "deploy@deploy"
        info "Main deploy key generated (add to target containers)"
    fi

    # Per-repo keys for private GitHub repos (each repo needs a unique deploy key)
    local private_repos=(wol-realm wol-accounts wol-world wol-ai wol-client tng-ai)
    for repo in "${private_repos[@]}"; do
        local repo_key="/home/deploy/.ssh/id_${repo}"
        if [[ ! -f "$repo_key" ]]; then
            sudo -u deploy ssh-keygen -t ed25519 -f "$repo_key" -N "" -C "deploy-${repo}"
            info "Key generated for $repo (add as deploy key on GitHub)"
        fi
    done

    # SSH config: per-repo host aliases for private repos
    sudo -u deploy bash -c 'cat > ~/.ssh/config <<SSHCONF
# Per-repo deploy keys for GitHub private repos
Host github-wol-realm
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_wol-realm
    IdentitiesOnly yes

Host github-wol-accounts
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_wol-accounts
    IdentitiesOnly yes

Host github-wol-world
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_wol-world
    IdentitiesOnly yes

Host github-wol-ai
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_wol-ai
    IdentitiesOnly yes

Host github-wol-client
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_wol-client
    IdentitiesOnly yes

Host github-tng-ai
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_tng-ai
    IdentitiesOnly yes

# Default for public repos
Host github.com
    User git
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
SSHCONF
chmod 600 ~/.ssh/config'

    # Add GitHub host key to known_hosts
    sudo -u deploy bash -c 'ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null'

    info "SSH keys and config ready"
    info "Per-repo public keys (add to GitHub):"
    for repo in "${private_repos[@]}"; do
        echo "  $repo: $(cat /home/deploy/.ssh/id_${repo}.pub)"
    done
}

# ---------------------------------------------------------------------------
# Poll-based deployment for public repos
# ---------------------------------------------------------------------------

setup_poll_deploy() {
    info "Setting up poll-based deployment for public repos"

    cat > /opt/deploy/poll-deploy.sh <<'POLL'
#!/usr/bin/env bash
# poll-deploy.sh -- Check public repos for new commits and deploy if changed.
# Runs via cron every 5 minutes.

set -euo pipefail

LOG="/var/log/deploy/poll.log"
REPO_DIR="/opt/deploy/repos"
DISPATCH="/opt/deploy/dispatch.sh"

REPOS=(
    "ackmudhistoricalarchive/acktng"
    "ackmudhistoricalarchive/ackmud431"
    "ackmudhistoricalarchive/ackmud42"
    "ackmudhistoricalarchive/ackmud41"
    "ackmudhistoricalarchive/Assault3.0"
    "ackmudhistoricalarchive/tngdb"
)

for REPO in "${REPOS[@]}"; do
    REPO_NAME="${REPO##*/}"
    REPO_PATH="$REPO_DIR/$REPO_NAME"

    REMOTE_HEAD=$(git ls-remote "https://github.com/${REPO}.git" HEAD 2>/dev/null | awk '{print $1}')
    if [[ -z "$REMOTE_HEAD" ]]; then
        continue
    fi

    LOCAL_HEAD=""
    if [[ -d "$REPO_PATH/.git" ]]; then
        LOCAL_HEAD=$(git -C "$REPO_PATH" rev-parse HEAD 2>/dev/null || echo "")
    fi

    if [[ "$REMOTE_HEAD" != "$LOCAL_HEAD" ]]; then
        echo "$(date): $REPO changed ($LOCAL_HEAD -> $REMOTE_HEAD), deploying" >> "$LOG"
        SSH_ORIGINAL_COMMAND="REPO=$REPO REF=$REMOTE_HEAD" "$DISPATCH" >> "$LOG" 2>&1
    fi
done
POLL

    chmod +x /opt/deploy/poll-deploy.sh
    chown deploy:deploy /opt/deploy/poll-deploy.sh

    # Cron: poll every 5 minutes
    cat > /etc/cron.d/poll-deploy <<CRON
*/5 * * * * deploy /opt/deploy/poll-deploy.sh
CRON

    info "Poll deploy configured (every 5 minutes for public ACK repos)"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if [[ "${1:-}" == "--configure" ]]; then
    configure
else
    echo "Usage: $0 --configure (run inside the container)"
    echo "This script is deployed to CT 101 by the operator."
    exit 1
fi
