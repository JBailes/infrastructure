# WOL AI Service

> **Note:** This proposal was written before the multi-environment split. wol-ai is now per-environment: `wol-ai-prod` and `wol-ai-test`. CTIDs are dynamically allocated from 200+. See `infrastructure/hosts.md` for the current layout.

**Status:** Active
**Created:** 2026-03-25

## Problem

WOL needs an AI service for NPC dialogue, quest generation, and other dynamic content. The existing `tng-ai` service is a legacy prototype tied to the Groq SDK. WOL needs a purpose-built service that can consume any OpenAI-compatible API (OpenAI, Groq, Ollama, vLLM, LM Studio, etc.) and integrate cleanly with the WOL infrastructure (SPIRE identity, mTLS, private network).

## Proposal

### New repo: `wol-ai/`

A C#/.NET service that provides AI capabilities to WOL services. It consumes external OpenAI-compatible APIs via the gateways' NAT and exposes its own internal API to WOL services on the private network.

### Architecture

```
Game client
    |
    v
wol-a (:6969)
    |
    v (private network, mTLS)
wol-realm-a
    |
    v (private network, mTLS)
wol-ai (10.0.0.212:8443)
    |
    v (outbound via gateway NAT, HTTPS)
External AI API (OpenAI, Groq, Ollama, etc.)
```

wol-ai sits on the private network like the other API services. It receives requests from wol-realm (and potentially other internal services) over mTLS, then makes outbound HTTPS calls to external AI providers through the gateways' NAT.

### OpenAI-compatible client

The service uses the `openai` Python SDK as its sole AI client library. Any provider that exposes an OpenAI-compatible API works without code changes, just configuration:

```python
from openai import AsyncOpenAI

client = AsyncOpenAI(
    api_key=provider_config.api_key,
    base_url=provider_config.base_url,  # e.g. https://api.openai.com/v1, https://api.groq.com/openai/v1
)
```

Provider configuration is loaded from environment/config, not hardcoded. Switching providers (or running multiple) is a config change, not a code change.

### Provider configuration

Each provider is defined by a base URL, API key, default model, and optional parameters:

```bash
# Primary provider
WOL_AI_PROVIDER_DEFAULT=groq
WOL_AI_GROQ_BASE_URL=https://api.groq.com/openai/v1
WOL_AI_GROQ_API_KEY=<key>
WOL_AI_GROQ_DEFAULT_MODEL=llama-3.3-70b-versatile

# Alternative provider (can be swapped via config)
WOL_AI_OPENAI_BASE_URL=https://api.openai.com/v1
WOL_AI_OPENAI_API_KEY=<key>
WOL_AI_OPENAI_DEFAULT_MODEL=gpt-4o

# Local provider (e.g. Ollama on a separate host)
WOL_AI_LOCAL_BASE_URL=http://10.0.0.14:11434/v1
WOL_AI_LOCAL_API_KEY=unused
WOL_AI_LOCAL_DEFAULT_MODEL=llama3
```

API keys are stored at `/etc/wol-ai/secrets/` with mode 600, owned by root. The service reads them at startup. Key rotation follows the same pattern as the DNS API token in the gateway proposal.

### Internal API

wol-ai exposes endpoints for specific game functions, not a raw chat proxy. Each endpoint encapsulates the prompt engineering, context management, and response parsing for its use case.

#### Endpoints

| Method | Path | Auth | Purpose |
|--------|------|------|---------|
| POST | `/v1/dialogue` | mTLS + JWT | Generate NPC dialogue response |
| POST | `/v1/quest` | mTLS + JWT | Generate a quest (objectives, rewards, narrative) |
| POST | `/v1/describe` | mTLS + JWT | Generate dynamic descriptions (rooms, items, scenes) |
| GET | `/health` | None | Liveness check |

These are initial endpoints. The API surface will grow as more AI-driven features are added.

#### Dialogue request/response

