# MAST cross-reference documentation site

> Status: **plan only — not implemented.** Origin: a build plan mailed round on
> 2026-08-10, expanded here with the hardware-stubbing work the endpoint half
> actually requires.

## Goal

One browsable site for the whole fleet that lets you jump to a definition and back,
indexes classes and where they are used across every repo, documents the FastAPI HTTP
endpoints, and carries UML-style diagrams. Rebuilt automatically in CI and published to
GitHub Pages.

The value is specifically **cross-repo**. Per-repo docs would be easy and would miss the
thing that is hard to hold in your head: a class defined in `MAST_common` and used in
`unit`, `spec`, `control` and `gui` at once.

## A dedicated repo

Create **`MAST_docs`**, whose only job is to run the combined build and publish it. It
holds no fleet code.

Its CI checks out all five code repos **plus `MAST_common`, arranged as a sibling
`common/` directory**, so `from common.X import Y` resolves exactly as it does on a dev
workstation and on the units:

```
<workspace>/
  common/     <- MAST_common; its repo root IS the `common` package
  unit/
  spec/
  control/
  gui/
```

This is the load-bearing step. Without it, every cross-reference into `MAST_common`
breaks at precisely the boundary the site exists to illuminate. `MAST_unit`'s CI already
does this two-checkout arrangement (`MAST_unit#103`) and can be copied.

Note the layout is not uniform across the fleet: `MAST_unit` consumes `common` as a
sibling clone, while `control`, `spec` and `gui` still submodule it at `./common/`. The
docs build should impose the sibling layout on all of them rather than initialise
submodules, so one arrangement produces one cross-referenced tree.

## Code documentation and navigation

- **Sphinx** as the framework, with **`sphinx-autoapi`** for the code.
- `autoapi` walks the source **statically — it never imports**, so missing hardware
  libraries and absent live config cannot break it. This is why the code half of the site
  is cheap and the endpoint half is not.
- Gives class and function indexes automatically, plus hyperlinked source for
  jump-to-definition and click-through cross-references.
- Run over the *combined* tree so a class defined in `MAST_common` shows every usage in
  `spec`, `control` and `gui`.

## Search — and what it is not

Sphinx's built-in search is a client-side full-text index over class, function and module
names plus docstring text.

It is **not** code-aware "find every call site". Use search to locate a symbol, then
follow the cross-references to trace usage. Worth stating plainly in the site's landing
page so nobody concludes the index is lying to them.

## API endpoint reference

- Each FastAPI app emits its own OpenAPI spec from the code and type hints.
- **`sphinxcontrib-openapi`** renders those into an interactive endpoint reference —
  routes, methods, request and response schemas.
- Render a combined index so every route across the fleet is on one page. Given the
  endpoint-contract work (`MAST_unit#42`, `#47`), a single view of what the fleet exposes
  is worth having on its own.

**The catch:** generating a spec requires briefly **importing** each app. Unlike
`autoapi`, this puts the docs build on the same footing as running the service. That is
the whole of the difficulty, and the next section is about it.

## Making the apps importable

This is the real work, and it is deliberately deferred to implementation. Two distinct
problems, often conflated:

### 1. Module-level side effects

`MAST_unit/src/app.py` calls `ensure_process_is_running` at **module scope** — its
`if __name__ == "__main__"` is far below — so importing it launches PWI4, PWShutter and
ps3cli. This is not theoretical: it happened on `mast00`, a live unit, during a lint
clean-up on 2026-08-09.

An app that starts processes on import cannot be imported by a docs build, a test, or
anything else. The fix is to move those calls into a function called from `__main__` and
from the service entry point. Until then, no endpoint docs.

### 2. Hardware bindings

Even with side effects removed, importing an app pulls in modules bound to hardware. The
inventory, as of 2026-08-10:

| module | binds to | fails on a Linux runner? |
|---|---|---|
| `unit/src/zwo.py` | `zwoasi` → ASI SDK (ctypes) | yes, unless the SDK is present |
| `unit/src/imagers/ascom.py` | `win32com.client` (COM) | **yes — Windows only** |
| `unit/src/covers.py` | `win32com.client` | **yes** |
| `unit/src/focuser.py` | `win32com.client`, PWI4 | **yes** |
| `unit/src/mount.py` | `win32com.client`, PWI4 HTTP | **yes** |
| `common/ascom.py` | `pywintypes`, `win32com.client` | **yes** |
| `unit/src/stage.py` | Standa `ximc` (ctypes) | **yes — raises `FileNotFoundError` at import** if the arch's library directory is absent |
| `unit/src/phd2/phd2.py` | socket RPC to PHD2, launches `phd2.exe` | no import failure; connects at call time |
| `common/dlipowerswitch.py` | httpx to the PDU | no import failure |
| `spec` side | Greateyes cameras, dispersers, filter wheels (`common/config/greateyes.py`, `common/models/greateyes.py`) | not surveyed — `MAST_spec` was not to hand |

