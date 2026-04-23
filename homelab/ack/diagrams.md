# ACK! MUD Network Diagrams

All diagrams use Mermaid syntax.

---

## Network Topology

```mermaid
graph TB
    subgraph Internet
        INET((Internet))
        PLAYERS((MUD Clients))
    end

    subgraph EXT["External Network (192.168.1.0/23)"]
        PVE["Proxmox Host<br/>192.168.1.253"]
    end

    subgraph ACK["ACK! Network (vmbr2, 10.1.0.0/24)"]
        GW["ack-gateway<br/>10.1.0.240 / 192.168.1.240<br/>NAT + DNS + port fwd"]

        ACKDB["ack-db<br/>10.1.0.246<br/>:5432 (PostgreSQL)"]

        subgraph MUDS["MUD Servers"]
            TNG["acktng<br/>10.1.0.241<br/>:4000"]
            V431["ack431<br/>10.1.0.242<br/>:4000"]
            V42["ack42<br/>10.1.0.243<br/>:4000"]
            V41["ack41<br/>10.1.0.244<br/>:4000"]
            ASS["assault30<br/>10.1.0.245<br/>:4000"]
        end

        ACKWEB["ack-web<br/>10.1.0.247<br/>:5000 (node)<br/>aha.ackmud.com"]

        TNGAI["tng-ai<br/>10.1.0.248<br/>:8000 (uvicorn)<br/>NPC dialogue"]
        TNGDB["tngdb<br/>10.1.0.249<br/>:8000 (uvicorn)<br/>game content API"]
    end

    subgraph SHARED["Shared Services"]
        CACHE["apt-cache<br/>10.1.0.115 (vmbr2)<br/>10.0.0.115 (vmbr1)<br/>192.168.1.115 (vmbr0)"]
        OBS["obs<br/>10.1.0.100 (vmbr2)<br/>10.0.0.100 (vmbr1)<br/>192.168.1.100 (vmbr0)<br/>Loki / Prometheus / Grafana"]
    end

    PLAYERS -->|":8890"| GW
    PLAYERS -->|":8891"| GW
    PLAYERS -->|":8892"| GW
    PLAYERS -->|":8893"| GW
    PLAYERS -->|":8894"| GW

    GW -->|"DNAT :8890 -> :4000"| TNG
    GW -->|"DNAT :8891 -> :4000"| V431
    GW -->|"DNAT :8892 -> :4000"| V42
    GW -->|"DNAT :8893 -> :4000"| V41
    GW -->|"DNAT :8894 -> :4000"| ASS

    GW -->|"NAT outbound"| INET

    TNG -->|"PostgreSQL"| ACKDB
    V431 -->|"PostgreSQL"| ACKDB
    V42 -->|"PostgreSQL"| ACKDB
    V41 -->|"PostgreSQL"| ACKDB
    ASS -->|"PostgreSQL"| ACKDB

    TNG -->|"TNGAI_URL"| TNGAI
    TNGAI -->|"Groq API"| INET
    TNGDB -->|"PostgreSQL"| ACKDB

    TNG -.->|"apt proxy"| CACHE
    V431 -.->|"apt proxy"| CACHE
    V42 -.->|"apt proxy"| CACHE
    V41 -.->|"apt proxy"| CACHE
    ASS -.->|"apt proxy"| CACHE

    TNG -.->|"Promtail"| OBS
    V431 -.->|"Promtail"| OBS
    V42 -.->|"Promtail"| OBS
    V41 -.->|"Promtail"| OBS
    ASS -.->|"Promtail"| OBS
    ACKWEB -.->|"Promtail"| OBS
    ACKDB -.->|"Promtail"| OBS
    ACKDB -.->|"postgres_exporter"| OBS
    TNGAI -.->|"Promtail"| OBS
    TNGDB -.->|"Promtail"| OBS

    style ACKDB fill:#96f,stroke:#333,color:#000
    style GW fill:#4a9,stroke:#333,color:#000
    style ACKWEB fill:#f96,stroke:#333,color:#000
    style TNGAI fill:#fc6,stroke:#333,color:#000
    style TNGDB fill:#fc6,stroke:#333,color:#000
    style TNG fill:#f66,stroke:#333,color:#000
    style V431 fill:#f66,stroke:#333,color:#000
    style V42 fill:#f66,stroke:#333,color:#000
    style V41 fill:#f66,stroke:#333,color:#000
    style ASS fill:#f66,stroke:#333,color:#000
    style CACHE fill:#9f9,stroke:#333,color:#000
    style OBS fill:#9cf,stroke:#333,color:#000
```

