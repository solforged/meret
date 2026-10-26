//! Conservative interpretation of written local-tag credits, shared by scans
//! and data migrations. The written credit itself is never rewritten.

/// A name's identity ignores case and whitespace, including space before a
/// comma. Numeric citation debris is not part of an agent's name.
pub fn name_key(name: &str) -> String {
    clean_name(name).to_lowercase()
}

pub fn clean_name(name: &str) -> String {
    let mut name = name.trim();
    if let Some(open) = name.rfind('[') {
        let suffix = &name[open..];
        if suffix.ends_with(']') && suffix[1..suffix.len() - 1].chars().all(|c| c.is_ascii_digit() || c.is_whitespace()) {
            name = name[..open].trim_end();
        }
    }
    name.split_whitespace().collect::<Vec<_>>().join(" ").replace(" ,", ",")
}

/// Semicolons and feat./ft./featuring are explicit separators. Ampersands,
/// `and`, and commas are separators only if *every* resulting name has two
/// or more words; this keeps Simon & Garfunkel and Earth, Wind & Fire whole.
/// A two-part comma name with a single surname or recognisable given names
/// after the comma is kept as written, not reordered: tags are not authority
/// records. These rules deliberately prefer an unsplit ambiguous band/name.
pub fn split_credit(written: &str) -> Vec<String> {
    let explicit = [";", " feat. ", " ft. ", " featuring "];
    let mut out = Vec::new();
    let mut start = 0;
    // Match ASCII separators in the original bytes; lowercasing Unicode can
    // change byte offsets, so search each suffix with ASCII-insensitive bytes.
    for (i, _) in written.char_indices() {
        if i < start { continue; }
        if let Some(separator) = explicit.iter().find(|s| ascii_starts_with(&written[i..], s)) {
            split_ambiguous(&written[start..i], &mut out);
            start = i + separator.len();
        }
    }
    split_ambiguous(&written[start..], &mut out);
    out.retain(|s| !s.is_empty());
    let mut seen = std::collections::HashSet::new();
    out.retain(|s| seen.insert(name_key(s)));
    out
}

fn ascii_starts_with(text: &str, prefix: &str) -> bool {
    text.as_bytes().get(..prefix.len()).is_some_and(|s| s.eq_ignore_ascii_case(prefix.as_bytes()))
}

fn split_ambiguous(text: &str, out: &mut Vec<String>) {
    // ID3v2.3 joins artists with `/`; like the others it splits only full names, so AC/DC stays.
    let separators = [" & ", " and ", ",", "/"];
    let mut parts = Vec::new();
    let mut start = 0;
    let mut commas = 0;
    for (i, _) in text.char_indices() {
        if i < start { continue; }
        if let Some(separator) = separators.iter().find(|s| ascii_starts_with(&text[i..], s)) {
            parts.push(text[start..i].trim());
            commas += usize::from(*separator == ",");
            start = i + separator.len();
        }
    }
    parts.push(text[start..].trim());
    let surname_first = commas == 1 && parts.len() == 2 && looks_like_given_names(parts[1]);
    if parts.len() > 1 && !surname_first && parts.iter().all(|s| s.split_whitespace().count() >= 2) {
        out.extend(parts.into_iter().map(clean_name));
    } else {
        out.push(clean_name(text));
    }
}

