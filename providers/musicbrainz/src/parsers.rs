use meret_model::{Provenance, ThreadKind};
use meret_provider::{Claim, ExternalRef, Field, Lookup, RefKind, ThreadClaim};
use serde_json::{Value, json};

fn provenance(subject: &ExternalRef) -> Provenance {
    Provenance { source: "musicbrainz".into(), external_ref: Some(subject.value.clone()), fetched_at: 0, confidence: 1.0 }
}

fn put(out: &mut Lookup, subject: &ExternalRef, field: Field, value: Value) {
    out.claims.push(Claim { subject: subject.clone(), field, value, provenance: provenance(subject) });
}

fn title_and_length(out: &mut Lookup, subject: &ExternalRef, value: &Value) {
    if let Some(title) = value["title"].as_str() {
        put(out, subject, Field::Title, title.into());
    }
    if let Some(length) = value["length"].as_u64() {
        put(out, subject, Field::LengthMs, length.into());
    }
}

fn credit(out: &mut Lookup, subject: &ExternalRef, agent: &Value, name: Option<&str>, role: &str, detail: Option<String>) {
    let Some(id) = agent["id"].as_str() else { return };
    put(out, subject, Field::Credit { role: role.into() }, json!({
        "agent": ExternalRef::mbid(RefKind::Agent, id),
        "name": name.or_else(|| agent["name"].as_str()).unwrap_or(""),
        "detail": detail,
    }));
}

fn artist_credits(out: &mut Lookup, subject: &ExternalRef, credits: &Value, role: &str) {
    for entry in credits.as_array().into_iter().flatten() {
        credit(out, subject, &entry["artist"], entry["name"].as_str(), role, None);
    }
}

fn attributes(relation: &Value) -> Option<String> {
    let attributes: Vec<_> = relation["attributes"].as_array().into_iter().flatten().filter_map(Value::as_str).filter(|s| !s.is_empty()).collect();
    (!attributes.is_empty()).then(|| attributes.join(", "))
}

fn thread(out: &mut Lookup, subject: &ExternalRef, to: ExternalRef, name: &str, kind: ThreadKind, detail: Option<String>) {
    out.threads.push(ThreadClaim {
        from: subject.clone(), to, to_name: name.into(), kind, detail, provenance: provenance(subject),
    });
}

/// Release facts and the positions of its recordings.
pub fn release(subject: &ExternalRef, value: &Value) -> Lookup {
    let mut out = Lookup::default();
    if let Some(title) = value["title"].as_str() {
        put(&mut out, subject, Field::Title, title.into());
    }
    for label in value["label-info"].as_array().into_iter().flatten() {
        for (field, text) in [(Field::Label, &label["label"]["name"]), (Field::CatalogNumber, &label["catalog-number"])] {
            if let Some(text) = text.as_str().filter(|text| !text.is_empty() && *text != "[none]") {
                put(&mut out, subject, field, text.into());
            }
        }
    }
    if let Some(id) = value["release-group"]["id"].as_str() {
        put(&mut out, subject, Field::SameAs, json!(ExternalRef { namespace: "mb_release_group".into(), kind: RefKind::Release, value: id.into() }));
    }
    artist_credits(&mut out, subject, &value["artist-credit"], "album_artist");
    for medium in value["media"].as_array().into_iter().flatten() {
        for track in medium["tracks"].as_array().into_iter().flatten() {
            let recording = &track["recording"];
            let Some(id) = recording["id"].as_str() else { continue };
            let recording_ref = ExternalRef::mbid(RefKind::Recording, id);
            let title = track["title"].as_str().or_else(|| recording["title"].as_str());
            if let (Some(disc), Some(position), Some(title)) = (medium["position"].as_u64(), track["position"].as_u64(), title) {
                put(&mut out, &recording_ref, Field::Position, json!({ "release": subject.value, "disc": disc, "track": position, "title": title }));
            }
            if let Some(title) = title {
                put(&mut out, &recording_ref, Field::Title, title.into());
            }
            if let Some(length) = track["length"].as_u64().or_else(|| recording["length"].as_u64()) {
                put(&mut out, &recording_ref, Field::LengthMs, length.into());
            }
            let credits = if track["artist-credit"].is_array() { &track["artist-credit"] } else { &recording["artist-credit"] };
            artist_credits(&mut out, &recording_ref, credits, "artist");
        }
    }
    out
}

