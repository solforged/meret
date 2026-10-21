# Stories

Draft, 2026-10-14. What a person does with Meret, from the first launch on, and where on the screen each thing happens. The plates show a library that already exists and services already connected; this file covers how someone gets there and where they look once they have. Read with [navigation.md](navigation.md) and [idioms.md](idioms.md).

Each story is marked:

- **Built**: works in the app today.
- **Placed**: a plate, a spec or a decision below says where it goes; not built.
- **Later**: placed and designed now, built late in the order of work.
- **Unplaced**: nothing says where it goes yet.

## The places on the screen

Desktop, macOS. Every story below happens in one of these, and each place answers one kind of question.

| Place | Where | Answers | Holds |
|---|---|---|---|
| Query line | Top, doubling as the title bar | "Take me to…", "Do…" | Search, commands (`play`, `want`, `crate add`) |
| Trail strip | Under the query line | "How did I get here?" | Stops, threads, branches, Keep |
| Panes | The middle | "What is this?" | The Front, tables, releases, people, works, crates, leads |
| Now | Pinned right, or a bar | "What's playing, and how?" | The body, signal path, transport, queue, history, zones |
| Status line | Bottom | "Is everything all right?" | Every source's state, running jobs, guesses to fix, files to write, keys |
| Settings | Its own window, `⌘,` | "How is Meret set up?" | Folders, sources, playback, lookups, files, history, devices, the light |
| Outside the window | Menu bar, media keys, system dialogs | "Control it without looking" | Transport, a short pick-up list |

## Decided

Decided 2026-10-14.

1. **Configuration lives in a Settings window** (`⌘,`), as on any Mac app. It never becomes a trail stop: the trail holds music. A status line item opens a small popover with its state and the common fix, and from there its section in Settings (Spotify's dot leads to Settings › Sources › Spotify; a job to its detail).
2. **First launch is doors, not a wizard.** The empty Front offers the folders Meret finds itself as one-click lines, then "connect a service" and "bring your history" below them. Nothing is required before the first scan. Output and online lookups are asked the first time they matter.
3. **Online lookups ask once.** Before matching sends tags or audio fingerprints to MusicBrainz or AcoustID, Meret asks, plainly, with what leaves the Mac. The answer lives in Settings › Lookups.
4. **Volume stays at the DAC.** Meret's own volume is off by default; turning it on is allowed, and the signal path then says the output is no longer bit-perfect.
5. **Meret's store is the main database, and changes propagate out to files** (see *Writing back to files*). Like beets: you correct things in Meret, and Meret writes tags and moves files to match.
6. **History import is designed now and built late.** Its doors and flow are placed (see *Bringing your history*); the importers come after the providers.
7. **The picks from the setup plates** ([`design/2026-10-14-setup/`](../design/2026-10-14-setup/index.html)):
   - The empty Front is the Front's own shape (plate f3): the doors fill the Collection column, and Leads, Crates and trails, and Pick up sit beside it as quiet outlines saying what will fill them.
   - The lookup question is a line in Needs you, with a reminder in the status line (f6). Matching waits until you answer; nothing interrupts.
   - Settings is one window with a section list on the left (s2).
   - Clicking a source's status line item opens a popover on it with the problem, a one-click fix and "Open in Settings" (c10).
   - Editing happens in place in the release pane for a few fields (w1), and in a tracks × fields sheet for many tracks at once (w2).
   - Tags are written on save, as beets does (w3); every batch can be undone.

## First launch

| Story | Where | State |
|---|---|---|
| I open Meret with nothing in it and see what to do first | The empty Front, shaped like the Front it becomes | Built |
| Meret finds my music without my hunting for it: `~/Music`, an Apple Music or iTunes library, mounted volumes and NAS shares | The empty Front, one line each, with counts once a quick look has run | Built |
| I see the scan working, and can start listening before it ends | Status line progress; the Front and table fill as batches commit | Built (progress) |
| I bring my history | The empty Front's "Bring your history"; Settings › History | Later |
| I choose where sound goes and whether Meret takes the device exclusively | Asked on the first play, in Now's signal path; Settings › Playback | Settings › Playback built; the first-play question isn't |
| I decide whether Meret may look my music up online | A line in Needs you before the first lookup, with a status line reminder; Settings › Lookups | Built for MusicBrainz lookups by ID (slice H) |
| I connect the services I pay for, now or later, without being forced through them | The empty Front's "Connect a service"; Settings › Sources | Doors built; every service says it's coming later |
| macOS asks for folder access and I understand why | Meret says why just before the system dialog | A suggested folder that macOS protects says so; the moment before the dialog isn't built |

## Every day

| Story | Where | State |
|---|---|---|
| I open Meret and carry on where I stopped | Now, paused at the position; `Space` | Built |
| I want music without choosing | `⇧Space` Play something, with why | Built (from listens and trails; habits and leads later) |
| I want one specific album, now | `/`, type, `↵` | Built |
| I browse the whole library as a table | `⌘L` or a Front door | Built |
| I wander from a credit to a person to their other work | Panes and threads; the strip | Built (local credits only) |
| I see what's next, and change it | Now, Up next | Built (shown; changing the queue isn't built) |
| I find out what played ten minutes ago | Now, "What was that?"; `H` for history | Built |
| I play on another speaker | Now, Play on | Built for this Mac's outputs; other zones later |
| I control playback while working in another app | Menu bar item, media keys | Built |
| I know whether I'm hearing it bit-perfect | Now, signal path | Built |
| I skip, go back, seek | Now, under the body; the bar on narrow windows | Built |
| I set the volume | Now's device-volume slider; at the DAC when the device has no settable volume | Built (device volume; samples stay untouched) |

