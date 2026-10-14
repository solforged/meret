//! The sky: your library placed by sound (plate 05).
//!
//! * **Stable.** New stars settle in near their nearest neighbours in
//!   embedding space; old stars never move. The map becomes something you
//!   remember. A full re-survey happens only when you ask for one.
//! * **GPU-ready.** Positions go to the UI once as a flat `f32` buffer.
//! * **Lasso.** A polygon in, a selection out, through a grid index.
//!
//! Planned: level-of-detail tiles (density at galaxy zoom, individual stars
//! close in) for a million stars.

pub mod grid;
pub mod place;

pub use grid::Grid;
pub use place::{Neighbour, settle};

/// One star as the UI draws it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Star {
    pub x: f32,
    pub y: f32,
    /// From plays.
    pub size: f32,
    /// From how recently it was played.
    pub brightness: f32,
    pub flags: u32,
}

pub mod flags {
    pub const LEAD: u32 = 1;
    pub const OWNED: u32 = 2;
    pub const ON_TRAIL: u32 = 4;
}

/// Floats per star in the buffer: x, y, size, brightness, flags.
pub const STRIDE: usize = 5;

/// Packs stars into the buffer the UI hands straight to the GPU.
pub fn pack(stars: &[Star]) -> Vec<f32> {
    let mut out = Vec::with_capacity(stars.len() * STRIDE);
    for s in stars {
        out.extend_from_slice(&[s.x, s.y, s.size, s.brightness, f32::from_bits(s.flags)]);
    }
    out
}

/// Ray casting. `poly` is closed implicitly.
pub fn inside(poly: &[[f32; 2]], p: [f32; 2]) -> bool {
    let mut hit = false;
    let mut j = poly.len().wrapping_sub(1);
    for i in 0..poly.len() {
        let (a, b) = (poly[i], poly[j]);
        if (a[1] > p[1]) != (b[1] > p[1]) && p[0] < (b[0] - a[0]) * (p[1] - a[1]) / (b[1] - a[1]) + a[0] {
            hit = !hit;
        }
        j = i;
    }
    hit
}
