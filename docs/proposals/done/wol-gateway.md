# WOL Gateway

> **Note:** This proposal was written before the multi-environment split. Hostnames like `wol-realm-a` are now `wol-realm-prod` and `wol-realm-test`. See `infrastructure/hosts.md` for the current layout.

**Status:** Active
**Created:** 2026-03-25

## Problem

The WOL infrastructure lacks a network boundary. All hosts (API services, databases, SPIRE, step-ca) sit on a private network, but there is no defined ingress/egress point for reaching the outside world. Hosts need outbound internet access for package installation, certificate issuance (Let's Encrypt, certbot), and OS updates, but this access must be controlled and mediated through a defined gateway layer.

## Service architecture

The WOL system has two distinct .NET services that run on separate hosts:

- **wol** (repo: `wol/`): Stateless connection interface. Handles telnet, TLS telnet, WebSocket, and WSS protocols. Accepts game client connections on port 6969 and passes data back and forth between clients and the realm. Calls API services (accounts, players, world) directly on the private network via mTLS. Designed for horizontal autoscaling: many wol instances can run simultaneously, each maintaining no state beyond its active client connections.

- **wol-realm** (repo: `wol-realm/`): The game engine. Runs the MUD world simulation (rooms, NPCs, combat, ticks, game logic). Internal-only service on the private network. wol instances connect to wol-realm to relay game traffic.

## Network architecture

The WOL network is a physically isolated private network (10.0.0.0/20). Two types of hosts have external interfaces:

1. **wol-gateway-a (10.0.0.200) and wol-gateway-b (10.0.0.201):** Active-active dual-homed gateways. Both provide controlled outbound internet access for all internal hosts (NAT gateway). Internal hosts use both gateways simultaneously via ECMP (equal-cost multi-path) routing, so traffic is load-balanced and either gateway can fail independently without disrupting the other. The gateways have no application-layer services (no reverse proxy, no API routing). They are pure network infrastructure.

2. **wol instances (10.0.0.208+):** Each has its own external interface, but it is **locked down to game client traffic only** (port 6969). wol instances cannot reach arbitrary internet hosts through their external interface; iptables OUTPUT rules restrict it to established connections on port 6969. Game clients connect directly to wol instances, not through the gateway.

All other hosts (including wol-realm) have only a private interface and no route to the internet except through the gateways' NAT.

```
                          +-------------------------------------------------------------+
                          |              WOL Private Network (10.0.0.0/20)              |
                          |              Physically isolated                            |
Internet                  |                                                             |
  |                       |  +--------------+  +--------------+                         |
  +----| wol-gw-a     |---+  |  10.0.0.207    |  |               |                         |
  |    |  10.0.0.200    |   |  +--------------+  +--------------+                         |
  |    | NAT/DNS/NTP  |   |  +--------------+  +--------------+  +--------------+       |
  |    +--------------+   |  | wol-world    |  | wol-realm    |  | spire-server |       |
  |    +--------------+   |  |  10.0.0.211    |  |  10.0.0.210   |  |  10.0.0.204    |       |
  +----| wol-gw-b     |---+  +--------------+  | (internal)   |  +--------------+       |
  |    |  10.0.0.201    |   |                    +--------------+                         |
  |    | NAT/DNS/NTP  |   |  +--------------+  +--------------+  +--------------+       |
  |    +--------------+   |  | step-ca      |  | provisioning |  | spire-db     |       |
  |                       |  |  10.0.0.203    |  |  10.0.0.205    |  |  10.0.0.202   |       |
  |    +--------------+   |  +--------------+  +--------------+  +--------------+       |
  +----| wol-a        |---+  +--------------+  +--------------+                         |
  |    |  :6969 only  |   |  |  10.0.0.213   |                         |
  |    +--------------+   |  +--------------+  +--------------+                         |
                          +-------------------------------------------------------------+
```

### Traffic flow summary

| Source | Destination | Path | Purpose |
|--------|-------------|------|---------|
| Game clients | wol-a :6969 | Direct (wol's external interface) | Telnet, TLS telnet, WS, WSS |
| wol-a | wol-realm-{prod,test} | Private network (direct) | Game world I/O relay |
| wol-a | wol-accounts :8443 | Private network (direct, mTLS) | Authentication, sessions |
| wol-a | wol-world :8443 | Private network (direct, mTLS) | World data |
| Any internal host | Internet | Via wol-gateway-a or wol-gateway-b NAT (ECMP) | apt, certbot, package downloads |
| API services | DB hosts | Private network (direct) | PostgreSQL over mTLS |

## Proposal

### 1. NAT gateway (outbound internet for internal hosts)

Each gateway's sole role is providing outbound internet access for hosts that have no external interface. Both run NAT masquerading so internal hosts can reach package repositories, Let's Encrypt ACME servers, and other operational endpoints.

```bash
# Persistent NAT configuration
iptables -t nat -A POSTROUTING -s 10.0.0.0/20 -o eth0 -j MASQUERADE
echo 1 > /proc/sys/net/ipv4/ip_forward
```

Both gateways run identical configurations. Internal hosts use ECMP routing with both gateways as equal-cost next hops, so traffic is load-balanced and either gateway can fail independently.

**Outbound filtering:** Each gateway restricts outbound NAT to specific destination ports and protocols. Internal hosts can reach:
- TCP 80, 443 (apt repositories, Let's Encrypt, package downloads)
- TCP 53, UDP 53 (DNS)
- All other outbound traffic is dropped

No inbound traffic from the internet is accepted on either gateway's external interface. The gateways have no public-facing services.

**DNS forwarder (dnsmasq):** Both gateways run dnsmasq on their private interfaces, forwarding queries to upstream DNS servers (1.1.1.1, 8.8.8.8) via their external interfaces. All internal hosts list both gateways in `/etc/resolv.conf` (`nameserver 10.0.0.200` and `nameserver 10.0.0.201`). The resolver library handles failover natively. Both dnsmasq instances serve identical local hostname entries for all WOL hosts.

**NTP server (chrony):** Both gateways sync to public NTP pools via their external interfaces and serve time to the private network. All internal hosts configure both gateways as chrony sources (`server 10.0.0.200 iburst` and `server 10.0.0.201 iburst`). chrony selects the best source automatically and fails over if one becomes unreachable. Accurate clocks are critical for mTLS certificate validation and SPIRE SVID TTLs. chrony is the only NTP daemon used across all hosts (no ntpd). NTS (Network Time Security) should be enabled on each gateway's upstream pool connections where supported (`server pool.ntp.org iburst nts`). Internal hosts trust the gateways over the physically isolated network, so NTS is not required on the internal leg.

**Default route (ECMP):** All single-homed internal hosts set two equal-cost default routes, one via each gateway (`ip route add default nexthop via 10.0.0.200 nexthop via 10.0.0.201`). The kernel load-balances outbound traffic across both paths. If one gateway goes down, its route becomes unreachable and traffic flows entirely through the surviving gateway. Each host's bootstrap script configures this route before installing packages.

**IPv6 disabled:** IPv6 is disabled on all hosts via sysctl (`net.ipv6.conf.all.disable_ipv6=1`) to prevent IPv6 egress bypassing the IPv4 NAT and firewall rules.

### 2. wol external interface (client-facing)

wol instances have their own external interface for game client traffic. This is NOT routed through the gateway. Game clients connect directly to wol instances.

Each wol instance's external interface is locked down with iptables:

```bash
# Only accept game client connections on :6969
iptables -A INPUT -i eth0 -p tcp --dport 6969 -j ACCEPT
iptables -A INPUT -i eth0 -j DROP

# Only allow outbound traffic for established game connections
iptables -A OUTPUT -o eth0 -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -o eth0 -j DROP
```

The wol instance cannot initiate outbound connections on its external interface. It cannot reach the internet. It can only respond to incoming game client connections on port 6969.

**Firewall toolchain note:** Dual-homed hosts (wol-gateway-a, wol-gateway-b, and wol instances) use raw iptables for the external interface and ufw for the internal interface. This is intentional: ufw manages simple allow/deny rules on the private network, while raw iptables provides precise control over the external interface lockdown (interface-specific INPUT/OUTPUT chains, FORWARD rules, NAT). The two toolchains operate on separate interfaces and do not conflict. Rules from both are persisted together via `netfilter-persistent save`.

For TLS (TLS telnet and WSS), wol uses its SPIRE-issued certificate from the private CA. MUD clients typically do not verify CA trust chains. For browser-based clients (WSS), wol needs a publicly-trusted certificate, obtained via certbot through the gateways' NAT (wol's internal interface routes to the internet via the ECMP default route through both gateways).

**ACME operational profile (certbot):**
- **Challenge method:** DNS-01 only. The wol instance's external IP may not match the domain's DNS, making HTTP-01 unreliable. DNS-01 also avoids opening any additional ports on the external interface.
- **DNS API token:** A narrowly scoped API token for the DNS provider, with permissions limited to TXT record creation/deletion on the specific domain zone. Stored at `/etc/wol/secrets/dns-api-token` with mode 600, owned by root. The token is never readable by the wol service user.
- **Token rotation:** DNS API tokens are rotated every 90 days. The rotation procedure is: generate new token at the DNS provider, update the file on each wol instance, verify renewal works, revoke the old token.
- **Audit trail:** certbot logs to `/var/log/wol/certbot.log`. Certificate issuance events (new cert, renewal, failure) are logged with timestamps.
- **Emergency revoke:** If a private key is compromised, revoke the certificate immediately via `certbot revoke`, rotate the DNS API token, and re-issue. The revoke/re-issue procedure should be tested during DR drills.
- **Renewal:** certbot runs as a systemd timer (twice daily, standard certbot behavior). On successful renewal, the wol service is reloaded to pick up the new certificate.

### 3. wol-to-API communication (direct mTLS on private network)

wol instances call API services directly on the private network. There is no API gateway or reverse proxy. Each wol instance knows the addresses of the API services and connects to them via mTLS using its SPIRE X.509-SVID.

```
wol-a  --mTLS-->  wol-accounts  (10.0.0.207:8443)
wol-a  --mTLS-->  wol-world     (10.0.0.211:8443)
```

The wol instance presents its SPIRE X.509-SVID (`spiffe://wol/server-a`). The API service verifies it against the SPIRE trust bundle. The wol instance also sends its JWT-SVID in the `Authorization` header for request-level authorization.

### 4. SPIRE identities

```
spiffe://wol/server-a
  parentID: spiffe://wol/node/wol-a
  selectors:
    unix:uid:1006
    unix:path:/usr/lib/wol/bin/start
```

Used for:
- mTLS to API services (accounts, players, world)
- mTLS to wol-realm
- wol instance identity for authorization

API services verify the exact SPIFFE ID URI SAN against an allowlist. Each API service maintains an explicit list of accepted SPIFFE IDs (e.g., `spiffe://wol/server-a`, `spiffe://wol/server-b`). Wildcard or prefix matching is not used; new wol instances must be added to the allowlist before they can call API services. This prevents unintended identity acceptance from malformed or unexpected SPIFFE IDs.

```
spiffe://wol/realm-a
  parentID: spiffe://wol/node/wol-realm-prod
  selectors:
    unix:uid:1001
    unix:path:/usr/lib/wol-realm/bin/start
```

Used for:
- mTLS for wol-to-realm communication on the private network

## Host setup

### wol-gateway-a and wol-gateway-b

| Property | wol-gateway-a | wol-gateway-b |
|----------|---------------|---------------|
| Hostname | `wol-gateway-a` | `wol-gateway-b` |
| Internal IP | `10.0.0.200` | `10.0.0.201` |
| External IP | Assigned by hosting provider | Assigned by hosting provider |
| Type | LXC (privileged, dual-homed) | LXC (privileged, dual-homed) |
| OS | Debian 13 | Debian 13 |
| Interfaces | 2 (private: `eth1` on 10.0.0.0/20, public: `eth0`) | 2 (private: `eth1` on 10.0.0.0/20, public: `eth0`) |

Both gateways are identical in configuration and role. They are pure network infrastructure: NAT, DNS forwarding, and NTP. They do not run application-layer services and do not need a SPIRE Agent or workload identity. A privileged LXC is acceptable because the gateways run no application code, no workload identity, and no user-facing services. Their attack surface is limited to kernel-level packet forwarding and two small network daemons (dnsmasq, chrony) running as unprivileged users. If the blast radius concern increases in the future (e.g., adding application services), the gateways should be migrated to VMs.

#### Bootstrap script: `00-setup-gateway.sh`

Runs on: wol-gateway-a (10.0.0.200) and wol-gateway-b (10.0.0.201)
Run order: Step 0 (both must be up before all other hosts, which need NAT for apt)

The script is parameterized for multiple instances:

```bash
GW_NAME=wol-gateway-a GW_IP=10.0.0.200 \
    ./00-setup-gateway.sh

GW_NAME=wol-gateway-b GW_IP=10.0.0.201 \
    ./00-setup-gateway.sh
```

The script sets up:
- NAT masquerading and IP forwarding (persistent via iptables-persistent)
- Outbound traffic filtering (restrict NAT to ports 80, 443, 53)
- IPv6 disabled via sysctl
- chrony NTP server for internal hosts
- dnsmasq DNS forwarder for internal hosts (identical host entries on both)
- Firewall rules (iptables on external, ufw on internal)

#### Firewall rules

Both gateways use identical firewall rules.

External interface (`eth0`):
```bash
# No inbound traffic accepted on external interface
iptables -A INPUT -i eth0 -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -i eth0 -j DROP

# Forward NAT traffic from internal hosts (restricted destinations)
iptables -A FORWARD -i eth1 -o eth0 -p tcp --dport 80 -j ACCEPT
iptables -A FORWARD -i eth1 -o eth0 -p tcp --dport 443 -j ACCEPT
iptables -A FORWARD -i eth1 -o eth0 -p udp --dport 53 -j ACCEPT
iptables -A FORWARD -i eth1 -o eth0 -p tcp --dport 53 -j ACCEPT
iptables -A FORWARD -i eth0 -o eth1 -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -j DROP

# NAT masquerade
iptables -t nat -A POSTROUTING -s 10.0.0.0/20 -o eth0 -j MASQUERADE
```

Private interface (`eth1`, via ufw):
```
ufw default deny incoming
ufw default allow outgoing

# SSH (management, private network only)
ufw allow from 10.0.0.0/20 to any port 22 proto tcp

# NTP (chrony, for all internal hosts)
ufw allow from 10.0.0.0/20 to any port 123 proto udp

# DNS (dnsmasq, for all internal hosts)
ufw allow from 10.0.0.0/20 to any port 53 proto udp
ufw allow from 10.0.0.0/20 to any port 53 proto tcp
```

### wol-a (connection interface)

| Property | Value |
|----------|-------|
| Hostname | `wol-a` |
| Internal IP | `10.0.0.208` |
| External IP | Assigned by hosting provider |
| Type | LXC (privileged, dual-homed) |
| OS | Debian 13 |
| UID | 1006 |
| GID | 1006 |
| SPIRE Agent | Yes |
| SPIFFE ID | `spiffe://wol/server-a` |
| Interfaces | 2 (private: `eth1` on 10.0.0.0/20, public: `eth0` locked to :6969) |
| Runtime | .NET 9 (runtime only, not SDK) |

wol is a stateless connection interface. It handles telnet, TLS telnet, WebSocket, and WSS protocols on port 6969. It maintains no persistent state beyond the active client connection. Multiple wol instances can run simultaneously for horizontal scaling.

#### Bootstrap script: `19-setup-wol.sh`

Runs on: wol-a (10.0.0.208)
Run order: Step 19 (SPIRE Agent must already be running on this host)

The script sets up:
- .NET 9 runtime (Microsoft install script, runtime only)
- Service user (`wol`, UID 1006, GID 1006)
- Directory structure (`/usr/lib/wol`, `/etc/wol`, `/var/log/wol`)
- Compiled C wrapper binary at `/usr/lib/wol/bin/start` (for SPIRE unix:path attestation, uses `execv` to run `dotnet Wol.Server.dll`, inheriting the systemd environment)
- External interface iptables lockdown (inbound :6969 only, no outbound initiation)
- Internal interface routing (ECMP routes via both gateways at metric 200 for apt/certbot)
- Internal interface firewall (ufw, SSH from private network only)
- IPv6 disabled via sysctl
- Production appsettings.json in the app directory
- Environment file (SPIRE socket, .NET root, API service addresses, realm address)
- Systemd service unit

The script is parameterized for multiple instances:

```bash
WOL_NAME=wol-a WOL_IP=10.0.0.208 \
    ./19-setup-wol.sh

# Additional wol instances for autoscaling (10.0.0.209 is now assigned to the web host):
WOL_NAME=wol-b WOL_IP=10.0.0.115 \
    ./19-setup-wol.sh
```

#### Dual-homed networking

The wol instance has two network interfaces with distinct roles:

**External (`eth0`):** Game client traffic only. iptables rules:
- `INPUT -i eth0 -p tcp --dport 6969 -j ACCEPT` (game clients in)
- `INPUT -i eth0 -j DROP` (everything else dropped)
- `OUTPUT -o eth0 -m state --state ESTABLISHED,RELATED -j ACCEPT` (responses only)
- `OUTPUT -o eth0 -j DROP` (no outbound initiation)

**Internal (`eth1`):** Private network (10.0.0.0/20). Used for:
- Direct mTLS to API services (accounts :8443, players :8443, world :8443)
- Communication with wol-realm
- SPIRE Agent communication
- Internet access via gateway NAT (metric 200 ECMP routes through both gateways, for apt/certbot)

### wol-realm-{prod,test} (game engine)

| Property | Value |
|----------|-------|
| Hostname | `wol-realm-prod` / `wol-realm-test` |
| Internal IP | `10.0.0.210` (prod) / `10.0.0.215` (test) |
| Type | LXC (privileged) |
| OS | Debian 13 |
| UID | 1001 |
| GID | 1001 |
| SPIRE Agent | Yes |
| SPIFFE ID | `spiffe://wol/realm-a` |
| Interfaces | 1 (private: on 10.0.0.0/20) |
| Runtime | .NET 9 (runtime only, not SDK) |

wol-realm is the game engine. It runs the MUD world simulation and is an internal-only service on the private network. wol instances connect to it to relay game traffic. It does not have an external interface and does not accept connections from the internet.

#### Bootstrap script: `18-setup-wol-realm.sh`

Runs on: wol-realm-prod (10.0.0.210) and wol-realm-test (10.0.0.215)
Run order: Step 18 (SPIRE Agent must already be running on this host)

The script sets up:
- .NET 9 runtime (Microsoft install script, runtime only)
- Service user (`wol-realm`, UID 1001, GID 1001)
- Directory structure (`/usr/lib/wol-realm`, `/etc/wol-realm`, `/var/log/wol-realm`)
- Compiled C wrapper binary at `/usr/lib/wol-realm/bin/start` (for SPIRE unix:path attestation, uses `execv` to run `dotnet Wol.Realm.dll`, inheriting the systemd environment)
- ECMP default route via both gateways (10.0.0.200 and 10.0.0.201) for internet access
- DNS client pointing to both gateways
- NTP client pointing to both gateways
- Firewall (ufw, SSH and wol connections from private network only)
- IPv6 disabled via sysctl
- Environment file (SPIRE socket, .NET root)
- Systemd service unit

## Changes to existing infrastructure

### IP assignment

wol instances start at 10.0.0.208 (dual-homed, autoscalable). wol-realm instances remain at 10.0.0.210+.

### API service firewall updates

API services currently allow the realm subnet (10.0.1.0/24). Update to allow the entire private network:

- Scripts 11, 14, 15: change `ufw allow from 10.0.1.0/24 to any port 8443` to `ufw allow from 10.0.0.0/20 to any port 8443`

### Internal hosts default gateway, DNS, and NTP

All single-homed internal hosts (including wol-realm) configure:
- ECMP default route via both gateways (10.0.0.200 and 10.0.0.201) for internet access
- DNS resolver listing both gateways (`nameserver 10.0.0.200` and `nameserver 10.0.0.201`)
- NTP client with both gateways as chrony sources

Each host's bootstrap script calls `configure_gateway_route` and `configure_dns_ntp` before installing packages.

wol instances do NOT use the gateways as their default route for the external interface. Their external interface has its own default route (hosting provider's gateway). Their internal interface uses both gateways for API traffic and internet access (apt, certbot) via lower-priority ECMP routes (metric 200).

### SPIRE workload registration

Add to `12-register-workload-entries.sh`:

```bash
# wol instance (connection interface)
ensure_entry "spiffe://wol/server-a" \
    -parentID "spiffe://wol/node/wol-a" \
    -selector "unix:uid:1006" \
    -selector "unix:path:/usr/lib/wol/bin/start" \
    -x509SVIDTTL 3600 \
    -jwtSVIDTTL 300
```

### wol instance configuration

wol instances call API services directly on the private network:

```
WOL_ACCOUNTS_URL=https://10.0.0.207:8443
WOL_WORLD_URL=https://10.0.0.211:8443
WOL_REALM_URL=10.0.0.210
```

### hosts.md updates

Add to host inventory:

| Hostname | IP | Type | OS | Role |
|----------|----|------|-----|------|
| `wol-gateway-a` | `10.0.0.200` (internal), external IP varies | LXC (privileged, dual-homed) | Debian 13 | NAT gateway (active-active); DNS forwarder; NTP server |
| `wol-gateway-b` | `10.0.0.201` (internal), external IP varies | LXC (privileged, dual-homed) | Debian 13 | NAT gateway (active-active); DNS forwarder; NTP server |
| `wol-a` | `10.0.0.208` (internal), external IP varies | LXC (privileged, dual-homed) | Debian 13 | WOL connection interface (stateless, autoscalable) + SPIRE Agent; external interface for game clients (:6969 only) |

Update realm entry:

| Hostname | IP | Type | Role |
|----------|-----|------|------|
| `wol-realm-prod` | `10.0.0.210` | LXC (privileged) | WOL game engine, prod (internal only) + SPIRE Agent |
| `wol-realm-test` | `10.0.0.215` | LXC (privileged) | WOL game engine, test (internal only) + SPIRE Agent |

Add to port reference:

| Host | Port | Clients | Purpose |
|------|------|---------|---------|
| `wol-gateway-a` | `53` | Private network | DNS forwarder (dnsmasq) |
| `wol-gateway-a` | `123` | Private network | NTP server (chrony) |
| `wol-gateway-b` | `53` | Private network | DNS forwarder (dnsmasq) |
| `wol-gateway-b` | `123` | Private network | NTP server (chrony) |
| `wol-a` | `6969` | Internet (external) | Game clients (telnet, TLS telnet, WS, WSS) |

## Bootstrap sequence update

| Script | Action | Where |
|--------|--------|-------|
| `00-setup-gateway.sh` | Configure NAT, DNS, NTP (parameterized, run twice) | `wol-gateway-a`, `wol-gateway-b` |
| `18-setup-wol-realm.sh` | .NET 9 runtime, single-homed internal service | `wol-realm-prod`, `wol-realm-test` |
| `19-setup-wol.sh` | .NET 9 runtime, dual-homed networking, external :6969 lockdown | `wol-a` |

`00-setup-gateway.sh` runs on both gateways before all other hosts (step 0).
`18-setup-wol-realm.sh` runs after SPIRE Agent is set up on the realm host.
`19-setup-wol.sh` runs after SPIRE Agent is set up on the wol host and after the realm is running.

## Trade-offs

**Active-active gateway pair.** Both gateways run simultaneously with ECMP routing. Either can fail independently without disrupting the other. However, both gateways must be provisioned before any other host can bootstrap (since they need NAT for apt). If both gateways fail simultaneously, internal hosts lose outbound internet access, but this only affects bootstrap and certbot renewals, not normal operation.

**wol instances have two interfaces.** Each wol instance needs both an external interface (game clients) and an internal interface (API services, realm). This requires two NICs in the LXC configuration, with careful routing to ensure game traffic uses the external interface and internal traffic uses the private interface.

**wol-to-realm communication.** The protocol and port for wol-to-realm communication is defined by the wol-realm service (not this proposal). This proposal ensures the network and SPIRE identities are in place for mTLS communication between them on the private network.

**Dual firewall toolchain on dual-homed hosts.** The gateways and wol instances use raw iptables for external interface lockdown and ufw for internal interface rules. This is intentional: ufw manages simple allow/deny on the private network, while raw iptables provides precise interface-specific control. The two operate on separate interfaces. Rules from both are persisted together via `netfilter-persistent save`.

**Direct API calls from wol instances.** Each wol instance needs the addresses of all API services. If a service moves, all wol instances need reconfiguration. This is acceptable because the private network is small and addresses are stable. DNS resolution via the gateways' dnsmasq provides a layer of indirection (wol instances can use hostnames like `wol-accounts` instead of IPs).

**One workload per host.** Each LXC/VM runs exactly one application workload. wol-a runs only the wol connection interface. wol-realm-prod (or wol-realm-test) runs only the game engine. The gateways run no application workloads at all. This is a hard requirement: co-locating multiple workloads on a single host weakens the SPIRE workload isolation model, since any process with access to the agent socket can request SVIDs for any registered workload on that host. Provisioning should fail if more than one workload registration entry targets the same parent node ID (except the gateway, which has no workload entries).

**Privileged LXC containers.** wol and wol-realm hosts require privileged LXCs so the SPIRE Agent's unix workload attestor can read `/proc/<pid>/exe` for the `unix:path` selector. The gateways do not run SPIRE and do not strictly require privileged LXCs, but use them for consistent dual-homed networking. If the security posture needs tightening, the gateways are the easiest candidates for migration to unprivileged containers or VMs since they run no workload identity.

## Security review response

Responses to findings from `proposals/reviews/infrastructure-proposals-security-review-2026-03-25.md` that are relevant to this proposal.

| Finding | Status | Resolution |
|---------|--------|------------|
| Followup #4 (gateway single-point dependency) | Addressed | Resolved by active-active dual-gateway design. Both gateways (10.0.0.200 and 10.0.0.201) run simultaneously with ECMP routing. Either can fail independently without disrupting the other. |
| H3 (privileged LXC blast radius) | Addressed | Gateways are pure network infrastructure with no application services, no SPIRE, no workload identity. Blast radius is minimal. Documented that migration to VM is warranted if application services are ever added. |
| H4 (IPv6 egress bypass) | Addressed | IPv6 disabled on all hosts via sysctl. Documented in proposal (section 1) and implemented in all bootstrap scripts. |
| H5 (mixed firewall stacks) | Addressed | Dual-toolchain rationale documented in proposal (section 2) and trade-offs. iptables for external interface, ufw for internal. Separate interfaces, no rule interaction. Persisted together via `netfilter-persistent save`. |
| H7 (gateway SPIFFE identity over-broad) | No longer applicable | Gateways have no SPIRE Agent and no workload identity. No SPIFFE ID matching at the gateways. |
| H9 (ACME/certbot threat model) | Addressed | Added ACME operational profile: DNS-01 only, scoped API tokens, token rotation, audit trail, emergency revoke procedure. |
| C5 (one-workload-per-host) | Addressed | Documented as a hard requirement in trade-offs. Each host runs exactly one application workload. Provisioning should fail on multi-workload registration per host. |
| M4 (NTP auth) | Addressed | Standardized on chrony only (no ntpd). NTS enabled on each gateway's upstream pool connections. Internal hosts trust the gateways over the isolated network. |
| L1 (API path versioning at gateway) | No longer applicable | Gateways have no API routing or reverse proxy. |

Findings that affect other proposals (C1, C2, C3, C4, H1, H2, H6, H8, M1-M3, M5-M11, L2-L3) are tracked in their respective proposal documents.

## Affected files

| Location | File | Change |
|----------|------|--------|
| `wol-docs/infrastructure/bootstrap/` | `00-setup-gateway.sh` | Rewrite: remove Envoy, simplify to NAT + DNS + NTP only; parameterized for dual-gateway (wol-gateway-a, wol-gateway-b) |
| `wol-docs/infrastructure/bootstrap/` | `18-setup-wol-realm.sh` | Rewrite as single-homed internal service |
| `wol-docs/infrastructure/bootstrap/` | `19-setup-wol.sh` | New bootstrap script (wol connection interface, dual-homed) |
| `wol-docs/infrastructure/` | `hosts.md` | Add gateway and wol hosts, update realm to internal-only, add ports |
| `wol-docs/infrastructure/bootstrap/` | `12-register-workload-entries.sh` | Add wol and realm SPIRE entries, remove gateway entry |
| `wol-docs/infrastructure/bootstrap/` | `02-setup-db.sh` | Add gateway route, DNS, NTP client |
| `wol-docs/infrastructure/bootstrap/` | `03-setup-step-ca.sh` | Add gateway route, DNS, NTP client |
| `wol-docs/infrastructure/bootstrap/` | `04-setup-spire-server.sh` | Add gateway route, DNS, NTP client |
| `wol-docs/infrastructure/bootstrap/` | `05-setup-provisioning-host.sh` | Add gateway route, DNS, NTP client |
| `wol-docs/infrastructure/bootstrap/` | `11-setup-wol-accounts.sh` | Update firewall, add gateway route, DNS, NTP client |
| `wol-docs/infrastructure/bootstrap/` | `15-setup-wol-world.sh` | Update firewall, add gateway route, DNS, NTP client |
| `wol-docs/infrastructure/bootstrap/` | `17-setup-wol-world-db.sh` | Add gateway route, DNS, NTP client |
