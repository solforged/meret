# Architecture

Draft, 2026-10-13. Decided: Flutter over a Rust core, macOS first, Android second, Windows and Linux later. Built for the trails plates ([`design/2026-10-13-trails/`](../design/2026-10-13-trails/index.html)) and the model in [direction.md](direction.md), [idioms.md](idioms.md) and [navigation.md](navigation.md).

## What it has to carry

| Demand | From | What it means for the build |
|---|---|---|
| 120 Hz, never a dropped frame | Panes sliding along a trail, the body turning, the sky panning, brushing a histogram header | The UI thread never waits on the core. Nothing animated asks the core for anything per frame |
| Bit-perfect, gapless, loop-aware | Signal path on every plate; Work and Set idioms; Score loops | A realtime audio thread that owns the device and never allocates, locks or logs |
| Multi-terabyte libraries | 48,210 tracks on the plates; plan for 1,000,000 files across disks and a NAS | Incremental scans, offline volumes kept, and hot columns in memory so the table and the histograms don't touch SQLite |
| Sources everywhere | sp, qb, yt, bc, ia marks; MusicBrainz, VGMdb, Discogs, ListenBrainz threads; Roon, Music Assistant, AirPlay zones | Every integration is an adapter with declared capabilities, and every fact keeps its source |
| Long work, always visible | ↻ analysing 1,204 of 3,880; ≈ 312 to identify | Everything slow is a persistent, resumable job whose state the status line shows |
| Playback outside the window | Plate 10: menu bar, media keys, lock screen | Playback lives in the process, not in the UI. Closing the window or killing the Flutter engine on Android doesn't stop the music |
| Desktop and phone, one library | Plates 03, 08, 11: hand-off, "continue from the Mac at 3:47" | The Mac is the hub; the phone is a satellite with its own copies, and it can control the hub |

## Shape

```mermaid
flowchart TB
    subgraph Process["One process"]
        subgraph UI["Flutter UI · UI thread + raster thread"]
            Shell["Surface: trail strip, panes, Now, query line, status line"]
            Draw["Painters and shaders: body, sky, histograms, constellation"]
        end
        subgraph Host["Platform host"]
            MacHost["macOS: app delegate, menu bar, MPNowPlaying"]
            DroidHost["Android: Media3 MediaSessionService"]
        end
        FFI["meret-ffi · flutter_rust_bridge"]
        API["meret-api · commands, live queries, DTOs"]
        Core["meret-core · runtime"]
        subgraph Workers["tokio + rayon workers"]
            Library["meret-library · scan, watch, tags, art"]
            Match["meret-match · identity"]
            Analysis["meret-analysis · loudness, DR, body, embeddings"]
            Graph["meret-graph · threads, trails, leads"]
            Sky["meret-sky · layout, tiles, lasso"]
            Jobs["meret-jobs · queue, scheduler, rate limits"]
            Providers["providers/* · adapters"]
        end
        Store["meret-store · SQLite writer + readers, hot columns"]
        Player["meret-player · queue, zones, idiom rules, resume"]
        Engine["meret-engine · decode → DSP → output"]
        RT(["audio callback · realtime"])
        Shell <--> FFI
        Draw <--> FFI
        MacHost --> Core
        DroidHost --> Core
        FFI <--> API <--> Core
        Core --> Workers
        Workers --> Store
        Core --> Player --> Engine --> RT
    end
    API <-->|"same API over websocket"| Phone["Phone or another Meret"]
    Providers <--> Net["MusicBrainz · VGMdb · Discogs · ListenBrainz · Music Assistant · Roon · Spotify Connect · Bandcamp · YouTube"]
```

## Rules

1. **The core owns the truth; the UI draws it.** Library, queue, trails, jobs and source state live in Rust. Dart keeps view state only: scroll offsets, hover, which pane is focused. Dart could be replaced without touching the model.
2. **Three clocks, three kinds of thread.** The audio callback (a deadline every few milliseconds), the UI frame (8.3 ms at 120 Hz), and everything else. They talk through lock-free rings and async channels, never shared locks.
3. **The UI never waits.** Every call into the core is async. A pane opens on the next frame with what it has (the title, the cover, the row count) and fills in. No synchronous FFI call ever happens in `build`.
4. **Animate from anchors, not streams.** The core sends the playhead as an anchor (position, host time, rate) when it changes. Dart extrapolates every vsync. The same goes for job progress (rate and ETA) and the sky (positions sent once as a buffer, after which the GPU does the work).
5. **Bulk data crosses as buffers.** Star positions, histogram bins, sparklines and body summaries arrive as typed arrays (zero-copy `Float32List` and `Uint8List`), not lists of objects.
6. **Slow means job.** Scanning, fingerprinting, matching, analysis, embeddings, sky placement, crawls and syncs are rows in a job table. They're resumable, prioritised, rate-limited per host, and visible in the status line.
7. **Every fact has a source.** Providers emit claims, not rows. A resolver merges them by precedence, and the UI can always say where a credit or thread came from and how sure Meret is (`≈`).
8. **Playback never depends on the UI.** The core is a process-wide singleton started by the platform host. The Flutter view attaches to it and can go away.

