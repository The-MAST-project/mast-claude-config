# Dynamic configuration: a live config store, refreshed on change

## Status

| Phase | State |
|---|---|
| 0 — the live store, generation-keyed memoization | **Landed**, `MAST_common` #95 |
| 1 — watcher, `on_change`, degraded mode, boot cache | **Landed**, `MAST_common` #96 |
| 2 — consumers: `control`, `gui`, `spec`, `unit` | Not started |
| 3 — remove the deprecated shims, org-wide grep | Not started |

Nothing in the fleet behaves differently yet: `start_watching()` is opt-in and no service
calls it, so phase 2 is what turns the mechanism on. What phases 0–1 did change is that
`set_unit` now sees its own write, and that an unreachable controller raises `ConfigError`
rather than a bare `ServerSelectionTimeoutError` (MAST_common#82).

Where this document was revised by what implementation turned up, the section says so
inline rather than being quietly corrected — the reasoning that was wrong is usually more
useful than the conclusion that replaced it.

One thing found along the way and fixed separately (`MAST_common` #94): the `planners`
group carries a `canManagePlans` capability that `UserCapabilities` did not list, so
`GroupConfig(**group)` raised on it and took `Config.get_users()`, `get_user()` and the
controller's `/config/users` and `/config/user` endpoints down with it. It had been that
way in production; MAST_gui was unaffected only because it derives that permission from
Django rather than from this enum.

## Context

`Config` reads MongoDB once and never again. `self.db` is assigned at
`common/config/__init__.py:127` and `get_config()` has exactly one caller — that line.
Everything downstream reads that frozen dict, so a DB edit reaches a running service only at
restart.

The two TTL caches are not merely superfluous, they are **inert**:

- `mongo_cache` (60 s) wraps `_load_config_from_mongodb_cached`, reachable only from `__init__`,
  so its TTL never causes a re-read.
- `config_db_cache` (30 s) wraps `config_db()`, whose body is `return self.db` — a timer around
  a live attribute reference.
- `set_unit()` therefore calls `clear_mongo_ttl_cache()` and clears a cache nothing re-reads:
  **a process does not see its own writes.**

Two things already in the tree show the intent was there and the mechanism underneath was
hollow: `MAST_control/control/controller.py:526` runs a 30 s "config refresh" timer whose body
rebuilds `Site` objects from the unchanged dict, and `DECISIONS.md [2026-07-02]` had to ratify
the consequence — *"a DB change takes effect on the next service restart"*. This project
supersedes that entry.

Intended outcome: one in-memory store per process, refreshed within seconds of a DB change, with
a documented degraded mode when MongoDB is unreachable. Closes MAST_common#82.

## Verified against the live system

Run before planning, so the design rests on facts rather than assumptions:

| Question | Answer |
|---|---|
| Is Mongo a replica set? | **Yes** — single-member `rs0`, PRIMARY, MongoDB 6.0.26. Change streams work. |
| Does `db.watch()` work over the production URI? | **Yes**, `mongodb://mast-ns-control.weizmann.ac.il:27017`, resume token returned. |
| Does it work with `directConnection=True`? | **Yes** — topology `Single`, `is_primary` True, token returned. |
| Collection sizes | groups 591 B, services 285 B, sites 1.3 KB, specs 3.5 KB, units 11 KB, users 796 B. **18 KB as a single JSON payload** (measured), after the user pictures were removed from Mongo on 2026-08-31. |
| Is `LocalConfig.data_root` writable on Linux? | **No.** `/var/mast` does not exist and `/var` is not writable by `mast` on `mast-ns-control`. |
| Is the config DB plain-JSON encodable? | **Yes.** Walked every document in all six collections: no BSON `Binary`, and `json.dumps` succeeds on each collection as-is. `_id` is already projected out, so no `ObjectId` either. |

**Do not add `replicaSet=rs0` to the URI.** `rs0`'s sole member advertises itself as the bare
`mast-ns-control:27017`, which per `DECISIONS.md [2026-07-09]` does not resolve off the
controller's subnet. Replica-set discovery would replace the FQDN seed with that name and break
every unit. `directConnection=True` forbids the discovery structurally.

**A change-stream event is a trigger, never data.** Deletes carry only `documentKey._id`, and
this code projects `_id` out of the stored docs, so an event cannot be mapped back to an
in-memory document. Every event causes a **full re-read of the named collection**. This also
dissolves the resume-token problem (below).

## Decisions taken

1. **Scope: `MAST_common` mechanism only.** Consumer conversion (~40 snapshot sites across
   unit/spec/control/gui) follows as separate per-repo PRs. Nothing pins `common` to its
   consumers (MAST_common#34), so every change here must be behaviour-compatible with today's
   call sites.
2. **Degraded startup is allowed, loudly.** Mongo unreachable + valid local cache ⇒ start,
   flag `degraded`, log one ERROR, keep retrying. Both sources failing is still fatal.
3. **Changes take effect immediately for reads**, plus an opt-in `on_change` hook for state that
   a property cannot reach (another process, a device register).
4. **An operation uses the configuration it started with.** Anything depending on config binds
   its values once, at the start of the operation, and is not required to notice changes
   afterwards. See "Operation-scoped stability" below.
5. **`db` and `fetch_config_section` become private.** All access goes through `get_xxx()`.

## Design

Five layers, each testable without the one below:

```text
accessors     get_unit / get_specs / get_sites / get_users   <- generation-memoized
store         immutable ConfigSnapshot, per-collection generations
refresher     watcher thread: change stream -> poll -> degraded
source        ConfigSource protocol; MongoConfigSource is the only prod impl
```

The `ConfigSource` seam is what makes ~90 % of this unit-testable with no Mongo.

### The store

Replace `self.db` with a frozen `ConfigSnapshot` (new `common/config/_snapshot.py`) published by
whole-reference assignment: `collections`, per-collection `generations`, a global `generation`,
`loaded_at`, `degraded`, `source`. Readers take no lock (attribute read is atomic under the GIL);
only the publisher serialises.

`_publish()` installs a re-read collection and returns the set that **actually** differs, using a
plain `docs != old.collections[c]`. No fingerprint — the prior art's
`(estimated_document_count, last _id)` misses in-place edits to an existing doc, which is our
dominant case. Sort by `name` before comparing if `find()` order ever proves unstable.

This is why the mutation fixes below are a **precondition, not hygiene**: today `get_specs()`
writes back into the store and `get_users()` injects `capabilities`, so against a fresh read the
diff would be permanent and every poll would republish forever.

### Watcher

One daemon thread, idempotent lazy start following `common/filer.py:527` `_ensure_sweeper`.
**Explicit opt-in** — `Config().start_watching()` from each service's startup path, not from
`__init__`; a `--help` or a `manage.py collectstatic` should not open a cursor. Honour
`MAST_CONFIG_NO_WATCH`.

Loop: full reload -> open stream -> block. On any exception, go degraded, retry with capped
backoff, and keep re-reading at the poll interval even with no stream. `invalidate` / `drop` /
`rename` return to the outer loop for a fresh full reload.

- **No resume tokens, ever.** pymongo already resumes transparently across blips. The cases it
  cannot cover (`invalidate`, `ChangeStreamHistoryLost`, failover) all want the same action the
  outer loop already takes: drop, full-reload, reopen from now. Because events are triggers,
  a missed event costs latency, not correctness. Persisting a token would buy nothing — we
  full-reload at startup regardless — and adds a stale-token failure mode.
- **No `full_document`.** We ignore it anyway, so it is pure wire cost.
- **Reload per collection**, named by `change["ns"]["coll"]`, one event at a time. At 18 KB
  total this is not about bytes — it is about giving `on_change` an accurate
  changed-collection set, so a `users` edit does not wake a callback registered for `units`.

  *Revised during implementation.* This originally specified a ~0.25 s burst coalesce in the
  watcher, collecting further events with another `try_next()` before reloading. That is
  wrong, and expensively so: `try_next()` blocks for the full idle timeout when no further
  event is waiting, which is the common case — so the coalescing meant to reduce work delayed
  **every** change by that timeout. Measured against `rs0`: 10.03 s to propagate a change the
  server had delivered in 0.02 s. The loop was removed, and nothing was lost — pymongo returns
  already-buffered events without a round trip, a duplicate reload publishes nothing because
  `_publish` compares documents rather than counting events, and the callbacks (the part that
  actually wants coalescing) are merged into one pending change by `_enqueue_change` anyway.
  **Coalescing belongs on the notification side, not in the watcher.**
- **Safety poll** every ~300 s while healthy: a stream can be alive and silently behind, and
  that failure is otherwise indistinguishable from "nobody edited anything".
- **Logging is edge-triggered**: one ERROR entering degraded, one INFO leaving it with the outage
  duration and what changed meanwhile. A weekend outage must not write 100 000 identical lines
  into a `DailyFileHandler`.

### Generation-keyed memoization (replaces both TTL caches)

Delete `mongo_cache`, `config_db_cache`, `_mongo_cache_key`, `config_db()`,
`_load_config_from_mongodb_cached`, `load_config_from_mongodb`.

The derived pydantic models are a pure function of (snapshot collections, call args), so key a
bounded `LRUCache` on the generations of exactly the collections each accessor reads —
`get_unit` -> `("units", "sites")`, `get_users` -> `("users", "groups")`, etc. Time-keyed caching
is simultaneously too eager (rebuilds an unchanged model every 60 s) and too lazy (serves a stale
one for 60 s, including the writer's own). Generation-keyed is always current *and* cheap, which
is what makes the property migration affordable.

Pin the snapshot at entry and thread it into the builder, so a value is provably a function of
its key; build outside the lock (two racing threads produce equal results). LRU rather than a
single slot because `MAST_control/control/controller.py:435` builds every unit's config in a loop.

`get_unit()` does a `socket.gethostbyname` — give DNS its own long TTL cache (1 h). That is the
one legitimate remaining TTL in the module, and it caches DNS, not configuration.

### The mutation fixes

- `fetch_config_section` -> private `_section()` returning a **deep copy**; keep a deprecated
  alias for one release. Its `assert ... section in db` becomes a `ConfigError` naming the
  collection (asserts vanish under `-O`, and an `AssertionError` is not a diagnosis).
- `get_specs()` builds a merged `deepspec` dict instead of writing
  `doc["deepspec"][band] = d` back into the store.
- `get_users()` stops doing `user_dict["capabilities"] = []`. Give `config/identification.py`
  `capabilities: list[...] = []` — it is derived from group membership and has never existed in a
  `users` document; requiring it and then injecting an empty list at every call site was the
  model lying about its contract.
- **Delete `UserConfig.picture`** in the same commit — the same class of fix. It is
  `exclude=True` (never serialised), no code in any of the five repos reads it, and the field is
  now gone from every Mongo document; the GUI already takes avatars from the social provider
  (`MAST_gui/accounts/adapter.py:40-42` -> `user.avatar_url`). Safe even if a stray `picture` key
  reappears: `UserConfig` sets no `extra`, so pydantic v2 ignores unknown keys by default.
- `get_sites()` routes through `_section("sites")` instead of reading `self.db["sites"]` directly
  (`config/__init__.py:378`).

### Operation-scoped stability

**An operation uses the configuration available when it started, and need not be aware of changes
afterwards.** An autofocus run, a slew, an acquisition or an exposure binds what it needs at entry
and reads no further.

This needs **no new machinery**, which is the payoff of the memoization design: a generation-keyed
accessor returns the *identical object* for every call within a generation, so

```python
conf = self.unit.unit_conf          # bound once, at operation entry
```

is already a stable, self-consistent view for as long as the operation holds it. A later
generation replaces what *new* callers get; the running operation keeps the object it has, and
Python's reference semantics do the rest. No copy, no lock, no version pinning, no "which view am
I on" bookkeeping.

Two obligations make it true rather than merely likely, and both are in this plan:

- **Nothing mutates a memoized model.** That is what `update_unit()` (hands the mutator a private
  deep copy) and the static guard exist for. Without them a shared model could change under a
  running operation even with no generation bump.
- **Bind once; do not re-read per step.** `conf = self.unit.unit_conf` at entry, not
  `self.unit.unit_conf.x` inside a loop. This is the one habit the phase-2 consumer PRs must
  apply consistently, and the thing to look for in review.

It also narrows `on_change` usefully: since operations deliberately do not react mid-flight,
callbacks are for out-of-process state only — the controller's `managed_*` maps, PHD2's limit
frame (an RPC), the GUI's broadcast. No hardware component needs one.

### `on_change`

`Config().on_change(cb, collections=(...), name=...) -> unsubscribe`. Delivered on a dedicated
`config-notify` thread — never the caller's, never the watcher's, since a callback that re-applies
a setting to a focuser can block for seconds and would stall the stream behind it.

A **single pending slot, not a queue**: if generations 7-9 land while a slow callback runs, it is
next called once at generation 9 with the union of the collection sets. Coalescing by
construction, no backpressure, no callback storm. One failing callback must not silence the
others; do **not** auto-unregister after N failures (silently disabling an operator-visible
behaviour is worse than a noisy log) — rate-limit the log instead.

Rule of thumb for the later consumer PRs: **if a consumer only reads config, it needs a property,
not a callback.** `on_change` is for state living somewhere a property cannot reach.

### Local JSON cache

Not a return of the backend deleted in `DECISIONS.md [2026-06-21]`. That was a *source* you could
edit; this is a write-only-by-us, read-once-on-failure cache. Three properties keep the
distinction real: written only by the watcher from a successful Mongo read; read only in
`__init__` and only after Mongo has failed; a hand-edit cannot reach any system that can reach
Mongo, because the first successful read overwrites it.

Its purpose is narrow: **a unit whose controller is down must still boot far enough to park the
mount and close the covers.** Today it raises `ConfigError` and exits.

Each copy is a **single self-contained file** holding all six collections — a partial set is worse
than none — with `schema_version`, `mongo_uri`, `database`, `written_at`, `written_by`,
`generation`, `collections`. At 18 KB the whole thing is trivial to write. Atomic write:
temp + `fsync` + `os.replace`, best-effort, never raises.

**Plain `json.dump` is sufficient** — measured, not assumed: every collection encodes as-is, with
no BSON `Binary`, no `ObjectId` (`_id` is projected out) and no `datetime`. An earlier draft
specified a base64 `$binary` round-trip for the user pictures; with those gone that machinery has
no purpose. Keep only a four-line `default=` fallback that logs once and drops the value, as
insurance against a future field — not as a round-trip. (`bson.json_util` stays rejected: it
reintroduces extended-JSON types the pydantic models do not expect.)

**Location and naming.** A directory of timestamped copies with a `latest` pointer:

| Platform | Directory |
|---|---|
| Linux | `~mast/MAST/config-db-cache/` |
| Windows | `C:\MAST\config-db-cache\` |

Add a dedicated `config_cache_dir()` to `config/local.py` returning those two literally. Do
**not** reuse `LocalConfig.data_root`: its Windows branch is already `C:/MAST`, but its Linux
branch is `/var/mast`, which does not exist and is not writable by `mast` on `mast-ns-control`.
(Worth noting separately that `data_root` currently has **zero consumers** — its only occurrence
in all five repos is its own definition — so its broken Linux value has never been exercised.
Fixing or deleting it is adjacent cleanup, not this project.) Explicitly **not** `Filer().local`,
which on Linux is the *share* (`common/filer.py:121`) — one file shared by every Linux host is
exactly wrong for a per-machine boot cache.

**The stamp in the filename must be a UTC timestamp, not the generation counter.** The
`generation` in this design is a per-process, in-memory counter that resets to 0 at every start,
so `config-db-cache-7.json` written by a unit this morning and by the controller this afternoon
would be different content under the same name, and a restart would overwrite its own history.
A timestamp is what makes the name unique and meaningful. Use a filename-safe compact form,
`config-db-cache-20260831T201103Z.json`: `time_stamp()` in `common/utils.py:109` returns
`isoformat_zulu`, whose **colons are illegal in Windows filenames**, so it cannot be reused here.
`common/paths.py:133` already sets the house precedent of dashes for this reason. Record the
process-local `generation` *inside* the file alongside `written_at`/`written_by`, where it is
useful for diagnosis and cannot collide.

**`latest`** is a symlink to the newest file, following the fleet's own precedent
(`MAST_config_db/mast_mongo_monitor.py:214-220`): `unlink()` then `symlink_to(name)`, **with a
copy fallback**, because creating a symlink on Windows needs Developer Mode or
`SeCreateSymbolicLinkPrivilege` and the units run as a service. Narrow the fallback's `except` to
`OSError, NotImplementedError` rather than the bare `except` the prior art uses — per this repo's
own "narrow the blind excepts" rule (`MAST_common` commit `35a4480`).

Because ISO-compact UTC sorts lexicographically as it sorts chronologically, **startup resolves
the newest by filename sort, not by following `latest`**. That is deliberate: on Windows `latest`
is a *copy*, so it cannot tell you which generation it is, and a sort needs no privilege and no
`readlink`. `latest` remains for an operator reading the directory by hand.

Files appear at their final name only via temp + `os.replace` **within the same directory**, so a
newest-by-name pick can never land on a half-written file.

**Retention: the newest 10 copies.** Prune on each successful write, oldest first, by the same
filename sort used to find the newest — so retention needs no separate notion of age. At 18 KB a
copy that is ~180 KB held. Two rules the pruner must follow: never delete the file `latest`
points at (on Windows it is a copy, so it survives pruning on its own, but on Linux a dangling
symlink would be a confusing artefact), and treat a failed unlink as a warning, not an error —
pruning is housekeeping and must not be able to fail a config refresh.

**No maximum age.** A three-week-old cache that lets a unit close its covers beats a fatal
startup. Staleness is reported (`ConfigHealth`), not punished. Reject instead on: unreadable /
bad JSON, wrong `schema_version`, `mongo_uri`/`database` mismatch, missing collection.
`_validate_local_identity()` still runs on the degraded path.

Recovery needs no special path: the watcher's first success publishes the real snapshot,
`_publish` returns exactly what changed while blind, and `on_change` fires with that set.

**`set_unit` must refuse while degraded**, or an autofocus result is written into a snapshot with
nothing behind it and lost. All three callers already wrap it in `try/except`.

### Client and error handling (MAST_common#82)

One `MongoClient`, created once in `ConfigOrigin` under a lock, reused by reads, `set_unit` and
the stream — deleting the leak at `config/__init__.py:184` (a fresh client per cache miss, never
closed, each with its own pool and monitor threads). Set `serverSelectionTimeoutMS=5000`,
`connectTimeoutMS=5000`, `directConnection=True`, and `appname=f"mast-{role}-{host}"` so
`db.currentOp()` can say which of forty processes opened a cursor. **Not** `socketTimeoutMS` —
the awaitData cursor legitimately blocks; bound it with `watch(max_await_time_ms=...)`.

Wrap read-path `PyMongoError` in `ConfigError` once, at the bottom, naming the collection and
address. Startup lets it propagate (fatal, per house rule); the watcher catches it and goes
degraded. One exception type, two policies chosen by the caller — exactly what #82 asks for.

## Phases

**Phase 0 — invisible improvements, no consumer change.** Shared client + timeouts; `ConfigError`
wrapping (#82); delete both TTL caches and the dead load path; `_section` deep-copies;
`get_specs`/`get_users` stop mutating; `get_sites` routes through `_section`;
`UserConfig.capabilities` default; `UserConfig.picture` removed; generation memoization installed
against a snapshot whose generations never move; DNS TTL cache. Consumers see the same API, fewer
bugs, faster calls, no new threads.

*Revised during implementation:* `Config._reset_for_tests` moved here from phase 1. Phase 0 had
no way to build a `Config` without reaching MongoDB, so none of it was testable offline without
it. It is small and test-only, and it also fixes a standing problem — the singleton's
`_initialized` guard leaks the first test's `Config` into the whole session.

**Phase 1 — additive mechanism, off by default.** `ConfigSource` + `MongoConfigSource`; snapshot
publishing; watcher; poll fallback; `degraded` + `ConfigHealth`; local cache; `on_change`;
`start_watching()`/`stop_watching()`. No thread starts unless a consumer opts in.

Two deliberate behaviour changes here, both worth their DECISIONS lines:

- `set_unit` **reloads `units` synchronously after a successful write**, so a process finally sees
  its own writes — and does so even with the watcher off.
- `set_unit` **raises `ConfigError` on write failure** instead of logging. Today all three
  callers log *"saved …"* after a failed write. They already catch exceptions, so this converts
  silent data loss into a reported error.

Also add `update_unit(mutate, ...)` — hands the mutator a private deep copy, persists, reloads —
so the read-modify-write sites in the later `unit` PR cannot mutate the shared memoized model.

**Phase 2 (separate PRs, later projects)** — consumers, in this order: `control` (no hardware,
runs on the Mongo host, validates the mechanism; deletes `config_timer`), `gui` (most
operator-visible payoff), `spec` (15 purely mechanical property conversions), `unit` (largest;
includes the `acquirer.py:512` fix below).

**Phase 3** — delete the deprecated shims; two `DECISIONS.md` entries: *"A DB change takes effect
within seconds, not at the next restart"* (superseding [2026-07-02], recording the
trigger-not-data invariant, the no-resume-token choice and the `directConnection` reasoning) and
*"The local config cache is a boot crutch, not a backend"* (stating its relationship to
[2026-06-21]).

## Execution

Work starts in `MAST_common` on a branch off **`master`** — `gh repo view` reports the default as
`master` and every recent PR merged there (#89, #90, #72). Note that some clones' `origin/HEAD`
symbolic ref points at `refs/remotes/origin/main`, which is stale and would aim a PR at the wrong
base; branch from `master` explicitly.

Branch name follows the house `<type>/<slug>` convention seen in the merge history
(`feat/greateyes-gain-literals`, `fix/observing-night-product-folders`): **`feat/dynamic-config`**.

**Two PRs, not one.** Phase 0 and phase 1 are separately reviewable and phase 0 stands on its own
merits even if phase 1 is deferred:

1. **PR 1 — phase 0.** Invisible improvements: no new threads, no new API, no consumer change.
   Already fixes real bugs (the two inert caches, the per-load `MongoClient` leak, the store
   mutations in `get_specs`/`get_users`, #82's error wrapping) and is safe to merge and let
   propagate to the unpinned consumers immediately.
2. **PR 2 — phase 1.** The mechanism, inert until a consumer calls `start_watching()`. Contains
   the two deliberate behaviour changes, so it deserves its own review and its own `DECISIONS.md`
   entry.

## Files

- `common/config/__init__.py` — the bulk of the work.
- `common/config/_snapshot.py`, `_source.py`, `_watcher.py`, `_cache.py` — new.
- `common/config/identification.py` — `capabilities` default, `picture` removed.
- `common/config/local.py` — `config_cache_dir()` helper.
- `common/tests/test_config_*.py` — new.
- `common/DECISIONS.md` — phase-3 entries.

Reuse rather than rebuild: `RepeatTimer` (`common/utils.py:31`), `common/filer.py:527`'s
idempotent lazy-thread pattern, `common/notifications.py:167`'s singleton + daemon-worker +
never-fatal shape, `deep_dict_update` / `deep_dict_difference` (`common/deep.py`).

## Verification

**Offline** (plain pytest, no Mongo, alongside the existing suite — the whole suite is designed
never to reach Mongo, and `conftest.py` blocks subprocess spawning at import):

- Generations: a `specs` edit bumps `generations["specs"]` and not `["users"]`; republishing
  identical docs bumps nothing.
- Memoization: `get_specs() is get_specs()`; a `specs` edit yields a new object; a `units` edit
  does not rebuild it; two different `get_unit(site, unit)` keys coexist.
- **Mutation regression tests with teeth** — call `get_specs()`, mutate both the returned model
  and `_section("specs")`, then assert the store is byte-identical to what was published. Same
  for `get_users`: assert `capabilities` never appears in the stored docs. These protect the
  poll's change detection, not just tidiness.
- `on_change`: right collections; three publishes during a slow callback deliver once with the
  union; a raising callback does not prevent the next; `collections=("units",)` is not woken by
  a `users` edit.
- Degraded lifecycle via `FakeConfigSource.fail_next()`; recovery reports the collections that
  differed while blind.
- Cache: round-trip through `tmp_path`; rejected on wrong `mongo_uri`, wrong `schema_version`,
  truncated JSON, missing collection — each without raising. Dead source + valid cache =>
  constructs, `degraded`, `source == "local-cache"`. Dead source + no cache => `ConfigError`.
- Cache directory: 12 successive writes leave exactly 10 files; the two deleted are the oldest by
  name; `latest` resolves to (or equals) the newest; startup picks the newest **by filename sort**
  and agrees with `latest`. Force `os.symlink` to raise `OSError` and assert the copy fallback
  leaves a readable `latest` and still loads — this is the Windows path, and CI's Linux half would
  otherwise never exercise it. A stray `config-db-cache-*.json.tmp` is ignored by both the picker
  and the pruner.
- `update_unit` hands over a copy; `set_unit` raises while degraded and on write failure.

**Against live Mongo** (`@pytest.mark.mongo`, deselected by default, run on the controller):

- `updateOne` on `units` reaches a running `Config` within ~5 s and fires `on_change({"units"})`.
- `set_unit` -> the writing process's own `get_unit()` reflects it immediately (today's bug, as a
  test).
- With `supports_watch()` forced False, the poll detects an **in-place update to an existing
  document** — the exact defect in the prior art.
- Stop `mongod` => degraded within `serverSelectionTimeoutMS` + backoff; start it => recovered
  with the right changed set.

End-to-end: run `control` with `start_watching()`, edit a `units` doc in `mongosh`, confirm the
controller's status endpoint shows a bumped generation and the new value without a restart.

## Risks and remaining unknowns

1. **Config changing mid-operation — decided, not open.** Resolved by the operation-scoped
   stability rule above: an operation uses what it started with. The residual risk is one of
   *discipline*, not design — a consumer that re-reads `self.unit.unit_conf.x` inside a loop
   instead of binding once at entry silently opts out of the rule. Cheap to catch in review, and
   the phase-2 PRs are where to look for it.
2. **`directConnection=True` narrows a working configuration.** Verified working, and it
   structurally forbids the [2026-07-09] bare-hostname failure — but if `rs0` ever gains members
   and this one steps down, writes fail loudly instead of being routed. Correct for a deliberate
   single-member RS; re-check if the topology changes.
3. **A stream can be alive and silently behind.** The 300 s safety poll is the only thing that
   catches it.
4. **`start_watching()` opt-in vs auto-start** — opt-in recommended, but it puts the burden on
   four repos to remember the call. Worth one team decision at phase 2.
5. **Anything outside these five repos importing `clear_mongo_ttl_cache` / `fetch_config_section`**
   (scripts, notebooks, `MAST_config_db`) — one org-wide grep before phase 3. The same grep should
   cover `UserConfig.picture`, since removing a model field is only safe in-tree.
6. The GUI's two django-q2 workers would each open a stream if they called `start_watching()`.
   They likely do not need live config; recommend they do not start a watcher.

## Adjacent bug found, worth its own issue

`MAST_unit/src/acquirer.py:512` does `self.unit.unit_conf.acquisition.exposure = seconds` and
never persists it — a per-call parameter smuggled through the config object. It is **already** a
bug: a global side effect on every component reading `acquisition.exposure`. Under a live config
it gets worse — the write either leaks into the shared store or is wiped mid-acquisition by an
unrelated `units` edit. Fix is local (`model_copy(update={"exposure": seconds})`, threaded through
the `conf=` parameter both consumers already take) and belongs in the phase-2 `unit` PR. Distinct
from `unit.py:475`, `autofocusing.py:361` and `imaging/stage_geometry.py:479`, which mutate *and*
persist and are handled by `update_unit`.
