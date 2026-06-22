---
name: proxy-cert-revocation
description: "Behind bcproxy, Windows CryptoAPI cert-revocation retrieval (cryptnet) fails (0x80070057) so WinINet installers (cygwin setup.exe, Chrome stub) hard-fail TLS with 12057; git is unaffected. Fix = WPAD off + best-effort revocation."
metadata: 
  node_type: memory
  type: project
  originSessionId: fe8833d2-b3ef-4810-a6a4-90a94adf1586
---

On-campus `--proxy-mode weizmann` runs through `bcproxy.weizmann.ac.il:8080`:
git/curl/.NET reach the internet fine (and the CRL `http://r12.c.lencr.org/...`
returns 200 via the proxy), but **Windows CryptoAPI revocation retrieval
(`cryptnet`) fails with `0x80070057 ERROR_INVALID_PARAMETER` ->
`CRYPT_E_REVOCATION_OFFLINE`** for the CRL/AIA fetch. It fails machine-wide:
under the WinRM logon, as SYSTEM, WinHTTP=proxy or =direct, with/without bypass
list. Confirmed via `certutil -f -urlfetch -verify <leaf.cer>`.

**Effect:** WinINet installers that enforce server-cert revocation -- cygwin
`setup-x86_64.exe` and Chrome's online stub -- hard-fail the TLS handshake with
WinINet error **12057** (cascades `astrometry-dependencies` -> `astrometry`,
and breaks `chrome`). git is unaffected because Git-for-Windows does revocation
best-effort. Root cause of the `cryptnet`<->bcproxy `0x80070057` itself is
unresolved (a cryptnet/forward-proxy incompatibility).

**Two-part fix (2026-05-27, see DECISIONS.md):**
1. `provide-proxy.ps1` now writes `DefaultConnectionSettings` to clear the WPAD
   auto-detect bit (`0x08`) / PAC (`0x04`) -- the legacy `ProxyEnable`/`ProxyServer`
   values it set before are NOT authoritative; WinINet reads the flags byte.
   Necessary hardening but NOT sufficient on its own.
2. New shared lib `server/lib/mast-net.ps1` (`Disable-/Restore-WinINetCertRevocationCheck`,
   toggles HKCU `Internet Settings\CertificateRevocation`). `provide-astrometry-dependencies.ps1`
   and `provide-chrome.ps1` set revocation best-effort around their installer
   only, then restore. Staged by build-mast like mast-log.ps1.

**Validated:** real `setup-x86_64.exe` install through bcproxy completed (all
cygwin DLLs present, zero 12057) once `CertificateRevocation=0` was set.

**How to apply:** Don't try to make `cryptnet` fetch revocation through bcproxy
(unsolved); don't remove the internet dependency (git needs it -- reliable
internet inside AND outside the proxy is non-negotiable). For any NEW
WinINet-based online installer behind the proxy, reuse `mast-net.ps1`'s
disable/restore toggle. The dev VM's multi-homing (host-only + NAT) is a
dev-only artifact; see [[mast-provisioning-upstream]], [[proxy-mode-explicit]].
