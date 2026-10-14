//! What Dart can call. Kept thin: each function forwards to `meret_api::Api`
//! and converts to plain mirror types.
//!
//! Rules: nothing here is called per frame. Now and the status line are
//! streams; the playhead is an anchor the UI extrapolates.

pub mod core;
pub mod types;
