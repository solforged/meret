use std::fmt;

use meret_model::Idiom;
use serde::{Deserialize, Serialize};

/// What was typed on the query line.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Input {
    /// A search. Running one from the query line starts a new trail.
    Search(Query),
    Command(Command),
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "verb", rename_all = "snake_case")]
pub enum Command {
    /// `play <query>`: play what matches, or the selection if empty.
    Play { query: Query },
    /// `queue <query>`: add to Up Next.
    Queue { query: Query },
    /// `want <query>`: mark as a want.
    Want { query: Query },
    /// `crate add <name>`: add the selection to a crate.
    CrateAdd { name: String },
    /// `crate new <name> [query]`: a rule crate if a query follows.
    CrateNew { name: String, rule: Option<Query> },
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Query {
    pub clauses: Vec<Clause>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Clause {
    pub negated: bool,
    pub term: Term,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Term {
    /// Free text, matched against titles, names and notes.
    Text { text: String },
    Flag { flag: Flag },
    Idiom { idiom: Idiom },
    /// A person in a role, or in any role when `role` is `None` (`by:`).
    Person { role: Option<Role>, name: String },
    Number { field: NumField, cmp: Cmp },
    /// `last:30d` — played within; `added:2w` — added within.
    Within { field: TimeField, span: Span },
    Format { format: Format },
    /// Games, films, labels, crates, works by name.
    Named { field: NameField, value: String },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Flag {
    Owned,
    Lossless,
    Streamable,
    Wanted,
    Guessed,
    Dormant,
    Lead,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Role {
    Composer,
    Arranger,
    Lyricist,
    Sung,
    Performer,
    Conductor,
    Producer,
    Engineer,
    Member,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NumField {
    Year,
    Plays,
    /// Seconds.
    Length,
    Dr,
    /// Integrated loudness in LUFS.
    Loudness,
    Bpm,
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "op", content = "value", rename_all = "snake_case")]
pub enum Cmp {
    Eq(f64),
    Lt(f64),
    Gt(f64),
    /// Inclusive at both ends.
    Range(f64, f64),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TimeField {
    LastPlayed,
    Added,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Span {
    pub amount: u32,
    pub unit: SpanUnit,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SpanUnit {
    Day,
    Week,
    Month,
    Year,
}

impl Span {
    pub fn as_millis(&self) -> i64 {
        const DAY: i64 = 86_400_000;
        let days = match self.unit {
            SpanUnit::Day => 1,
            SpanUnit::Week => 7,
            SpanUnit::Month => 30,
            SpanUnit::Year => 365,
        };
        self.amount as i64 * days * DAY
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Format {
    Flac,
    HiRes,
    Dsd,
    Chiptune,
    Lossy,
    Mp3,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NameField {
    Game,
    Film,
    Label,
    Crate,
    Work,
    Release,
    Service,
}

// Display writes the canonical form, so a brushed histogram can write its
// clause back into the query line and the query line can be saved as a crate.

impl fmt::Display for Query {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        for (i, c) in self.clauses.iter().enumerate() {
            if i > 0 {
                f.write_str(" ")?;
            }
            write!(f, "{c}")?;
        }
        Ok(())
    }
}

impl fmt::Display for Command {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let with_query = |f: &mut fmt::Formatter<'_>, verb: &str, q: &Query| {
            if q.clauses.is_empty() { f.write_str(verb) } else { write!(f, "{verb} {q}") }
        };
        match self {
            Command::Play { query } => with_query(f, "play", query),
            Command::Queue { query } => with_query(f, "queue", query),
            Command::Want { query } => with_query(f, "want", query),
            Command::CrateAdd { name } => write!(f, "crate add {}", quoted(name)),
            Command::CrateNew { name, rule: None } => write!(f, "crate new {}", quoted(name)),
            Command::CrateNew { name, rule: Some(rule) } => write!(f, "crate new {} {rule}", quoted(name)),
        }
    }
}

impl fmt::Display for Clause {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match (&self.term, self.negated) {
            (Term::Flag { flag }, true) => write!(f, "not:{}", flag.as_str()),
            (term, true) => write!(f, "-{term}"),
            (term, false) => write!(f, "{term}"),
        }
    }
}

fn quoted(s: &str) -> String {
    if s.is_empty() || s.contains(char::is_whitespace) { format!("\"{s}\"") } else { s.to_string() }
}

/// Free text, quoted wherever bare it would read as something else: a
/// clause (`ac:dc`), a negation (`-live`), or a command (`play`).
fn quoted_text(s: &str) -> String {
    let verb = ["play", "queue", "want", "crate"].iter().any(|v| s.eq_ignore_ascii_case(v));
    if verb || s.contains(':') || s.starts_with('-') { format!("\"{s}\"") } else { quoted(s) }
}

impl fmt::Display for Term {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Term::Text { text } => f.write_str(&quoted_text(text)),
            Term::Flag { flag } => write!(f, "is:{}", flag.as_str()),
            Term::Idiom { idiom } => write!(f, "idiom:{}", idiom.as_str()),
            Term::Person { role: None, name } => write!(f, "by:{}", quoted(name)),
            Term::Person { role: Some(r), name } => write!(f, "{}:{}", r.as_str(), quoted(name)),
            Term::Number { field, cmp } => write!(f, "{}:{}", field.as_str(), cmp_str(*field, *cmp)),
            Term::Within { field, span } => {
                let key = match field {
                    TimeField::LastPlayed => "last",
                    TimeField::Added => "added",
                };
                let unit = match span.unit {
                    SpanUnit::Day => 'd',
                    SpanUnit::Week => 'w',
                    SpanUnit::Month => 'm',
                    SpanUnit::Year => 'y',
                };
                write!(f, "{key}:{}{unit}", span.amount)
            }
            Term::Format { format } => write!(f, "format:{}", format.as_str()),
            Term::Named { field, value } => write!(f, "{}:{}", field.as_str(), quoted(value)),
        }
    }
}

fn num(v: f64) -> String {
    if v.fract() == 0.0 { format!("{v:.0}") } else { format!("{v}") }
}

fn cmp_str(field: NumField, cmp: Cmp) -> String {
    match cmp {
        // A ten-year range on a decade boundary reads back as "1970s".
        Cmp::Range(a, b) if field == NumField::Year && a % 10.0 == 0.0 && b == a + 9.0 => format!("{}s", num(a)),
        Cmp::Range(a, b) => format!("{}..{}", num(a), num(b)),
        Cmp::Eq(v) => num(v),
        Cmp::Lt(v) => format!("<{}", num(v)),
        Cmp::Gt(v) => format!(">{}", num(v)),
    }
}

macro_rules! names {
    ($ty:ident { $($variant:ident => $s:literal $(| $alias:literal)*),* $(,)? }) => {
        impl $ty {
            pub fn as_str(self) -> &'static str {
                match self { $($ty::$variant => $s),* }
            }
            pub fn from_key(s: &str) -> Option<Self> {
                match s { $($s $(| $alias)* => Some($ty::$variant),)* _ => None }
            }
        }
    };
}

names!(Flag {
    Owned => "owned" | "own",
    Lossless => "lossless",
    Streamable => "streamable" | "stream",
    Wanted => "wanted" | "want",
    Guessed => "guessed" | "unmatched",
    Dormant => "dormant",
    Lead => "lead",
});

names!(Role {
    Composer => "composer" | "composed",
    Arranger => "arranger" | "arranged",
    Lyricist => "lyrics" | "lyricist",
    Sung => "sung" | "vocals",
    Performer => "performer" | "played",
    Conductor => "conductor" | "conducted",
    Producer => "producer" | "produced",
    Engineer => "engineer",
    Member => "member",
});

names!(NumField {
    Year => "year",
    Plays => "plays",
    Length => "length",
    Dr => "dr",
    Loudness => "lufs",
    Bpm => "bpm",
});

names!(Format {
    Flac => "flac",
    HiRes => "hires" | "hi-res" | "24bit",
    Dsd => "dsd",
    Chiptune => "chiptune" | "native",
    Lossy => "lossy",
    Mp3 => "mp3",
});

names!(NameField {
    Game => "game",
    Film => "film",
    Label => "label",
    Crate => "crate",
    Work => "work",
    Release => "release" | "album",
    Service => "on" | "service",
});
