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

CTIDs are **allocated randomly**, and a host's address is
`192.168.1.<CTID>`. Addresses are an output of provisioning, not an input.
That is the whole reason the internal DNS zone exists — nothing should refer
to these hosts by number.

Allocation is one independent `random_integer` per host, keyed on the host
name, so adding or removing a host never disturbs the CTIDs (and therefore the
IPs) of the others. Shuffling a shared pool would reassign everything whenever
the host set changed, recreating every container.

The tradeoff: independent draws can collide. A `precondition` turns a collision
into a loud plan-time failure rather than two containers silently fighting over
one ID. If it fires:

```bash
terraform apply -var 'ctid_salt={"obs"=1}'
```

`dns` is the one pinned host (`.149`, just below the `150-239` pool). It is the
bootstrap floor — every other container needs a predictable address to point
`--nameserver` at before name resolution exists.

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