## Crates

One Cargo workspace. The arrows are the only allowed dependencies; `meret-engine` in particular never sees the store.

```
meret-model ◄── everything        pure types: IDs, entities, idioms, threads, availability, signal path
meret-query ◄── store, core       the query language: parser and AST, no IO
meret-store ◄── library, match, analysis, graph, sky, jobs, core
meret-engine ◄── core             realtime audio; depends on model only
meret-player ◄── provider, core   queue, zones, idiom playback rules, resume; doesn't know the engine
meret-provider ◄── providers/*, core
meret-core ◄── api                composes the runtime
meret-api ◄── ffi, cli, (server)  the one public surface
```

| Crate | Owns | Notes |
|---|---|---|
| `meret-model` | Typed IDs, the entity graph (work, recording, release, edition, track, agent, context, source), idioms and their playback rules, thread kinds, provenance, availability and identity marks, the signal path | No IO. Everything else speaks these types |
| `meret-query` | `sung:"Joanne Hogg" not:owned`, `idiom:session year:1970s plays:0`, `last:30d`, plus the commands (`play`, `want`, `crate add`) | Smart crates are saved queries, so the parser is shared by search, crates and the table |
| `meret-store` | SQLite schema and migrations; one writer thread that batches transactions; a pool of readers; the **hot column store**; FTS5 search | See *Storage* |
| `meret-library` | Roots (volumes), the stat walk, diffs, move detection, FSEvents resume, tag reading, CUE sheets, rip logs, artwork extraction and the light tokens; writing tags and moving files to match the store, as undoable jobs ([stories.md](stories.md)) | Offline volumes are marked, never deleted |
| `meret-match` | Identity: MBID tag → ISRC → AcoustID → fuzzy, with method and confidence kept | Below the threshold a match is `≈` |
| `meret-analysis` | EBU R128 loudness, dynamic range, tempo and key, structure, the **body summary** (what the radial drawing is made of), audio embeddings | Runs on the hub; phones receive results |
| `meret-graph` | Threads (typed, sourced edges), trails as trees (branch, peek, meet, prune), leads and how they converge | The product's heart, and almost all pure logic, so it's tested hardest |
| `meret-sky` | Stable placement from embeddings, level-of-detail tiles, star buffers for the GPU, lasso | New stars settle in; old ones don't move |
| `meret-jobs` | Persistent queue, resource classes (IO, CPU, network per host), token buckets, pausing on battery or while playing | MusicBrainz allows one request a second, so this is not optional |
| `meret-engine` | Decoders, gapless joins, loops, DSP stages, output backends, the playback clock | See *Audio* |
| `meret-player` | Queue, trail and tree playback, idiom rules (never shuffle inside a work), resume per idiom (plate 09), zones | A local engine, a Roon zone and a Sonos room are all `Zone`s; `meret-core` wraps the engine as the local one |
| `meret-provider` | Capability traits, the registry, claims, an HTTP context with rate limits, cache and keychain | One crate per service under `providers/` |
| `meret-core` | Starts and wires everything; live-query invalidation; the status snapshot | The process singleton |
| `meret-api` | Commands, live queries and DTOs for panes, lists, Now, the status line and the sky | Transport-agnostic: FFI on device, websocket from a phone |
| `meret-ffi` | flutter_rust_bridge bindings over `meret-api` | Built by the Flutter build; not in the default workspace members |
| `meret-cli` | `meret scan`, `meret query`, `meret decode`, `meret play` | For exercising the core without a UI |

## Storage

**SQLite in WAL mode, one writer.** A writer thread owns the only write connection and batches work into transactions, so a scan inserting thousands of rows a second doesn't contend with anything. Readers come from a pool. The schema is in [`crates/meret-store/migrations/`](../crates/meret-store/migrations/).

| File | Holds | Rebuildable? |
|---|---|---|
| `library.db` | Entities, files, sources, threads, provenance, listens, notes, trails, crates, wants, jobs, FTS | No: it holds your trails and notes |
| `cache.db` | Provider responses (HTTP cache), crawl results | Yes |
| `embeddings.f16` | One vector per track, memory-mapped, plus an HNSW index | Yes, by re-analysis |
| `sky.bin` | Placed positions and LOD tiles | Partly: positions are part of your memory of the map, so they're backed up |
| `art/` | Content-addressed covers at 64, 128, 256 and 512 px, with OKLCH light tokens precomputed | Yes |

