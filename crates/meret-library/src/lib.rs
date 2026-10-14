//! The library on disk: roots, the stat walk, diffs, and tag reading.
//!
//! A multi-terabyte library is mostly unchanged between runs, so the scan is
//! built around not reading files:
//!
//! 1. **Walk** with `stat` only, in parallel. A million files is seconds on SSD.
//! 2. **Diff** against the `file` table by (path, size, mtime). Pair removals
//!    with additions of the same size and head hash as moves, so history and
//!    notes follow a file to its new folder.
//! 3. **Read tags** only for what's new or changed, as jobs.
//! 4. On macOS, resume from the last FSEvents event ID instead of walking at
//!    all; walk only when the volume's event history was lost.
//!
//! A root that isn't mounted is marked offline. Nothing on it is deleted.

pub mod diff;
pub mod tags;
pub mod walk;

pub use diff::{Diff, diff};
pub use tags::{Tags, read_tags};
pub use walk::{FileStat, is_audio, walk};
