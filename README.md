# Meret

Meret is a music player for one person's library. You open a release, a person or a work, and each thread you follow (*composed by*, *sung by*, *member of*, *soundtrack of*) opens the next pane beside it. The row of panes is a trail; trails branch into trees, are kept, and can be played. Underneath is a Rust core that plays files bit-perfect and gapless and says exactly what it does to the sound.

Meret is named for the Egyptian goddess of song, who in some accounts sets the cosmos in order with music.

## Status

Early and macOS only. The Flutter app over the Rust core works end to end on a real library:

- Scanning folders, with FSEvents watching, tags, credits, works and cover art; copies of one track in several formats merge into one track with several sources.
- A query language for search and filtering (`composer:beethoven`, `year:1990s`, `format:flac`, `lufs:`), answered from full-text search and in-memory columns.
- Trails as trees: release, person, work and game panes, threads from tags, MusicBrainz and Wikidata, forks, `[` `]` along a branch, and trails kept across restarts.
- Playback through the CoreAudio HAL: gapless joins, rate switching, exclusive (hog) mode, and a signal path that computes whether output is bit-perfect.
- Home and Today, per-idiom resume (an album from the top of the track, a score at the exact second, spoken word five seconds back), Play something with its reason, and a menu bar item with media keys.
- Analysis as background jobs: EBU R128 loudness, true peak, dynamic range and the body drawing of each track.

Not built yet: the sky (the library placed by sound), embeddings and *sounds like*, leads, Android, and the streaming and zone integrations (Music Assistant, Roon, Spotify Connect, ListenBrainz). [Architecture](docs/architecture.md#state-of-the-scaffold) keeps the detailed state and the order of work.

## Design plates

These images are renders of the HTML design plates, with mock data and drawn covers, not screenshots of the app. The built app follows them where the docs say so. More are in [Design plates](docs/plates.md).

### Home

![Home: doors on the left and Today beside them, with a paused score cue, three picks with their reasons, partway tracks, recent additions and a week of listening](docs/images/home.png)

### A trail with its threads drawn

![A trail of three panes, from the Tyranny soundtrack to its composer Justin E. Bell to his Pillars of Eternity II soundtrack, joined by drawn threads](docs/images/trail-threads.png)

### The sky

![The library placed by sound as a field of stars, with one trail drawn across it and a lassoed selection](docs/images/sky.png)

## What it is for

- **Following music rather than filing it.** No tabs, sidebar or destinations. Every pane comes from the one before it, and the thread you followed stays drawn.
- **Each kind of music on its own terms.** Albums, songs, classical works, jazz sessions, game and film scores, live sets and spoken word differ in what they lead with, how they credit people and how they resume. See [Idioms](docs/idioms.md).
- **Works and recordings kept apart.** Gould 1955 and Gould 1981 are two readings of BWV 988, compared and never merged.
- **Truthful state.** Meret says when output is resampled or altered, how a track was matched (`≈` below the confidence threshold), and where every credit came from.
- **Your library as the hub.** Streaming services and other players are sources and outputs, not the centre.

## Principles

1. The core owns the truth; the UI draws it. Library, queue, trails and jobs live in Rust.
2. The UI never waits. Every call into the core is async, and animation runs from anchors the core sends, not per-frame queries.
3. Playback never depends on the UI. Closing the window doesn't stop the music.
4. Slow work is a job: resumable, rate-limited per host and visible in the activity indicator.
5. Every fact has a source. Providers emit claims, not rows, so a bad provider can be switched off without damage.

## Documents

- [Architecture](docs/architecture.md): crates, storage, the audio path, the Flutter UI, budgets, the state of the build and how to work on it.
- [Direction](docs/direction.md): what Meret is, the data model, sources and the look.
- [Navigation](docs/navigation.md): trails, panes, threads, Home and keys.
- [Idioms](docs/idioms.md): how different kinds of music are treated.
- [Stories](docs/stories.md): first launch, settings, sources and writing back to files.
- [Design plates](docs/plates.md): renders of the mockups.
- [App](apps/meret/README.md): notes on the Flutter app.

## Building

Meret needs macOS with Xcode, [Flutter](https://docs.flutter.dev/get-started) and Rust through rustup; `rust-toolchain.toml` pins the exact version the build uses. CocoaPods is not needed.

```sh
cargo test --workspace                 # the core
cargo run -p meret-cli --release -- library add ~/Music
cargo run -p meret-cli --release -- library ls 'year:1990s' --limit 20

cd apps/meret
flutter run -d macos                   # the app, building the Rust core through a native-assets hook
flutter run -d macos --dart-define=MERET_FAKE=true   # mock data, no Rust
```

`mise run install` builds the release app and installs it as `/Applications/Meret.app`. The CLI and the app share one library in `~/Library/Application Support/io.sowilo.meret`. [Working on it](docs/architecture.md#working-on-it) lists every CLI command.