**Hot columns.** The table pane and the histogram headers can't round-trip through SQL at 120 Hz. The store keeps a struct-of-arrays copy of the columns you sort, filter and brush (release, artist, album artist, case-insensitive title/artist/album ranks, idiom, year, length, format, DR, plays, last played, added, availability), about 64 bytes a track, or 64 MB for a million. Name ranks are computed while loading and the strings are then dropped. Filters produce roaring bitmaps, and facet counts scan the matching row numbers. Brushing *Last played*, recounting the year histogram and the idiom facets over a million rows took 3 ms in a release build on this Mac before the browsing columns were added (`cargo test -p meret-store --release -- --ignored --nocapture`).

**Lists are handles.** The core caches each `(query, view)` as track IDs in display order plus display items: track ordinals and, when grouped, release headers. Sort keys are library, title, artist, album, year, length and format; ties stay in library order even descending. Group sorting moves whole releases, never their disc/track order. The UI pages display items; playback starts from a track ordinal in that same view. Release labels and artwork are read in batches for each page.

**Column browser.** Idiom → person → release facets count tracks over the query's non-browser clauses, then its idioms, then its people. A track counts once for its artist and once for a different album artist. Clicking a new entry clears that column and downstream selections; clicking a selected entry removes only its clause. Counts, selected flags, and canonical entry/All queries come from the core. `meret library ls '' --group --sort year --desc` and `meret library facets 'idiom:score'` expose the same API without the UI.

**Sync-ready from day one.** Library rows carry a `rev` taken from a global counter, so a phone can pull "everything since *rev*". Things you make (listens, notes, trails, crates, wants, resume points) have ULIDs and merge rules. Trails are append-only trees, so merging them is a union.

## Audio

```
source ─► decoder ─► [resampler] ─► DSP stages ─► ring ─► output callback ─► device
 file      Symphonia   only when       ReplayGain,   SPSC     CoreAudio HAL
 stream    libgme,      the device      EQ,           rtrb     AAudio
 zone      vgmstream,   can't take      crossfeed
           FFmpeg       the rate
```

- **Samples travel as `i32` in a left-justified 32-bit container,** so 16- and 24-bit PCM and DoP-packed DSD pass through untouched. A stage that needs float converts internally and says so in the signal path.
- **The callback only reads the ring.** Control comes in on a second SPSC queue. Position goes out through two atomics (frames played, host time). Nothing in the callback allocates, locks, logs or calls into Dart.
- **Gapless.** Decoders report encoder delay and padding. The engine opens the next source a few seconds early and splices it into the same stream. A change of sample rate means reopening the device for bit-perfect output; that gap is unavoidable, and the signal path shows it.
- **Loops.** Score sources expose loop points (native formats, vgmstream metadata, or detected). Each idiom has a `LoopPolicy`: intro, loop ×2, fade; or loop forever.
- **macOS output** goes straight to the CoreAudio HAL rather than through cpal: hog mode, setting the nominal sample rate, choosing the physical stream format. **Android** uses AAudio (exclusive, MMAP where offered), plus Android 14's bit-perfect mixer attributes for USB DACs, which have to be set from Kotlin.
- **The signal path is data.** Every stage describes itself and whether it changes the samples, so `● Bit-perfect` is computed, not asserted.
- **Zones.** `meret-player` drives anything that implements `Zone`: the local engine, a Roon zone, a Music Assistant player (Sonos, AirPlay, Chromecast), Spotify Connect, or another Meret. Each zone reports its fidelity (bit-perfect, resampled above 48 kHz, lossy, delayed about 2 s), which is the PLAY ON list on plate 09.

## UI (Flutter)

```
apps/meret/lib/
  core/      the bridge: CoreBridge interface, the Rust implementation, a fake for building without Rust
  shell/     surface, trail strip, pane row, query line, status line, width classes
  panes/     one widget per pane kind: person, release, group, work, table, sky, tree, front
  now/       Now: body, signal path, up next, pick up
  draw/      painters: body, constellation, histogram header, sparkline, availability marks
  theme/     instrument tokens, light tokens from the cover, idiom registers
shaders/     sky.frag (density), body.frag   (planned)
```

- **Width classes, not platforms**, from navigation.md's scaling table: phone (one pane, swipe along the trail), foldable (two), laptop (two or three plus a narrow Now), large (four or five, spines, a pinned Now).
- **The pane row is a `Flow`.** Sliding panes and folding them to spines changes only paint transforms, never layout. Each pane sits in a `RepaintBoundary`.
- **The body and the playhead repaint without rebuilding.** A `PlayheadClock` ticks on vsync only while playing and extrapolates from the core's anchor. Painters take it as `repaint:`, so nothing above them rebuilds.
- **Lists are virtual with fixed extents.** Rows come from the core in pages through a small cache. Covers are decoded off the UI thread at the size they're drawn.
- **The sky is the GPU's job.** Positions arrive once as a `Float32List` and are drawn with `drawRawPoints` or `drawVertices`. A fragment shader draws the density at galaxy zoom, and tiles take over as you zoom in. A lasso is a polygon sent to the core, which returns a selection.
- **Keyboard first on desktop.** `Shortcuts` and `Actions` carry navigation.md's keys: `/`, `[` `]`, `⌥[` `⌥]`, `⌘↵`, `T`, `M`, `W`, `C`, `⌘S`, Space, `⇧Space`.
- **Platform glue stays native.** On the Mac: the menu-bar item, `MPNowPlayingInfoCenter` and media keys, in Swift. On Android: a Media3 `MediaSessionService` in Kotlin that talks to the same Rust engine directly, so playback survives the Flutter engine being torn down.

