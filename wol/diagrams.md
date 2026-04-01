# WOL Infrastructure Diagrams

Visual reference for the WOL infrastructure proposals. All diagrams use Mermaid syntax.

**Cross-proposal dependencies:** These proposals are tightly coupled. The authoritative ownership boundaries are defined in `spiffe-spire-workload-identity.md` Section 8 (ownership table). When two proposals appear to conflict, that table is authoritative. Key dependency chain:

1. `private-ca-and-secret-management.md` (root CA, cfssl CA for DB certs, cert profiles, TLS policy, incident playbooks)
2. `spiffe-spire-workload-identity.md` (service-to-service mTLS, JWT-SVIDs; depends on #1 for root CA)
3. `proxmox-deployment-automation.md` (host provisioning and bootstrap orchestration; depends on #1 and #2 for bootstrap ordering)
4. `wol-accounts-db-and-api.md` (depends on #1 and #2)
6. `wol-world-db-and-api.md` (depends on #1 and #2)
7. `observability-stack.md` (depends on #1 and #3; all services depend on this for log/metric delivery)

---

## 1. Network Topology

Physical network layout showing all hosts, interfaces, and connectivity.

```mermaid
graph TB
    subgraph Internet
        INET((Internet))
        CLIENTS((Game Clients))
    end

    subgraph GW["Gateway Layer (Active-Active, Dual-Bridge)"]
        GWA["wol-gateway-a<br/>10.0.0.200 / 10.0.1.200<br/>NAT / DNS / NTP"]
        GWB["wol-gateway-b<br/>10.0.0.201 / 10.0.1.201<br/>NAT / DNS / NTP"]
    end

    subgraph PRIV["Private Networks (vmbr1 10.0.0.0/24 + vmbr3 10.0.1.0/24)"]
        subgraph INFRA["Infrastructure Services"]
            SPIRE["spire-server<br/>10.0.0.204"]
            CFSSL["cfssl CA<br/>10.0.0.203"]
            PROV["provisioning<br/>10.0.0.205"]
        end

        subgraph API["Shared API Services"]
            ACCT["wol-accounts<br/>10.0.0.207<br/>:8443"]
        end

        subgraph DBS["Shared Databases"]
            ACCTDB["wol-accounts-db<br/>10.0.0.206<br/>:5432"]
            SPIREDB["spire-db<br/>10.0.0.202<br/>:5432 + Tang :7500"]
        end

        subgraph PROD["Prod (vmbr1, 10.0.0.0/24)"]
            WRLD_P["wol-world-prod<br/>10.0.0.211"]
            WRLDDB_P["wol-world-db-prod<br/>10.0.0.213"]
            REALM_P["wol-realm-prod<br/>10.0.0.210"]
            AI_P["wol-ai-prod<br/>10.0.0.212"]
        end

        subgraph TEST["Test (vmbr3, 10.0.1.0/24)"]
            WRLD_T["wol-world-test<br/>10.0.1.216"]
            WRLDDB_T["wol-world-db-test<br/>10.0.1.218"]
            REALM_T["wol-realm-test<br/>10.0.1.215"]
            AI_T["wol-ai-test<br/>10.0.1.217"]
        end

        subgraph CONN["Connection Interfaces (Dual-Homed)"]
            WOLA["wol-a<br/>10.0.0.208<br/>:6969 external"]
        end

        subgraph WEBHOST["WOL Web Frontend (Single-Homed)"]
            WEB["wol-web<br/>10.0.0.209<br/>:5000 (Kestrel)<br/>ackmud.com"]
        end

        subgraph OBS["Observability (Tri-Homed, Homelab-Managed)"]
            WOLOBS["obs<br/>10.0.0.100<br/>Loki :3100 / Prometheus :9090<br/>Grafana :80 external"]
        end
    end

    PVE["Proxmox Host<br/>192.168.1.253"]

    INET --- GWA
    INET --- GWB
    GWA --- PRIV
    GWB --- PRIV

    CLIENTS -->|":6969 direct"| WOLA
    CLIENTS -->|"via nginx-proxy"| WEB

    ACCT --- ACCTDB
    SPIRE --- SPIREDB
    WRLD_P --- WRLDDB_P
    WRLD_T --- WRLDDB_T
    REALM_P -->|"mTLS"| AI_P
    REALM_T -->|"mTLS"| AI_T
    AI_P -->|"outbound HTTPS via NAT"| GWA
    AI_T -->|"outbound HTTPS via NAT"| GWA

    WOLA --> ACCT
    WOLA -->|"realm routing"| REALM_P
    WOLA -->|"realm routing"| REALM_T
    WEB -->|"mTLS :8443"| ACCT

    ACCT -.->|"Promtail<br/>mTLS"| WOLOBS
    WRLD_P -.->|"Promtail"| WOLOBS
    WRLD_T -.->|"Promtail"| WOLOBS
    REALM_P -.->|"Promtail"| WOLOBS
    REALM_T -.->|"Promtail"| WOLOBS
    WOLA -.->|"Promtail"| WOLOBS
    WEB -.->|"Promtail<br/>(wol-web)"| WOLOBS
    AI_P -.->|"Promtail"| WOLOBS
    AI_T -.->|"Promtail"| WOLOBS
    ACCTDB -.->|"Promtail +<br/>pg_exporter"| WOLOBS
    SPIREDB -.->|"Promtail +<br/>pg_exporter"| WOLOBS
    PVE -.->|"Promtail +<br/>pve_exporter<br/>(external)"| WOLOBS

    style GWA fill:#4a9,stroke:#333,color:#000
    style GWB fill:#4a9,stroke:#333,color:#000
    style SPIRE fill:#a6d,stroke:#333,color:#000
    style CFSSL fill:#a6d,stroke:#333,color:#000
    style ACCT fill:#69f,stroke:#333,color:#000
    style WRLD_P fill:#69f,stroke:#333,color:#000
    style WRLD_T fill:#69f,stroke:#333,color:#000
    style AI_P fill:#69f,stroke:#333,color:#000
    style AI_T fill:#69f,stroke:#333,color:#000
    style ACCTDB fill:#fa0,stroke:#333,color:#000
    style SPIREDB fill:#fa0,stroke:#333,color:#000
    style WRLDDB_P fill:#fa0,stroke:#333,color:#000
    style WRLDDB_T fill:#fa0,stroke:#333,color:#000
    style REALM_P fill:#f66,stroke:#333,color:#000
    style REALM_T fill:#f66,stroke:#333,color:#000
    style WOLA fill:#f66,stroke:#333,color:#000
    style WEB fill:#f96,stroke:#333,color:#000
    style WOLOBS fill:#9cf,stroke:#333,color:#000
    style PVE fill:#ccc,stroke:#333,color:#000
```

---

## 2. Gateway Active-Active (ECMP Routing)

How internal hosts use both gateways for outbound internet, DNS, and NTP.

```mermaid
graph LR
    subgraph INTERNAL["Internal Hosts"]
        HOST["Any internal host<br/>(e.g. wol-accounts 10.0.0.207)"]
    end

    subgraph GW_LAYER["Active-Active Gateways"]
        GWA["wol-gateway-a<br/>10.0.0.200"]
        GWB["wol-gateway-b<br/>10.0.0.201"]
    end

    INET((Internet))

    HOST -->|"ECMP route 1"| GWA
    HOST -->|"ECMP route 2"| GWB

    GWA -->|"NAT masquerade"| INET
    GWB -->|"NAT masquerade"| INET

    style HOST fill:#69f,stroke:#333,color:#000
    style GWA fill:#4a9,stroke:#333,color:#000
    style GWB fill:#4a9,stroke:#333,color:#000
```

**Routing:** `ip route add default nexthop via 10.0.0.200 nexthop via 10.0.0.201`
**DNS:** `/etc/resolv.conf` lists both `nameserver 10.0.0.200` and `nameserver 10.0.0.201`
**NTP:** chrony config has `server 10.0.0.200 iburst` and `server 10.0.0.201 iburst`

---

## 3. Certificate Authority Trust Chain

Two-tier PKI: offline root CA with online intermediates for different purposes.

```mermaid
graph TD
    ROOT["WOL Root CA<br/>(offline, air-gapped)<br/>ECDSA P-256"]

    ROOT --> SPIRE_INT["SPIRE Intermediate CA<br/>(managed by SPIRE Server)<br/>Issues X.509-SVIDs"]
    ROOT --> STEP_INT["cfssl CA Intermediate CA<br/>(online, 10.0.0.203:8443)<br/>Issues PostgreSQL client certs"]
    ROOT --> VTPM_INT["vTPM Provisioning CA<br/>(online, 10.0.0.205)<br/>Issues DevID certs for node attestation"]

    SPIRE_INT --> SVID1["X.509-SVID<br/>spiffe://wol/accounts<br/>1h lifetime"]
    SPIRE_INT --> SVID2["X.509-SVID<br/>spiffe://wol/players<br/>1h lifetime"]
    SPIRE_INT --> SVID3["X.509-SVID<br/>spiffe://wol/world<br/>1h lifetime"]
    SPIRE_INT --> SVID4["X.509-SVID<br/>spiffe://wol/server-a<br/>1h lifetime"]
    SPIRE_INT --> SVID5["X.509-SVID<br/>spiffe://wol/realm-a<br/>1h lifetime"]
    SPIRE_INT --> SVID6["X.509-SVID<br/>spiffe://wol/ai<br/>1h lifetime"]

    STEP_INT --> DBCERT1["DB client cert<br/>CN=wol (runtime)<br/>24h lifetime"]
    STEP_INT --> DBCERT2["DB client cert<br/>CN=wol_migrate (DDL)<br/>24h lifetime"]
    STEP_INT --> DBCERT3["DB server certs<br/>CN=*-db hosts<br/>24h lifetime"]

    VTPM_INT --> DEVID1["DevID cert<br/>(per-VM vTPM)<br/>Node attestation"]

    style ROOT fill:#d32,stroke:#333,color:#fff
    style SPIRE_INT fill:#a6d,stroke:#333,color:#000
    style STEP_INT fill:#a6d,stroke:#333,color:#000
    style VTPM_INT fill:#a6d,stroke:#333,color:#000
    style SVID1 fill:#cdf,stroke:#333,color:#000
    style SVID2 fill:#cdf,stroke:#333,color:#000
    style SVID3 fill:#cdf,stroke:#333,color:#000
    style SVID4 fill:#cdf,stroke:#333,color:#000
    style SVID5 fill:#cdf,stroke:#333,color:#000
    style SVID6 fill:#cdf,stroke:#333,color:#000
    style DBCERT1 fill:#fda,stroke:#333,color:#000
    style DBCERT2 fill:#fda,stroke:#333,color:#000
    style DBCERT3 fill:#fda,stroke:#333,color:#000
    style DEVID1 fill:#fda,stroke:#333,color:#000
```

---

## 4. SPIRE Identity and Attestation Flow

How hosts and workloads obtain their identities.

```mermaid
sequenceDiagram
    participant VM as New VM
    participant VTPM as vTPM (in VM)
    participant PCA as Provisioning CA<br/>(10.0.0.205)
    participant SA as SPIRE Agent<br/>(on VM)
    participant SS as SPIRE Server<br/>(10.0.0.204)
    participant WL as Workload<br/>(e.g. wol-accounts)

    Note over VM,PCA: Phase 1: Node Provisioning (one-time)
    VM->>VTPM: Generate DevID key pair
    VM->>PCA: Submit CSR
    PCA->>VTPM: Signed DevID certificate

    Note over SA,SS: Phase 2: Node Attestation (on agent start)
    SA->>VTPM: Read DevID cert + key
    SA->>SS: Attest with DevID cert (mTLS)
    SS->>SS: Verify cert chain<br/>(DevID -> Provisioning CA -> Root)
    SS->>SA: Node SVID<br/>(spiffe://wol/node/hostname)

    Note over WL,SA: Phase 3: Workload Attestation (on workload start)
    WL->>SA: Connect to agent socket<br/>(/var/run/spire/agent.sock)
    SA->>SA: Check unix:uid + unix:path<br/>against registration entries
    SA->>SS: Request workload SVID
    SS->>SA: X.509-SVID + trust bundle
    SA->>WL: X.509-SVID<br/>(spiffe://wol/accounts)

    Note over WL,SA: Phase 4: Ongoing Renewal
    SA-->>WL: Stream updated SVIDs<br/>before expiry (every ~30min)
```

---

## 5. Service-to-Service Authentication (mTLS + JWT-SVID)

How wol instances authenticate to API services.

```mermaid
sequenceDiagram
    participant W as wol-a<br/>(10.0.0.208)
    participant AG as SPIRE Agent<br/>(local)
    participant API as wol-accounts<br/>(10.0.0.207:8443)
    participant AG2 as SPIRE Agent<br/>(on API host)

    Note over W,AG: Step 1: Get credentials from local SPIRE Agent
    W->>AG: fetch_x509_svid()
    AG->>W: X.509-SVID (spiffe://wol/server-a)
    W->>AG: fetch_jwt_svid(aud="spiffe://wol/accounts")
    AG->>W: JWT-SVID (5min TTL)

    Note over W,API: Step 2: mTLS handshake + JWT request
    W->>API: TLS ClientHello<br/>(client cert: spiffe://wol/server-a)
    API->>AG2: Verify client cert against trust bundle
    AG2->>API: Valid (SPIFFE ID: spiffe://wol/server-a)
    API->>W: TLS ServerHello (mutual auth complete)

    W->>API: POST /auth/login<br/>Authorization: Bearer <JWT-SVID>
    API->>AG2: Validate JWT signature + aud + exp
    AG2->>API: Valid (sub: spiffe://wol/server-a)
    API->>API: Check SPIFFE ID against allowlist
    API->>W: 200 OK (response)
```

---

## 6. Client Connection Flow (Login to Gameplay)

End-to-end flow from a game client connecting through to active gameplay.

```mermaid
sequenceDiagram
    participant C as Game Client
    participant W as wol-a<br/>(:6969 external)
    participant ACCT as wol-accounts<br/>(10.0.0.207:8443)
    participant WRLD as wol-world<br/>(10.0.0.211:8443)
    participant R as wol-realm-prod<br/>(10.0.0.210)

    Note over C,W: Phase 1: Connect
    C->>W: TCP connect :6969<br/>(telnet/TLS/WS/WSS)
    W->>C: Welcome banner

    Note over C,ACCT: Phase 2: Login
    C->>W: Email + password
    W->>ACCT: POST /auth/login<br/>(mTLS + JWT-SVID)
    ACCT->>ACCT: bcrypt verify, create session
    ACCT->>W: session_token + account_id
    W->>C: Login successful

    Note over C,PLAY: Phase 3: Character Selection
    W->>PLAY: GET /characters?account_id=42<br/>(mTLS + JWT-SVID)
    PLAY->>W: Character list
    W->>C: Show character menu
    C->>W: Select character (or create new)
    W->>PLAY: GET /characters/7
    PLAY->>W: Character data (name, race, class, level)

    Note over PLAY,ACCT: Write ops: players validates account ownership
    opt Character creation
        W->>PLAY: POST /characters<br/>(account_id + session_token)
        PLAY->>ACCT: POST /sessions/validate<br/>(verify account_id owns session)
        ACCT->>PLAY: 200 OK (valid)
        PLAY->>W: 201 Created (new character)
    end

    Note over W,R: Phase 4: Enter Game World
    W->>WRLD: GET /bulk/rooms?area_id=1<br/>(if realm needs data)
    WRLD->>W: Room/NPC/object data
    W->>R: Connect (mTLS)<br/>Relay: player enters world
    R->>W: Room description
    W->>C: "You are standing in..."

    Note over C,R: Phase 5: Gameplay Loop
    C->>W: "north"
    W->>R: Relay command
    R->>W: New room description
    W->>C: Room text + exits

    Note over W,ACCT: Heartbeat (every 5 min)
    W->>ACCT: POST /sessions/validate
    ACCT->>W: 200 OK (session alive)
```

---

## 7. Database Connectivity

How API services connect to their databases using cfssl CA client certificates.

```mermaid
graph LR
    subgraph API_HOSTS["API Hosts"]
        ACCT_API["wol-accounts<br/>10.0.0.207"]
        WRLD_API["wol-world<br/>10.0.0.211"]
    end

    subgraph DB_HOSTS["Database Hosts"]
        ACCT_DB["wol-accounts-db<br/>10.0.0.206:5432<br/>wol_accounts"]
        WRLD_DB["wol-world-db<br/>10.0.0.213:5432<br/>wol_world"]
    end

    CFSSL["cfssl CA<br/>10.0.0.203:8443"]

    ACCT_API -->|"mTLS<br/>CN=wol_accounts (runtime)<br/>CN=wol_accounts_migrate (DDL)"| ACCT_DB
    WRLD_API -->|"mTLS<br/>CN=wol_world<br/>CN=wol_world_migrate"| WRLD_DB

    CFSSL -.->|"enroll-host-certs.sh<br/>24h certs"| ACCT_API
    CFSSL -.->|"enroll-host-certs.sh<br/>24h certs"| WRLD_API
    CFSSL -.->|"enroll-host-certs.sh<br/>server certs"| ACCT_DB
    CFSSL -.->|"enroll-host-certs.sh<br/>server certs"| WRLD_DB

    style CFSSL fill:#a6d,stroke:#333,color:#000
    style ACCT_API fill:#69f,stroke:#333,color:#000
    style PLAY_API fill:#69f,stroke:#333,color:#000
    style WRLD_API fill:#69f,stroke:#333,color:#000
    style ACCT_DB fill:#fa0,stroke:#333,color:#000
    style PLAY_DB fill:#fa0,stroke:#333,color:#000
    style WRLD_DB fill:#fa0,stroke:#333,color:#000
```

**pg_hba.conf pattern** (each DB host):
```
hostssl <db_name> <runtime_user>  <api_host>/32  cert clientcert=verify-full
hostssl <db_name> <migrate_user>  <api_host>/32  cert clientcert=verify-full
host    all       all             0.0.0.0/0      reject
```

---

## 8. Bootstrap Sequence

Order of operations for bringing up the entire infrastructure from scratch.

```mermaid
gantt
    title Bootstrap Sequence
    dateFormat X
    axisFormat %s

    section Network + Proxy
    00-setup-gateway.sh (both gateways)   :gw, 0, 1
    01-setup-apt-cache.sh                 :cache, 1, 2

    section Core Infrastructure
    02-setup-spire-db.sh (spire-db)        :db, 2, 3
    02-setup-wol-accounts-db.sh            :adb, 2, 3
    03-setup-cfssl CA.sh                   :ca, 3, 4
    04-setup-spire-server.sh              :ss, 4, 5
    05-setup-provisioning-host.sh         :prov, 5, 6
    06-complete-cfssl CA.sh                :ca2, 6, 7
    07-complete-spire-server.sh           :ss2, 7, 8
    08-complete-provisioning.sh           :prov2, 8, 9

    section SPIRE Agents
    09-setup-spire-agent.sh (all hosts)   :sa, 9, 10

    section API Services
    10-setup-wol-accounts.sh              :acct, 10, 11
    11-register-workload-entries.sh       :reg, 11, 12

    section Per-Environment Services
    12-setup-wol-world-db.sh              :wdb, 12, 13
    13-setup-wol-world.sh                 :wrld, 13, 14
    14-setup-wol-realm.sh                 :realm, 14, 15
    15-setup-wol.sh (connection interface) :wol, 15, 16
    16-setup-wol-ai.sh                    :ai, 13, 14

    section Observability + Web
    17-setup-obs.sh                   :obs, 16, 17
    18-setup-web.sh                       :web, 17, 18
    19-setup-promtail.sh (all hosts)      :prom, 18, 19
    20-setup-proxmox-obs.sh (PVE host)    :pve, 19, 20
```

**Dependencies:**
- Gateways must be up first (all hosts need DNS for apt)
- apt-cache must be up before all other hosts (provides caching proxy)
- cfssl CA before SPIRE Server (root CA trust)
- SPIRE Server before SPIRE Agents
- SPIRE Agents before any service that needs workload identity
- Workload registration before services start requesting SVIDs
- Internal hosts have no direct outbound internet; all HTTP/HTTPS goes through apt-cache
- obs must be up before Promtail agents are deployed (they push to it)
- Proxmox obs setup runs last (on the Proxmox host itself, not in a container)

---

## 9. wol Instance Dual-Homed Networking

How a wol instance's two network interfaces are configured.

```mermaid
graph TB
    subgraph EXTERNAL["External Interface (eth0)"]
        direction TB
        EXT_IN["INPUT: TCP :6969 ACCEPT<br/>All else DROP"]
        EXT_OUT["OUTPUT: ESTABLISHED,RELATED ACCEPT<br/>All else DROP"]
    end

    subgraph INTERNAL["Internal Interfaces (eth1 vmbr1 10.0.0.0/24, eth2 vmbr3 10.0.1.0/24)"]
        direction TB
        INT_UFW["ufw: SSH from 10.0.0.0/24 + 10.0.1.0/24"]
        INT_ROUTE["ECMP routes via 10.0.0.200 + 10.0.0.201<br/>(metric 200, for apt/certbot)"]
    end

    CLIENTS((Game Clients)) -->|"TCP :6969"| EXT_IN
    EXT_OUT -->|"responses only"| CLIENTS

    subgraph WOL["wol-a (10.0.0.208)"]
        PROC["wol process<br/>UID 1006<br/>spiffe://wol/server-a"]
    end

    PROC -->|"mTLS :8443"| ACCT["wol-accounts<br/>10.0.0.207"]
    PROC -->|"mTLS :8443"| WRLD["wol-world<br/>10.0.0.211"]
    PROC -->|"mTLS"| REALM["wol-realm-prod<br/>10.0.0.210"]
    PROC -->|"unix socket"| SPIRE["SPIRE Agent<br/>/var/run/spire/agent.sock"]

    INT_ROUTE -->|"outbound NAT"| GW["Gateways<br/>10.0.0.200 / 10.0.0.201"]

    style EXTERNAL fill:#fcc,stroke:#333,color:#000
    style INTERNAL fill:#cfc,stroke:#333,color:#000
    style WOL fill:#ccf,stroke:#333,color:#000
```

---

## 10. Data Model Overview

Logical data domains across the three API services.

```mermaid
erDiagram
    ACCOUNTS ||--o| SESSIONS : "one active session"
    ACCOUNTS ||--o| FAILED_LOGINS : "lockout tracking"
    ACCOUNTS ||--o{ CHARACTERS : "owns (cross-service)"

    ACCOUNTS {
        bigserial id PK
        text email UK
        text account_name UK
        text password_hash
        timestamptz created_at
    }

    SESSIONS {
        bigserial id PK
        bigint account_id UK
        bytea token_hash
        timestamptz expires_at
        timestamptz last_seen_at
    }

    FAILED_LOGINS {
        bigserial id PK
        bigint account_id UK
        int attempt_count
        timestamptz locked_until
    }

    CHARACTERS {
        bigserial id PK
        bigint account_id
        text name
        text race
        text character_class
        int level
        bigint experience
        timestamptz deleted_at
    }

    AREAS ||--o{ ROOMS : contains
    AREAS ||--o{ RESETS : defines
    ROOMS ||--o{ ROOM_EXITS : has
    ROOMS ||--o{ ROOM_EXTRA_DESCS : has
    AREAS ||--o{ OBJECT_PROTOTYPES : contains
    AREAS ||--o{ NPC_PROTOTYPES : contains
    OBJECT_PROTOTYPES ||--o{ OBJECT_AFFECTS : has
    NPC_PROTOTYPES ||--o{ NPC_LOOT : drops
    NPC_PROTOTYPES ||--o{ NPC_SCRIPTS : runs
    NPC_PROTOTYPES ||--o| SHOPS : "may be merchant"

    AREAS {
        bigserial id PK
        text name UK
        int level_min
        int level_max
        int reset_rate_min
        text_arr flags
    }

    ROOMS {
        bigserial id PK
        bigint area_id
        text name
        text sector_type
        text_arr flags
    }

    ROOM_EXITS {
        bigserial id PK
        bigint room_id FK
        text direction
        bigint destination_room_id
        text_arr flags
    }

    OBJECT_PROTOTYPES {
        bigserial id PK
        bigint area_id
        text item_type
        int level
        text_arr flags
        jsonb values
    }

    NPC_PROTOTYPES {
        bigserial id PK
        bigint area_id
        int level
        text race
        text_arr flags
        jsonb combat_mods
    }

    RESETS {
        bigserial id PK
        bigint area_id
        text command
        int seq
    }
```

**Note:** `ACCOUNTS` and `CHARACTERS` are in separate databases on separate hosts. The `account_id` reference in `CHARACTERS` is a plain BIGINT with no foreign key constraint (cross-service boundary). Similarly, `area_id` in rooms/objects/NPCs/resets uses plain BIGINT references (future-proofed for domain splitting).

---

## 11. Firewall Rules Summary

Per-host firewall configuration across the infrastructure.

```mermaid
graph TB
    subgraph GW["wol-gateway-a / wol-gateway-b"]
        GW_EXT["eth0 (external, iptables):<br/>INPUT: ESTABLISHED only<br/>FORWARD: TCP 80,443 + TCP/UDP 53<br/>NAT: MASQUERADE 10.0.0.0/24 + 10.0.1.0/24"]
        GW_INT["eth1+eth2 (internal, ufw):<br/>Allow: SSH :22, DNS :53, NTP :123<br/>From: 10.0.0.0/24 + 10.0.1.0/24"]
    end

    subgraph WOL["wol-a"]
        WOL_EXT["eth0 (external, iptables):<br/>INPUT: TCP :6969 only<br/>OUTPUT: ESTABLISHED only"]
        WOL_INT["eth1+eth2 (internal, ufw):<br/>Allow: SSH :22<br/>From: 10.0.0.0/24 + 10.0.1.0/24"]
    end

    subgraph API["API Services (accounts/world/ai)"]
        API_FW["eth0+eth1 (internal, ufw):<br/>Allow: SSH :22 from 10.0.0.0/24 + 10.0.1.0/24<br/>Allow: HTTPS :8443 from 10.0.0.0/24 + 10.0.1.0/24"]
    end

    subgraph DBS["Database Hosts"]
        DB_FW["eth0+eth1 (internal, ufw):<br/>Allow: SSH :22 from 10.0.0.0/24 + 10.0.1.0/24<br/>Allow: PostgreSQL :5432 from API host IP only"]
    end

    subgraph CORE["SPIRE / cfssl CA"]
        CORE_FW["eth0+eth1 (internal, ufw):<br/>Allow: SSH :22 from 10.0.0.0/24 + 10.0.1.0/24<br/>Allow: service port from 10.0.0.0/24 + 10.0.1.0/24"]
    end

    subgraph OBSFW["obs (tri-homed, homelab-managed)"]
        OBS_EXT["eth0 (external, ufw):<br/>Allow: Grafana :80 from 192.168.0.0/23<br/>Allow: Loki :3100 from 192.168.0.0/23<br/>Allow: Prometheus :9090 from 192.168.0.0/23"]
        OBS_INT["eth1 (WOL, ufw):<br/>Allow: SSH :22 from 10.0.0.0/24<br/>Allow: Loki :3100 from 10.0.0.0/24 (mTLS)<br/>Allow: Prometheus :9090 scrape outbound"]
        OBS_ACK["eth2 (ACK, ufw):<br/>Allow: Loki :3100 from 10.1.0.0/24<br/>Allow: Prometheus :9090 from 10.1.0.0/24"]
    end

    style GW fill:#4a9,stroke:#333,color:#000
    style WOL fill:#f66,stroke:#333,color:#000
    style API fill:#69f,stroke:#333,color:#000
    style DBS fill:#fa0,stroke:#333,color:#000
    style CORE fill:#a6d,stroke:#333,color:#000
    style OBSFW fill:#9cf,stroke:#333,color:#000
```

---

## 12. Observability Data Flow

How logs and metrics flow from services to the central observability stack.

```mermaid
graph LR
    subgraph WOL_NET["WOL Private Networks (vmbr1 10.0.0.0/24 + vmbr3 10.0.1.0/24)"]
        SVC["WOL Services<br/>(accounts, players, world,<br/>realm, wol, ai)"]
        DB["DB Hosts<br/>(db, world-db)"]
        INFRA["Infra Services<br/>(spire-server, cfssl CA)"]
    end

    subgraph EXT_NET["External Network (192.168.0.0/23)"]
        PVE["Proxmox Host<br/>192.168.1.253<br/>pve-exporter :9221"]
        OTHER["Other Services<br/>(future)"]
    end

    subgraph ACK_NET["ACK Network (10.1.0.0/24)"]
        MUDS["ACK MUD Servers<br/>10.1.0.241-14"]
    end

    subgraph OBS_HOST["obs (10.0.0.100 / 192.168.1.100 / 10.1.0.100)"]
        LOKI["Loki :3100<br/>Log aggregation"]
        PROM["Prometheus :9090<br/>Metrics"]
        AM["Alertmanager :9093<br/>Alert routing"]
        GRAF["Grafana :80<br/>Dashboards"]
    end

    SVC -->|"Promtail<br/>mTLS (eth1)"| LOKI
    SVC -->|"Prometheus scrape<br/>mTLS (eth1)"| PROM
    DB -->|"Promtail + pg_exporter<br/>mTLS (eth1)"| LOKI
    DB -->|"pg_exporter<br/>mTLS (eth1)"| PROM
    INFRA -->|"Promtail<br/>mTLS (eth1)"| LOKI
    INFRA -->|"built-in metrics<br/>mTLS (eth1)"| PROM

    PVE -->|"Promtail<br/>TLS + API key (eth0)"| LOKI
    PVE -->|"pve-exporter<br/>(eth0)"| PROM
    OTHER -->|"Promtail<br/>TLS + API key (eth0)"| LOKI

    MUDS -->|"Promtail<br/>TLS (eth2)"| LOKI

    PROM --> AM
    LOKI --> GRAF
    PROM --> GRAF
    AM -->|"webhook"| OPERATOR((Operator))

    style OBS_HOST fill:#9cf,stroke:#333,color:#000
    style WOL_NET fill:#e8f4e8,stroke:#333,color:#000
    style EXT_NET fill:#f4e8e8,stroke:#333,color:#000
```

---

## 13. Certificate Renewal Lifecycle

How certificates are automatically renewed across the system.

```mermaid
sequenceDiagram
    participant SVC as Service Process
    participant SA as SPIRE Agent
    participant SS as SPIRE Server
    participant CFSSL as cfssl CA (10.0.0.203)

    Note over SVC,SS: SPIRE X.509-SVID Renewal (1h lifetime)
    loop Every ~30 minutes
        SA->>SS: Request renewed SVID
        SS->>SA: New X.509-SVID + trust bundle
        SA-->>SVC: Stream updated SVID<br/>(automatic, no restart needed)
        SVC->>SVC: New connections use new cert<br/>Existing connections finish on old cert
    end

    Note over SVC,STEP: cfssl CA DB Client Cert Renewal (24h lifetime)
    loop Every ~19 hours (80% of 24h)
        SVC->>CFSSL: enroll-host-certs.sh
        CFSSL->>SVC: New client cert + key
        SVC->>SVC: --exec "systemctl reload <service>"
    end

    Note over SVC,SS: SPIRE JWT-SVID (5min lifetime)
    loop Per-request (cached ~2.5 min)
        SVC->>SA: fetch_jwt_svid(audience)
        SA->>SVC: JWT (if cached and valid)<br/>or fetch new from Server
    end
```

---

## 14. Authorization Matrix

Which services can call which, and what identity they present.

```mermaid
graph LR
    subgraph CALLERS["Callers"]
        WOLA["wol-a<br/>spiffe://wol/server-a"]
        REALM["wol-realm-prod<br/>spiffe://wol/realm-prod"]
    end

    subgraph TARGETS["Target Services"]
        ACCT["wol-accounts<br/>:8443"]
        WRLD["wol-world<br/>:8443"]
        AI["wol-ai<br/>:8443"]
    end

    WOLA -->|"mTLS + JWT-SVID"| ACCT
    WOLA -->|"mTLS + JWT-SVID"| PLAY
    WOLA -->|"mTLS + JWT-SVID"| WRLD
    REALM -->|"mTLS + JWT-SVID"| ACCT
    REALM -->|"mTLS + JWT-SVID"| PLAY
    REALM -->|"mTLS + JWT-SVID"| WRLD
    REALM -->|"mTLS + JWT-SVID"| AI
    PLAYERS -->|"mTLS + JWT-SVID<br/>(session validate)"| ACCT

    style WOLA fill:#f66,stroke:#333,color:#000
    style REALM fill:#f66,stroke:#333,color:#000
    style PLAYERS fill:#69f,stroke:#333,color:#000
    style ACCT fill:#69f,stroke:#333,color:#000
    style WRLD fill:#69f,stroke:#333,color:#000
    style AI fill:#69f,stroke:#333,color:#000
```


---

## Host IP Reference

**SPIFFE ID mapping:** SPIFFE IDs identify the workload role, not the hostname. For example, `spiffe://wol/server-a` is the identity of the wol process running on host `wol-a`. The full mapping:

| SPIFFE ID | Host | Workload |
|-----------|------|----------|
| `spiffe://wol/accounts` | wol-accounts | Accounts API |
| `spiffe://wol/world-prod` | wol-world-prod | World API (prod) |
| `spiffe://wol/world-test` | wol-world-test | World API (test) |
| `spiffe://wol/server-a` | wol-a | Connection interface |
| `spiffe://wol/realm-prod` | wol-realm-prod | Game engine (prod) |
| `spiffe://wol/realm-test` | wol-realm-test | Game engine (test) |
| `spiffe://wol/ai-prod` | wol-ai-prod | AI service (prod) |
| `spiffe://wol/ai-test` | wol-ai-test | AI service (test) |
| (none, infrastructure) | obs | Observability (no SPIRE Agent, uses cfssl CA certs) |

**Shared infrastructure (dual-bridge: vmbr1 + vmbr3):**

| vmbr1 IP | vmbr3 IP | Hostname | Role |
|----------|----------|----------|------|
| 10.0.0.200 | 10.0.1.200 | wol-gateway-a | NAT gateway, DNS, NTP |
| 10.0.0.201 | 10.0.1.201 | wol-gateway-b | NAT gateway, DNS, NTP (active-active) |
| 10.0.0.202 | 10.0.1.202 | spire-db | PostgreSQL (SPIRE) + Tang (NBDE) |
| 10.0.0.203 | 10.0.1.203 | cfssl CA | Private CA (DB certs) |
| 10.0.0.204 | 10.0.1.204 | spire-server | SPIRE Server (workload identity) |
| 10.0.0.205 | -- | provisioning | vTPM Provisioning CA |
| 10.0.0.206 | 10.0.1.206 | wol-accounts-db | PostgreSQL (wol-accounts) |
| 10.0.0.207 | 10.0.1.207 | wol-accounts | Accounts API (C#/.NET) |
| 10.0.0.208 | 10.0.1.208 | wol-a | Connection interface (.NET, also ext-homed) |
| 10.0.0.209 | 10.0.1.209 | wol-web | Web frontend: ackmud.com (.NET Kestrel) |
| 10.0.0.100 | -- | obs | Observability (Loki, Prometheus, Grafana; tri-homed, homelab) |
| 10.0.0.115 | -- | apt-cache | apt-cacher-ng package cache (tri-homed, homelab) |

**Prod environment (vmbr1, 10.0.0.0/24):**

| IP | Hostname | Role |
|----|----------|------|
| 10.0.0.210 | wol-realm-prod | Game engine (.NET, internal only) |
| 10.0.0.211 | wol-world-prod | World API (C#/.NET) |
| 10.0.0.213 | wol-world-db-prod | PostgreSQL (wol_world) |
| 10.0.0.212 | wol-ai-prod | AI service (C#/.NET) |

**Test environment (vmbr3, 10.0.1.0/24):**

| IP | Hostname | Role |
|----|----------|------|
| 10.0.1.215 | wol-realm-test | Game engine (.NET, internal only) |
| 10.0.1.216 | wol-world-test | World API (C#/.NET) |
| 10.0.1.218 | wol-world-db-test | PostgreSQL (wol_world) |
| 10.0.1.217 | wol-ai-test | AI service (C#/.NET) |
| 192.168.1.253 | (Proxmox host) | Hypervisor (pve-exporter + Promtail push to obs) |