/// Recording facts, performers and related works.
pub fn recording(subject: &ExternalRef, value: &Value) -> Lookup {
    let mut out = Lookup::default();
    title_and_length(&mut out, subject, value);
    if let Some(credits) = value["artist-credit"].as_array() {
        let mut printed = String::new();
        for entry in credits {
            printed.push_str(entry["name"].as_str().or_else(|| entry["artist"]["name"].as_str()).unwrap_or(""));
            printed.push_str(entry["joinphrase"].as_str().unwrap_or(""));
        }
        put(&mut out, subject, Field::ArtistCredit, printed.into());
    }
    artist_credits(&mut out, subject, &value["artist-credit"], "artist");
    for isrc in value["isrcs"].as_array().into_iter().flatten().filter_map(Value::as_str) {
        put(&mut out, subject, Field::Isrc, isrc.into());
    }
    for relation in value["relations"].as_array().into_iter().flatten() {
        if relation["target-type"] == "work" && relation["type"] == "performance" {
            if let Some(id) = relation["work"]["id"].as_str() {
                thread(&mut out, subject, ExternalRef::mbid(RefKind::Work, id), relation["work"]["title"].as_str().unwrap_or(""), ThreadKind::RecordingOf, attributes(relation));
            }
            continue;
        }
        if relation["target-type"] != "artist" {
            continue;
        }
        let role = match relation["type"].as_str() {
            Some("instrument" | "vocal" | "performer" | "performing orchestra") => "performer",
            Some("conductor") => "conductor",
            Some("producer") => "producer",
            Some("engineer" | "recording" | "audio" | "mix" | "sound") => "engineer",
            Some("arranger" | "instrument arranger" | "vocal arranger" | "orchestrator") => "arranger",
            _ => continue,
        };
        let detail = attributes(relation).or_else(|| (relation["type"] == "vocal").then(|| "vocals".into()));
        credit(&mut out, subject, &relation["artist"], None, role, detail);
    }
    out
}

fn relationship_detail(relation: &Value) -> Option<String> {
    let year = |key: &str| relation[key].as_str().and_then(|s| s.split('-').next()).filter(|s| !s.is_empty());
    let (begin, end) = (year("begin"), year("end"));
    let dates = (begin.is_some() || end.is_some()).then(|| format!("{}–{}", begin.unwrap_or(""), end.unwrap_or("")));
    match (attributes(relation), dates) {
        (Some(attributes), Some(dates)) => Some(format!("{attributes}, {dates}")),
        (attributes, dates) => attributes.or(dates),
    }
}

/// Artist identity, membership and collaborations.
pub fn artist(subject: &ExternalRef, value: &Value) -> Lookup {
    let mut out = Lookup::default();
    if let Some(name) = value["name"].as_str() {
        put(&mut out, subject, Field::Title, name.into());
    }
    if let Some(name) = value["sort-name"].as_str() {
        put(&mut out, subject, Field::SortName, name.into());
    }
    let agent_type = match value["type"].as_str() {
        Some("Person") => Some("person"),
        Some("Group" | "Orchestra" | "Choir") => Some("group"),
        _ => None,
    };
    if let Some(agent_type) = agent_type {
        put(&mut out, subject, Field::AgentType, agent_type.into());
    }
    for relation in value["relations"].as_array().into_iter().flatten() {
        if relation["target-type"] != "artist" {
            continue;
        }
        let kind = match (relation["type"].as_str(), relation["direction"].as_str()) {
            (Some("member of band"), Some("forward")) => ThreadKind::MemberOf,
            (Some("member of band"), Some("backward")) => ThreadKind::HasMember,
            (Some("collaboration" | "supporting musician"), _) => ThreadKind::WorkedWith,
            _ => continue,
        };
        if let Some(id) = relation["artist"]["id"].as_str() {
            thread(&mut out, subject, ExternalRef::mbid(RefKind::Agent, id), relation["artist"]["name"].as_str().unwrap_or(""), kind, relationship_detail(relation));
        }
    }
    out
}

/// Work credits and the first page of known recordings.
pub fn work(subject: &ExternalRef, value: &Value, browse: &Value) -> Lookup {
    let mut out = Lookup::default();
    let title = value["title"].as_str();
    if let Some(title) = title {
        put(&mut out, subject, Field::Title, title.into());
    }
    if let Some(count) = browse["recording-count"].as_u64() {
        put(&mut out, subject, Field::RecordingCount, count.into());
    }
    for relation in value["relations"].as_array().into_iter().flatten() {
        if relation["target-type"] != "artist" {
            continue;
        }
        let role = match relation["type"].as_str() {
            Some("composer" | "writer") => "composer",
            Some("lyricist" | "librettist") => "lyricist",
            Some("arranger") => "arranger",
            _ => continue,
        };
        credit(&mut out, subject, &relation["artist"], None, role, attributes(relation));
    }
    for recording in browse["recordings"].as_array().into_iter().flatten() {
        let Some(id) = recording["id"].as_str() else { continue };
        let recording_ref = ExternalRef::mbid(RefKind::Recording, id);
        title_and_length(&mut out, &recording_ref, recording);
        artist_credits(&mut out, &recording_ref, &recording["artist-credit"], "artist");
        thread(&mut out, &recording_ref, subject.clone(), title.unwrap_or(""), ThreadKind::RecordingOf, None);
    }
    out
}

#[cfg(test)]
mod tests;