## Integrations

A provider declares which of these it can do. The registry asks by capability, so a new service is one crate and one line in the registry.

| Capability | Gives | First providers |
|---|---|---|
| `Catalog` | Claims about entities: titles, credits, editions, external IDs | MusicBrainz, VGMdb, Discogs, Open Opus |
| `ThreadSource` | Typed, sourced relations to follow | MusicBrainz, VGMdb, Discogs, Wikidata, ListenBrainz |
| `LibrarySync` | What you own or saved elsewhere, with a cursor | Spotify, Bandcamp, YouTube likes, Qobuz |
| `StreamSource` | Bytes Meret can decode itself | Bandcamp downloads, Internet Archive, podcast feeds |
| `ZoneHost` | Zones Meret can drive but not decode for | Music Assistant, Roon, Spotify Connect |
| `ListenHistory` | Import and scrobble | ListenBrainz, Last.fm |
| `Shop` | Watches wants | Bandcamp, Qobuz, Discogs marketplace |
| `Crawler` | Candidates for leads | YouTube, Bandcamp, SoundCloud |

Each provider gets a `ProviderContext`: an HTTP client with that host's rate limit and a response cache, a key-value store for cursors, the keychain for tokens, and a way to emit claims and edges. Its health goes to the status line. The claim model means a provider never writes the library directly, so a bad provider can be switched off and its claims dropped without damage.

Later, the same traits can be exposed to out-of-process plugins (a WASM component or a subprocess speaking `meret-api`). Nothing is built for that yet; keeping providers behind claims and capabilities keeps it possible.

## Hub and satellites

- **The Mac is the hub.** It holds the whole library, runs analysis and providers, and serves `meret-api` over a websocket on the LAN (mDNS) or a tailnet.
- **The phone is a satellite.** It replicates library metadata by `rev`, keeps its own copies of what you've put on it, plays them through its own engine, and controls the hub's zones for everything else. With no hub it runs as a hub of one.
- **Hand-off** moves the queue and the anchor. The phone plays its own copy if it has one, or controls the Mac if it doesn't (plate 10).
- **Your data merges.** Listens are append-only, trails are unions of trees, and crates and notes are last-writer-wins per field.

## Budgets

These are what a spike or a regression test should hold the build to.

| What | Budget |
|---|---|
| Cold start to Now drawn | 400 ms, from saved state; no scan on the way |
| Opening a pane | First frame on the next vsync; filled within 50 ms at p95 |
| Scrolling the table, 1,000,000 rows | 120 Hz on an M-series Mac and a mid-range 120 Hz Android phone |
| Brushing a histogram, 1,000,000 rows | Recount within 4 ms |
| Search as you type | 30 ms at p95 |
| Sky, 1,000,000 stars | Pan and zoom at 120 Hz |
| Playing FLAC, window hidden | Under 1% CPU on an M-series Mac |
| Rescan of an unchanged 1,000,000-file library | Seconds via FSEvents resume; under 60 s by full stat walk on SSD |
| Core memory, 1,000,000 tracks | Under 400 MB on desktop |

## State of the scaffold

As of 2026-10-17. `cargo test --workspace` runs 148 tests (plus two ignored: a benchmark and a device listing that needs hardware); `flutter test` in `apps/meret` runs 76, eleven of them through the real Rust core (scan to play, search, grouped rows and facets, release and person panes on a trail, device volume, a counted play and a skip, and kept trails across a reopen).

