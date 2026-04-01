# Proposal: Rewrite WOL and AHA Sites as Blazor WebAssembly SPAs

## Problem

The WOL (`ackmud.com`) and AHA (`aha.ackmud.com`) sites are currently served by a Python stdlib HTTP server that renders templates. The user wants both sites rebuilt as Blazor (C#) SPAs, and stories moved from AHA to WOL.

## Scope

1. Move the stories section from AHA to WOL
2. Replace `wol/templates/` and `aha/templates/` with Blazor WASM projects
3. Replace the Python server's WOL and AHA logic entirely -- `web_who_server.py` is removed
4. Update nginx to serve the WASM static bundles and proxy API calls to a .NET backend

## Architecture

### Blazor WebAssembly + ASP.NET Core Hosted

A true Blazor WASM SPA runs entirely in the browser. However, AHA has server-side concerns:
- `/acktng/who` -- proxies live player list from the game server
- `/acktng/gsgp` -- proxies game stats JSON from the game server
- `/acktng/reference/` -- reads help/shelp/lore files from the filesystem

These require a backend API. We use the **ASP.NET Core Hosted** Blazor template: a single .NET solution that builds both a Blazor WASM client and a minimal ASP.NET Core backend in one project. The backend is what nginx proxies to; it hosts the WASM app and exposes the dynamic API endpoints.

### Project structure

```
web/
  AckWeb.sln
  AckWeb.Server/          # ASP.NET Core backend (hosts both sites' APIs + WASM)
    Program.cs
    Controllers/
      WhoController.cs    # GET /api/who    → proxy to game server
      GsgpController.cs   # GET /api/gsgp   → proxy to game server
      ReferenceController.cs  # GET /api/reference/{type}/{topic}
    AckWeb.Server.csproj
  AckWeb.Client.Aha/      # Blazor WASM project for AHA site
    Pages/
      Home.razor
      Acktng.razor
      Who.razor
      MudClient.razor
      WorldMap.razor
      Reference.razor
    Shared/
      NavMenu.razor
      Layout.razor
    wwwroot/
    AckWeb.Client.Aha.csproj
  AckWeb.Client.Wol/      # Blazor WASM project for WOL site
    Pages/
      Home.razor
      Stories.razor       # Moved here from AHA
    Shared/
      NavMenu.razor
      Layout.razor
    wwwroot/
    AckWeb.Client.Wol.csproj
  personal/               # React SPA (unchanged)
  nginx/ackmud.conf       # Updated
```

The solution lives directly in `web/` (replacing the old flat Python layout).

### Why one server for both clients

Both WASM apps are different bundles but served by the same ASP.NET Core backend. The backend inspects the `Host` header (same as the Python server does today) to decide which client's `wwwroot/index.html` to serve for unknown routes. Static assets for each client live under distinct paths (`/_aha/` and `/_wol/`) to avoid collisions.

### nginx changes

Both sites currently proxy to the Python server. Under the new model:

```nginx
# AHA and WOL both proxy to the .NET backend
server {
    listen 443 ssl;
    server_name ackmud.com www.ackmud.com;
    # proxy to .NET on port 5000
    location / { proxy_pass http://127.0.0.1:5000; ... }
}

server {
    listen 443 ssl;
    server_name aha.ackmud.com;
    location / { proxy_pass http://127.0.0.1:5000; ... }
}
```

The Python server (`web_who_server.py`) and its systemd service are removed. The .NET app replaces it.

### Stories move (WOL)

The story HTML fragments in `aha/templates/stories/` become `.razor` component files under `AckWeb.Client.Wol/Pages/Stories/`. The WOL nav gains a Stories link. AHA loses its stories route.

### Reference data (AHA)

The help/shelp/lore files are currently read from the filesystem at runtime by the Python server. The .NET `ReferenceController` does the same: reads files from `ACKTNG_DIR` on the server and returns their content via API. The Blazor client fetches `/api/reference/{type}/{topic}` via `HttpClient`.

### MUD client (AHA)

The WebSocket MUD client is pure JavaScript embedded in a Blazor `IJSRuntime`-backed component. The existing `mud_client.html` template's JS logic is extracted into a `wwwroot/js/mud-client.js` file called via JS interop.

### Styling

Each client (`Aha`, `Wol`) gets its own `app.css` in `wwwroot/css/`. The shared `base.html` Python template is gone; each Blazor app has its own `MainLayout.razor`. The existing color palette and CSS from the Python `base.html` template is ported to each app's CSS.

## Files Removed

| File/Dir | Reason |
|----------|--------|
| `web_who_server.py` | Replaced by .NET backend |
| `test_integration.py` | Python server tests obsolete; .NET has xUnit tests |
| `aha/templates/` | Replaced by Blazor project |
| `wol/templates/` | Replaced by Blazor project |
| `templates/base.html` | Replaced by Blazor layouts |
| `systemd/web-server.service` | Replaced with .NET systemd service |

## Files Added

| File/Dir | Content |
|----------|---------|
| `AckWeb.sln` | Solution file |
| `AckWeb.Server/` | ASP.NET Core backend + API controllers |
| `AckWeb.Client.Aha/` | Blazor WASM for aha.ackmud.com |
| `AckWeb.Client.Wol/` | Blazor WASM for ackmud.com (includes Stories) |
| `systemd/ackweb.service` | systemd unit for the .NET app |

## Trade-offs

- **Build dependency**: .NET SDK required on the build machine (similar to Node for the personal site). The production server only runs the pre-built binary.
- **Single backend vs. two**: Running one .NET process for both sites is simpler operationally than two. The host-header dispatch is minimal added complexity.
- **MUD client JS interop**: The WebSocket-heavy MUD client is best kept in JavaScript, called from Blazor via `IJSRuntime`. It's not realistic to rewrite the WebSocket terminal in pure Blazor.
- **Reference file API**: Help/shelp/lore files are still read from the filesystem on the server at runtime, same as today -- no behaviour change, just a different language.
- **Python server removal**: `web_who_server.py` and `test_integration.py` are deleted. Testing moves to xUnit inside the .NET solution.

## Out of Scope

- Rewriting the MUD client's WebSocket logic in C# (JS interop is sufficient)
- World map: ported as-is (static HTML in a Blazor component)
- The `personal/` React SPA is untouched
