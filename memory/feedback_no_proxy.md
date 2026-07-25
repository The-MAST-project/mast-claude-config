---
name: Use no_proxy for internal MAST machines
description: Bypass the proxy for internal fleet hosts; external URLs still go through it
type: feedback
---

Use `no_proxy` only for **internal** machines. External URLs (e.g. grafana.com) require the proxy.

**Why:** A proxy (`http://bcproxy.weizmann.ac.il:8080`) is configured in the environment; internal MAST hostnames/IPs are not routed through it, but external sites are.

**How to apply:**
- Internal fleet hosts (mastw, mast00/mast02, mast-ns-control, mast-ns-spec, `10.23.x`, localhost, etc.): `no_proxy="*" curl ...` or `curl --noproxy "*" ...`
- External URLs (grafana.com, github.com, etc.): plain `curl ...` (let the proxy handle it)

Complement of [[feedback_weizmann_proxy]] (when to USE the proxy). Machine list: [[reference_fleet_topology]].