| Works | Stubbed or missing |
|---|---|
| Query language: parse, canonical form for searches and commands, errors; the planner answers column clauses from bitmaps. Free text, people (`by:`, and `performer:` for the artist tag) and `release:` go to full-text search: a word matches where a word starts, ignoring case and accents ("iona" finds Iona Brown, not "traditional"; "olafsson" finds Ólafsson). Exact case-insensitive agent names and release titles take precedence over contains matches in `by:` and `release:`. `play <query>` runs from the query line | Games, films, labels, works, wants, dormant and BPM match nothing until something in the library says them; composers and the other roles find no one until the scan reads those tags. `queue`, `want` and `crate` say they aren't built yet |
| Store: schema v9, migrations, settings (the light level and the output device and mode) through the writer, a device id minted on first use (every row a person makes carries it), the single writer (a write returns once its batch has committed), readers, hot columns loaded from SQLite at start-up and after every scan, one row per track in library order (album artist, album, disc, track), with histograms and cascaded idiom/person/release facets; the FTS5 trigram `search` table, kept by the scan and backfilled by migration 0003; the last six query/view lists held by the core, sorted and optionally grouped, then paged. Migration 0006 merges tracks that are copies of one another into one track with several sources; migration 0007 splits joint credits into people, both without a rescan. Memory (slice B, 2026-10-17): every playback attempt is a `listen` row (started at, played ms, the trail stop it came from); a play counts when it ran for half the length or four minutes, whichever is less, and `plays`/`last played` in the hot columns count only those, updated in place as each counted listen lands. Migration 0008 adds `queue_state` (the queue, cursor, position and playing flag as JSON, checkpointed every ten seconds while playing and at once on pause or stop) beside the `resume` table (one row per release partway through, cleared when it plays to the end). Migration 0009 persists trails: stops, parents, threads, dwell, pruning, actions, names, kept and the history order | A hot-column snapshot file for a faster cold start; live-query invalidation; a word-prefix index, so a one- or two-letter search doesn't scan the table; an open listen's `played_ms` is written only when the item ends, so a quit mid-track leaves it at zero |
| Engine: Symphonia decode, the ring, gapless joins, reopening on a format change, seeks that flush, anchors, the signal path. CoreAudio HAL output: device list, hog mode, rate switching, integer physical formats, restoring the device on close, latency-corrected anchors. Devices match by UID only. With the system default chosen, the device is resolved once when playback starts and kept for every reopen until playback stops or the setting changes, because macOS moves its default output away from a hogged device. Lossy sources report 24 bits, so exclusive mode doesn't pick a 16-bit format for them. Output changes apply at once when idle and on resume when paused. The device's own volume (`kAudioDevicePropertyVolumeScalar`, master or per channel) is read and set from Now; samples are never scaled | Device unplug (an unplugged DAC stalls); a resampler for rates the device can't do; releasing hog mode during a long pause; the system volume keys, which follow macOS's moved default while Meret holds a device; loops; DSD, libgme, vgmstream; dither |
| Library: parallel stat walk, diff with move detection confirmed by a head hash, tags through lofty. Scans run on a background worker and write roots, files, sources, recordings, tracks, releases and credits through the writer in batches of 256. A file whose release already has a track with the same disc, number and normalised title (or, without numbers, the same title within 2 s) becomes another source of that track, so the Tyranny soundtrack's FLAC and MP3 folders are 43 tracks with two copies each; a title that repeats the track number ("1 - Terratus") loses the prefix. Playback and the format column use the best present copy (lossless, then depth, then rate; lossy by bitrate, then Opus, AAC, Vorbis, MP3; lowest source id on a tie), and `format:` matches any copy. Artist and album artist credits keep the written string for display and sorting, and credit each person: multi-value tags first, otherwise split on `;` and *feat.* always, and on `&`, *and* and commas only when every part has two or more words, so "Simon & Garfunkel" and "Gibbons, Orlando" stay whole. Missing files and unplugged roots are marked, never deleted; unreadable files are retried on the next scan. Each release gets a first idiom from cheap signals (chiptune formats and `.m4b`, genre tags, tracks over 40 minutes), or Album with `idiom_source = 'default'`, which any signal replaces. Covers and their light tokens are read after each root scan. Removing a folder marks its root removed and hides its tracks everywhere; adding it again restores the same tracks. Suggested folders for the empty Front: `~/Music`, Steam soundtracks, an Apple Music media folder outside `~/Music`, and mounted volumes Finder shows, counted within a two-second budget, except paths macOS would ask about, which aren't walked until you add them | FSEvents; CUE sheets; composers, MBIDs and the other tags; MusicBrainz genres and local audio classification for idioms; surname-first names ("Gibbons, Orlando") are kept as written, not reordered |
| Trails as trees: follow, branch, peek, meet, prune, depth-first play; leads converge. The API drives them: a search or a Front door starts one, a pane's threads follow from the stop it was picked in (a branch when that isn't the last), `[` `]` walk the branch and a star on the strip jumps to its stop. Following a thread to something already on the current path goes back to that stop instead of adding one, and `]` never lands on a folded peek. Starting a trail keeps the old one: `[` at a root steps back into the previous trail at the stop you left it from, and `]` there returns to the newer trail. Every trail survives a restart, written after each move; the history comes back with no active trail, so Meret opens to the Front and `[` steps into the newest trail where it was left. `keep_trail` marks and names the whole tree; `trail_history` lists summaries ("Root → Leaf", stops, branches, when, kept, played, wanted) for the Front. Local threads come from tags: *by* (artist), *album artist*, *on* (a release someone is on), *worked with* (people sharing a release), and *matched* from a search to a hit. Release pages (tracklist, formats, credits with the tracks each artist is on) and person pages (their releases, other people's they're on, who they worked with). `meret library trails` and `library walk '['` read the saved history | Forks shown inside panes (⑂ and "Forks here"); `⌥[` `⌥]`, prune, keep and play-the-tree from the UI; kept trails on the Front; threads from providers; the sky's "close neighbours" for meetings |
| Player: per-idiom resume (plate 09), shuffle that never splits a work; the queue driving any `Zone`, one item loaded ahead for gapless joins; `LocalZone` over the engine, playing each track's best copy and setting device volume; Now with title and artist; next (at the queue's end, stop) and previous (more than three seconds in, by the extrapolated anchor, it restarts the item; otherwise the one before), both stepping past items the zone can't open; the queue after the playing item as Up next. Memory: on start the saved queue is described into Now as paused at its position without opening the device; `Resume` then plays it at the idiom's point (album, song, session from the top of the track; score and set the exact second; spoken five seconds back), `FromStart` from the top of the item, and `pick_up(release)` any release partway through, listed by `resume_points`; `history`, `most_played(days)` and `dormant` (five counted plays, none in 180 days) read the listens. `meret library resume`, `library now` and `library history` show them; the CLI's `play` checkpoints before exiting on Ctrl-C | Queues longer than 10,000 rows; the UI for Pick up, What was that?, Most played and Dormant (slice C) |
| Matching, DR, the body summary, sky placement and lasso, job scheduling and rate limits | AcoustID, R128, embeddings, LOD tiles, the persistent job runner |
| Providers: capability traits, claims, rate-limited HTTP; MusicBrainz recording and artist threads | Every other provider; Music Assistant is a shell |
| Flutter: the surface, width classes (Now is a bar below 1400 px and a pinned pane from there: 360 px to 1800, 380 beyond; decided 2026-10-17), the `Flow` pane row with spines, the query line (on macOS also the window's title bar; a command runs). The panes after the Front are the trail's current branch, nothing else: a search, a Front door or `⌘L` starts a trail, every pane opened from a pane follows a thread from that pane's stop (a branch when it isn't the last), `[` `]` walk the branch (`[` at a root steps into the previous trail, or shows the Front when there is none) and a star on the strip goes to its stop. The strip names every stop and the thread into it, with other branches in grey below and forks ringed; stops that reach the same thing are joined by a dotted line, and a deep trail scrolls sideways, keeping 44 px stars at least 144 px apart and the current stop in view, with arrows when more lies off either edge. Typing a search drops grouped hits under the query line (people, releases, tracks, and "All N tracks"), moved through with the arrows; `↵` opens a search pane (the result's table under a strip of its people and releases); a person or release hit opens its pane, and a track plays from its row in the result. In any table the album cell opens the release and the artist cell the person; `⌘↵` opens the selected row's release. A release pane: idiom, year, tracks, discs, length and formats (the best copy, then "also MP3"), Play, the written credit with each person in it openable, credits (each album artist, then each track artist with the tracks they're on; a compilation's fold after eight) and the tracklist, which plays from a clicked row. A person pane: their releases, other people's they're on (joint credits included), and who they worked with, each a thread. The status line with scan progress. Now: playing or paused, the title, previous, play or pause and next (off until something has been queued), the time, a seek bar that re-anchors the clock on release, a bare dial (minute ticks, the played arc, the hand) with the cover at its centre, the signal path, Up next (the queue after the playing item, eight rows and "N more", refetched when the item changes, "then stop" at the end) and the device's volume (disabled with the reason when the device has none); the Now bar carries the transport, the title, and from 560 px the seek bar and from 760 the volume, and its title opens the full pane as a sheet; brushable histogram headers. The Front from real data: the collection by idiom and by format, added lately (each opens its release), needs you, folders, and an add-folder door when the library is empty; every line with a query starts a trail at it. The table pane (plate 04) with paged rows from the core: the idiom → people → releases column browser across the top, whose entries write the query; grouped by release by default, each group a header with its 18 px cover, track count, album artist, year, length and formats; headers that sort ascending, descending, then back to library order, with numbers in names compared by value; the playing row lit; Enter or a double-click to play from the row in the order shown, and adding a music folder. The light: whatever is playing lends its cover's clamped colour to the playing rows, the progress line and the body, and brass otherwise; the release pane shows its cover. `⌘1` brings back the Front. Setup ([stories.md](stories.md)): the empty Front offers the folders Meret found, a folder picker, Connect a service and a Bring your history placeholder, beside outlines of Leads, Crates and trails, and Pick up; Settings (`⌘,` or the app menu) is a window-styled panel over the surface with Folders (add, remove), Sources, Playback (output device and exclusive mode, applied at once when idle, on resume when paused and otherwise from the next track; device volume), Lookups, Files, History, Devices and Light (off, accent, accent and wash); a source or the scan in the status line opens a popover with its state and Open in Settings | Works, contexts, crates and leads as panes; leads, crates and kept trails on the Front; in the table, grouping by work or person, columns that follow the idiom, plays sparklines, and a brushed histogram that adds its clause instead of replacing the pane's query; covers on the Front; the body summary in Now's dial; keys for previous and next; the sky; fonts; menu bar and Media3 glue |

Covers come from the first present track's embedded front picture (or its first picture), then from its folder: `cover`, `folder`, `front`, `album`, `albumart`, then the first JPEG or PNG by name. Reading and rendering happen in parallel, outside the store writer; each chunk commits together. Original bytes determine the blake3 name in `art/`, with JPEGs at 64, 128, 256 and 512 px on the long edge, never upscaled. A release checked without a cover is not read again until a new or changed track is ingested; unchanged rescans write no art. The 64 px image feeds hue buckets in OKLab: the winning chroma-weighted colour is restrained to lightness 0.68–0.80 and chroma at most 0.14, gamut-mapped to sRGB, with wash and dim alpha 0x14 and 0x55. Grey or pale covers keep the instrument accent. Release pages and Now carry cover paths; Now also carries track and release ids and the light tokens. `meret library rescan` reports cover reads and new files, including the startup scan.

Measured so far: through the MacBook Pro speakers, 16/44.1 and 24/96 FLAC play bit-perfect (the speakers switch to 96 kHz and back to 48 afterwards), 8 s of audio takes 8.3 s of wall clock including the device open, and sends 2–5 anchors; the null output sends **one** for a 6-second file; decoding runs at 1,200–2,600× real time; the core cross-compiles for `aarch64-linux-android`. Scanning 928 files (3.7 GB, mostly AAC and Vorbis) into an empty store takes 0.1 s, and rescanning them unchanged takes 9 ms. A page of 50 rows comes back in about 0.1 ms. Through the Studio Display speakers, six tracks of a 16/44.1 FLAC album played through the queue, bit-perfect in hog mode. Every join came as Ended then Started, and the device started each track within 0.02 ms of the previous one's last frame (−0.24 ms after a full 82-second track, inside the anchors' 2 ms tolerance). There was no reopen and no gap.

