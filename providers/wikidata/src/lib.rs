//! Video games, credits and series from Wikidata's SPARQL endpoint.
//! Searches use the shared HTTP context's cache and per-host rate limit.

use std::collections::{BTreeMap, BTreeSet};

use meret_provider::{Context, Http, Result};
use serde_json::Value;

pub const SPARQL: &str = "https://query.wikidata.org/sparql";

/// A video game as Wikidata describes it.
#[derive(Clone, Debug, PartialEq)]
pub struct Game {
    pub qid: String,
    /// The English label, falling back to the multilingual label.
    pub title: String,
    /// English and multilingual aliases.
    pub aliases: Vec<String>,
    /// The earliest publication year.
    pub year: Option<u16>,
    pub composers: Vec<Named>,
    pub developers: Vec<String>,
    pub platforms: Vec<String>,
    pub series: Option<Named>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Named {
    pub qid: String,
    pub name: String,
}

/// The query URL for up to ten entity-search hits that are video games.
pub fn games_url(name: &str) -> String {
    Http::url(SPARQL, &[("query", &query(name)), ("format", "json")])
}

fn query(name: &str) -> String {
    let mut literal = String::with_capacity(name.len());
    for c in name.chars() {
        match c {
            '\\' => literal.push_str("\\\\"),
            '"' => literal.push_str("\\\""),
            '\n' => literal.push_str("\\n"),
            '\r' => literal.push_str("\\r"),
            '\t' => literal.push_str("\\t"),
            _ => literal.push(c),
        }
    }
    format!(r#"SELECT DISTINCT ?game ?property ?value ?item WHERE {{
  SERVICE wikibase:mwapi {{
    bd:serviceParam wikibase:api "EntitySearch";
      wikibase:endpoint "www.wikidata.org";
      mwapi:search "{literal}";
      mwapi:language "en";
      mwapi:limit "10".
    ?game wikibase:apiOutputItem mwapi:item.
  }}
  ?game wdt:P31/wdt:P279* wd:Q7889.
  {{ ?game rdfs:label ?value. BIND("title" AS ?property) }}
  UNION {{ ?game skos:altLabel ?value. BIND("alias" AS ?property) }}
  UNION {{ ?game wdt:P577 ?value. BIND("year" AS ?property) }}
  UNION {{ ?game wdt:P86 ?item. ?item rdfs:label ?value. BIND("composer" AS ?property) }}
  UNION {{ ?game wdt:P178 ?item. ?item rdfs:label ?value. BIND("developer" AS ?property) }}
  UNION {{ ?game wdt:P400 ?item. ?item rdfs:label ?value. BIND("platform" AS ?property) }}
  UNION {{ ?game wdt:P179 ?item. ?item rdfs:label ?value. BIND("series" AS ?property) }}
  FILTER(?property = "year" || LANG(?value) IN ("en", "mul"))
}}"#)
}

#[derive(Default)]
struct Label {
    name: String,
    english: bool,
}

impl Label {
    fn update(&mut self, name: &str, english: bool) {
        if self.name.is_empty() || (english && !self.english) {
            self.name = name.to_owned();
            self.english = english;
        }
    }
}

#[derive(Default)]
struct Candidate {
    title: Label,
    aliases: BTreeSet<String>,
    year: Option<u16>,
    composers: BTreeMap<String, Label>,
    developers: BTreeMap<String, Label>,
    platforms: BTreeMap<String, Label>,
    series: BTreeMap<String, Label>,
}

fn qid(value: &Value) -> Option<&str> {
    let uri = value["value"].as_str()?;
    let id = uri.strip_prefix("http://www.wikidata.org/entity/")
        .or_else(|| uri.strip_prefix("https://www.wikidata.org/entity/"))?;
    let digits = id.strip_prefix('Q')?;
    (!digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit())).then_some(id)
}

fn named(values: BTreeMap<String, Label>) -> impl Iterator<Item = Named> {
    values.into_iter().map(|(qid, label)| Named { qid, name: label.name })
}

/// Parses the query's JSON results, preferring English over multilingual labels.
pub fn games(value: &Value) -> Vec<Game> {
    let Some(rows) = value["results"]["bindings"].as_array() else { return vec![] };
    let mut candidates = BTreeMap::<String, Candidate>::new();
    for row in rows {
        let (Some(id), Some(property), Some(text)) = (
            qid(&row["game"]), row["property"]["value"].as_str(), row["value"]["value"].as_str(),
        ) else { continue };
        if property == "year" {
            if let Some(year) = text.split('-').next().and_then(|y| y.parse::<u16>().ok()).filter(|y| *y > 0) {
                let candidate = candidates.entry(id.to_owned()).or_default();
                candidate.year = Some(candidate.year.map_or(year, |old| old.min(year)));
            }
            continue;
        }
        let english = match row["value"]["xml:lang"].as_str() {
            Some("en") => true,
            Some("mul") => false,
            _ => continue,
        };
        if text.is_empty() { continue }
        let candidate = candidates.entry(id.to_owned()).or_default();
        match property {
            "title" => candidate.title.update(text, english),
            "alias" => { candidate.aliases.insert(text.to_owned()); }
            "composer" | "developer" | "platform" | "series" => {
                let Some(item) = qid(&row["item"]) else { continue };
                let labels = match property {
                    "composer" => &mut candidate.composers,
                    "developer" => &mut candidate.developers,
                    "platform" => &mut candidate.platforms,
                    _ => &mut candidate.series,
                };
                labels.entry(item.to_owned()).or_default().update(text, english);
            }
            _ => {}
        }
    }
    candidates.into_iter().filter(|(_, candidate)| !candidate.title.name.is_empty()).map(|(qid, c)| Game {
        qid,
        title: c.title.name,
        aliases: c.aliases.into_iter().collect(),
        year: c.year,
        composers: named(c.composers).collect(),
        developers: c.developers.into_values().map(|label| label.name).collect(),
        platforms: c.platforms.into_values().map(|label| label.name).collect(),
        series: named(c.series).next(),
    }).collect()
}

/// Runs a game search through the context's HTTP client (rate limits and cache).
pub async fn search_games(ctx: &Context, name: &str) -> Result<Vec<Game>> {
    Ok(games(&ctx.http.get_json(&games_url(name)).await?))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn search_literals_escape_sparql_syntax() {
        let name = "A \\\"B\"\nC\rD\tE";
        let expected = "mwapi:search \"A \\\\\\\"B\\\"\\nC\\rD\\tE\";";
        assert!(query(name).contains(expected));
    }
}
