//! Where playback picks up, per idiom (plate 09, "each resumes the way its
//! music does").

use meret_model::idiom::{Idiom, ResumePolicy};

/// A part of the thing being resumed: a track of an album, a movement of a
/// work, a cue. `start_ms` is from the start of the whole.
#[derive(Clone, Debug, PartialEq)]
pub struct Part {
    pub start_ms: u64,
    pub title: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ResumeAt {
    pub position_ms: u64,
    /// Which part that is, if there are parts.
    pub part: Option<usize>,
    /// "from the start of II. Allegretto, never mid-movement".
    pub why: String,
}

pub fn resume_point(idiom: Idiom, stopped_ms: u64, parts: &[Part]) -> ResumeAt {
    let part = parts.iter().rposition(|p| p.start_ms <= stopped_ms);
    let part_start = part.map(|i| parts[i].start_ms).unwrap_or(0);
    let title = part.map(|i| parts[i].title.as_str()).unwrap_or("");

    match idiom.resume() {
        ResumePolicy::Exact => ResumeAt { position_ms: stopped_ms, part, why: "the exact second".into() },
        ResumePolicy::Rewind { ms } => ResumeAt {
            position_ms: stopped_ms.saturating_sub(ms as u64).max(part_start),
            part,
            why: format!("{} seconds back", ms / 1000),
        },
        ResumePolicy::StartOfPart => ResumeAt {
            position_ms: part_start,
            part,
            why: format!("from the start of {title}, never mid-movement"),
        },
        ResumePolicy::StartOfTrack => ResumeAt {
            position_ms: part_start,
            part,
            why: format!("from the top of {title}"),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn beethoven7() -> Vec<Part> {
        vec![
            Part { start_ms: 0, title: "I. Poco sostenuto – Vivace".into() },
            Part { start_ms: 822_000, title: "II. Allegretto".into() },
            Part { start_ms: 1_322_000, title: "III. Presto".into() },
        ]
    }

    #[test]
    fn plate_09_resumes() {
        let w = resume_point(Idiom::Work, 1_000_000, &beethoven7());
        assert_eq!(w.position_ms, 822_000);
        assert_eq!(w.part, Some(1));
        assert!(w.why.contains("II. Allegretto"));

        let podcast = resume_point(Idiom::Spoken, 1_459_000, &[]);
        assert_eq!(podcast.position_ms, 1_454_000);

        let set = resume_point(Idiom::Set, 6_850_000, &[]);
        assert_eq!(set.position_ms, 6_850_000);

        let cue = resume_point(Idiom::Score, 226_000, &[]);
        assert_eq!(cue.position_ms, 226_000);
    }

    #[test]
    fn rewinding_never_crosses_back_into_the_previous_chapter() {
        let chapters = vec![Part { start_ms: 0, title: "Intro".into() }, Part { start_ms: 60_000, title: "Two".into() }];
        assert_eq!(resume_point(Idiom::Spoken, 62_000, &chapters).position_ms, 60_000);
    }
}