## Port Forwarding

```mermaid
graph LR
    C1["Client :8890"] -->|DNAT| TNG["acktng<br/>10.1.0.241:4000"]
    C2["Client :8891"] -->|DNAT| V431["ack431<br/>10.1.0.242:4000"]
    C3["Client :8892"] -->|DNAT| V42["ack42<br/>10.1.0.243:4000"]
    C4["Client :8893"] -->|DNAT| V41["ack41<br/>10.1.0.244:4000"]
    C5["Client :8894"] -->|DNAT| ASS["assault30<br/>10.1.0.245:4000"]

    style TNG fill:#f66,stroke:#333,color:#000
    style V431 fill:#f66,stroke:#333,color:#000
    style V42 fill:#f66,stroke:#333,color:#000
    style V41 fill:#f66,stroke:#333,color:#000
    style ASS fill:#f66,stroke:#333,color:#000
```

## Network Isolation

```mermaid
graph TB
    subgraph VMBR0["vmbr0 (External LAN)"]
        EXT["192.168.1.0/23"]
    end

    subgraph VMBR1["vmbr1 (WOL Private)"]
        WOL["10.0.0.0/20"]
    end

    subgraph VMBR2["vmbr2 (ACK! Private)"]
        ACK["10.1.0.0/24"]
    end

    CACHE["apt-cache<br/>(tri-homed)"]
    OBS2["obs<br/>(tri-homed)"]

    CACHE --- VMBR0
    CACHE --- VMBR1
    CACHE --- VMBR2
    OBS2 --- VMBR0
    OBS2 --- VMBR1
    OBS2 --- VMBR2

    WOL -.-x|"NO traffic"| ACK

    style VMBR0 fill:#ccc,stroke:#333
    style VMBR1 fill:#69f,stroke:#333
    style VMBR2 fill:#f96,stroke:#333
    style CACHE fill:#9f9,stroke:#333,color:#000
    style OBS2 fill:#9cf,stroke:#333,color:#000
```

## Host Reference

| IP | Hostname | CTID | Bridge | Role |
|----|----------|------|--------|------|
| 10.1.0.240 / 192.168.1.240 | ack-gateway | 240 | vmbr0 + vmbr2 | NAT gateway, DNS, port forwarding |
| 10.1.0.241 | acktng | 241 | vmbr2 | ACK!TNG MUD server |
| 10.1.0.242 | ack431 | 242 | vmbr2 | ACK! 4.3.1 MUD server |
| 10.1.0.243 | ack42 | 243 | vmbr2 | ACK! 4.2 MUD server |
| 10.1.0.244 | ack41 | 244 | vmbr2 | ACK! 4.1 MUD server |
| 10.1.0.245 | assault30 | 245 | vmbr2 | Assault 3.0 MUD server |
| 10.1.0.246 | ack-db | 246 | vmbr2 | PostgreSQL database (acktng) |
| 10.1.0.247 | ack-web | 247 | vmbr2 | AHA web app (aha.ackmud.com) |
| 10.1.0.248 | tng-ai | 248 | vmbr2 | NPC dialogue AI (Python/FastAPI/Groq) |
| 10.1.0.249 | tngdb | 249 | vmbr2 | Read-only game content API (Python/FastAPI) |
| 10.1.0.115 | apt-cache | 115 | vmbr0 + vmbr1 + vmbr2 | Package cache (shared) |
| 10.1.0.100 | obs | 100 | vmbr0 + vmbr1 + vmbr2 | Observability stack (shared) |