Output routing, 2026-10-17, on the Studio Display: with the system default chosen and exclusive mode on, playing the Tyranny release through the core alternated MP3 and FLAC copies (both 44.1 kHz), and each change of source format reopened the device. While Meret held the Studio Display, macOS moved its default output to the MacBook Pro speakers, so a reopen that looked up the default again moved playback to them, and the volume keys controlled the speakers instead of the display. Keeping the device chosen when playback starts fixed the routing: every reopen stayed on the Studio Display. Its volume reads and sets in steps (0.24 reads back as 0.2383). With the copies merged, the same release opens the device once.

Search, on the 1,014-track library: each keystroke's hits come back in 0.1–7 ms, the slowest being the first letter. On a synthetic million-row `search` table, a word of three or more letters takes 0.15–0.33 s when it matches a third of the rows and less as it gets rarer; a one- or two-letter word scans the table in about 0.43 s.

## Working on it

```
cargo test --workspace                       # the core
cargo run -p meret-cli --release -- decode some.flac
cargo run -p meret-cli --release -- devices
cargo run -p meret-cli --release -- play some.flac          # default device, hog mode; --shared, --device UID, --null --speed 20
cargo run -p meret-cli --release -- scan ~/Music --stat-only

# The library, through meret-api. --data defaults to the app's own directory
# (~/Library/Application Support/io.sowilo.meret), so the CLI and the app share one library.
cargo run -p meret-cli --release -- library add ~/Music            # scan a root into the store, with progress
cargo run -p meret-cli --release -- library ls 'year:1990s' --limit 20
cargo run -p meret-cli --release -- library front                 # the Front as text: idioms, formats, added lately, needs you
cargo run -p meret-cli --release -- library search 'baldur gate'   # the query line's hits, timing every prefix as if typed
cargo run -p meret-cli --release -- library walk 'civ' 0 1          # open hit 0, then that pane's thread 1; prints each pane and the trail
cargo run -p meret-cli --release -- library walk 'civ' 0 search=iona '[' ']'   # a second trail, then back into the first and forward again
cargo run -p meret-cli --release -- library volume [0.4]          # read, or set, the output device's own volume
cargo run -p meret-cli --release -- library play 'format:flac' --from 3 --count 5 --tail 6   # times every join
cargo run -p meret-cli --release -- library history            # every listen, newest first, ✓ when it counted as a play
cargo run -p meret-cli --release -- library resume             # releases partway through, with the recording and position
cargo run -p meret-cli --release -- library now                # Now as the app would open it: paused at the saved position
cargo run -p meret-cli --release -- library trails             # saved trails, newest first; `library walk '['` steps into the last

cd apps/meret
flutter test                                 # bridge tests need: cargo build -p meret-ffi
flutter run -d macos --dart-define=MERET_FAKE=true   # mock data, no Rust
flutter_rust_bridge_codegen generate         # after changing crates/meret-ffi/src/api
```