```python
class DialogueRequest(BaseModel):
    npc_id: int                          # NPC prototype ID (from wol-world)
    npc_name: str
    npc_description: str                 # Short description from prototype
    npc_personality: str | None = None   # ai_prompt field from npc_prototypes
    player_name: str
    player_message: str                  # What the player said
    conversation_history: list[Message] = []  # Recent exchanges
    context: dict | None = None          # Room, area, quest state, etc.
    provider: str | None = None          # Override default provider
    model: str | None = None             # Override default model

class DialogueResponse(BaseModel):
    npc_message: str                     # What the NPC says back
    action: str | None = None            # Optional action hint (e.g. "give_item", "attack", "flee")
    model: str
    provider: str
    usage: dict | None = None
```

#### Quest generation request/response

```python
class QuestRequest(BaseModel):
    area_name: str
    area_level_min: int
    area_level_max: int
    quest_giver_npc: str
    player_level: int
    player_class: str
    context: dict | None = None          # Available NPCs, objects, rooms for the quest to reference
    provider: str | None = None
    model: str | None = None

class QuestResponse(BaseModel):
    title: str
    description: str                     # Narrative text shown to player
    objectives: list[str]                # e.g. ["Kill 5 goblins", "Return to Aldric"]
    rewards: dict | None = None          # e.g. {"experience": 500, "gold": 100}
    model: str
    provider: str
    usage: dict | None = None
```

### Host setup

| Property | Value |
|----------|-------|
| Hostname | `wol-ai` |
| IP | `10.0.0.212` |
| Type | LXC (privileged) |
| OS | Debian 13 |
| UID | 1005 |
| GID | 1005 |
| SPIRE Agent | Yes |
| SPIFFE ID | `spiffe://wol/ai` |
| Interfaces | 1 (private: on 10.0.0.0/20) |

Single-homed on the private network. Outbound AI API calls go through the gateways' NAT (ports 443 only, already allowed by gateway firewall rules).

#### Bootstrap script: `20-setup-wol-ai.sh`

Runs on: wol-ai (10.0.0.212)
Run order: Step 20 (SPIRE Agent must already be running on this host)

The script sets up:
- IPv6 disabled via sysctl
- ECMP default route via both gateways (10.0.0.200 and 10.0.0.201)
- DNS and NTP client pointing to both gateways
- Service user (`wol-ai`, UID 1005, GID 1005)
- Directory structure (`/usr/lib/wol-ai`, `/etc/wol-ai`, `/var/log/wol-ai`, `/etc/wol-ai/secrets`)
- Python 3 + venv at `/usr/lib/wol-ai/venv`
- Compiled C wrapper binary at `/usr/lib/wol-ai/bin/start` (for SPIRE unix:path attestation)
- Firewall (ufw): SSH from private network, :8443 from private network
- Systemd service unit

### SPIRE registration

Add to `12-register-workload-entries.sh`:

```bash
ensure_entry "spiffe://wol/ai" \
    -parentID "spiffe://wol/node/wol-ai" \
    -selector "unix:uid:1005" \
    -selector "unix:path:/usr/lib/wol-ai/bin/start" \
    -x509SVIDTTL 3600 \
    -jwtSVIDTTL 300
```

### Callers

