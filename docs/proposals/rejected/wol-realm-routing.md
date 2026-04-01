# WOL Realm Routing

## Problem

With multiple environments (test, prod), the shared connection interface (wol-a) needs to route players to the correct realm based on their selection at login. Currently wol-a connects to a single hardcoded realm address.

## Design

### Login Flow

1. Player connects to wol-a (port 6969 via telnet/TLS/WS/WSS)
2. Player authenticates via wol-accounts
3. After authentication, wol-a presents a realm selection menu listing available realms
4. Player selects a realm
5. wol-a establishes a connection to the chosen wol-realm instance and begins proxying game traffic

### Realm Registry

wol-a needs to know which realms are available and how to reach them. Options:

**Option A: Static configuration**
A config file or environment variables listing realm name, address, and status. Simple, but requires redeployment to add/remove realms.

**Option B: Service discovery via SPIRE/DNS**
Realms register themselves; wol-a discovers them dynamically. More complex, but realms can come and go without reconfiguring wol-a.

**Option C: Database-backed registry**
A `realms` table in the accounts database listing realm name, address, status, and description. wol-accounts exposes a "list realms" API endpoint. Realms can be enabled/disabled without redeploying wol-a.

### Realm Selection UI

After login, before entering the game:

```
Welcome back, <player>.

Available realms:
  1. Prod    - Live game world
  2. Test    - Testing environment

Select a realm [1]:
```

### Access Control

Some realms may be restricted (e.g. test realm only available to staff accounts). This could be handled by:
- A flag on the account (e.g. `staff` or `roles` column)
- A per-realm access list
- No restriction (all realms visible to all players)

## Open Questions

- Which realm registry approach (A, B, or C)?
- Should realm selection be part of the telnet/text flow only, or also in the Flutter client UI?
- Should test realm access be restricted to staff accounts?
- Does the realm need to report its status (online/offline, player count) back to wol-a?

## Affected Repos

- `wol/` -- realm selection UI, routing logic, realm registry client
- `wol-accounts/` -- possibly a realms API endpoint (if Option C)
- `wol-client/` -- realm selection in Flutter UI (if applicable)
