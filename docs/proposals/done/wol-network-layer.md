# Proposal: WOL Network Layer -- Single-Port Multi-Protocol Socket Server

**Date:** 2026-03-24
**Status:** Pending approval

---

## Problem

WOL is a new C# .NET Core MUD server replacing acktng. It needs a network layer that:

1. Accepts connections from classic MUD telnet clients (plain and TLS), browser-based clients (WebSocket and WSS), and modern MUD clients that expect the full MUD telnet protocol suite (MSSP, MSDP, GMCP, MCCP2, MCCP3, NAWS, TTYPE/MTTS, CHARSET, SGA).
2. Supports email-based account login/registration rather than acktng's character-name-first model.
3. Improves on acktng's per-protocol port model by multiplexing all four protocols on a single configurable port (default `6969`).

**Terminology clarification:** The user mentioned "MDDP" and "MDSP" -- these are interpreted as **MSSP** (MUD Server Status Protocol, telnet option 70) and **MSDP** (MUD Server Data Protocol, telnet option 69) respectively, which are the standard MUD telnet protocols acktng supports.

---

## Approach: Single-Port Protocol Sniffing

A single TCP listener accepts all connections. After `accept()`, the server peeks at the first bytes with a **1.0-second timeout** to determine protocol:

| First byte(s) seen | Protocol |
|---|---|
| `0x16` (TLS ClientHello) | Wrap with `SslStream`, then re-sniff (see below) |
| `GET ` (0x47 0x45 0x54 0x20) | Plain WebSocket (`ws://`) -- HTTP upgrade |
| Anything else / timeout | Plain Telnet |

After TLS handshake, sniff again:

| Post-TLS first bytes | Protocol |
|---|---|
| `GET ` | Secure WebSocket (`wss://`) -- HTTP upgrade over TLS |
| Anything else / timeout | TLS Telnet |

**Timeout semantics:** Many telnet clients send nothing until the server sends a prompt. If the peek times out (1.0s), the connection is assumed to be plain telnet and the greeting is sent. TLS and WebSocket clients always initiate immediately, so the timeout only fires for telnet.

This eliminates acktng's four-port setup (8890, 9890, 9891, 18890). A single port handles everything; TLS cert/key are loaded at startup and used for both TLS Telnet and WSS.

---

## Architecture

### Project Layout

```
wol/
  Wol.sln
  Wol.Server/
    Program.cs                  # Entry point, config, startup
    Network/
      ConnectionListener.cs     # TcpListener, accept loop
      ProtocolDetector.cs       # Byte-sniff logic, 1s timeout
      TelnetConnection.cs       # Telnet state machine + IAC/option negotiation
      TelnetOptions.cs          # MSSP, MSDP, GMCP, MCCP2/3 constants and handlers
      WebSocketConnection.cs    # HTTP upgrade handshake + WS frame codec
      IGameConnection.cs        # Common interface for both connection types
    Auth/
      LoginStateMachine.cs      # Telnet login/registration state machine
      AccountStore.cs           # Account lookup and password validation (stub)
    Wol.Server.csproj
```

### Key Types

**`IGameConnection`**
Common interface implemented by both `TelnetConnection` and `WebSocketConnection`. Provides:
- `SendAsync(string text)` -- deliver text to client
- `SendRawAsync(byte[] data)` -- for telnet option bytes, WS binary frames
- `CloseAsync()` -- graceful close
- `ConnectionType` property (`Telnet` / `WebSocket`)