Initially, **wol-realm** is the primary caller. The realm holds game state (which NPC the player is talking to, what room they're in, quest progress) and constructs the request with full context. wol-realm calls wol-ai over mTLS with its JWT-SVID.

wol-ai validates the caller's SPIFFE ID against an allowlist (initially just `spiffe://wol/realm-a`).

### Rate limiting and safety

- Per-caller rate limit: 120 req/min (configurable)
- Per-player rate limit: 10 req/min (passed as player_name in request, enforced by wol-ai)
- Max input length: 2000 characters for player messages
- Max conversation history: 20 messages
- Response timeout: 30 seconds per AI API call
- System prompts are server-side only (not controllable by players)

### Prompt engineering

System prompts are stored as templates in `/etc/wol-ai/prompts/` (not in code). Each endpoint has a default system prompt that can be customized without redeployment:

```
/etc/wol-ai/prompts/
    dialogue_system.txt      # System prompt for NPC dialogue
    quest_system.txt         # System prompt for quest generation
    describe_system.txt      # System prompt for descriptions
```

The service loads these at startup and caches them. A SIGHUP reloads prompts without restarting.

### Repo structure

```
wol-ai/
    app/
        __init__.py
        Program.cs              # ASP.NET Core app, endpoints
        config.py            # Settings (pydantic-settings)
        schemas.py           # Request/response models
        providers.py         # OpenAI client wrapper, provider registry
        prompts.py           # Prompt template loading
    tests/
        __init__.py
        test_api.py
        test_providers.py
        test_schemas.py
    pyproject.toml
    .csproj
    .env.example
    CLAUDE.md
```

Flat provider module (not a sub-package like tng-ai). Since all providers use the same OpenAI SDK client with different base URLs, there is no need for a provider abstraction hierarchy.

## Changes to existing infrastructure

### hosts.md

Add:

| Hostname | IP | Type | OS | Role |
|----------|----|------|-----|------|
| `wol-ai` | `10.0.0.212` | LXC (privileged) | Debian 13 | WOL AI service (C#/.NET); SPIRE Agent for workload identity |

Add to port reference:

| Host | Port | Clients | Purpose |
|------|------|---------|---------|
| `wol-ai` | `8443` | `wol-realm-a` | AI API (mTLS) |

### Proxmox inventory

Add to `inventory.conf`:

```bash
"wol-ai|auto|lxc|10.0.0.212|${PRIVATE_BRIDGE}||yes|8|512|1|AI service + SPIRE Agent"
```

### Bootstrap sequence

Add after step 19:

| Script | Action | Where |
|--------|--------|-------|
| `20-setup-wol-ai.sh` | Python venv, wrapper binary, prompt templates | `wol-ai` |

### Gateway dnsmasq

Add hostname entry to `00-setup-gateway.sh`:

```
address=/wol-ai/10.0.0.212
```

### SPIRE workload registration

Add entry to `12-register-workload-entries.sh` (shown above).

### wol-realm configuration

Add to wol-realm's environment:

```
WOL_AI_URL=https://10.0.0.212:8443
```

## Trade-offs

**External API dependency.** wol-ai depends on external AI APIs that go through the gateways' NAT. If both gateways fail or the external API is down, AI features are unavailable. The realm should handle this gracefully (fall back to scripted responses, log the failure, do not crash).

**API key management.** API keys for external providers are stored on disk. They cannot use SPIRE/step-ca (those are for internal identity, not external API auth). Keys are file-based with restrictive permissions, rotated manually.

**Prompt injection.** Player messages are untrusted input passed to an LLM. System prompts must be carefully constructed to resist prompt injection. The service should never expose internal state, system prompts, or infrastructure details in responses. This is an ongoing concern, not a one-time fix.

**Cost.** External AI API calls cost money per token. Rate limiting (per-player and per-caller) bounds costs. Usage statistics are logged for monitoring.

**Latency.** AI API calls add 1-5 seconds of latency per request. The realm must handle this asynchronously so it does not block the game tick loop. Dialogue responses can arrive after a short delay without degrading gameplay.

## Affected files

| Location | File | Change |
|----------|------|--------|
| `wol-ai/` | (new repo) | New: entire service |
| `wol-docs/infrastructure/bootstrap/` | `20-setup-wol-ai.sh` | New: bootstrap script |
| `wol-docs/infrastructure/` | `hosts.md` | Update: add wol-ai host and port |
| `wol-docs/infrastructure/bootstrap/` | `00-setup-gateway.sh` | Update: add wol-ai DNS entry |
| `wol-docs/infrastructure/bootstrap/` | `12-register-workload-entries.sh` | Update: add wol-ai SPIRE entry |
| `wol-docs/infrastructure/proxmox/` | `inventory.conf` | Update: add wol-ai container |