`library play` prints Started and Ended in the order the engine sent them. For each join it also prints the gap between where the device put the last frame of one track and the first frame of the next, worked out from the anchors. `--tail N` seeks into each track's last N seconds, so an album's joins can be heard in a minute.

The macOS app isn't sandboxed (decided 2026-10-13). Like most audiophile players sold outside the App Store, it reads music folders anywhere directly, so there are no security-scoped bookmarks to keep. The folder picker is `file_selector`.

Each debug rebuild re-signs the app, so macOS asks again whether it may access the Music library. The startup scan waits on that prompt, and the status line shows "scanning 0 of 0" until it's answered.

Building the app needs Xcode on macOS and a JDK on Android. CocoaPods is not needed. `apps/meret/hook/build.dart` is a native-assets build hook: it compiles `crates/meret-ffi` for whichever target Flutter asks for, and Flutter bundles the library. Plugins come through Swift Package Manager (`enable-swift-package-manager` in the pubspec). The hook requires a pinned toolchain, so `rust-toolchain.toml` names an exact version. `crates/meret-ffi/rust-toolchain.toml` is a symlink to it; bump the version there.

## Licences to watch

Fine for personal use; they matter before distributing anything.

| Dependency | Licence | Note |
|---|---|---|
| Essentia | AGPL-3.0 | Its trained models are CC BY-NC-SA. Keep it behind a feature flag or replace it |
| libgme | LGPL | Dynamic linking |
| FFmpeg | LGPL or GPL by build | Fallback decoder only, behind a feature flag |
| Chromaprint | LGPL | `rusty-chromaprint` is an MIT port |

