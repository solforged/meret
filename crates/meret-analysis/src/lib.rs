//! Local analysis. Runs on the hub as low-priority jobs; satellites receive
//! the results.
//!
//! * `dr`: dynamic range, the TT DR meter's method.
//! * `body`: the compact summary the radial Body drawing is made of.
//! * Planned: EBU R128 loudness (`ebur128`), tempo and key, structure, and
//!   an embedding model for "sounds like" and the sky (see the licences note
//!   in docs/architecture.md before choosing Essentia's models).

pub mod body;
pub mod dr;

pub use body::BodySummary;
pub use dr::dynamic_range;

/// Implemented by whichever embedding model is chosen.
pub trait Embedder: Send + Sync {
    fn dims(&self) -> usize;
    fn sample_rate(&self) -> u32;
    /// One vector for a mono clip at `sample_rate()`.
    fn embed(&self, mono: &[f32]) -> Vec<f32>;
}

/// Converts left-justified i32 samples to f32 in -1..1.
pub fn to_f32(samples: &[i32]) -> Vec<f32> {
    samples.iter().map(|&s| s as f32 / 2_147_483_648.0).collect()
}
