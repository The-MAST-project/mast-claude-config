---
name: Weizmann HTTP proxy (fallback for outbound access)
description: Use http://bcproxy.weizmann.ac.il:8080 for git/curl/web only after direct (non-proxied) access fails
type: feedback
---

Outbound internet from the observatory/Weizmann machines is often firewalled — direct
access to github.com:443 (git push/fetch, `curl`) times out (~connect timeout, no proxy
in env or git config by default).

The Weizmann HTTP proxy is **http://bcproxy.weizmann.ac.il:8080**.

**Why:** keep the proxy as a *fallback*, not a default — direct access is preferred when it
works; Arie does not want it persisted into git config.

**How to apply:** try the command directly first. If it fails with a connection timeout,
retry with the proxy as a per-command env var (do NOT `git config` it):
`export https_proxy=http://bcproxy.weizmann.ac.il:8080 http_proxy=http://bcproxy.weizmann.ac.il:8080`
then re-run the `git push` / `curl` / fetch. Verified 2026-06-23: direct curl to github
timed out; via the proxy returned 200 and `git push` to the mast-claude-config repo succeeded.
