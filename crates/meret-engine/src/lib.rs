//! The audio engine.
//!
//! ```text
//! decode thread                                 audio callback (realtime)
//! ─────────────                                 ────────────────────────
//! Decoder ─► DSP stages ─► RingWriter ══ring══► RingReader ─► device
//!     ▲                                             │
//!     └── Control (from the player)                 └─► SharedClock (atomics)
//!                                                          │
//!                                   clock publisher ◄──────┘  ─► Anchor events
//! ```
//!
//! Rules for anything that runs in the callback: no allocation, no locks, no
//! logging, no syscalls that can block, no calls into Dart. It reads the ring
//! and writes two atomics.
//!
//! Samples travel as `i32`, left-justified (a 16-bit sample `s` is `s << 16`),
//! so 16- and 24-bit PCM and DoP-packed DSD pass through untouched.

pub mod clock;
pub mod decode;
pub mod dsp;
pub mod engine;
pub mod output;
pub mod ring;

pub use clock::{Anchor, SharedClock};
pub use decode::{DecodeError, Decoder, LoopPoints};
pub use engine::{Control, Engine, EngineEvent, ItemToken, Load};

/// One interleaved sample, left-justified in 32 bits.
pub type Sample = i32;
