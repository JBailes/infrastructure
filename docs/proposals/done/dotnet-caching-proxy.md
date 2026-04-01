# Proposal: .NET SDK Caching Proxy on nginx-proxy (CT 118)

## Problem

`setup.sh` installs the .NET 9 SDK via Microsoft's `dotnet-install.sh`, which downloads ~200 MB from `dotnetcli.azureedge.net` on every VM. With dozens of VMs running setup, this wastes bandwidth and slows provisioning. Additionally, the Microsoft apt repository's GPG key uses SHA-1 binding signatures, which Debian 13's `sqv` rejects as of 2026-02-01, making the apt-based install path broken.

## Approach

Add an nginx caching reverse proxy on CT 118 (`nginx-proxy`) that transparently caches .NET SDK downloads. This host already has access to all three networks (LAN, WOL, ACK), so every VM can reach it.

### nginx-proxy changes (CT 118)

Add a caching proxy configuration that:

1. Listens on a dedicated port (e.g., 8080) on all interfaces
2. Proxies requests to `https://dotnetcli.azureedge.net`
3. Caches responses on disk (e.g., `/var/cache/nginx/dotnet`, 2 GB max)
4. Serves cached responses for subsequent requests (long TTL, since SDK tarballs are immutable by version)

Example nginx config (`/etc/nginx/sites-available/dotnet-cache`):

```nginx
proxy_cache_path /var/cache/nginx/dotnet
    levels=1:2
    keys_zone=dotnet_cache:10m
    max_size=2g
    inactive=30d
    use_temp_path=off;

server {
    listen 8080;
    server_name _;

    location / {
        proxy_pass https://dotnetcli.azureedge.net;
        proxy_ssl_server_name on;
        proxy_set_header Host dotnetcli.azureedge.net;

        proxy_cache dotnet_cache;
        proxy_cache_valid 200 30d;
        proxy_cache_use_stale error timeout updating;
        proxy_cache_lock on;

        # SDK tarballs are immutable per URL, so aggressive caching is safe
        add_header X-Cache-Status $upstream_cache_status;
    }
}
```

Open port 8080 in the firewall for all local networks (LAN, WOL, ACK).

### Bootstrap script changes (06-setup-nginx-proxy.sh)

Add the caching proxy config, cache directory creation, and firewall rule to the existing bootstrap script.

### setup.sh changes (aicli)

Change the `dotnet-install.sh` invocation to use `--azure-feed` pointed at the local cache:

```bash
DOTNET_CACHE="http://192.168.1.118:8080"
curl -fsSL https://dot.net/v1/dotnet-install.sh | bash -s -- \
    --channel 9.0 \
    --install-dir /usr/local/dotnet \
    --azure-feed "$DOTNET_CACHE"
```

Also includes the already-implemented fix to remove stale Microsoft apt sources.

### Disk space consideration

CT 118 currently has 4 GB disk. The .NET 9 SDK tarball is ~200 MB, so the cache is small. The 2 GB `max_size` limit on the cache zone ensures it self-evicts old entries. No disk resize needed unless we start caching more than .NET.

## Affected files/repos

| File | Repo | Change |
|------|------|--------|
| `setup.sh` | aicli | Point `dotnet-install.sh` at cache, remove stale apt source |
| `wol-docs/homelab/bootstrap/06-setup-nginx-proxy.sh` | wol-docs | Add caching proxy config, cache dir, firewall rule |

## Trade-offs

- **Pro:** Transparent to VMs, first download caches automatically, no manual tarball management
- **Pro:** Reuses existing infrastructure (CT 118 already serves all networks)
- **Pro:** Immutable SDK tarballs make aggressive caching safe
- **Con:** Adds a dependency on CT 118 being reachable during setup (but it already is for web proxying)
- **Con:** First VM still downloads from Microsoft; subsequent VMs hit cache
- **Fallback:** If the cache is unreachable, `dotnet-install.sh` could fall back to the direct URL (setup.sh can attempt cache first, direct second)

## Open questions

1. Should we add a fallback in `setup.sh` that tries the direct URL if the cache is unreachable?
2. Should we cache anything else through this proxy in the future (e.g., NuGet packages, npm tarballs)?
