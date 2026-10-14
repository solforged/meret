# Idioms

Draft, 2026-10-13. How Meret treats different kinds of music without flattening them into one shape.

Plates: [`design/2026-10-13-idioms/`](../design/2026-10-13-idioms/index.html), one release page per idiom on a shared shell.

## The problem

One grammar for all music gets most of it wrong. A classical work, a country song, a jazz session, a game cue and a DJ mix differ in their unit of listening, their credits, what counts as "another version", and how they should play. Genre labels alone don't capture that; they are too many and too fuzzy.

An **idiom** is a small bundle of rules that does capture it: the unit, the credits that matter, what you compare, how playback behaves, which drawing describes it, and a light typographic register. Every release gets one idiom (sometimes two), assigned automatically and overridable. Seven cover nearly everything one person listens to.

## Shared primitives

Every idiom uses these. The idioms decide which of them to put forward.

| Primitive | Meaning |
|---|---|
| Work | A composition: a song, a movement, a cue, a standard |
| Recording | One captured performance of a work |
| Edition | One published form of a release: a remaster, a pressing, a regional CD, a hi-res reissue. Meret needs these, not just releases, because audiophiles compare masterings |
| Track | A recording's place on an edition |
| Credit | A person or group and their role |
| Context | Where a recording is heard: a scene, a level, a show, a set |
| Source | Where the bytes come from, with format and quality |
| Signal path | Source → decode → DSP → output, with what each step does to the audio. Always visible, not a footnote |
| Listen | One play, with when, where and how much |
| Note | Yours, attached to any of the above, or to a moment in time |

Audiophile facts are first-class on editions and sources: lossless or not, bit depth and sample rate, dynamic range (per edition, from local analysis or the Dynamic Range Database), whether a rip is verified (AccurateRip or CUETools logs), and loudness for ReplayGain.

## The seven idioms

| | Unit | Credits up front | You compare | Playback rules | The Body drawing |
|---|---|---|---|---|---|
| **Album** (rock, pop, metal, indie, hip hop) | The album, then the track | Band or artist; producer and engineer one level down | **Editions and masterings**: original CD vs 2009 remaster vs vinyl rip, with dynamic range side by side. Samples and interpolations for hip hop | Gapless within an album; album ReplayGain; shuffle by album as an option | Song structure (intro, verse, chorus, bridge, from analysis) over loudness |
| **Song** (country, folk, singer-songwriter, standards-based pop) | The song as a work | **Songwriters** beside the performer; session players | **Every recording of the song**: the writer's demo, the hit, covers, live versions | Track ReplayGain; shuffle is natural | Lyrics laid out by section, synced where available |
| **Work** (classical, opera, early music) | The work and its movements | Composer, then performers, conductor, ensemble, soloists | **Recordings of the work**, by tempo per movement | Never shuffle inside a work; gapless across movements; queue whole works | Movements as segments with tempo markings; your recordings' timings aligned |
| **Session** (jazz, much blues) | The session date, then the tune | **Personnel per track**, leader first; date and studio | Takes and alternates; versions of a standard across sessions | Gapless for live dates | Who plays when: solo order across the tune's form, where data or your notes provide it |
| **Score** (game, film, TV, anime) | The cue, placed in its context | Composer, arranger; game or film, developer, platform | OST vs in-game rip vs remaster vs arrangement vs orchestral concert | **Loop-aware**: intro, loop, loop, fade, or loop indefinitely. Native chiptune formats (SPC, NSF, VGM and others) play through emulation | Loop structure, with the context (area, scene, boss) as the label |
| **Set** (DJ mixes, live sets, ambient long-form, jam bands) | The whole set, with cue points | DJ or band; the tracks inside | The same song across shows; the same set across sources | **Strictly gapless**; seek by cue point; never split | Tempo and key across the set, with track boundaries |
| **Spoken** (podcasts, audiobooks, lectures) | The episode or chapter | Host, guests, author, narrator | Rarely compared | Speed, skip silence, resume position, sleep timer; no album gain | Chapters as rings, the transcript as margin notes (plate 04) |

Hip hop sits under Album, with lineage (samples, interpolations) put forward. A release can carry two idioms: a jazz album is Session and Album; a concert film's audio is Set and Score.

## Assigning an idiom without a crowd

In order of precedence:

1. **Your override**, per release or per artist.
2. **MusicBrainz genres** on the release group. These are curated from community tags and cover most catalogued music.
3. **Local audio classification.** Essentia's Discogs-trained models label audio with about 400 Discogs styles and need no catalog entry, which matters for obscure rips. A table maps styles to idioms.
4. **Structural signals.** Chiptune formats, VGMdb matches, podcast feeds, cue sheets and tracks over 40 minutes each imply an idiom on their own.

ListenBrainz helps with taste and similarity (your history, similar artists and recordings) more than with idiom.

## Where the idiom-specific data comes from

Each idiom must work from public data and local analysis alone, with your notes on top. No crowd is required.

| Idiom | Data |
|---|---|
| Album | MusicBrainz editions; Discogs pressings; Dynamic Range Database; local loudness and DR |
| Song | MusicBrainz work and writer relationships; LRCLIB for synced lyrics |
| Work | MusicBrainz works and parts; Open Opus for composers and periods |
| Session | Discogs and MusicBrainz personnel and recording dates |
| Score | VGMdb track lists and arrangers; loop points from native formats or detected locally; context from your notes and, later, wiki extraction |
| Set | Cue sheets; Internet Archive's Live Music Archive for show recordings |
| Spoken | Podcasting 2.0 feed tags for chapters and transcripts; local speech-to-text when a feed has none |

Context for game music ("where it plays") is the one field that truly needs people. Start with VGMdb's track notes and your own notes; consider a shared, opt-in context file per soundtrack later.

## How the idiom flavours the app

Subtly, and in three layers. Each is optional and isolated in tokens.

1. **Structure (always).** The idiom decides what the release page leads with: editions for Album, writers for Song, recordings for Work, personnel for Session, contexts for Score. This is the main flavour, and it's functional.
2. **Register (light).** Idioms adjust titles and numerals only. Work might use an engraved serif for work titles and roman movement numerals; Score might use monospaced cue numbers and loop marks; Session might set dates and matrix numbers prominently. Body text, controls and the signal path never change.
3. **Light (from the cover).** The accent colour, clamped as before.

The sky becomes a surface you visit, not the frame of the app: a map of your library by sound, for memory and discovery. Home is the queue, now playing and the signal path.

Navigation is in [navigation.md](navigation.md): panes, threads and trails replace the tabs and sidebar shown on the idiom plates.

## Open

1. Is seven the right number? Electronic music that isn't a Set (a single or an EP) may want its own idiom, built around BPM and key.
2. Which idioms come first? Probably Score, Work and Album: your rarest needs, the hardest model, and the most common case.
3. How should a release with two idioms choose which structure leads?