## Order of work

Completed steps below record the sequence of development, not necessarily the current interface. See [State of the scaffold](#state-of-the-scaffold) for implementation status.

1. **Spikes, to test the decisions.** (a) Flutter: a million-row virtual table, 100,000 stars and the body painter, measured in DevTools on a ProMotion Mac and a 120 Hz Android phone. (b) The engine: gapless FLAC through the CoreAudio HAL with hog mode and rate switching. The engine side is done, including a gapless album through the queue on a real device; a USB DAC still has to prove integer formats. These two gate the stack.
2. **The iTunes core.** Library, store, hot columns, the table pane, local playback and the transport on the Mac work end to end. Left: FSEvents, the menu bar.

   Getting from an empty window to the music you want comes next, in four slices (decided 2026-10-13). Each ends with something usable and adds one way in:

   1. **A shell with only real content.** Done. The real core shows no placeholder panes. With nothing to resume, Meret opens to the Front, and the Front shows only what the library can answer: the collection by idiom and by format, added lately, needs you (unreadable and untagged files), and a door to add a folder. Idioms come from cheap signals at scan time: chiptune formats, genre tags, and tracks over 40 minutes. The trail strip starts at "Front · no trail yet", and the query line runs searches.
   2. **Search.** Done. The scan fills the FTS5 `search` table. The planner answers text clauses from it and intersects them with the column bitmaps. Typing shows people, releases and tracks as you type, grouped by kind, and `↵` opens a search pane that starts a trail.
   3. **Release and person panes.** Done. A row or a hit opens a release (tracklist, edition, format, play) or a person (releases by role) to the right, and the trail records it. Threads come from local credits only for now: *by*, *album artist*, *on*.
   4. **Browsing like iTunes.** Done. Rows grouped by release, sorting by column, and an artist → album column browser over facet counts. Cover art is read during the scan, and it also feeds the light.

   Then the UX plan of 2026-10-17, in slices: **A** transport, seek and Up next in Now, pinned from 1400 px (done); **B** memory in the core: listens, resume and the queue, trails across restarts (done; the UI only shows Now paused and `[` into the last trail); **C** Meret opens to Now paused where you left it, with Pick up, What was that? and Up next, the Front gains Kept trails, Pick up, Most played and Dormant, ⌘S keeps a trail and ⌥Space starts from the top; **D** the pane row as plate 01 draws it (the Front behind ⌘1 when a trail is open, spines, pane facts and actions); **E** Play something (⇧Space) with its why, and Play on; **F** the menu bar item and media keys.
3. **Trails.** Panes, threads from MusicBrainz and VGMdb, trees, the Front.
4. **Analysis and the sky.** Loudness, DR, the body, embeddings, placement, leads.
5. **Android.** AAudio, the Media3 service, the satellite sync, hand-off.
6. **The rest of the integrations.** Music Assistant, Roon, Spotify Connect, ListenBrainz, Bandcamp, YouTube.

## Open

1. Does the phone replicate the whole library's metadata (around 1 GB for a million tracks), or only what it holds plus what you've recently touched?
2. Is remote playback from the hub to the phone (streaming the Mac's files, transcoded when off Wi-Fi) in scope, or only control plus local copies?
3. Which embedding model? It decides `sounds like`, the sky and the licence story.
4. Where do backups go? Trails, notes and sky positions are irreplaceable; the rest can be rebuilt.
