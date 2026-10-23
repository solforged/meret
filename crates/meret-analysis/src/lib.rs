//! Local analysis. Runs on the hub as low-priority jobs; satellites receive
//! the results.
//!
//! * `Analyzer`: streaming R128 loudness, true peak, DR and the body summary.
//! * `dr`: dynamic range, the TT DR meter's method.
//! * `body`: the compact summary the radial Body drawing is made of.
//! * Planned: tempo and key, structure, and an embedding model for "sounds
//!   like" and the sky (see the licences note in docs/architecture.md).

mod analyzer;
pub mod body;
pub mod dr;

pub use analyzer::{Analysis, Analyzer};
pub use body::BodySummary;
pub use dr::dynamic_range;

/// Implemented by whichever embedding model is chosen.
pub trait Embedder: Send + Sync {
    fn dims(&self) -> usize;
    fn sample_rate(&self) -> u32;
    /// One vector for a mono clip at `sample_rate()`.
    fn embed(&self, mono: &[f32]) -> Vec<f32>;
}

