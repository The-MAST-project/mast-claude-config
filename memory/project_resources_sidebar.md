---
name: Resources sidebar & nginx setup
description: How the Resources sidebar link, Grafana iframe, and nginx config are wired together
type: project
---

The "Resources" entry in the sidebar opens a Django page that embeds Grafana in an iframe.

**Flow:**
- Sidebar link → Django view `grafana` → renders `templates/grafana.html`
- `grafana.html` has `<iframe src="/grafana/dashboards/">` (full-page iframe)
- nginx `/grafana/` location proxies to `localhost:3000/grafana/` (local Grafana, sub-pathed at `/grafana/`)

**nginx config** (`/etc/nginx/conf.d/mast-wis-control.conf`) — working block:
```nginx
location /grafana/ {
    proxy_pass http://localhost:3000/grafana/;
    proxy_set_header Host $proxy_hostname;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_hide_header X-Frame-Options;
    proxy_redirect / /grafana/;
}
```

**Why `proxy_hide_header X-Frame-Options`:** Grafana sends `X-Frame-Options: deny` by default, blocking iframe embedding. Stripping it at nginx avoids needing `allow_embedding = true` in grafana.ini.

**Why `proxy_redirect / /grafana/`:** After login, Grafana redirects to `/dashboards/` (sub-path stripped in `redirectTo`). Without this, nginx catch-all fires and sends the browser to `/mast-dash/` (Django, also frame-blocked). `proxy_redirect` rewrites `Location: /dashboards/` → `Location: /grafana/dashboards/` so the iframe stays within the `/grafana/` proxy.

**Note:** There is also a legacy `/resources/` nginx block pointing to `localhost:3000/grafana/dashboards/` — it is unused now that the iframe src was changed to `/grafana/dashboards/`.
