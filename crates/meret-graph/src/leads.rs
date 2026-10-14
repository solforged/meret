//! Leads: things you haven't heard, with the threads that produced them.
//! "A lead that several threads converge on is a strong one, and Meret says so."

use meret_model::ThreadKind;
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Evidence {
    pub thread: ThreadKind,
    /// Who said so: musicbrainz, listenbrainz, local_audio, your trail.
    pub source: String,
    pub confidence: f32,
    /// "Creid, which you've streamed 6 times, sounds like Iona".
    pub reason: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct LeadStrength {
    /// 0 to 1.
    pub score: f32,
    /// Distinct sources that point here. Two independent routes beat one
    /// confident one.
    pub routes: usize,
    pub strong: bool,
}

/// Combines evidence as independent votes (noisy-OR), counting each source
/// once at its most confident, so one chatty provider can't make a lead strong.
pub fn converge(evidence: &[Evidence]) -> LeadStrength {
    let mut best: Vec<(&str, f32)> = vec![];
    for e in evidence {
        match best.iter_mut().find(|(s, _)| *s == e.source) {
            Some((_, c)) => *c = c.max(e.confidence),
            None => best.push((&e.source, e.confidence.clamp(0.0, 1.0))),
        }
    }
    let miss: f32 = best.iter().map(|(_, c)| 1.0 - c).product();
    let score = 1.0 - miss;
    let routes = best.len();
    LeadStrength { score, routes, strong: routes >= 2 && score >= 0.8 }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn e(source: &str, c: f32) -> Evidence {
        Evidence { thread: ThreadKind::SoundsLike, source: source.into(), confidence: c, reason: String::new() }
    }

    #[test]
    fn independent_routes_make_a_strong_lead() {
        // Plate 01: Iona, from the trail, local audio and ListenBrainz.
        let s = converge(&[e("trail", 0.6), e("local_audio", 0.81), e("listenbrainz", 0.5)]);
        assert!(s.strong);
        assert_eq!(s.routes, 3);
    }

    #[test]
    fn one_source_repeating_itself_is_not_convergence() {
        let s = converge(&[e("local_audio", 0.81), e("local_audio", 0.84), e("local_audio", 0.77)]);
        assert_eq!(s.routes, 1);
        assert!(!s.strong);
        assert!((s.score - 0.84).abs() < 1e-6);
    }
}
