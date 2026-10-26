# Navigation

> **Design specification.** This document includes planned behavior as well as implemented navigation. For what is built and what is missing, see [Architecture](architecture.md#state-of-the-scaffold).

Draft, 2026-10-13. Sol: "this is it" for the trail model. Plates: `design/2026-10-13-trails/` (01 trail, 02 Front, 03 phone and foldable, 04 table, 05 sky, 06–08 forks, 09–11 press play and resume, 12 habits). Revised 2026-10-23 after driving the build: Home, the pane row and the chrome. Plates: `design/2026-10-23-navigation/` (01 Home, 02 a trail with its threads drawn, 03 and 09 motion demos, 04 chrome, 06 Home's states and doors, 07 a day of trails, 08 every move). Renders of both sets are in [plates.md](plates.md).

## What was wrong

The idiom plates used a website shell: top tabs (Home, Library, Map), a sidebar of places (library sections, Sources, Unmatched), and a page in the middle. That shell is built for filing, not listening. Sources and Unmatched are plumbing, and they had become destinations. Nothing in the shell helped you find music.

Every current app gets part of this right:

| App | Right | Wrong |
|---|---|---|
| iTunes | One big table; column browser; smart playlists as rules; the library is the app | Discovery meant the store |
| Roon | Every credit is a link, so you wander | Wandering leaves no trace; heavy chrome; its data is licensed |
| Plexamp | Sane on a phone; radio drawn from your own library | Built around one screen; thin on a large one |
| Spotify, YouTube Music, Apple Music | Fast search; discovery feeds | The feed decides; the library is a sidebar list; desktop is a stretched phone |
| foobar, Winamp | Dense; yours | A widget, not a place |

U.S. Graphics' principles fit the large screen: dense, not sparse; expose state and inner workings; flat, not hierarchical; verbosity over opacity; don't infantilize users.

## The model: trails

There are no pages to file things into. There is one surface.

- **Pane.** Everything you open (a release, a person, a work, a crate, a search, the collection table) is a pane. It opens to the right of the pane you opened it from. A large screen shows four or five panes side by side, a laptop two or three, an unfolded foldable two, a phone one. Older panes fold to spines.
- **Thread.** A labelled relation between two things: *composed by*, *sung by*, *member of*, *recording of*, *sampled*, *same session*, *sounds like*, *listened after*. Every thread names its source (MusicBrainz, VGMdb, Discogs, local audio, ListenBrainz, you). Following one opens a pane, and the pane says which thread brought you.
- **Trail.** The row of panes you followed. Each pane's header is its star, and the thread you followed is drawn from the row you clicked to the pane it opened (decided 2026-10-23; the separate strip across the top is gone, and the tree view keeps the whole constellation). This is where the galaxy idea survives: a constellation is lines you draw between stars yourself. Trails are kept automatically, can be named, and can be **played** (the queue walks the trail).
- **Query line.** `/` searches everything you own, can stream or have found, in one list, and takes commands (`play`, `want`, `crate add`). Saved queries are smart crates.
- **Home.** Where trails start: a column of doors at the left edge, folding to a rail inside a trail. It replaced the Front and the Now stage on 2026-10-23. See [Home](#home).
- **Now.** The transport, title, scrubber and quality marks sit in an LCD at the top centre at every desktop width (iTunes' place). The Now panel (the playing body, the signal path and the queue) opens from it or with `N`, and is pinned by default from 1800 pt. Phones keep a player bar under the thumb.
- **Activity.** One indicator in the top line, replacing the status line on 2026-10-23. It is a dot while every source is fine, a ring while a job runs, and amber when something needs you. Its popover lists sources, folders, jobs and guesses, and opens Settings. There is no bottom row on desktop.

Keyboard: `/` search, `[` `]` move along the trail, `⌘↵` follow, `W` want, `C` crate, `⌘S` keep the trail, `⌘1` Home, `N` Now. Key hints live in the menu bar (Go and Controls menus), a `?` sheet and tooltips, not on screen.

## Home

Decided 2026-10-23 (plates 01, 06, 07). Sol: "Home as a column feels right." It isn't a sidebar of places: every entry is a door that opens a pane, and plumbing stays out of it.

- **Three states.** A 248 pt column when nothing is open, beside Today. A 52 pt rail inside a trail, with the door the trail started from lit. The column laid over the trail with `⌘1` or `◐`: the panes dim and never move. `Esc`, `]` or a click on a pane closes it. From 2200 pt the column can stay open as a setting.
- **Today** is Home's own page, not a trail stop: Resume first, then Play something with its reasons, partway through, added lately and your week. Meret opens here. Opening something from Today starts a trail whose first pane says so ("from Today · added lately").
- **Doors start trees.** A door starts a new tree, as a search does, and the old tree moves to Trails, one `[` away. Doors never fork the current tree. The tree and its first pane take the door's name (All tracks, Scores), not its query, and a row opened from a search's table is *found* by it.
- **Sections are fixed:** Listen (Today, Pick up, Play something), Library (All tracks, then one row per idiom you own, People, Games), Crates, Trails, Out there (Leads, Wants, Needs you). Crates and trails can be pinned and reordered. Needs you shows only while it isn't zero. Folders, sources and jobs never get a door; they live in the activity popover and Settings.
- **Keys.** `⌘1`–`⌘9` go to the first nine doors in order.

## The pane row

Decided 2026-10-23 (plates 03, 08, 09). One rule: only the thing that changed moves. A pane enters, a branch leaves, or the window shifts by whole panes. The row never slides as a block.

- **What the row shows:** the path (root to current) plus the stops ahead, the chain of most recently entered children that `]` would walk. Stops ahead are dimmed. `[` moves focus and dims; it never removes a pane. A click anywhere on a dimmed pane goes to its stop, as a spine does; nothing inside it takes the click.
- **Widths.** A pane's width depends only on the row's width: as many 440–560 pt panes as fit with one spine's room kept back, capped by the width class (about 560 pt at 1728). So a pane never resizes when a neighbour opens, and pinning Now costs one pane, not a reshuffle. A wide pane (the table) takes the leftover room and gives some back when a pane opens after it, the one time a pane changes width.
- **Spines on both sides.** Stops before the window fold to 46 pt spines on the left, and stops ahead of it fold on the right; when there isn't room for every spine, the ones nearest the window show. The window only shifts when the focused pane would fall outside it, and only far enough to fit it. A resize fits it afresh, keeping as much of the path in view as it can.
- **The ghost slot** shows where the next pane will open, while the last stop is in the window and at least 140 pt are left over.
- **Threads look like threads.** Followable rows end in an arrow, and `←` marks where you came from.

| Move | Motion |
|---|---|
| Follow | The new pane fades in from 12 pt to the left, 160 ms ease-out. Nothing else moves |
| Follow past the window | The oldest full pane folds to a spine and the rest shift by its width, 200 ms, then the new pane enters |
| `[` `]` within the window | Focus moves and panes dim or brighten, 120 ms |
| `[` past the window, or a spine | The window shifts by whole panes, 200 ms |
| Fork, peek, prune | The panes ahead drop 16 pt and fade, 160 ms; a new pane enters 120 ms later |
| `⌥[` `⌥]` | The panes after the fork swap vertically (`⌥]` brings the next branch up from below), 180 ms |
| New tree, previous tree, the tree view | The page fades through, 100 ms out and 100 ms in |
| `⌘1` | The Home column slides over the rail, 200 ms; panes dim |
| `N` | Now slides in from the right; a covered pane folds to a spine in the same move |

## Discovery primitives

These join the shared primitives in [idioms.md](idioms.md):

| Primitive | Meaning |
|---|---|
| Thread | A typed, sourced relation you can follow |
| Trail | A path of followed threads; kept, named, playable |
| Lead | Something you haven't heard, with the thread or threads that produced it. A lead that several threads converge on is a strong one, and Meret says so |
| Want | A lead you mean to own; Meret watches for it in shops and on Discogs |
| Crate | A hand-made set of anything, owned or not. Ordered crates are playlists; rule crates are smart playlists |
| Dormant | Something you loved and stopped playing. Rediscovery is discovery |

Leads come from: people you follow, the rest of what you own (other editions, the arranged album, the audience tape), crawls of your YouTube likes and Bandcamp, sound similarity to this week's listening, other recordings of works you love, and ListenBrainz neighbours.

## What replaces Sources and Unmatched

- **Availability is a mark on every row.** Filled: own, lossless. Half: own, lossy. Ringed: stream, with a service code (sp, qb, yt, bc, ia). Dashed: known, nowhere to hear yet. A pane shows "where to hear it" when that matters, such as for a lead. Connections live in the activity popover and settings.
- **Identity is a mark too.** `≈` means guessed. You fix it where you see it. The activity indicator counts the guesses, and Home's Needs you door offers batch fixes (for example, sending 41 game rips to MusicBrainz's editor).

## Forks: trails are trees

Decided 2026-10-13: a trail is a tree. Plates 06–08.

- **Branching.** Following a thread from any pane except the last starts a branch. Nothing is thrown away.
- **Panes show one branch:** the path from the root to where you are, plus the stops ahead of you on it (dimmed; decided 2026-10-23). The tree view (`T`) shows the whole tree: the current branch on the main line in gold, earlier branches above and below in grey, each fork ringed.
- **Forks are visible in the panes too.** A pane you forked from says so ("Forks here", with each branch, its time and what happened on it). A thread you've already followed carries `⑂ → where it led`.
- **Peeks fold away.** A stop you leave within a few seconds is a peek. It folds into a tick, so browsing doesn't fill the tree with stubs.
- **Branches meet.** When two branches reach the same thing, or close neighbours on the sky, a dotted line joins them. Two independent routes to one place make that place a strong lead.
- **Keeping and pruning.** Keeping a trail keeps the whole tree. A branch you did something on (played, wanted, crated, noted) is always kept with it. A branch with nothing on it can be pruned with `⌘⌫`.
- **Playing.** Play this branch, or play the whole tree depth first.
- **Keys.** `[` `]` move along this branch. `⌥[` `⌥]` switch to a sibling branch at the nearest fork. `T` opens the whole tree as a pane, with a table of branches and the same tree drawn on the sky.
- **A search ends a trail.** Decided 2026-10-13. Running a search from the query line starts a new tree, rooted at that search, and the old trail is kept as it was. Nothing else ends a trail: not time, not idle, not the Front, and not filtering inside a pane (brushing a table column, lassoing the sky). `[` from the first stop of a new trail steps back into the previous one.
- **Phone.** The trail chip shows only the current branch, with ringed stars and stubs at forks. Long-press a fork for a sheet of its branches.

## Press play and resume

Plates 09–11. Most sessions are "press play", so playing never goes through a trail.

- **Meret opens to Today** (decided 2026-10-23; it was the Now stage), with Resume at the top, paused where you left it. `Space` resumes. `⌥Space` starts the current piece from the top. `[` steps back into the last trail. Pressing play never starts or changes a trail.
- **Pick up where you left off.** Everything you were partway through is listed, and each resumes the way its music does:

| Idiom | Resumes |
|---|---|
| Album | From the top of the track you were on |
| Song | From the top of the song |
| Work | From the start of the movement, never mid-movement |
| Session | From the top of the take |
| Score | The cue where it stopped, loop count kept |
| Set | The exact second; a set has no track boundaries worth snapping to |
| Spoken | Five seconds back from where you stopped, at your speed |

- **Play something** (`⇧Space`, or `Space` when there's nothing to resume) always says why it chose what it did. Picks are ranked: your habit for this day and time (a crate you play on most Tuesday evenings), something dormant, then the region of the sky your latest trail ended in, mixed with leads.
- **When the queue ends**, the idiom decides by default. An album or score you were exploring stops; a podcast moves on to the next unplayed episode; radio only starts if you asked for it.
- **What was that?** The last few plays, with times, sit under Now. `H` opens the full history.
- **Play on.** Every zone (this Mac, Roon, Sonos and AirPlay through Music Assistant, Spotify Connect, your phone) is listed with what it does to the sound: bit-perfect, resampled, lossy, delayed.
- **Outside the app.** A menu bar item shows the title and time. Its panel has the controls, the signal path, three things to pick up, and play something. Media keys work without opening anything. On phones Meret fills the system player and adds one "pick up" widget; it doesn't redraw the lock screen.
- **Hand-off.** Open the phone and Now offers "Continue from the Mac at 3:47". The phone plays its own copy if it has one, otherwise it controls the Mac.

## Habits

Plate 12, opened from "why this?" on a Play something pick.

- **What counts.** The same kind of thing in the same window (±1 hour) on 4 of the last 6 weeks, at least 30 minutes each time. "The same kind of thing" can be one crate, or a description ("instrumental scores and ambient over 40 minutes, no vocals").
- **States.** *Forming* (3 of 6 weeks, not used yet), *habit*, *yours* (made by hand, so it needs no evidence) and *turned down*.
- **What a habit may do.** It ranks Play something, and says so. It never starts playback, changes a trail or moves a lead.
- **Fading.** Miss 4 weeks in a row and a habit drops to forming. Miss another 4 and it's gone, without asking.
- **Saying no.** "Not a habit" removes the habit, not the music, and Meret doesn't suggest it again. You can narrow a habit instead ("only Tuesdays") or pause it.
- **Phases are separate.** A short obsession (14 plays this week) or a new purchase is a phase. It lifts "this week" picks for about three weeks, then fades, and never becomes a habit by itself.
- **Shared speakers.** Plays started outside Meret, or on a zone other people use, count only once you say they're yours.
- **Per device.** Decided 2026-10-13: habits stay on the device that formed them and never sync. The Mac's habits and the phone's (commutes, runs) are different lives.
- **Privacy.** Habits are computed and stored on your machine from time, day, device and zone. Location is never used.
- **Drawing.** A week dial in the same grammar as the body drawing: rings are days, angle is the hour, brightness is listening, habits are lettered outlines keyed to cards.

## The table

iTunes' one big table, as a pane like any other (plate 04). An empty query or `⌘L` opens it; any search can be opened as a table with `↵`.

- **Facets across the top**, as in iTunes' column browser: idiom, people in any role, games and films and labels, format.
- **Every numeric column header is a histogram** of that column's values: year, length, dynamic range, plays, last played, added. Brushing one filters the table and writes the query (`last:30d`). The header shows the shape of your library before you filter it.
- **Rows group** by release, work or person. Grouped by work, every recording of BWV 988 sits together.
- **Columns follow the idiom.** Filter to Works and they become composer, work, performers, conductor and recorded date. Filter to Scores and they become game, platform, where it plays and loop. The idiom's type register applies, so work titles are set in the serif and movements in roman numerals.
- **Plays carry a sparkline** of the last 16 weeks, and availability and identity marks sit on every row as elsewhere.
- **Opening a row continues the trail**, so the table is a starting point, not a dead end.

## The sky

The galaxy comes back as the map the trail is drawn on (plate 05). Press `M` and the trail's constellation unfolds onto your library, placed by sound.

- **Stars are tracks or releases**, placed by a local audio embedding, sized by plays and brightened by recent listening. Leads are hollow stars.
- **People are rings** around their work, not points. A person has no single sound.
- **Lines are trails**: the current one in gold, kept ones faint. A trail that jumps between regions (game scores to Celtic music) shows the jump.
- **Lasso a region** to get a selection, which can open as a table, become a crate or play.
- **Positions are stable.** New tracks settle in and old ones don't move, so the map becomes something you remember. Spoken word stays off it.

The table and the sky are two views of the same query: `↵` opens a search as a table, `⌘↵` as a sky.

## How it scales

| Surface | Home | Panes | Trail | Query | Now |
|---|---|---|---|---|---|
| Large desktop (2560+) | Column can stay open | 4–5, plus spines | Pane headers, threads drawn; chip | Top line | LCD; panel pinned |
| Laptop (1440) | Rail | 2–3, plus spines | Pane headers, threads drawn; chip | Top line | LCD; panel on `N` |
| Foldable, open | Rail | 2: where you came from, where you are | Chip | Bottom, beside the player | Bar |
| Phone, foldable cover | A sheet from the chip | 1; swipe sideways along the trail | Chip: stars only, current name | Bottom, under the thumb | Bar above the query |

## Open

1. ~~Does the Front stay fixed, or can you arrange it?~~ Decided 2026-10-23: Home's sections are fixed; crates and trails inside them can be pinned and reordered.
2. Should a kept trail be shareable (a file, or a ListenBrainz playlist with the threads as annotations)?
3. ~~On a laptop, does Now take a pane or collapse to a bar?~~ Decided 2026-10-17: a pinned pane, a bar below it; the pin moved from 1400 to 1560 px on 2026-10-23. Superseded 2026-10-23: the transport is the top line's LCD at every width, and the Now panel is pinned by default from 1800 pt.
4. Long trails: ~~when do old stops fold to spines~~ (decided 2026-10-17, revised 2026-10-23: a pane's width depends only on the row's width, 440–560 px, and stops outside the window fold to 46 px spines on either side, up to the width class's cap of 3 or 5 panes), and how deep can the tree view draw a tree before it collapses older branches?
5. How is the sky laid out (UMAP or similar over embeddings) so that it stays put as the library grows?
