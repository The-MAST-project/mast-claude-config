---
name: project_ntp_priority_list_plan
description: "Stashed plan to make the timesync provider configure units with an ordered NTP priority list (RPI@Naot Smadar, Weizmann internal, prov server, Windows default) - awaiting RPI + Weizmann IPs/hostnames"
metadata: 
  node_type: memory
  type: project
  originSessionId: 1605315a-29c4-4596-b265-2d7521c0ec67
---

Planned (not yet implemented as of 2026-06-16) enhancement to NTP provisioning: configure unit machines with an ordered time-server priority list.

**Priority order:** 1. RPI time server @ Naot Smadar  2. Weizmann internal NTP  3. provisioning server (auto-discovered)  4. `time.windows.com` (Windows default).

**Decisions settled with user:**
- Ongoing/steady-state config = ALL FOUR peers in `manualpeerlist`, w32time auto-selects best + fails over (NOT strict ordered failover - w32time picks by stratum/dispersion, so order is advisory only for steady state).
- Prov server stays PERMANENTLY in the ongoing list at #3 (this REVERSES the prior design where prov server was one-time-only; needs a new DECISIONS.md entry).
- One-time provisioning correction = probe peers in strict priority order, first that locks wins.

**Files to touch:**
- `server/providers/timesync/provide-timesync.ps1` - replace single `NormalNtp` param with `RpiNtp`/`WeizmannNtp`/`ProvServer`/`WindowsNtp`; build `${ordered}` list skipping blanks; probe in order for one-time fix; leave all four space-joined as ongoing `manualpeerlist`. Rewrite header comment (prov server now permanent #3).
- `server/providers/timesync/module.json` - description text only.
- `client/bootstrap-winrm.ps1` - `Sync-MastSystemTime` default list (line ~366) add RPI + Weizmann to match (DRY).
- `DECISIONS.md` - new entry.

**BLOCKED on user providing:** RPI @ Naot Smadar IP/host, and Weizmann internal NTP IP/host.

Related: current one-time-correction design in [[project_proxy_cert_revocation]] context (wrong clock breaks TLS git clone). ASCII-only scripts per MAST_provisioning CLAUDE.md.
