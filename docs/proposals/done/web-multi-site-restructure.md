# Proposal: Web Multi-Site Restructure (aha / wol / personal)

## Problem

The `web/` project currently serves two virtual hosts from a single flat layout:
- `ackmud.com` → WOL landing page
- `aha.ackmud.com` → ACKmud Historical Archive

We need to:
1. Add a third site (`bailes.us`) as a personal landing page
2. Reorganize the code into per-site subfolders for clarity and future independence
3. Update nginx to route `bailes.us` to the Python server

## Approach

### Directory restructure

Create three site subdirectories under `web/`:

```
web/
  aha/
    templates/          # AHA-specific templates (moved from web/templates/)
      home.html         # was templates/home.html
      acktng.html
      stories.html
      stories/
      mud_client.html
      world_map.html
  wol/
    templates/
      home.html         # was templates/home_wol.html
  personal/
    templates/
      home.html         # new simple landing page
  templates/
    base.html           # stays shared (used by all three sites)
  img/                  # stays shared
  mp3/                  # stays shared
  web_who_server.py
```

The shared `base.html` remains in `web/templates/` since all three sites use the same styling for now. When the personal site needs its own look, its template dir can be given its own `base.html` and the loader can be made site-aware.

### Server changes (`web_who_server.py`)

1. **`_get_site()`** -- extend to return `"personal"` for `bailes.us`:
   ```python
   host = (headers.get("Host", "") or "").lower().split(":")[0]
   if host.startswith("aha."):
       return "aha"
   if host in ("bailes.us", "www.bailes.us"):
       return "personal"
   return "wol"
   ```

2. **Template directories** -- add per-site dirs alongside the existing `TEMPLATE_DIR`:
   ```python
   AHA_TEMPLATE_DIR   = WEB_DIR / "aha"      / "templates"
   WOL_TEMPLATE_DIR   = WEB_DIR / "wol"      / "templates"
   PERSONAL_TEMPLATE_DIR = WEB_DIR / "personal" / "templates"
   ```
   Update `_load_template()` to accept a directory argument (or site tag) so each site loads from its own folder, falling back to `web/templates/` for shared templates like `base.html`.

3. **`_handle_personal_route()`** -- new handler serving just `/`:
   ```python
   def _handle_personal_route(self, route: str) -> None:
       if route in ("/",):
           self._send_html(_build_personal_home_page(), title="Josh Bailes", site="personal")
           return
       self.send_error(404, "Not Found")
   ```

4. **`do_GET()`** -- add the `personal` branch.

5. **`_build_full_page()`** -- add `personal` site constants (tagline, nav).

### New landing pages

- `web/wol/templates/home.html` -- content unchanged from current `templates/home_wol.html`
- `web/personal/templates/home.html` -- simple placeholder: name, brief bio blurb, links (LinkedIn, GitHub, or whatever is appropriate). Plain content; no game-specific sections.

### nginx changes (`web/nginx/ackmud.conf`)

Add HTTP redirect and HTTPS proxy blocks for `bailes.us`:

```nginx
# HTTP: redirect + ACME challenge (add bailes.us to existing block)
server {
    listen 80;
    server_name ackmud.com www.ackmud.com aha.ackmud.com bailes.us www.bailes.us;
    ...
}

# HTTPS: personal site (bailes.us)
server {
    listen 443 ssl;
    server_name bailes.us www.bailes.us;

    ssl_certificate     /etc/letsencrypt/live/bailes.us/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/bailes.us/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    location / {
        proxy_pass              http://127.0.0.1:8080;
        proxy_set_header        Host              $host;
        proxy_set_header        X-Real-IP         $remote_addr;
        proxy_set_header        X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header        X-Forwarded-Proto $scheme;
    }
}
```

`bailes.us` is a different domain and needs its own SSL cert (cannot share with `ackmud.com`). A note will be added to the nginx file:
```
# certbot certonly --webroot --webroot-path /var/www/certbot -d bailes.us -d www.bailes.us
```

### Test changes (`test_integration.py`)

- Add `_get_personal()` helper (sends `Host: bailes.us`)
- Add tests: `test_personal_home_200`, `test_personal_unknown_route_404`
- Add a test confirming `bailes.us /` is NOT served for `ackmud.com` host

## Affected Files

| File | Change |
|------|--------|
| `web/web_who_server.py` | Extend `_get_site()`, add personal handler, per-site template dirs |
| `web/nginx/ackmud.conf` | Add `bailes.us` HTTP + HTTPS blocks |
| `web/templates/home_wol.html` | Move to `web/wol/templates/home.html` |
| `web/templates/home.html` | Move to `web/aha/templates/home.html` |
| `web/templates/acktng.html` | Move to `web/aha/templates/acktng.html` |
| `web/templates/stories.html` | Move to `web/aha/templates/stories.html` |
| `web/templates/stories/` | Move to `web/aha/templates/stories/` |
| `web/templates/mud_client.html` | Move to `web/aha/templates/mud_client.html` |
| `web/templates/world_map.html` | Move to `web/aha/templates/world_map.html` |
| `web/templates/base.html` | Stays in place (shared) |
| `web/personal/templates/home.html` | New |
| `web/test_integration.py` | Add personal site tests |

## Trade-offs

- **Shared `base.html`**: All three sites share the same base template and styling for now. This keeps things DRY but means the personal site has the ACKmud aesthetic. This is a known temporary state -- when the personal site needs its own look, it gets its own `base.html` in `web/personal/templates/`.
- **Template loader**: `_load_template()` currently takes just a filename. It needs to become site-aware. The cleanest approach is adding a `template_dir` parameter rather than a global, which keeps the caching logic intact.
- **Personal site content**: The proposal leaves the landing page content open -- just a placeholder for now. You should decide what goes on it before I write the HTML.
- **SSL for `bailes.us`**: Requires a separate certbot run on the production server. Not part of the code change, but documented in the nginx file.

## Out of Scope

- Actual content of the personal landing page (TBD)
- Any new pages under `/wol` beyond the existing home page
- DNS configuration for `bailes.us` pointing to the web server
