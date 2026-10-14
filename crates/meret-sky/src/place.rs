/// A placed star near a new one in embedding space.
#[derive(Clone, Copy, Debug)]
pub struct Neighbour {
    pub similarity: f32,
    pub pos: [f32; 2],
}

/// Where a new star settles: the similarity-weighted centre of its nearest
/// placed neighbours, nudged by a small offset derived from its id so that
/// near-duplicates don't stack. Deterministic, and it never moves anyone else.
pub fn settle(id: u64, neighbours: &[Neighbour], spread: f32) -> Option<[f32; 2]> {
    let total: f32 = neighbours.iter().map(|n| n.similarity.max(0.0).powi(2)).sum();
    if total <= 0.0 {
        return None;
    }
    let mut c = [0f32; 2];
    for n in neighbours {
        let w = n.similarity.max(0.0).powi(2) / total;
        c[0] += n.pos[0] * w;
        c[1] += n.pos[1] * w;
    }
    // A hash of the id picks an angle and a radius within `spread`.
    let h = id.wrapping_mul(0x9E37_79B9_7F4A_7C15);
    let angle = (h >> 40) as f32 / (1u64 << 24) as f32 * std::f32::consts::TAU;
    let radius = ((h & 0xFFFF) as f32 / 65_535.0).sqrt() * spread;
    Some([c[0] + angle.cos() * radius, c[1] + angle.sin() * radius])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn settles_near_its_closest_neighbour_and_stays_put() {
        let n = [
            Neighbour { similarity: 0.9, pos: [10.0, 10.0] },
            Neighbour { similarity: 0.3, pos: [-10.0, -10.0] },
        ];
        let a = settle(42, &n, 0.5).unwrap();
        assert!(a[0] > 7.0 && a[1] > 7.0, "{a:?}");
        assert_eq!(settle(42, &n, 0.5), Some(a));
        assert_ne!(settle(43, &n, 0.5), Some(a));
    }
}
