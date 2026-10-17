//! Local tags: explicit artist lists outrank interpretation of a display string.

use meret_model::credit::{clean_name, name_key, split_credit};

/// ARTISTS / ALBUMARTISTS, or repeated ARTIST / ALBUMARTIST frames, are
/// authoritative boundaries. Never split an explicitly named band again.
pub fn people(written: Option<&str>, values: &[String]) -> Vec<String> {
    if values.is_empty() {
        return written.map(split_credit).unwrap_or_default();
    }
    let mut seen = std::collections::HashSet::new();
    values.iter().map(|s| clean_name(s)).filter(|s| !s.is_empty() && seen.insert(name_key(s))).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn explicit_values_override_the_written_credit_without_resplitting() {
        assert_eq!(people(Some("Misleading & Display Credit"), &["Simon & Garfunkel".into(), "Earth, Wind & Fire".into()]),
            ["Simon & Garfunkel", "Earth, Wind & Fire"]);
        assert_eq!(people(Some("Roger Briggs & Mark Cromer"), &[]), ["Roger Briggs", "Mark Cromer"]);
        assert_eq!(people(None, &[" Roger  Briggs ".into(), "ROGER BRIGGS".into()]), ["Roger Briggs"]);
    }
}
