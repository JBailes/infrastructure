# Homelab Infrastructure Diagrams

Visual reference for the homelab infrastructure. All diagrams use Mermaid syntax.

---

## Network Topology

```mermaid
graph TB
    subgraph Internet
        INET((Internet))
    end

    subgraph LAN["Home LAN (192.168.1.0/23)"]
        ROUTER["Router<br/>192.168.1.1"]

        subgraph HOMELAB["Homelab Services"]
            APTCACHE["apt-cache<br/>192.168.1.115 (vmbr0)<br/>10.0.0.115 (vmbr1)<br/>10.1.0.115 (vmbr2)<br/>apt-cacher-ng :3142"]
            OBS["obs<br/>192.168.1.100 (vmbr0)<br/>10.0.0.100 (vmbr1)<br/>10.1.0.100 (vmbr2)<br/>Loki / Prometheus / Grafana"]
            VPN["vpn-gateway<br/>192.168.1.104<br/>OpenVPN + kill switch"]
            BT["bittorrent<br/>192.168.1.116<br/>qBittorrent-nox"]
            NGINX["nginx-proxy<br/>192.168.1.118 (vmbr0)<br/>10.0.0.118 (vmbr1)<br/>10.1.0.118 (vmbr2)<br/>nginx + certbot"]
            PWEB["personal-web<br/>192.168.1.117<br/>node serve :3000"]
            WOLF["wolf<br/>192.168.1.120<br/>Moonlight streaming"]
            OLLAMA["ollama<br/>192.168.1.103<br/>Ollama :11434<br/>AMD 7900XTX GPU"]
        end

        NAS["NAS<br/>192.168.1.254<br/>NFS storage"]
        PVE["Proxmox Host<br/>192.168.1.253"]
    end

    subgraph WOL["WOL Private Network (10.0.0.0/20)"]
        WOLHOSTS["All WOL hosts"]
    end

    INET --- ROUTER
    ROUTER --- VPN
    ROUTER --- APTCACHE
    VPN -->|"VPN tunnel<br/>(all traffic)"| INET
    BT -->|"default gw<br/>192.168.1.104"| VPN
    BT -->|"NFS :2049"| NAS
    APTCACHE -.->|"apt proxy :3142<br/>(tri-homed)"| WOLHOSTS
    OBS -.->|"log/metric ingestion<br/>(tri-homed)"| WOLHOSTS
    INET -->|":80/:443"| NGINX
    NGINX -->|"proxy"| PWEB
    NGINX -.->|"proxy via vmbr1"| WOLHOSTS
    PVE --- VPN
    PVE --- BT
    PVE --- APTCACHE
    PVE --- OBS
    PVE --- NGINX
    PVE --- PWEB
    PVE --- WOLF
    PVE --- OLLAMA

    style APTCACHE fill:#9f9,stroke:#333,color:#000
    style OBS fill:#9cf,stroke:#333,color:#000
    style VPN fill:#4a9,stroke:#333,color:#000
    style BT fill:#69f,stroke:#333,color:#000
    style NGINX fill:#f96,stroke:#333,color:#000
    style PWEB fill:#f96,stroke:#333,color:#000
    style NAS fill:#fa0,stroke:#333,color:#000
    style PVE fill:#ccc,stroke:#333,color:#000
    style WOLHOSTS fill:#ddd,stroke:#999,color:#333
    style WOLF fill:#c6f,stroke:#333,color:#000
    style OLLAMA fill:#f6c,stroke:#333,color:#000
```

## VPN Kill Switch (Three Layers)

```mermaid
graph LR
    BT["bittorrent<br/>container"] -->|"1. default route"| VPN["vpn-gateway<br/>kill switch"]
    BT -->|"2. iptables OUTPUT"| FW["local firewall<br/>(DROP policy)"]
    BT -->|"3. watchdog"| WD["60s health check<br/>(stops qBittorrent)"]

    VPN -->|"tunnel up"| INET((Internet))
    VPN -->|"tunnel down"| DROP["DROPPED"]

    FW -->|"only allows"| ALLOWED["192.168.1.104 (VPN gw)<br/>192.168.1.254 (NAS :2049)"]

    style DROP fill:#f66,stroke:#333,color:#000
    style VPN fill:#4a9,stroke:#333,color:#000
```

## Host Reference

| IP | Hostname | ID | Type | Role |
|----|----------|------|------|------|
| 192.168.1.115 (vmbr0), 10.0.0.115 (vmbr1), 10.1.0.115 (vmbr2) | apt-cache | 115 | LXC (unprivileged, tri-homed) | apt-cacher-ng package cache for all networks |
| 192.168.1.100 (vmbr0), 10.0.0.100 (vmbr1), 10.1.0.100 (vmbr2) | obs | 215 | LXC (unprivileged, tri-homed) | Loki + Prometheus + Grafana + Alertmanager |
| 192.168.1.104 | vpn-gateway | 104 | VM (cloud-init) | OpenVPN gateway with kill switch |
| 192.168.1.116 | bittorrent | 116 | LXC (privileged) | qBittorrent-nox, triple VPN enforcement |
| 192.168.1.117 | personal-web | 117 | LXC (unprivileged) | Static file server (bailes.us) on :3000 |
| 192.168.1.118 (vmbr0), 10.0.0.118 (vmbr1), 10.1.0.118 (vmbr2) | nginx-proxy | 118 | LXC (unprivileged, tri-homed) | nginx reverse proxy + certbot TLS for all web sites |
| 192.168.1.120 | wolf | 120 | LXC (privileged, GPU passthrough) | Wolf cloud gaming (Moonlight streaming) |
| 192.168.1.103 | ollama | 103 | LXC (privileged, AMD 7900XTX GPU) | Ollama LLM inference, OpenAI-compatible API on :11434 |
| 192.168.1.253 | pve | N/A | Proxmox host | Hypervisor |
| 192.168.1.254 | nas | N/A | NAS | NFS storage for downloads |