## Keeping the collection

| Story | Where | State |
|---|---|---|
| I add or remove a folder, or an external drive comes and goes | Settings › Folders; the Front's Folders list adds | Built (drives coming and going are marked offline) |
| I see what Meret couldn't read | The Front, Needs you | Built |
| I fix a release Meret guessed wrong | The `≈` mark where I see it; the Front's Needs you for batches | Placed |
| I tell Meret what kind of music a release is (its idiom) | The release pane's header | Placed |
| Two rips of one album show once, and I pick which plays | The release pane; Needs you, "albums with two editions" | Built (copies show once; picking which plays isn't built) |
| I correct a title or credit, and my files follow | The release pane, in place for a few fields; an edit sheet for many tracks; see *Writing back to files* | Placed |
| My folders follow a naming scheme I choose | Settings › Files, a path template with a preview | Placed |
| I see what a long job is doing and pause it | The status line job opens its detail | Status line built |
| I move to a new Mac, or back up my trails and notes | Settings › Library | Unplaced |

## Writing back to files

Meret works like beets: its store is the main database, and your files are an output of it.

- **Every correction lands in the store first**, with *you* as its source, so it outranks any provider's claim and survives a rescan.
- **Each file knows whether its tags match the store**: in step, waiting to be written, or changed outside Meret.
- **Writing is a job.** Saving an edit queues its files, the status line shows them ("✎ 14 files to write"), and the job writes them in the background. Writing on save is the default; Settings › Files can hold writes until you say so.
- **Moving and renaming files always shows the plan first**: from, to, and what's in the way. The path template lives in Settings › Files.
- **Every write can be undone.** Meret keeps the tag values it replaced, per batch.
- **Changed on both sides** (you edited in Meret, and another app edited the file) goes to Needs you, showing both; you pick which wins.
- **Offline volumes and read-only folders wait.** Their writes stay queued until the volume is back or the folder is writable.

Open: which fields Meret writes (everything it reads, plus MusicBrainz IDs and the cover).

## Bringing your history

Designed now, built late. The doors exist from the start and say what they'll do once the importers land.

- **Doors.** The empty Front's "Bring your history", and Settings › History, list Apple Music (play counts, ratings, playlists, date added), Last.fm and ListenBrainz (every listen, with times).
- **Flow.** Pick a source, then sign in or point at the library. Meret matches what it finds and shows a preview first: how many plays matched tracks you own, how many are things you don't own (kept as listens of known recordings), and what becomes a crate. Importing is a job in the status line.
- **Afterwards.** The Front gains most played, dormant and pick up where you left off on the first day. Importing again adds only what's new.

## Sources and connections

| Story | Where | State |
|---|---|---|
| I connect Spotify (sign in through the browser) | Settings › Sources; the empty Front's "Connect a service" | Placed |
| I connect Music Assistant (found on the network, or a URL) | Settings › Sources | Placed |
| I let Meret control Roon (authorised inside Roon's own app) | Settings › Sources, which says where to look in Roon | Placed |
| I connect Bandcamp, YouTube, Qobuz (session-based, no public API) | Settings › Sources | Placed |
| I connect ListenBrainz or Last.fm to import and scrobble | Settings › Sources and Settings › History | Placed |
| I see at a glance whether every source is working | Status line dots, each opening a popover with its state | Built (local and MusicBrainz) |
| A token expires or a service rate-limits; I find out and fix it | The status line dot turns; clicking it opens a popover with the problem, a one-click fix and "Open in Settings" | Placed |
| I disconnect a service and its claims go with it | That source's section in Settings | Placed |
| I see where I can hear something I don't own | A pane's "Where to hear it" | Placed (plate 01) |

## Discovery and memory

Mostly placed by the plates; listed so the whole set is in one file.

| Story | Where | State |
|---|---|---|
| I see what's new for me, and why | The Front, Leads (`L`) | Placed |
| I mark something I want to own | `W` anywhere; the Front, Wants | Placed |
| I make a crate by hand, or from a rule | `C` / `⌘K`; the Front, Crates and trails | Placed |
| I keep a trail and come back to it | `⌘S`; the Front; `[` from a new root | Built |
| I see my library as a map | `M`, the sky | Placed (plate 05) |
| I check and refuse a habit | Play something's why → plate 12 | Placed |

## Other devices

| Story | Where | State |
|---|---|---|
| I pair my phone with the Mac | Settings › Devices | Placed |
| I choose what lives on the phone | Settings › Devices on the Mac; the phone's own settings | Placed |
| I pick up on the phone where the Mac stopped | Phone Now: "Continue from the Mac at 3:47" | Placed (plate 11) |

## Still open

1. Moving to a new Mac and backing up trails and notes: a Settings action, a file, or a sync between hubs.
2. Which fields Meret writes.
3. Where transport sits on the Front when nothing has played yet.
