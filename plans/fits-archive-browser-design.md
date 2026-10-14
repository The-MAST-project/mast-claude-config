# FITS archive browser — a MAST_gui page over the mast-share

*Design for a page in MAST_gui that indexes every FITS frame the units and spectrographs
have written to the mast-share on `mast-ns-control`, shows preview thumbnails, and hands out
a PNG or the full FITS in one click. Written 2026-10-13.*

**Status: plan only — nothing is implemented.** The proposed code home is MAST_gui. One
small change lands in MAST_control: the nginx vhost (§8). §10 lists the open questions, and
§11 is the staging. Once this ships, this document moves into `MAST_gui/docs/`, per this
repo's "put it in the repo it's about" rule.

Code baseline: MAST_gui `main` @ `ae58625`, MAST_control `master`, MAST_common `master`,
MAST_unit `main`, 2026-10-13. The measurements in §1 were taken read-only on
`mast-ns-control` that day.

---

## 1. What exists today

**The data.** `/Storage/mast-share/MAST` holds **14,805 FITS files, 816 GiB** (RAID 5,
66 TB, 2% used). The last 30 days added **~1,500 files / 63 GiB**. Most files are either
~17 MB or the 67–93 MB 8256×5636 uint16 acquisition and guiding frames. The spectrograph
frames are ~1.3 MB. The layout is `<host>/<night>/<kind>/…`:

| path shape | files | size |
|---|---|---|
| `mast00/<night>/Acquisitions/seq=*/spec` | 2041 | 120 GiB |
| `mastw/<night>/Acquisitions/seq=*/sky` | 1964 | 59 GiB |
| `mast02/<night>/FluxMetering/<n>` | 1653 | 74 GiB |
| `mastw/<night>/Acquisitions/seq=*/spec` | 1297 | 114 GiB |
| `mastw/<night>/Acquisitions/seq=*/guiding` | 985 | 115 GiB |
| `mast-ns-spec/<night>/highspec/{Autofocus,Exposures}/…` | ~850 | 1 GiB |
| `*/<night>/Autofocus/<n>`, `Calibration/Focuser/<n>`, `Exposures`, `Spirals`, … | the rest | |

There is a long tail of about 40 shapes, including `backup/`, `saved/`, `CapObj/` and
`acquisition,seq=*`. The top level also holds non-frame files and personal folders.

**`<night>` is an observing-night label, not a UT date.** `PathMaker.make_observing_night_folder`
(`common/paths.py`) names the folder by `observing_night()`, which turns at 12:00 UTC.
Folders written before MAST_common#28 are naive local calendar dates, and nothing in the
folder distinguishes the two conventions. A frame's absolute time must therefore come from
its header (`DATE-OBS`), never from the folder plus the filename's `time=HH-MM-SS`.

**Headers depend on the writer.** Three different writers produce frames, and each uses
its own keywords:

| writer | exposure | sensor temp | `INSTRUME` | other |
|---|---|---|---|---|
| PHD2 (`CREATOR='PHD2 Guiding …'`) | `EXPOSURE` | `CCD-TEMP` | camera model | `RA`/`DEC`, `PIXSCALE`, `GAIN` (0–100) |
| MAST_unit `src/imagers/saving.py` | `EXPTIME` | `CCDTEMP` | unit hostname | |
| MAST_unit `src/flux_metering/session.py` | `EXPTIME` | — | camera model | `OBJECT`, `RUNDATE`, `RUNSEQ` |

Much of the meaning is in the path, not the header. The unit, the kind of frame, seq,
exposure seconds, gain, binning and ROI are in the directory and filename, for example
`Exposures/seq=0001,time=21-05-36_406,roi,seconds=3.0,binning=1,gain=170,binned_roi=8240x5632@21,3.fits`.

**Serving.** nginx's `/mast-share/` proxies to `MAST_gui/tools/cors_http_server.py` on
:8008, an open directory listing of the whole share. The nginx vhost is version-controlled
in MAST_control's `root/etc/nginx/conf.d/mast-ns-control.conf` and deployed with
`make deploy-nginx`. The host's `/etc` is not edited by hand.

MAST_control's `DataServer` (`control/data_server.py`) walks the share for the focuser
panel's autofocus tree. It returns download URLs on the share server, rewritten for the
proxy with `ProxyContext.rewrite(..., base="/mast-share/")`. Its session-zip endpoint
(`get_date_session`) is commented out of the router; it builds an in-memory `ZIP_DEFLATED`.