**`ConnectionListener`**
- Binds `TcpListener` to `0.0.0.0:6969` (configurable via `appsettings.json`)
- Loads TLS cert/key at startup from configured paths (PEM files; Let's Encrypt compatible)
- Accept loop: for each accepted `TcpClient`, spawns `Task.Run(() => HandleConnectionAsync(client))`

**`ProtocolDetector`**
- `PeekAsync(NetworkStream, TimeSpan timeout) → ProtocolKind`
- Uses `ReadAsync` with `CancellationTokenSource` for the 1.0s timeout
- Returns `Tls`, `WebSocket`, or `PlainTelnet`
- For `Tls`: performs `SslStream.AuthenticateAsServerAsync`, then calls itself recursively on the `SslStream` to detect WSS vs TLS Telnet

**`TelnetConnection`**
- Wraps a `Stream` (either `NetworkStream` for plain or `SslStream` for TLS)
- Reads bytes in a loop; strips and processes IAC command sequences
- Sends protocol offers on connect: `WILL ECHO`, `WILL SGA`, `WILL MSSP`, `WILL MSDP`, `WILL GMCP`, `WILL MCCP2`, `WILL MCCP3`, `DO NAWS`, `DO TTYPE`, `DO CHARSET`
- Tracks per-connection client capabilities: terminal dimensions (NAWS), terminal type and MTTS bitmask (TTYPE), agreed character set (CHARSET)
- Dispatches received `DO`/`DONT`/`WILL`/`WONT` and subnegotiation to `TelnetOptions`
- Drives `LoginStateMachine` with decoded text lines

**`WebSocketConnection`**
- HTTP upgrade: parses `GET` request headers, validates `Upgrade: websocket` and `Sec-WebSocket-Key`, returns 101 response with computed `Sec-WebSocket-Accept`
- WS frame codec: reads/writes frames per RFC 6455 (text and binary opcodes; ping/pong; close handshake)
- Drives authentication via JSON messages (see Auth section below)

---

## Telnet Protocol Support

All protocols acktng supports are carried forward, plus four additions (marked **new**):

| Protocol | Telnet Option | Direction | Notes |
|---|---|---|---|
| **MSSP** -- MUD Server Status Protocol | 70 | Server sends on request | Server name, uptime, player count, area/mob/room counts |
| **MSDP** -- MUD Server Data Protocol | 69 | Bidirectional | Variable subscription; same variable set as acktng (HEALTH, MANA, ROOM_NAME, etc.) |
| **GMCP** -- Generic MUD Comm Protocol | 201 | Bidirectional | Package subscription; Char, Room, Comm packages |
| **MCCP2** -- Compression Protocol v2 | 86 | Server compresses output | zlib deflate stream; uses `System.IO.Compression.DeflateStream` |
| **MCCP3** -- Compression Protocol v3 | 87 | Client and server compressed | zlib, per-message framing |
| **Echo suppression** | 1 | Server `WILL ECHO` | Suppress echo during password entry |
| **SGA** -- Suppress Go-Ahead | 3 | Server `WILL SGA` | **new.** Most clients expect this; suppresses `IAC GA` after every prompt when agreed |
| **Go-Ahead** | -- | Server sends `IAC GA` | Sent after prompts when SGA is *not* negotiated; signals end of server output |
| **NAWS** -- Negotiate About Window Size | 31 | Client sends `DO NAWS` | **new.** Client reports terminal cols×rows on connect and on resize; used for word-wrap and map rendering |
| **TTYPE** -- Terminal Type + MTTS | 24 | Server sends `DO TTYPE` | **new.** Client identifies terminal type ("MUDLET", "XTERM", etc.) and MTTS capability bitmask (ANSI, UTF-8, 256-color, truecolor, mouse tracking, OSC color palette) |
| **CHARSET** | 42 | Server sends `DO CHARSET` | **new.** Negotiate UTF-8 on the wire; important since WOL strings are UTF-16 internally |

### MTTS Capability Bitmask (via TTYPE subnegotiation)

When a client supports MTTS it sends `"MTTS <N>"` as its terminal-type string. `TelnetOptions` will parse and store the bitmask so the game layer can query client capabilities:

| Bit | Meaning |
|---|---|
| 1 | ANSI color |
| 2 | VT100 |
| 4 | UTF-8 |
| 8 | 256-color |
| 16 | Mouse tracking |
| 32 | OSC color palette |
| 64 | Screen reader mode |
| 256 | 24-bit truecolor |

`TelnetOptions.cs` will define all byte constants (matching acktng's `socket.h` where applicable) and handler methods called from `TelnetConnection`.

For MCCP2/3, the `TelnetConnection` wraps its write path in a `DeflateStream` once compression is negotiated, exactly as acktng's `mccp2_start()` does.

---

## Authentication

### Telnet Login State Machine (`LoginStateMachine.cs`)

States:

```
PromptEmail
  → if email exists in AccountStore: PromptPassword
  → if email is new:                 ConfirmNewEmail

PromptPassword          (echo suppressed)
  → if password correct:  LoggedIn
  → if password wrong:    [send "Wrong password." → close connection]

ConfirmNewEmail
  → if user confirms:     PromptNewPassword
  → if user cancels:      PromptEmail

PromptNewPassword       (echo suppressed)
  → always:               PromptConfirmPassword

PromptConfirmPassword   (echo suppressed)
  → if passwords match:   [create account → LoggedIn]
  → if mismatch:          [send "Passwords do not match." → PromptNewPassword]

LoggedIn
  → hand off to game session
```

Text prompts (telnet):
- `"Enter email: "`
- `"Password: "` (send `IAC WILL ECHO` before, `IAC WONT ECHO` after)
- `"New account. Is {email} correct? [y/n] "`
- `"Choose a password: "` (echo suppressed)
- `"Confirm password: "` (echo suppressed)
- `"Welcome! Logged in as {email}."` → hand off
- `"Wrong password."` → close
- `"Passwords do not match."` → re-prompt

### WebSocket Authentication

WebSocket clients send JSON messages. The server responds with JSON.

**Login:**
```json
{ "action": "login", "email": "user@example.com", "password": "secret" }
```
Response (success): `{ "status": "ok", "email": "user@example.com" }`
Response (wrong password): `{ "status": "error", "message": "Wrong password." }` → close
Response (unknown email -- redirect to register): `{ "status": "register_required" }`

**Register:**
```json
{ "action": "register", "email": "user@example.com", "password": "secret", "confirm": "secret" }
```
Response (success): `{ "status": "ok", "email": "user@example.com" }`
Response (password mismatch): `{ "status": "error", "message": "Passwords do not match." }`
Response (email taken): `{ "status": "error", "message": "Email already registered." }`

The web client (Blazor) presents either a login form or a registration form and sends the appropriate JSON message. No multi-step state machine is needed on the server side for WebSocket -- the client handles the UI flow.

### Password Storage

Passwords are stored as salted bcrypt hashes. .NET's `BCrypt.Net-Next` NuGet package provides `BCrypt.HashPassword()` and `BCrypt.Verify()`. `AccountStore` is a stub in this proposal (backed by in-memory dict initially; a real database backend is a follow-on proposal).

---

## Configuration (`appsettings.json`)

```json
{
  "Network": {
    "Port": 6969,
    "TlsCertPath": "data/tls/server.crt",
    "TlsKeyPath": "data/tls/server.key",
    "SniffTimeoutMs": 1000
  }
}
```

TLS cert/key are optional at startup -- if absent, TLS and WSS are disabled and only plain Telnet and WS are available (with a warning logged). This matches acktng's behaviour where TLS required `--tls-cert` / `--tls-key`.

---

## Single-Port vs Multi-Port Trade-offs

| | Single port (this proposal) | acktng multi-port |
|---|---|---|
| Client config | One port, all protocols | Must know which port for which protocol |
| Firewall rules | One rule | Four rules |
| Sniff latency | Up to 1.0s for slow telnet clients (in practice 0ms) | None |
| Protocol isolation | All on one socket | Separate listeners |
| nginx proxy | Not required for WSS | Required for ws:// loopback |

The 1.0s sniff timeout only fires if no bytes arrive within 1 second of connect. In practice:
- TLS clients: `ClientHello` arrives in <5ms
- WebSocket clients: `GET` request arrives in <5ms
- Telnet clients that send immediately: first byte <5ms
- Telnet clients that wait for a prompt: timeout fires at 1.0s, then plain telnet greeting is sent -- identical to current user experience

---

## Out of Scope (follow-on proposals)

- Database-backed `AccountStore` (PostgreSQL via Npgsql/EF Core)
- Game session / MUD world logic
- MSDP/GMCP variable population (needs game world)
- MCCP compression (can be added after basic connection works)
- IPv6 (not currently supported by acktng either)
- Proxy protocol / HAProxy header support

---

## Affected Files / Repos

| Repo | Action |
|---|---|
| `wol/` | All new files under `Wol.Server/` |
| `wol-docs/proposals/` | This document |

No changes to acktng, web, tngdb, or tng-ai.

---

## NuGet Dependencies

| Package | Purpose |
|---|---|
| `BCrypt.Net-Next` | Password hashing |
| (none other) | TLS via `System.Net.Security.SslStream`, WS framing manual, compression via `System.IO.Compression` -- all stdlib |
