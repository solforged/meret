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

/// The people one role's tag values name, each with what a performer value
/// says they play ("Joji Hirota (shakuhachi)"). Notes and placeholders
/// ("not separately itemized in the release", "composer unknown") name no one.
pub fn role_people(values: &[String]) -> Vec<(String, Option<String>)> {
    let mut seen = std::collections::HashSet::new();
    let mut out = vec![];
    // Each `;` part carries its own "(instrument)", so split there before reading it.
    for part in values.iter().flat_map(|v| v.split(';')) {
        let (names, detail) = match part.trim().strip_suffix(')').and_then(|v| v.rsplit_once(" (")) {
            Some((names, detail)) if !detail.trim().is_empty() => (names, Some(detail.trim().to_owned())),
            _ => (part, None),
        };
        for name in split_credit(names) {
            if is_name(&name) && seen.insert(name_key(&name)) {
                out.push((name, detail.clone()));
            }
        }
    }
    out
}

/// A name, not a sentence about the credit or a stand-in for one.
fn is_name(name: &str) -> bool {
    const NO_ONE: [&str; 6] = ["unknown", "composer unknown", "anonymous", "various", "n/a", "none"];
    name.split_whitespace().count() <= 6 && !NO_ONE.contains(&name.to_lowercase().as_str())
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

    #[test]
    fn role_values_name_people_with_instruments_and_skip_notes() {
        let values = ["Michael Askill & Omar Faruk Tekbilek (percussion)".to_string(),
            "traditional; composer unknown".into(),
            "not separately itemized in the consulted DLC release metadata".into(),
            "Joji Hirota".into(),
            "Ada Brennan (orchestration); Tomas Vey (guitar arrangement)".into()];
        assert_eq!(role_people(&values), [
            ("Michael Askill".to_string(), Some("percussion".to_string())),
            ("Omar Faruk Tekbilek".into(), Some("percussion".into())),
            ("traditional".into(), None),
            ("Joji Hirota".into(), None),
            ("Ada Brennan".into(), Some("orchestration".into())),
            ("Tomas Vey".into(), Some("guitar arrangement".into())),
        ]);
    }
}
