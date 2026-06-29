---
name: Weizmann HTTP proxy — always use for GitHub
description: ALWAYS route GitHub git access through http://bcproxy.weizmann.ac.il:8080 (direct times out); other outbound as fallback
type: feedback
---

Outbound internet from the observatory/Weizmann machines is firewalled. **Direct
access to github.com:443 (git push/fetch/clone) ALWAYS times out** here (~21 s
connect timeout each attempt) — so trying direct first just wastes ~21 s every time.

The Weizmann HTTP proxy is **http://bcproxy.weizmann.ac.il:8080**.

**Why:** Arie's standing instruction (2026-06-29) — **always use `http_proxy` for
GitHub access; do not attempt direct first.**

**How to apply (GitHub git ops):** set the proxy as a per-command env var and run the
git command directly through it — no direct-first attempt:
```
export https_proxy=http://bcproxy.weizmann.ac.il:8080 http_proxy=http://bcproxy.weizmann.ac.il:8080
git push origin main      # (or fetch/clone)
```
Use the env var, **not** `git config http.proxy` (keep it out of repo/git config).

**Other outbound** (curl/web on the box): direct may work; the same proxy is the
reliable fallback if it times out. (Note: the harness's WebSearch/WebFetch run
server-side and are unaffected.)
