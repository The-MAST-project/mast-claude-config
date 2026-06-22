---
name: project_config_file_plan_locked
description: LOCKED implementation plan for the eli/configuration-file task (TOML bootstrap config replacing hard-coded values in common/config/__init__.py)
metadata: 
  node_type: memory
  type: project
  originSessionId: d865c83f-3f1b-45a8-9948-83cb59268f99
---

Locked plan (2026-06-21) for branch `eli/configuration-file` — see [[project_configuration_file_branch]]. **IMPLEMENTED, pushed, and VM-tested 2026-06-21.** Branch tips: MAST_common `69d6bae`, MAST_unit `55646d9` (src/common→69d6bae), MAST_gui `6c770d5`, MAST_control `4f86557`. Validated on VM mast-wis-01 (192.168.56.113) against host Mongo: 7/7 scenarios pass (valid-match, project/location mismatch diffs, site-not-in-DB, missing-field, missing-file, MAST_PROJECT-unset) + lazy initiator + domain cheap-lookup.

TWO FINDINGS FROM VM TESTING (both handled):
1. **BOM fix**: PowerShell `Set-Content -Encoding utf8` writes a UTF-8 BOM that tomllib rejects ("Invalid statement" line 1). `load_local_config` now reads with `utf-8-sig` (commit 69d6bae). See [[project_ps_build_mast_utf8_bom]].
2. **DEPLOYMENT CAVEAT**: the DB `sites` docs must have `location` (lat/lon/elevation) MATCHING the config file, else startup fails the validate-on-startup check. (The match/mismatch is the intended drift guard.) MongoDB is on the host (this machine, localhost:27017; reached from the VM as mast-wis-control->192.168.56.1). As of 2026-06-21: `ns` site location SET to latitude=30.0533026, longitude=35.0386461, elevation=400 (Neot Smadar, the real observatory) — verified via Config validate (only controller_host diff, no location diff). `wis` site STILL has NO location (it's the control/test box, mastw); populate it before deploying a wis config with coords. `ns` controller_host=mast-ns-control (resolves to real 10.23.1.181, not the host), so full ns valid-boot can only be tested at the real deployment.

**1. New `MAST_common/config/local.py`**: `LocalConfig(BaseModel)` with `site, project, controller_host, database, domain, location: Location` (reuse config/site.py:Location), `mongo_port: int = 27017`; props `mongo_uri`, `data_root`. `ConfigError(Exception)` with detailed reason. `load_local_config()`: role from `MAST_PROJECT` env (unit|spec|control); path = `$MAST_CONFIG` else Windows `C:\WIS\<role>.toml` / *nix `/etc/wis/<role>.toml`; parse with `tomllib`; missing file/bad role/ValidationError -> ConfigError.

**2. Gut `config/__init__.py`**: constructor -> `__init__(self)` (drop site, load_from). Build ConfigOrigin from `self.local`. **Mongo-only** (drop entire file backend: `_load_config_from_file_cached`, `load_config_from_file`, file branches of get_config & set_unit, file_cache, clear_file_ttl_cache, load_from/DataSource). `DEFAULT_COLLECTIONS` constant. Delete hostname site-parsing block + `NUMBER_OF_UNITS` + hard-coded mongo_uri/db. `local_site` -> match `s.name == self.local.site`. get_unit/set_unit local default site = `self.local.site` (keep site_name_from_unit_name for explicit unit_name = DB lookup). Delete `config_toml.py`.

**3. Validate-on-startup (conscious duplication, no drift)**: config file is authoritative for local identity but the same project/controller_host/location ALSO live in the DB `sites` doc by design. After Mongo load, find DB site by `name==local.site` (else ConfigError) and compare project/controller_host/location; on mismatch raise ConfigError with the exact field diff.

**4. Remove `Site.local`**: drop `local: bool` from Site model; route `parsers.py:36` + `MAST_gui/MAST_gui/context_processors.py:58` to `Config().local_site`. (Pydantic ignores leftover DB field; no migration.)

**5. `notifications.py` lazy initiator**: delete import-time hostname-parsing block (lines ~31-71); build `initiator` LAZILY (first use) from `Config().local.site/.project` + `MAST_PROJECT` role->type + `gethostname()`->hostname.

**6. Fail-fast `MAST_unit/src/app.py`**: wrap first `Config()` (line ~181, before uvicorn.run) in try/except ConfigError -> log detailed reason -> `app_quit()` (also kills the PWI4 child) -> `sys.exit(1)`. Graceful; server never starts. control/spec/gui need same guard (follow-up; not checked out for this branch's work but clones exist on Desktop).

**Rule confirmed by user: site is NEVER derived from hostname anywhere — always the config file.** Hostname stays only for machine self-identity (which unit am I, FITS INSTRUME, file paths).

**7. Domain -> config file, single source** (user directive): add `domain: str` to LocalConfig. DELETE `Const.WEIZMANN_DOMAIN` (const.py:6), `networking.py:12` WEIZMANN_DOMAIN, AND the `Site.domain` model field. Route all consumers to `Config().local.domain`: api.py:177,458; config/__init__.py:384; dlipowerswitch.py:38,358; assignments.py:33,52,117; plans.py:304; networking.py:48,49. Domain is config-ONLY (NOT in the validate-against-DB set). KNOWN CONSEQUENCE: api.py:458 / assignments.py:117 build FQDNs for possibly-remote sites, so this bakes in a single-domain assumption (fine today: all weizmann.ac.il; multi-domain would need domain back per-site).

**8. Remove NUMBER_OF_UNITS** from config/__init__.py (only a doc-comment ref in MAST_control/controller.py:361; control should later derive count from local_site.unit_ids).

**9. Remove seeds** (nothing imports them): delete `MAST_common/mongo_seeds/` (makepic.py + 2024-06-13/) and `MAST_common/config/backup/` (mast-config-db.json 570KB + mast-config.py, tied to deleted file backend / old load_from API).

Housekeeping: sample `C:\WIS\unit.toml`; DECISIONS.md entries both repos (incl. domain single-source + single-domain assumption); bump unit's common gitlink after MAST_common pushed.