fn looks_like_given_names(text: &str) -> bool {
    // Common given names plus unambiguous Slavic patronymic endings. This is
    // only a veto, never a reason to split or to normalise surname order.
    text.split_whitespace().all(|word| {
        let word = word.to_lowercase();
        matches!(word.as_str(), "orlando" | "mikhail" | "nikolai" | "johann" | "johannes" | "sebastian"
            | "james" | "john" | "george" | "thomas" | "william" | "henry" | "ralph" | "edward"
            | "richard" | "robert" | "paul" | "peter" | "michael" | "alan" | "david" | "anton"
            | "ludwig" | "wolfgang" | "amadeus" | "franz" | "joseph" | "carl" | "charles")
            || word.ends_with("ovich") || word.ends_with("evich") || word.ends_with("ovna") || word.ends_with("evna")
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn written_credit_boundaries_are_conservative() {
        let cases: &[(&str, &[&str])] = &[
            ("Roger Briggs & Mark Cromer", &["Roger Briggs", "Mark Cromer"]),
            ("Geoff Knorr & Michael Curran", &["Geoff Knorr", "Michael Curran"]),
            ("Jeff van Dyck, Richard Vaughan & James Vincent", &["Jeff van Dyck", "Richard Vaughan", "James Vincent"]),
            ("George Frideric Handel , Thomas Beecham", &["George Frideric Handel", "Thomas Beecham"]),
            ("George Frideric Handel, Thomas Beecham", &["George Frideric Handel", "Thomas Beecham"]),
            ("Gibbons, Orlando", &["Gibbons, Orlando"]),
            ("Ippolitov-Ivanov, Mikhail Mikhaylovich", &["Ippolitov-Ivanov, Mikhail Mikhaylovich"]),
            ("van Dyck, John Michael", &["van Dyck, John Michael"]),
            ("Simon Park [ 23 ]", &["Simon Park"]),
            ("Simon & Garfunkel", &["Simon & Garfunkel"]),
            ("Roger Briggs/Mark Cromer", &["Roger Briggs", "Mark Cromer"]),
            ("Roger Briggs / Mark Cromer", &["Roger Briggs", "Mark Cromer"]),
            ("AC/DC", &["AC/DC"]),
            ("Earth, Wind & Fire", &["Earth, Wind & Fire"]),
            ("A; B feat. C FT. D featuring E", &["A", "B", "C", "D", "E"]),
            ("Jan Stoeckart [ 24 ]", &["Jan Stoeckart"]),
            ("Brian Keane & Omar Faruk Tekbilek", &["Brian Keane", "Omar Faruk Tekbilek"]),
            ("John Leach, Francis Silkstone", &["John Leach", "Francis Silkstone"]),
            ("Laurence Joyce, John Leach", &["Laurence Joyce", "John Leach"]),
            ("Lee Chu Kiong, Ling Kun", &["Lee Chu Kiong", "Ling Kun"]),
            ("Leonard Slatkin and the Saint Louis Symphony Orchestra", &["Leonard Slatkin", "the Saint Louis Symphony Orchestra"]),
            ("Michael Askill & Omar Faruk Tekbilek", &["Michael Askill", "Omar Faruk Tekbilek"]),
            ("Michael Hoppe , Tim Wheater", &["Michael Hoppe", "Tim Wheater"]),
            ("Neil M. Goldberg, Dave G. Fraser", &["Neil M. Goldberg", "Dave G. Fraser"]),
            ("Patrick David Wilson, Adam Francis Routh", &["Patrick David Wilson", "Adam Francis Routh"]),
            ("Patrick Fradji Maarek, Philippe Victor Guez", &["Patrick Fradji Maarek", "Philippe Victor Guez"]),
            ("Paul Clarvis , Richard Harvey", &["Paul Clarvis", "Richard Harvey"]),
            ("Pichit Paiboon, Traditional Thai", &["Pichit Paiboon", "Traditional Thai"]),
            ("Ravi Shankar, Terence Emery, The London Symphony Orchestra and André Previn", &["Ravi Shankar", "Terence Emery", "The London Symphony Orchestra", "André Previn"]),
            ("Ravi Shankar, The London Philharmonic Orchestra and Zubin Mehta", &["Ravi Shankar", "The London Philharmonic Orchestra", "Zubin Mehta"]),
            ("Robert White, Michael Norton, Anthony Hinnigan", &["Robert White", "Michael Norton", "Anthony Hinnigan"]),
            ("Roger Abaji, Thomas Ostrowiecki", &["Roger Abaji", "Thomas Ostrowiecki"]),
            ("Simon Park & Antonio Valotti", &["Simon Park", "Antonio Valotti"]),
            ("Srikanta, Manjeet Amar", &["Srikanta, Manjeet Amar"]),
            ("Johann Sebastian Bach , arr. Leopold Stokowski", &["Johann Sebastian Bach", "arr. Leopold Stokowski"]),
            ("Richard Wagner , arr. Leopold Stokowski", &["Richard Wagner", "arr. Leopold Stokowski"]),
        ];
        for &(written, expected) in cases {
            assert_eq!(split_credit(written), expected, "{written}");
        }
    }

    #[test]
    fn identity_is_case_whitespace_and_citation_insensitive() {
        assert_eq!(name_key("  Jan  Stoeckart [ 24 ] "), name_key("JAN STOECKART"));
        assert_eq!(name_key("Gibbons ,  Orlando"), name_key("Gibbons, Orlando"));
    }
}