**MAST_gui** is Django 6 + HTMX + Alpine + JS9. JS9 is loaded globally but is used only
in the focuser panel today. The repo depends on `astropy`, `Pillow` and `django-q2`. The
GUI is served under `/mast-dash/`. The tracked unit file
`root/home/mast/.config/systemd/user/mast-gui.service` cannot be what runs it today: it
names a non-existent `config.settings` and a per-repo `.venv`. How the GUI is actually
launched on the host has to be established in stage 4 (§11).

**Costs, measured on a 93 MB acquisition frame:**

| operation | cost |
|---|---|
| header read | ~1 ms |
| full read + 8×8 decimate + zscale | ~0.1 s (probably a warm page cache) |
| `gzip -1` | 93 → 42 MB |
| `fpack` (Rice) | 93 → 55 MB, 0.37 s |
| 512 px JPEG thumbnail | tens of KB |

The CPU is cheap. **The backfill is I/O-bound**: all 816 GiB must be read off the RAID the
units write to, which takes tens of minutes at best. The site link is slow, and that drives
the whole design: **a browser must never pull a 93 MB frame just to see what's in it.**

---

## 2. Goals and non-goals

**Goals.**

- Find frames fast: filter by host, night, kind, exposure and seq, plus a free-text path
  match.
- See them before downloading: a server-side thumbnail grid, and a larger preview on click.
- Get them in one click: a PNG or the raw FITS, compressed on the wire. A selection can be
  downloaded together.
- Never miss a frame. A frame whose path the parser does not recognize is still indexed
  (as `kind=other`) and shown, never dropped.

**Non-goals, each a decision rather than an oversight:**

- **No writes to the share.** The tool never moves, renames, deletes or annotates a frame.
  Its own state (index and thumbnails) lives outside `mast-share` (§5).
- **No reduction or analysis.** Previews are a display stretch only.
- **No frames that never reached the share.** A unit that loses the share writes locally,
  and those frames are invisible here.
- **No changes to MAST_unit, MAST_common or the spec hosts.** Thumbnails are generated
  centrally, not at capture time (§10, Q8).

---

## 3. Architecture

```
units / spec hosts --SMB--> /Storage/mast-share/MAST/...          (unchanged, read-only to us)
                                     |                       \
                      archive_index (management command,      \  existing open share server
                       systemd timer, flock)                   \ /mast-share/ (raw FITS, gzip)
                         |  walk + parse path + read header     \
                         |  render missing thumbnails            \
                         v                                        \
              /Storage/mast-archive/index.sqlite3   /Storage/mast-archive/thumbs/...
                         |                                   |
        MAST_gui `archive` app (Django views, HTMX)          |
           - query the index, render the grid                |
           - authorize, then X-Accel-Redirect  --------------+--> nginx `internal` location
           - raw-FITS links: ProxyContext.rewrite(…, "/mast-share/")
```

There are three pieces in MAST_gui and one in MAST_control:

1. **MAST_gui `archive/` Django app.** It holds the views, templates, the path parser and
   the index schema.
2. **MAST_gui `manage.py archive_index`.** This is the indexer plus thumbnailer, run by a
   systemd user timer.
3. **MAST_gui download views.** Thumbnail and PNG bytes are authorized by Django and then
   served by nginx via `X-Accel-Redirect`. Raw FITS uses the same share links the focuser
   panel already uses (§6).
4. **MAST_control vhost.** One `internal` location aliasing the thumbnail store, plus
   `gzip` for the FITS content type on `/mast-share/` (§8).

**Django never streams frame bytes.** Whether a request came through nginx is decided per
request, with `ProxyContext.from_request(request).proxied`. The same process also answers
direct :8010 requests, so a process-wide switch can't work. A proxied request gets
`X-Accel-Redirect`. A direct request (local development) falls back to `FileResponse`.

**Views accept an index key, never a path.** Every byte-serving view takes the frame's row
id and resolves it to a path under `ARCHIVE_STATE_ROOT`. This matters most on the direct
`FileResponse` path, where nginx's own normalization doesn't apply.

---

## 4. The path parser

**The vocabulary comes from MAST_common.** Kinds and calibration phases are taken from
`common.paths`: the `PathMaker.make_*_folder` methods and `CALIBRATION_PHASE_FOLDERS`
(Focuser / OpticalCenter / Stage). They are not re-listed in MAST_gui. The test fixture
tree is built by *calling* `PathMaker`, which is importable on the control host via
`mast.pth`, plus a small hand-written set of the historical shapes from §1. A writer change
in MAST_common then shows up in the GUI's tests rather than as a mis-parse on the page.

