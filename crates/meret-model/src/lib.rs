//! Meret's shared vocabulary. Every other crate speaks these types.
//!
//! Nothing here does IO, so the model can be used from the realtime audio
//! thread, from tests, and from the FFI layer alike.

pub mod audio;
pub mod entity;
pub mod ids;
pub mod idiom;
pub mod marks;
pub mod signal;
pub mod thread;

pub use entity::{EntityKind, EntityRef};
pub use ids::*;
pub use idiom::Idiom;
pub use thread::{Provenance, ThreadKind};
