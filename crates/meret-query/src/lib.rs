//! The query language.
//!
//! One grammar serves the query line (`/`), smart crates (saved queries) and
//! the table (brushing a histogram header writes a clause back, such as
//! `last:30d`). Parsing is pure; planning against the store happens in
//! `meret-store`.
//!
//! ```text
//! sung:"Joanne Hogg" not:owned
//! idiom:session year:1970s plays:0
//! last:30d
//! play idiom:work composer:bach
//! crate add "Celtic, via games"
//! ```

mod ast;
mod lex;
mod parse;

pub use ast::*;
pub use parse::{ParseError, parse};