The parser maps each path to these fields:

| field | from |
|---|---|
| `host` | first path component (`mast01`, `mastw`, `mast-ns-spec`, …) |
| `night` | the `YYYY-MM-DD` component, stored as a label (§1), never as a timestamp |
| `kind` | the PathMaker folder (`Acquisitions`, `Autofocus`, `FluxMetering`, `Calibration/<phase>`, `Exposures`, …), else `other` |
| `phase` | `spec` / `sky` / `guiding` under `Acquisitions` |
| `instrument` | `highspec` / `deepspec` (spec hosts), arm `G`/`I`/`R` |
| `seq`, `exposure_s`, `gain`, `binning`, `roi` | the `key=value` segments of directory and file names |
| `archived` | true under `backup/` or `saved/` |

**Tokenizing `key=value` segments is not a plain comma split.** Values can contain commas
(`binned_roi=8240x5632@21,3`), some tokens are bare flags (`roi`), and `binning` is
sometimes `1` and sometimes `1x1`. The tokenizer therefore attaches a token without `=`
to the previous value when that value is mid-coordinate, and treats it as a flag
otherwise. Every value is stored as text, and the typed columns are filled only where the
value parses. An unknown key is kept, as data rather than as a parse failure.

**Header fields go through one alias table per writer** (§1), keyed on `CREATOR` and the
keywords present: exposure from `EXPOSURE`|`EXPTIME`, temperature from
`CCD-TEMP`|`CCDTEMP`, plus `DATE-OBS`, `RA`, `DEC`, `OBJECT`, `NAXIS1/2`, `BITPIX` and the
HDU count. `INSTRUME` is stored verbatim with the detected writer, because its meaning
differs between writers. The full primary header is stored as text, for the detail view.

---

## 5. Index and thumbnail store

**Location: `/Storage/mast-archive/`**, outside `mast-share`. That keeps it invisible to
the units' SMB view, off the root disk, and disposable. Deleting the directory and
re-running the indexer rebuilds everything.

**Index: plain SQLite (`index.sqlite3`), not the GUI's Django database.** A rebuildable
cache doesn't belong beside the GUI's users and accounts. The views open it read-only. WAL
mode lets the page read while the indexer writes.

```
frames(id PK, path UNIQUE, host, night, kind, phase, instrument, seq, exposure_s, gain,
       binning, roi, path_tokens, archived, writer, date_obs, ra, dec, object, instrume,
       ccd_temp, naxis1, naxis2, bitpix, n_hdu, size, mtime, header_text, parse_pattern,
       thumb_key, thumb_state, thumb_error)
indexes on (night), (host, night), (kind)
```

**One indexer at a time.** `archive_index` takes an `flock` on
`ARCHIVE_STATE_ROOT/index.lock` at startup and exits if it is held. systemd stops a timer
from overlapping only with its own service, not with a hand-run backfill.

**Incremental scan.** Each run walks the whole share, which takes seconds for 15k entries.
A row is (re)indexed when `(size, mtime)` changed. Files modified in the last
`ARCHIVE_SETTLE_SECONDS` are skipped, because the RAM-disk mover may still be writing them.

**A failed directory listing is never read as an empty one.** The walk passes an `onerror`
that records the directory. Rows under any directory that failed to list are left
untouched, and the failure is reported at the end of the run (non-zero exit). Otherwise one
unreadable folder, or a transient I/O error, would silently delete its whole subtree. Only
rows whose file is confirmed gone are deleted, together with their thumbnails.

**Thumbnails.** There are two sizes per frame:

- `grid`: 512 px on the long side, JPEG q≈80.
- `preview`: 2048 px PNG. This is both the click-through preview and the "download PNG".

They are keyed by `path + mtime + RENDER_VERSION`. `RENDER_VERSION` is a constant bumped
whenever the stretch changes, so the per-kind tuning in stage 2 regenerates thumbnails
without deleting the store by hand. A row whose key changed has its old files removed.

The stretch is block-mean decimation to roughly the target size, then zscale, then linear,
with a per-`kind` default (§10, Q6). Multi-HDU files use the first image HDU. Rendering
writes to a temp file and renames it into place. A frame that fails to render gets
`thumb_state=error` with the message stored, and the page shows a placeholder and the
error. It is never silently skipped.

