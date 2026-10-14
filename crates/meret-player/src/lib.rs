//! Playback above the engine: the queue, idiom rules, resume, and zones.
//!
//! Pressing play never starts a trail (plate 10). Playing from a trail leaves
//! the trail as it was.

pub mod queue;
pub mod resume;
pub mod zone;

pub use queue::{Queue, QueueItem};
pub use resume::{Part, ResumeAt, resume_point};
pub use zone::{Zone, ZoneCommand, ZoneFidelity, ZoneInfo, ZoneState};
