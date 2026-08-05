# Terraform provisioning

Creates the homelab LXC containers and registers their DNS records.

**Scope: provisioning only.** Terraform creates containers and their network;
the bash scripts in `../homelab/bootstrap/` still do in-guest configuration.
Those scripts encode a lot of hard-won service setup and rewriting them as
Terraform would trade working code for churn.

> **Status: not yet applied.** This has never been run against the live host —
> there is no Terraform binary on the obs container where it was written, so it
> has not been `validate`d or `plan`ned. Review the plan carefully on first use.

## Addressing model

CTIDs are assigned **sequentially**, and a host's address is
`192.168.1.<CTID>` — the CTID *is* the address. Services still refer to each
other by name through the internal DNS zone, so renumbering a host does not
mean editing config all over the place.

CTIDs are assigned **sequentially** from `ctid_start` (101) in `host_order`,
skipping `reserved_ctids`. The current assignment:

| CTID | Host | | CTID | Host |
|---|---|---|---|---|
| 101 | dns | | 106 | personal-web |
| 103 | apt-cache | | 107 | rakuen-web |
| 104 | obs | | 108 | bittorrent |
| 105 | nginx-proxy | | 109 | deploy |
| | | | 110 | vpn-gateway (VM) |

`102` is skipped — it belongs to the unifi controller, which is not managed
here. `dns` is simply first, so its address is predictable without needing a
special pin.

**Order matters.** Append new hosts to the end of `host_order`; inserting into
the middle renumbers everything after it, and since the CTID *is* the address,
that means recreating those containers.

This must stay in step with the `CTID_*` block in
`../homelab/bootstrap/lib/common.sh`, which the bash scripts use when Terraform
is not involved.

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars   # fill in, gitignored
terraform init
terraform plan
terraform apply
```

First apply: leave `dns_api_token` empty — the dns host does not exist yet, so
there is nothing to register against. Bring it up with
`../homelab/bootstrap/05-setup-dns.sh`, take the token from
`/etc/dns-api-token` on that host, put it in `terraform.tfvars`, and apply
again to register every record.

## Outputs

- `hosts` — allocated CTID, IP and FQDN per host
- `dns_host` — the pinned resolver
- `homelab/bootstrap/lib/terraform.env` — written on apply; sourced by
  `lib/common.sh` so bash and Terraform cannot disagree about where DNS lives.
  It carries only the resolver's address; everything else is reached by name.

## Files

| File | Purpose |
|------|---------|
| `hosts.tf` | Host inventory and CTID allocation |
| `containers.tf` | LXC container resources |
| `dns.tf` | Technitium record registration (no maintained provider, so the HTTP API) |
| `outputs.tf` | Outputs and the generated `terraform.env` |
| `variables.tf` | Inputs, with the ACK range guarded off |

## Not managed here

- **The `vpn-gateway` VM** — needs a cloud-init image import that
  `01-setup-vpn-gateway.sh` already handles well. It is still registered in DNS.
- **The ACK network** (`vmbr2`, CTIDs 240-254) — deliberately left alone;
  `homelab/ack/bootstrap/pve-setup-ack.sh` owns it.
