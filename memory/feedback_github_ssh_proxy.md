---
name: GitHub over SSH — tunnel through the Weizmann proxy
description: Use SSH keys (not PATs) for GitHub git ops; tunnel SSH over port 443 through bcproxy via a ProxyCommand in ~/.ssh/config
type: feedback
---

Outbound **port 22 is blocked** on the observatory/Weizmann machines, so plain
`git@github.com` SSH times out. This is the SSH counterpart to the HTTPS proxy rule
(see *Weizmann HTTP proxy*). The fix is to tunnel SSH over the HTTPS port (443) to
GitHub's `ssh.github.com` endpoint, through the HTTP CONNECT proxy.

**Why:** it lets each machine authenticate to GitHub with an **SSH key instead of a
Personal Access Token**. PATs kept ending up embedded in plaintext repo remote URLs
(`https://ghp_…@github.com/…`), which is a recurring credential-leak hazard and can't
be rotated when one token is shared across projects. With SSH set up, remotes become
`git@github.com:OWNER/REPO.git` and **no token lives on disk** (and the HTTPS
`http_proxy` env-var dance is no longer needed for these repos — the tunnel is baked
into ssh config).

**How to apply (per machine):**

1. Add to `~/.ssh/config`:
   ```
   Host github.com
       HostName ssh.github.com
       Port 443
       User git
       IdentityFile ~/.ssh/mast          # this machine's key
       IdentitiesOnly yes
       ProxyCommand nc -X connect -x bcproxy.weizmann.ac.il:8080 %h %p
       ServerAliveInterval 30
       ServerAliveCountMax 3
   ```
2. Register that machine's **public** key on GitHub (Settings → SSH and GPG keys).
   Prefer a **separate key per machine** so one can be revoked independently.
3. Verify: `ssh -T git@github.com` → "Hi <user>!".
4. Point repo remotes at SSH: `git remote set-url origin git@github.com:OWNER/REPO.git`
   (do this for submodule remotes too — incl. the cached `submodule.<name>.url` in the
   superproject's `.git/config`).

`nc` (OpenBSD netcat) provides the HTTP-CONNECT tunnel via `-X connect -x host:port`.
`gh` CLI still needs a token in its keyring for API calls (SSH can't do the API) —
that's encrypted, not plaintext, so it's acceptable. Related: *Weizmann HTTP proxy*
(HTTPS transport), *SSH key auth on Windows*.