**I/O load.** The backfill, not the incremental run, is what contends with the units' SMB
writes. The service unit sets `Nice=` and `IOSchedulingClass=idle`. The idle I/O class is
honored only by schedulers that implement priorities (BFQ), so the md members' scheduler
(`/sys/block/sd*/queue/scheduler`) is checked in stage 2. If it isn't BFQ, the unit uses
`IOReadBandwidthMax=` or a frames-per-run cap (`ARCHIVE_THUMBS_PER_RUN`). When large runs
are allowed is §10, Q4.

---

## 6. The page

`/archive/` in the sidebar has the following parts.

- **Filters:** host (multi-select, production units first), night range, kind/phase,
  exposure range, include-archived toggle, and a path substring search. The filter state
  lives in the query string, so a view is a shareable link. The GUI has no date-range
  widget yet. The focuser panel inlines a single-date bootstrap-datepicker, and
  `django-bootstrap-datepicker-plus` is declared but unused, so stage 3 picks one.
- **Grid:** thumbnails grouped by host and night, newest first, paginated through HTMX.
  Each tile shows the time (from `DATE-OBS`), kind, exposure and seq.
- **Detail** (modal): the preview, a table of the parsed fields plus the full header, and
  the actions below.
- **Actions:**
  - **PNG**: the 2048 px preview.
  - **FITS**: the existing share link, built with `ProxyContext.rewrite(…, "/mast-share/")`
    exactly as `DataServer` does. nginx `gzip` compresses it in transit, and the browser
    saves a plain `.fits` (§8).
  - **Open in JS9**: loads the same link.
  - **Copy path**: the share path, for anyone on the SMB share.
- **Selection:** a checkbox per tile, then *Download selection*. This returns a URL list
  for `wget -i` / `curl` over the share links. There is deliberately no server-built zip:
  nginx cannot X-Accel a zip generated on the fly, so a multi-GB selection would stream out
  of a Django thread for the whole transfer (§10, Q7).

Every view is `login_required`. Whether it also needs a capability is §10, Q2. The raw
FITS links carry exactly the protection `/mast-share/` already has, which today is none
(§10, Q3).

---

## 7. Configuration

These are Django settings, read through `python-decouple` like the rest of the GUI:

| setting | default |
|---|---|
| `ARCHIVE_SHARE_ROOT` | `/Storage/mast-share/MAST` |
| `ARCHIVE_STATE_ROOT` | `/Storage/mast-archive` |
| `ARCHIVE_SETTLE_SECONDS` | `120` |
| `ARCHIVE_THUMB_WORKERS` | `4` |
| `ARCHIVE_THUMBS_PER_RUN` | unset (no cap) unless I/O throttling needs it (§5) |

The timer interval goes in the unit file. The proposal is every 10 minutes, which is short
enough that last night's frames are browsable by the morning.

---

## 8. Changes outside MAST_gui

- **MAST_control `root/etc/nginx/conf.d/mast-ns-control.conf`** gets two changes in one
  PR, deployed with `make deploy-nginx` and checked with `check-deployed`:
  - an `internal` location aliasing `ARCHIVE_STATE_ROOT/thumbs/`, the X-Accel-Redirect
    target;
  - `gzip on` with the FITS content type the share server actually sends (to be checked
    in stage 3) on `/mast-share/`. That roughly halves FITS transfers, at the measured
    93 → 42 MB.

  The vhost is not documented a second time in `MAST_gui/docs/reverse-proxy.md`. That
  page is already out of date against the deployed vhost, and fixing it means pointing it
  at MAST_control's tree.
- **`/Storage/mast-archive/`:** created once, owned by `mast`.
- **No new Python dependencies.** MAST_common and MAST_unit are unchanged.

---

## 9. Verification

- **Parser:** a fixture tree built from `PathMaker` plus the historical shapes in §1,
  including the `binned_roi=…@x,y` filename, both `binning` forms, both night-folder
  conventions, and one unknown shape that must land as `kind=other`.
- **Header aliasing:** one tiny FITS per writer (§1) yields the same exposure and
  temperature columns.
- **Indexer:** add, modify (mtime bump, old thumbnails removed), delete, a file inside the
  settle window, a corrupt file (`thumb_state=error`), an unreadable directory (rows kept,
  non-zero exit), a second concurrent run (exits on the lock), and a `RENDER_VERSION` bump
  (regenerates).
- **On the host, before enabling the timer:** `archive_index --dry-run` prints counts per
  `kind` and `parse_pattern`, plus every path that parsed as `other`. The total must match
  `find … -iname '*.fit*' | wc -l`.
