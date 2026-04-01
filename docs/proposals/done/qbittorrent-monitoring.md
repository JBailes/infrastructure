# Add qBittorrent to Infrastructure Monitoring

## Problem

qBittorrent (CT 116, `192.168.1.116:8080`) has Promtail for log shipping but no
Prometheus metrics visibility. If the WebUI goes down, there is no dashboard
indication.

## Approach

qBittorrent-nox does not expose a `/metrics` endpoint, so we use the same
blackbox HTTP probe pattern already in place for personal-web and nginx-proxy.

### Changes

**`08-setup-dashboards.sh`**

1. Add `http://192.168.1.116:8080` to the blackbox scrape job's `static_configs`
   targets list, alongside the existing personal-web and nginx-proxy entries.

That is the only change required. The blackbox probe result
(`probe_success{job="blackbox"}`) already feeds into the Infrastructure panel on
the Service Health dashboard, so the new qBittorrent tile will appear
automatically.

### What this monitors

- HTTP 200 reachability of the qBittorrent WebUI on port 8080.
- The probe runs every 15 seconds (the global scrape interval).
- If the service is down or unreachable, the tile turns red on the Service Health
  dashboard.

## Trade-offs

- This only checks "is the WebUI responding 200?" It does not monitor download
  speeds, VPN tunnel health, or disk usage. Those could be added later with a
  dedicated exporter, but a simple up/down probe covers the immediate need.
- The WebUI auth whitelist (`192.168.0.0/23`) already includes the obs container
  (`192.168.1.100`), so the probe will not be blocked by authentication.

## Affected files

- `homelab/bootstrap/08-setup-dashboards.sh`
