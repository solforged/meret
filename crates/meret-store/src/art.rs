//! Covers. The scan writes each release's cover into the art directory at
//! a few sizes, named by the blake3 of the original image, and records its
//! light here; the UI reads the files directly.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use meret_model::{EntityKind, ReleaseId};

use crate::{Result, Store};

/// The sizes, in pixels on the long edge, every cover is written at.
pub const COVER_SIZES: [u32; 4] = [64, 128, 256, 512];

/// A release's cover and the light it lends.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Artwork {
    /// Lowercase hex of the blake3 of the original image.
    pub hash: String,
    /// ARGB, clamped in OKLCH; None for pale or grey covers, which keep the
    /// instrument's own accent.
    pub light: Option<u32>,
    pub light_wash: Option<u32>,
    pub light_dim: Option<u32>,
}

/// Where a cover is written at `size` (one of `COVER_SIZES`).
pub fn cover_file(art_dir: &Path, hash: &str, size: u32) -> PathBuf {
    art_dir.join(format!("{hash}-{size}.jpg"))
}

impl Store {
    /// The covers of `releases` that have one.
    pub fn release_art(&self, releases: &[ReleaseId]) -> Result<HashMap<ReleaseId, Artwork>> {
        let mut out = HashMap::with_capacity(releases.len());
        self.read(|c| {
            for chunk in releases.chunks(500) {
                let marks = vec!["?"; chunk.len()].join(",");
                let mut stmt = c.prepare_cached(&format!(
                    "SELECT ea.entity_id, a.hash, a.light, a.light_wash, a.light_dim
                     FROM entity_artwork ea JOIN artwork a ON a.hash = ea.hash
                     WHERE ea.entity_kind = {} AND ea.entity_id IN ({marks})",
                    EntityKind::Release as i64
                ))?;
                let rows = stmt.query_map(rusqlite::params_from_iter(chunk.iter().map(|r| r.0)), |r| {
                    let hash: Vec<u8> = r.get(1)?;
                    Ok((
                        ReleaseId(r.get(0)?),
                        Artwork {
                            hash: hash.iter().map(|b| format!("{b:02x}")).collect(),
                            light: r.get::<_, Option<i64>>(2)?.map(|v| v as u32),
                            light_wash: r.get::<_, Option<i64>>(3)?.map(|v| v as u32),
                            light_dim: r.get::<_, Option<i64>>(4)?.map(|v| v as u32),
                        },
                    ))
                })?;
                for row in rows {
                    let (release, art) = row?;
                    out.insert(release, art);
                }
            }
            Ok(())
        })?;
        Ok(out)
    }
}