- **Load:** time one full backfill and watch `iostat` on `md0`. Run it in daytime.
- **Page:** filters, grid, detail and each download work both behind nginx and directly. A
  logged-out request is refused by every archive view and by the thumbnail location. A
  download view given an id that isn't in the index returns 404, and none accepts a path.

---

## 10. Open questions

1. **Backend placement.** This plan keeps everything except the vhost in MAST_gui. The
   alternative follows the autofocus precedent: index and query endpoints in MAST_control's
   `DataServer`, called from the GUI through `ControlApi`. That fits the existing split, at
   the cost of a larger cross-repo change and putting I/O-heavy thumbnailing in the control
   backend. **Recommended: MAST_gui**, because the page is the only consumer.
2. **Audience and access.** Is this for the team on the intranet, or also for scientists
   off-site? That decides whether `login_required` is enough or a capability
   (e.g. `canBrowseArchive`) is needed, and how off-site users reach the host at all.
3. **The open share listing.** Raw FITS links reuse `/mast-share/`, so the page's login
   doesn't protect them. If the team decides that listing should close, raw FITS moves
   behind a second `internal` location aliasing the share, using the same views. Until
   then, a second path to the same bytes would add no protection.
4. **I/O policy.** Is a throttled incremental run acceptable during observing? Should the
   one-off backfill be confined to daytime?
5. **Scope of hosts and folders.** Should `mast00`, `mastw` and the `backup/` and `saved/`
   copies be indexed but hidden by default, or not indexed at all? Should personal and
   top-level folders be excluded?
6. **Preview defaults per kind.** Spectrograph frames (per arm) and FluxMetering frames
   probably want a different stretch from the A&G full-frame zscale. Who signs off on what
   a useful preview looks like?
7. **Selection as one file.** The URL list covers bulk download without streaming through
   Django. If a single archive download is wanted anyway, it needs a stated exception
   (Django streams it, with a size cap) or nginx `mod_zip`, which isn't in stock nginx.
8. **Thumbnails at capture time instead?** A unit-side thumbnail would remove the central
   read, but it would touch every writer and leave the existing 800 GiB uncovered.
   Recommended: central only.
9. **`.fz` downloads.** nginx `gzip` beats `fpack` on the measured frame (42 vs 55 MB) and
   needs no cache. An `fpack`ed download is worth adding only if someone wants tiled access
   to the files. If so, use `-q 0` for float images (fpack quantizes floats by default),
   pass through files that are already `.fz`, and write to temp then rename.

---

## 11. Staging

Each stage is one PR, mergeable and useful on its own.

| stage | delivers | done when |
|---|---|---|
| 0 | this document (mast-claude-config) | §10 Q1, Q2, Q4, Q5 answered |
| 1 | MAST_gui: `archive/` app skeleton, path parser, header aliasing, SQLite index, `archive_index --dry-run` / index-only, lock | the dry run on the host accounts for every FITS file; parser and indexer tests pass |
| 2 | MAST_gui: thumbnailer (pool, `RENDER_VERSION`, error state); I/O scheduler check | one full backfill measured on the host; per-kind stretch reviewed (Q6) |
| 3 | MAST_gui: `/archive/` page (filters, grid, detail, PNG / FITS links, auth, per-request X-Accel-Redirect + direct fallback). MAST_control: vhost `internal` location + `/mast-share/` gzip | verification §9 "Page" passes behind nginx and directly |
| 4 | MAST_gui: establish how the GUI is really launched; fix or replace the stale `mast-gui.service`; add the `archive_index` service + timer | last night's frames appear without a manual run |
| 5 | MAST_gui: selection URL list, Open in JS9 | a 20-frame selection downloads with one `wget -i` over the site link |

**Docs, per stage:**

- **Stage 1:** the `archive` section in `MAST_gui/README.md`, and a `CLAUDE.md` note
  ("parser vocabulary comes from `common.paths`; add a pattern, never special-case a
  path").
- **Stage 3:** the vhost change is described in MAST_control's `root/README.md` if that
  page's conventions call for it.
- **Stage 4:** deployment steps, with the corrected unit files.
- **Rationale:** the decisions behind §3 and §5 are recorded in a `DECISIONS.md` in
  MAST_gui. The repo has none today, so whether to start one is the team's call. Failing
  that, they stay in this document.
- **After stage 5:** this document moves to `MAST_gui/docs/`.
