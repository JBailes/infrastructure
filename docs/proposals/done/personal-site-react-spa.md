# Proposal: Personal Site Redesign -- React SPA with Independent Template

## Problem

The current `bailes.us` personal site is a four-line HTML fragment rendered inside the shared ACKmud `base.html` template by the Python server. It has the wrong aesthetic (dark blue ACKmud look) and no meaningful content structure. The user wants a modern React SPA with an entirely independent design.

## Approach

### Build toolchain

Use **Vite + React + TypeScript** in `web/personal/`. Vite is the standard modern choice: fast HMR, minimal config, produces a production-optimised static bundle.

```
web/personal/
  src/
    App.tsx
    main.tsx
    index.css
  index.html        (Vite entry point)
  vite.config.ts
  tsconfig.json
  package.json
  dist/             (build output, gitignored)
```

### Serving strategy -- nginx serves static files directly

Rather than proxying bailes.us through the Python server (which was designed for server-side template rendering), nginx will serve the built `dist/` directly as a static site. This is the standard pattern for SPAs.

**nginx change for bailes.us:**
```nginx
server {
    listen 443 ssl;
    server_name bailes.us www.bailes.us;

    ssl_certificate     /etc/letsencrypt/live/bailes.us/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/bailes.us/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    root /path/to/web/personal/dist;
    index index.html;

    # SPA fallback: all routes serve index.html
    location / {
        try_files $uri $uri/ /index.html;
    }
}
```

The Python server (`web_who_server.py`) loses the `personal` site handler and `bailes.us` logic -- it no longer handles that domain at all.

### Design -- professional dark

A clean, modern dark professional design. No connection to the ACKmud aesthetic.

Color palette:
- Background: deep slate (`#070b14`)
- Surface: dark navy (`#0f1623`)
- Card: `#162032`
- Accent: electric blue (`#4f8ef7`)
- Accent bright: `#7eb3ff`
- Text: clean off-white (`#e8f0ff`)
- Muted: slate blue (`#7a8fb5`)

Typography: **Inter** throughout (clean, modern, widely used for professional sites). Large weight contrast between heading and body.

Content (single-page, vertically centred):
- Name: Jared Bailes
- GitHub link: https://github.com/JBailes
- LinkedIn link: https://www.linkedin.com/in/jaredbailes/

Subtle radial gradient glow behind the card for depth.

### Deployment note

On the production server, after building:
```
cd web/personal && npm run build
```
The `dist/` path must match what's in the nginx `root` directive. The Makefile should be updated with a `build-personal` target.

### Removed from Python server

- `_get_site()` no longer checks for `bailes.us` / `www.bailes.us`
- `_handle_personal_route()` removed
- `_build_personal_home_page()` removed
- `PERSONAL_TEMPLATE_DIR` constant removed
- `_PERSONAL_TAGLINE`, `_PERSONAL_NAV` constants removed
- `personal/templates/home.html` deleted (replaced by React app)
- Personal site tests in `test_integration.py` removed (the Python server no longer handles bailes.us)

## Affected Files

| File | Change |
|------|--------|
| `web/personal/` | Replace `templates/home.html` with full Vite+React project |
| `web/web_who_server.py` | Remove personal site handler, constants, and routing |
| `web/nginx/ackmud.conf` | Change bailes.us from proxy to static file serving |
| `web/test_integration.py` | Remove personal site tests (server no longer handles it) |
| `web/Makefile` | Add `build-personal` target |

## Trade-offs

- **Static vs. dynamic**: Losing the Python proxy for bailes.us is a strict improvement -- nginx static file serving is faster and simpler for a pure SPA.
- **Build step required**: Unlike the template-based sites, the personal site needs `npm run build` before changes are visible in production. This is standard for any React project.
- **No shared styles**: The personal site is fully independent. If the ACKmud base styles ever improve (fonts, layout), those changes won't carry over -- this is intentional.
- **Node.js dependency**: The build machine (and CI if any) needs Node.js. The production server does NOT need Node -- it only serves the pre-built `dist/`.
