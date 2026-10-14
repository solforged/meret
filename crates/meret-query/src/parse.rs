use meret_model::Idiom;

use crate::ast::*;
use crate::lex::{Word, words};

#[derive(Debug, thiserror::Error, PartialEq)]
pub enum ParseError {
    #[error("unclosed quote starting at {0}")]
    UnclosedQuote(usize),
    #[error("unknown key `{0}:`")]
    UnknownKey(String),
    #[error("can't read `{value}` as {expected}")]
    BadValue { value: String, expected: &'static str },
    #[error("`{0}` needs a name")]
    MissingName(&'static str),
}

/// Parses a query-line input. Commands are recognised only as the first,
/// unquoted word, so searching for a song called "Play" means typing `"play"`.
pub fn parse(input: &str) -> Result<Input, ParseError> {
    let ws = words(input).map_err(ParseError::UnclosedQuote)?;

    if let Some(first) = ws.first().filter(|w| w.key.is_none() && !w.quoted && !w.negated) {
        let rest = &ws[1..];
        match first.value.to_ascii_lowercase().as_str() {
            "play" => return Ok(Input::Command(Command::Play { query: query(rest)? })),
            "queue" => return Ok(Input::Command(Command::Queue { query: query(rest)? })),
            "want" => return Ok(Input::Command(Command::Want { query: query(rest)? })),
            "crate" => return crate_command(rest).map(Input::Command),
            _ => {}
        }
    }

    Ok(Input::Search(query(&ws)?))
}

fn crate_command(rest: &[Word]) -> Result<Command, ParseError> {
    let sub = rest.first().map(|w| w.value.to_ascii_lowercase());
    let name = rest.get(1).map(|w| w.value.clone()).ok_or(ParseError::MissingName("crate"))?;
    match sub.as_deref() {
        Some("add") => Ok(Command::CrateAdd { name }),
        Some("new") => {
            let rule = query(&rest[2..])?;
            Ok(Command::CrateNew { name, rule: (!rule.clauses.is_empty()).then_some(rule) })
        }
        _ => Err(ParseError::MissingName("crate add | crate new")),
    }
}

fn query(ws: &[Word]) -> Result<Query, ParseError> {
    ws.iter().map(clause).collect::<Result<Vec<_>, _>>().map(|clauses| Query { clauses })
}

fn clause(w: &Word) -> Result<Clause, ParseError> {
    let Some(key) = w.key.as_deref() else {
        return Ok(Clause { negated: w.negated, term: Term::Text { text: w.value.clone() } });
    };
    let v = w.value.as_str();
    let bad = |expected| ParseError::BadValue { value: v.to_string(), expected };

    // `not:owned` is the plates' spelling of a negated flag.
    if key == "not" || key == "is" {
        let flag = Flag::from_key(&v.to_ascii_lowercase()).ok_or_else(|| bad("a flag"))?;
        return Ok(Clause { negated: (key == "not") != w.negated, term: Term::Flag { flag } });
    }

    let term = if key == "idiom" {
        Term::Idiom { idiom: Idiom::parse(v).ok_or_else(|| bad("an idiom"))? }
    } else if key == "by" {
        Term::Person { role: None, name: v.to_string() }
    } else if let Some(role) = Role::from_key(key) {
        Term::Person { role: Some(role), name: v.to_string() }
    } else if let Some(field) = NumField::from_key(key) {
        Term::Number { field, cmp: cmp(field, v).ok_or_else(|| bad("a number, <n, >n, a..b or a decade"))? }
    } else if key == "last" || key == "added" {
        let field = if key == "last" { TimeField::LastPlayed } else { TimeField::Added };
        Term::Within { field, span: span(v).ok_or_else(|| bad("a span such as 30d, 2w, 6m, 1y"))? }
    } else if key == "format" {
        Term::Format { format: Format::from_key(&v.to_ascii_lowercase()).ok_or_else(|| bad("a format"))? }
    } else if let Some(field) = NameField::from_key(key) {
        Term::Named { field, value: v.to_string() }
    } else {
        return Err(ParseError::UnknownKey(key.to_string()));
    };

    Ok(Clause { negated: w.negated, term })
}

fn cmp(field: NumField, v: &str) -> Option<Cmp> {
    let n = |s: &str| -> Option<f64> {
        if field == NumField::Length { duration_secs(s) } else { s.parse().ok() }
    };
    if let Some(rest) = v.strip_prefix('<') {
        return n(rest).map(Cmp::Lt);
    }
    if let Some(rest) = v.strip_prefix('>') {
        return n(rest).map(Cmp::Gt);
    }
    if let Some((a, b)) = v.split_once("..") {
        return Some(Cmp::Range(n(a)?, n(b)?));
    }
    if field == NumField::Year
        && let Some(decade) = v.strip_suffix('s')
    {
        let d: f64 = decade.parse().ok()?;
        return Some(Cmp::Range(d, d + 9.0));
    }
    n(v).map(Cmp::Eq)
}

/// `90`, `90s`, `10m`, `1h`, `4:33`.
fn duration_secs(s: &str) -> Option<f64> {
    if let Some((m, sec)) = s.split_once(':') {
        return Some(m.parse::<f64>().ok()? * 60.0 + sec.parse::<f64>().ok()?);
    }
    let (num, mul) = match s.chars().last()? {
        's' => (&s[..s.len() - 1], 1.0),
        'm' => (&s[..s.len() - 1], 60.0),
        'h' => (&s[..s.len() - 1], 3600.0),
        _ => (s, 1.0),
    };
    num.parse::<f64>().ok().map(|n| n * mul)
}

fn span(v: &str) -> Option<Span> {
    let unit = match v.chars().last()? {
        'd' => SpanUnit::Day,
        'w' => SpanUnit::Week,
        'm' => SpanUnit::Month,
        'y' => SpanUnit::Year,
        _ => return None,
    };
    let amount = v[..v.len() - 1].parse().ok()?;
    Some(Span { amount, unit })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn search(s: &str) -> Query {
        match parse(s).unwrap() {
            Input::Search(q) => q,
            other => panic!("expected a search, got {other:?}"),
        }
    }

    #[test]
    fn plate_01_query() {
        let q = search(r#"sung:"Joanne Hogg" not:owned"#);
        assert_eq!(
            q.clauses,
            vec![
                Clause { negated: false, term: Term::Person { role: Some(Role::Sung), name: "Joanne Hogg".into() } },
                Clause { negated: true, term: Term::Flag { flag: Flag::Owned } },
            ]
        );
    }

    #[test]
    fn rule_crate_from_the_front() {
        let q = search("idiom:session year:1970s plays:0");
        assert_eq!(q.clauses[0].term, Term::Idiom { idiom: Idiom::Session });
        assert_eq!(q.clauses[1].term, Term::Number { field: NumField::Year, cmp: Cmp::Range(1970.0, 1979.0) });
        assert_eq!(q.clauses[2].term, Term::Number { field: NumField::Plays, cmp: Cmp::Eq(0.0) });
    }

    #[test]
    fn brushing_writes_a_clause_that_reads_back() {
        for s in [
            "last:30d",
            r#"sung:"Joanne Hogg" not:owned"#,
            "idiom:session year:1970s plays:0",
            "dr:>12 -format:lossy",
            "by:mitsuda game:Xenogears",
        ] {
            assert_eq!(search(s).to_string(), s);
        }
    }

    #[test]
    fn lengths_accept_minutes_and_clock_time() {
        let q = search("length:>10m length:4:33");
        assert_eq!(q.clauses[0].term, Term::Number { field: NumField::Length, cmp: Cmp::Gt(600.0) });
        assert_eq!(q.clauses[1].term, Term::Number { field: NumField::Length, cmp: Cmp::Eq(273.0) });
    }

    #[test]
    fn commands_only_as_the_first_bare_word() {
        assert!(matches!(parse("play idiom:work").unwrap(), Input::Command(Command::Play { .. })));
        assert!(matches!(parse(r#""play" it again"#).unwrap(), Input::Search(_)));
        assert_eq!(
            parse(r#"crate add "Celtic, via games""#).unwrap(),
            Input::Command(Command::CrateAdd { name: "Celtic, via games".into() })
        );
    }

    #[test]
    fn commands_read_back_from_their_canonical_form() {
        for s in ["play idiom:work year:1970s", "queue", "want sung:\"Joanne Hogg\"", r#"crate add "Celtic, via games""#, "crate new tuesdays idiom:score"] {
            let Input::Command(c) = parse(s).unwrap() else { panic!("{s} is a command") };
            assert_eq!(c.to_string(), s);
            assert_eq!(parse(&c.to_string()).unwrap(), Input::Command(c));
        }
    }

    #[test]
    fn searches_keep_their_meaning_through_their_canonical_form() {
        for s in [r#""play" it"#, r#""ac:dc""#, r#""-live" bootleg"#, r#"by:"Iona Brown" -wisdom"#, r#""corridors of time" year:1990s"#] {
            let Input::Search(q) = parse(s).unwrap() else { panic!("{s} is a search") };
            assert_eq!(parse(&q.to_string()).unwrap(), Input::Search(q), "{s}");
        }
    }

    #[test]
    fn errors_say_what_was_wrong() {
        assert_eq!(parse(r#"sung:"Joanne"#), Err(ParseError::UnclosedQuote(0)));
        assert_eq!(parse("colour:red"), Err(ParseError::UnknownKey("colour".into())));
        assert!(matches!(parse("idiom:polka"), Err(ParseError::BadValue { .. })));
    }

    #[test]
    fn free_text_mixes_with_clauses() {
        let q = search("corridors of time idiom:score");
        assert_eq!(q.clauses.len(), 4);
        assert_eq!(q.clauses[0].term, Term::Text { text: "corridors".into() });
    }
}
