# Design plates

The plates are static HTML mockups with drawn covers and mock data. They live in `design/`, which Git ignores; the images below are renders of them at their native sizes. The built app follows the plates but differs where building it changed a decision, and [navigation.md](navigation.md) and [architecture.md](architecture.md) record those changes.

With the plates checked out locally, serve them with `python3 -m http.server -d design`, or use the `plates` entry in `.claude/launch.json`.

| Set | Date | What it covers | Doc |
|---|---|---|---|
| `2026-10-23-navigation` | 2026-10-23 | Home, a trail with its threads drawn, motion, the top line, a day of trails | [navigation.md](navigation.md) |
| `2026-10-14-setup` | 2026-10-14 | First launch, Settings, sources, writing back to files | [stories.md](stories.md) |
| `2026-10-13-trails` | 2026-10-13 | Trails, the Front, phone and foldable, the table, the sky, forks, resume, outside the app, habits | [navigation.md](navigation.md) |
| `2026-10-13-idioms` | 2026-10-13 | One release page per idiom on a shared shell | [idioms.md](idioms.md) |
| `2026-10-13-spheres` | 2026-10-13 | The listening sky: galaxy, system and body | [direction.md](direction.md) |
| `2026-10-13-directions` | 2026-10-13 | Faceplate, Orrery and Liner, drawn on the same screen | [direction.md](direction.md) |
| `2026-10-13-first-light` | 2026-10-13 | The first plates: a strip comparison of recordings and clamping album colour | [direction.md](direction.md) |

## Navigation, 2026-10-23

### Home

Home is stop zero: doors on the left, Today beside them. Today offers what you left partway, a few picks to play with their reasons, what was added lately and your week.

![Home: the Home column with Listen, Library, Crates, Trails and Out there, beside Today with a paused score cue, three picks, partway tracks, recent additions and a week of listening](images/home.png)

### A trail with its threads drawn

Home folds to a rail. Each pane keeps one width, its header is its star, and the thread you followed runs from the row you clicked to the pane it opened.

![A trail of three panes: the Tyranny soundtrack, Justin E. Bell as its album artist, and the Pillars of Eternity II soundtrack he composed, joined by drawn threads](images/trail-threads.png)

## Trails, 2026-10-13

### A trail on a large screen

2560 × 1440. Corridors of Time, its composer, Xenogears, the singer of its two vocal tracks and her band, with Now pinned on the right.

![Four panes from Yasunori Mitsuda to Iona, with the trail drawn as a constellation across the top and the playing track's body drawing in Now](images/trail.png)

### The table

iTunes' one big table as a pane. Each numeric column header is a histogram you brush to filter, and rows group by release, work or person.

![The table pane listing the last 30 days of plays, grouped by release, with facets across the top and histogram headers](images/table.png)

### The sky

The library placed by sound. Press `M` on a trail and its constellation unfolds onto it; leads are hollow stars, and a lasso turns a region into a table.

![The sky: stars clustered into regions such as game scores and Celtic music, with the trail drawn across them and a lassoed selection](images/sky.png)

### The whole tree

Trails are trees. `T` shows every branch with its times, the peeks folded away, the point where two branches meet, and the same tree on the sky.

![The trail tree for one evening, its branches and meeting point above the same tree drawn on the sky](images/tree.png)

### Phone and foldable

The same trail. The phone shows one pane and swipes along the constellation; the unfolded foldable shows two.

![A phone showing the Iona pane and a foldable showing Joanne Hogg and Iona side by side](images/phone.png)

### Outside the app

The menu bar, media keys and the lock screen, where most plays start.

![The macOS menu bar panel for the playing track beside a phone lock screen with Meret's media controls](images/outside.png)

## Idioms, 2026-10-13

The shell stays put; per idiom, the page's lead, the track columns, the body drawing and a type register change. These plates predate the trail model, so their sidebar shell is gone; the idioms themselves still hold.

### Work

A release that holds two works leads with them, and recordings of the same work are compared movement by movement.

![Beethoven's Fifth and Seventh Symphonies under Carlos Kleiber, with four recordings of the Seventh compared by movement](images/idiom-work.png)

### Score

A game score leads with where the music is heard, and playback understands loops.

![Chrono Trigger's soundtrack grouped by the game's eras, with a cue's intro, two loops and fade drawn as rings](images/idiom-score.png)

## Setup, 2026-10-14

### Settings › Playback

Settings is its own window. Volume stays at the DAC by default, and the signal path says whether output is bit-perfect.

![The Settings window at Playback, with the output device, exclusive mode, Meret volume off and a bit-perfect signal path](images/settings-playback.png)
