//! Splits a line into words, keeping quoted runs together.
//! `sung:"Joanne Hogg" -idiom:score` → [`sung:"Joanne Hogg"`, `-idiom:score`]

#[derive(Debug, PartialEq)]
pub struct Word {
    /// The text before the first unquoted `:`, if there is one.
    pub key: Option<String>,
    /// The rest, with quotes removed.
    pub value: String,
    pub negated: bool,
    /// Whether the value was quoted, so `"play"` is text, not a command.
    pub quoted: bool,
}

pub fn words(input: &str) -> Result<Vec<Word>, usize> {
    let mut out = Vec::new();
    let mut chars = input.char_indices().peekable();

    while let Some(&(start, c)) = chars.peek() {
        if c.is_whitespace() {
            chars.next();
            continue;
        }

        let mut negated = false;
        if c == '-' {
            negated = true;
            chars.next();
        }

        let mut key = None;
        let mut buf = String::new();
        let mut quoted = false;
        let mut in_quote = false;

        while let Some(&(_, c)) = chars.peek() {
            match c {
                '"' => {
                    in_quote = !in_quote;
                    quoted = true;
                    chars.next();
                }
                ':' if !in_quote && key.is_none() && !quoted => {
                    key = Some(std::mem::take(&mut buf).to_ascii_lowercase());
                    chars.next();
                }
                c if c.is_whitespace() && !in_quote => break,
                c => {
                    buf.push(c);
                    chars.next();
                }
            }
        }

        if in_quote {
            return Err(start);
        }
        if buf.is_empty() && key.is_none() && !quoted {
            // A lone "-".
            continue;
        }
        out.push(Word { key, value: buf, negated, quoted });
    }

    Ok(out)
}