Two consequences worth deciding early:

- **`stage.py` raises at import**, not at first use. Any import-based step must either
  provide the vendored `ximc` tree for the runner's architecture or stub the module.
- **Every ASCOM-bound module needs `win32com`**, which does not exist on Linux. So the
  OpenAPI generation step must either run on a **Windows runner**, or import under stubs
  that stand in for the COM layer. Running it on Windows is the cheaper answer and matches
  where those services actually run; the rest of the docs build is platform-independent
  and can stay on Linux.

### What "stubbed" has to mean

Stub the **boundary**, not the application. The aim is that constructing the FastAPI app
and walking its routes succeeds, so the OpenAPI schema is generated from the real
signatures and type hints. Nothing about device behaviour needs to be faithful — no frames,
no motion, no solutions. The devices need only import, construct, and answer "not
connected".

Boundaries to stub: **camera** (ZWO and ASCOM imagers), **stage** (Standa ximc), **mount**
(PWI4/ASCOM), **PHD2**, **covers**, **focuser**, and the **spec devices** (Greateyes and
friends).

### This is not the test-suite guard

`tests/conftest.py` in `MAST_common` and `MAST_unit` installs a process-launch **guard**
that raises on any spawn. That is the opposite of a stub: it exists to make an accidental
launch fail loudly, and under it importing `app.py` raises `ProcessLaunchError` rather
than producing a spec.

The docs build needs **stubs that let import proceed**. The guard and the stubs can share
an allow-list and probably a module, but they are different mechanisms with opposite
goals, and the original plan's claim that "we already run the suite under stubs" is not
accurate today.

Doing this well has value beyond the docs: the same stubs would let the contract/regression
suite asked for in `MAST_unit#52` run off-hardware.

### Import-clean check

Once stubs exist, add a small CI step — import the app and dump its OpenAPI spec to a file,
under the same stub environment. Cheap, and it fails pointing at exactly which import needs
the stub active earlier (at app-construction time, not merely at call time).

## Diagrams

- Sphinx's `inheritance-diagram` extension for UML-style hierarchy graphs woven into the
  pages. Needs **Graphviz on the runner**.
- Optionally `pyreverse` (ships with pylint) for richer standalone class and package
  diagrams.
- Run across the combined tree, so a base class in `MAST_common` shows its subclasses in
  `spec` and `control` in the same graph. `Component`, the ABC every hardware component
  implements, is the obvious first thing to look at.

## CI and publishing

- Publish to **GitHub Pages**. All the repos are public, so this needs no extra access.
- **Gate publishing on the TEST jobs passing on `master`/`main`, not on the whole CI.**
  Lint is a separate job and is deliberately red while the ruff burn-down proceeds; the
  docs must not be held hostage to it. This is exactly why the CI guidelines split tests
  and lint into separate jobs.
- Rebuild on push to the default branch; deploy with the built-in Pages Actions flow.
- Pin actions by major tag and let Dependabot keep them current, per
  `code-validation-and-ci-guidelines.md`.

## Open questions

1. **Does the endpoint half earn its cost?** The code/diagram half is nearly free —
   `autoapi` never imports. The endpoint half needs stubs for every device in the fleet.
   Ship the site without endpoints first, and add them when the stubs exist?
2. **Which runner generates the specs?** Windows (matching where the services run, and
   where `win32com` exists) versus stubbing COM to keep everything on Linux.
3. **`MAST_gui` is a Django app**, not FastAPI. It has no OpenAPI spec and its entry points
   differ; decide whether it appears in the code docs only.
4. **Versioning.** One site tracking each repo's default branch, or tagged snapshots? The
   fleet deploys from branch tips, which argues for the former.
5. **Where do the stubs live?** `MAST_common` is the only repo everyone already depends on,
   which makes it the natural home — but it would then carry test/doc scaffolding for
   devices it does not own.

## Next step

Draft the `MAST_docs` workflow: multi-checkout in the sibling layout, the Sphinx +
`autoapi` + diagram build, and the Pages deploy gated on tests — **endpoints excluded
initially**. That gets a useful cross-referenced site up without waiting on the stub work,
and makes the stub work a clearly-scoped follow-up rather than a blocker.
