use super::*;

fn fixture(text: &str) -> Value {
    serde_json::from_str(text).unwrap()
}

fn values<'a>(lookup: &'a Lookup, subject: &ExternalRef, field: Field) -> Vec<&'a Value> {
    lookup.claims.iter().filter(|c| c.subject == *subject && c.field == field).map(|c| &c.value).collect()
}

#[test]
fn reads_release_positions_and_ordered_album_credits() {
    let value = fixture(include_str!("../../tests/fixtures/release.json"));
    let subject = ExternalRef::mbid(RefKind::Release, value["id"].as_str().unwrap());
    let lookup = release(&subject, &value);
    assert_eq!(values(&lookup, &subject, Field::Title), vec![&json!("Tenchu 2")]);
    assert_eq!(values(&lookup, &subject, Field::SameAs), vec![&json!(ExternalRef {
        namespace: "mb_release_group".into(), kind: RefKind::Release, value: "f12c0cd3-0e72-41f0-a405-9576bd5b3604".into(),
    })]);
    let recording = ExternalRef::mbid(RefKind::Recording, "6050819b-b2d5-48d4-872b-3cc5d0db978f");
    assert_eq!(values(&lookup, &recording, Field::Position), vec![&json!({"release":subject.value,"disc":1,"track":1,"title":"Hyouteki (Abin Barba)"})]);
    assert_eq!(values(&lookup, &recording, Field::LengthMs), vec![&json!(179000)]);
    assert_eq!(values(&lookup, &subject, Field::Credit { role: "album_artist".into() })[0]["name"], "Nera Vale");
    assert_eq!(values(&lookup, &recording, Field::Credit { role: "artist".into() })[0]["name"], "Nera Vale");
}

#[test]
fn release_skips_absent_labels_and_uses_recording_credit_fallback() {
    let value = json!({
        "label-info":[{"label":{"name":"Cloud Label"},"catalog-number":"CL-1"},{"label":null,"catalog-number":"[none]"},{"label":{"name":"[none]"},"catalog-number":null}],
        "artist-credit":[{"name":"Tavi","artist":{"id":"a"}},{"name":"Nera","artist":{"id":"b"}}],
        "media":[{"position":2,"tracks":[{"position":7,"title":"Track title","recording":{"id":"rec","title":"Recording title","length":42,"artist-credit":[{"artist":{"id":"a","name":"Tavi"}}]}}]}]
    });
    let subject = ExternalRef::mbid(RefKind::Release, "release");
    let lookup = release(&subject, &value);
    assert_eq!(values(&lookup, &subject, Field::Label), vec![&json!("Cloud Label")]);
    assert_eq!(values(&lookup, &subject, Field::CatalogNumber), vec![&json!("CL-1")]);
    let credits = values(&lookup, &subject, Field::Credit { role: "album_artist".into() });
    assert_eq!(credits.iter().map(|v| v["agent"]["value"].as_str().unwrap()).collect::<Vec<_>>(), vec!["a", "b"]);
    let rec = ExternalRef::mbid(RefKind::Recording, "rec");
    assert_eq!(values(&lookup, &rec, Field::Title), vec![&json!("Track title")]);
    assert_eq!(values(&lookup, &rec, Field::Position)[0]["disc"], 2);
    assert_eq!(values(&lookup, &rec, Field::Position)[0]["track"], 7);
    assert_eq!(values(&lookup, &rec, Field::LengthMs), vec![&json!(42)]);
    assert_eq!(values(&lookup, &rec, Field::Credit { role: "artist".into() })[0]["name"], "Tavi");
}

#[test]
fn reads_recording_title_length_and_printed_credits() {
    for (text, title, length, printed) in [
        (include_str!("../../tests/fixtures/recording.json"), "宿命～SADAME～", 187933, "Luma Fen"),
        (include_str!("../../tests/fixtures/recording2.json"), "Diplomacy: Middle Eastern Early Peace", 76000, "Ruvo Fen & Tavi Wren"),
    ] {
        let value = fixture(text);
        let subject = ExternalRef::mbid(RefKind::Recording, value["id"].as_str().unwrap());
        let lookup = recording(&subject, &value);
        assert_eq!(values(&lookup, &subject, Field::Title), vec![&json!(title)]);
        assert_eq!(values(&lookup, &subject, Field::LengthMs), vec![&json!(length)]);
        assert_eq!(values(&lookup, &subject, Field::ArtistCredit), vec![&json!(printed)]);
        let credits = values(&lookup, &subject, Field::Credit { role: "artist".into() });
        assert_eq!(credits.len(), value["artist-credit"].as_array().unwrap().len());
        assert!(credits.iter().all(|credit| credit["detail"].is_null()));
    }
}

#[test]
fn recording_relations_map_roles_and_work_performances() {
    let mut relations = vec![
        json!({"type":"instrument","direction":"backward","target-type":"artist","attributes":["electric guitar","guest"],"begin":null,"end":null,"artist":{"id":"guitar","name":"Nera Vale"}}),
        json!({"type":"vocal","direction":"backward","target-type":"artist","attributes":[],"begin":null,"end":null,"artist":{"id":"voice","name":"Tavi Wren"}}),
        json!({"type":"performance","direction":"forward","target-type":"work","attributes":["live","partial"],"begin":null,"end":null,"work":{"id":"work","title":"Cloud Study"}}),
        json!({"type":"performance","direction":"forward","target-type":"work","attributes":[],"begin":null,"end":null,"work":{"id":"work2","title":"Sky Study"}}),
        json!({"type":"unrelated","target-type":"artist","artist":{"id":"ignored"}}),
    ];
    let mappings = [
        ("performer", "performer"), ("performing orchestra", "performer"), ("conductor", "conductor"), ("producer", "producer"),
        ("engineer", "engineer"), ("recording", "engineer"), ("audio", "engineer"), ("mix", "engineer"), ("sound", "engineer"),
        ("arranger", "arranger"), ("instrument arranger", "arranger"), ("vocal arranger", "arranger"), ("orchestrator", "arranger"),
    ];
    for (kind, _) in mappings {
        relations.push(json!({"type":kind,"direction":"backward","target-type":"artist","attributes":[],"begin":null,"end":null,"artist":{"id":kind,"name":"Ruvo Fen"}}));
    }
    let subject = ExternalRef::mbid(RefKind::Recording, "recording");
    let lookup = recording(&subject, &json!({"isrcs":["ZZABC2600001"],"relations":relations}));
    assert_eq!(values(&lookup, &subject, Field::Isrc), vec![&json!("ZZABC2600001")]);
    let performers = values(&lookup, &subject, Field::Credit { role: "performer".into() });
    assert_eq!(performers[0]["detail"], "electric guitar, guest");
    assert_eq!(performers[1]["detail"], "vocals");
    for (kind, role) in mappings {
        assert!(values(&lookup, &subject, Field::Credit { role: role.into() }).iter().any(|c| c["agent"]["value"] == kind));
    }
    assert_eq!(lookup.claims.len(), 1 + 2 + mappings.len());
    assert_eq!(lookup.threads.len(), 2);
    assert_eq!(lookup.threads[0].from, subject);
    assert_eq!(lookup.threads[0].to, ExternalRef::mbid(RefKind::Work, "work"));
    assert_eq!(lookup.threads[0].to_name, "Cloud Study");
    assert_eq!(lookup.threads[0].kind, ThreadKind::RecordingOf);
    assert_eq!(lookup.threads[0].detail.as_deref(), Some("live, partial"));
    assert_eq!(lookup.threads[1].detail, None);
}

#[test]
fn reads_artist_identity_and_membership() {
    let value = fixture(include_str!("../../tests/fixtures/artist.json"));
    let subject = ExternalRef::mbid(RefKind::Agent, value["id"].as_str().unwrap());
    let lookup = artist(&subject, &value);
    assert_eq!(values(&lookup, &subject, Field::Title), vec![&json!("Nera Vale")]);
    assert_eq!(values(&lookup, &subject, Field::SortName), vec![&json!("Vale, Nera")]);
    assert_eq!(values(&lookup, &subject, Field::AgentType), vec![&json!("person")]);
    assert_eq!(lookup.threads.len(), 1);
    assert_eq!(lookup.threads[0].kind, ThreadKind::MemberOf);
    assert_eq!(lookup.threads[0].to_name, "Nera & GANG");
    assert_eq!(lookup.threads[0].detail, None);
}

#[test]
fn artist_membership_direction_and_dates_are_preserved() {
    let subject = ExternalRef::mbid(RefKind::Agent, "artist");
    let value = json!({"type":"Group","relations":[
        {"type":"member of band","direction":"forward","target-type":"artist","attributes":["lead vocals"],"begin":"1990-03-04","end":"1998","artist":{"id":"band","name":"Cloud Ensemble"}},
        {"type":"member of band","direction":"backward","target-type":"artist","attributes":[],"begin":"1990","end":null,"artist":{"id":"member","name":"Nera Vale"}},
        {"type":"collaboration","direction":"forward","target-type":"artist","attributes":[],"begin":null,"end":null,"artist":{"id":"peer","name":"Tavi Wren"}},
        {"type":"supporting musician","direction":"backward","target-type":"artist","attributes":["guest"],"begin":null,"end":"2005-02","artist":{"id":"peer2","name":"Ruvo Fen"}}
    ]});
    let lookup = artist(&subject, &value);
    assert_eq!(values(&lookup, &subject, Field::AgentType), vec![&json!("group")]);
    assert_eq!(lookup.threads.iter().map(|t| (t.kind, t.detail.as_deref())).collect::<Vec<_>>(), vec![
        (ThreadKind::MemberOf, Some("lead vocals, 1990–1998")),
        (ThreadKind::HasMember, Some("1990–")),
        (ThreadKind::WorkedWith, None),
        (ThreadKind::WorkedWith, Some("guest, –2005")),
    ]);
    assert!(lookup.threads.iter().all(|t| t.from == subject));
    assert_eq!(ThreadKind::HasMember.label(), "has member");
}

#[test]
fn work_credits_and_browse_recordings_form_one_lookup() {
    let subject = ExternalRef::mbid(RefKind::Work, "work");
    let mut relations = Vec::new();
    for kind in ["composer", "writer", "lyricist", "librettist", "arranger", "ignored"] {
        relations.push(json!({"type":kind,"direction":"backward","target-type":"artist","attributes":[],"begin":null,"end":null,"artist":{"id":kind,"name":"Nera Vale"}}));
    }
    let browse = json!({"recording-count":213,"recording-offset":0,"recordings":[
        {"id":"rec","title":"Cloud Study live","length":12345,"artist-credit":[{"name":"Tavi Wren","joinphrase":"","artist":{"id":"performer","name":"Tavi Wren"}}]},
        {"id":"rec2","title":"Cloud Study","length":null,"artist-credit":[]}
    ]});
    let lookup = work(&subject, &json!({"title":"Cloud Study","relations":relations}), &browse);
    assert_eq!(values(&lookup, &subject, Field::RecordingCount), vec![&json!(213)]);
    for (role, count) in [("composer", 2), ("lyricist", 2), ("arranger", 1)] {
        assert_eq!(values(&lookup, &subject, Field::Credit { role: role.into() }).len(), count);
    }
    let rec = ExternalRef::mbid(RefKind::Recording, "rec");
    assert_eq!(values(&lookup, &rec, Field::Title), vec![&json!("Cloud Study live")]);
    assert_eq!(values(&lookup, &rec, Field::LengthMs), vec![&json!(12345)]);
    assert_eq!(values(&lookup, &rec, Field::Credit { role: "artist".into() })[0]["name"], "Tavi Wren");
    assert_eq!(lookup.threads.len(), 2);
    assert_eq!(lookup.threads[0].from, rec);
    assert!(lookup.threads.iter().all(|t| t.to == subject && t.kind == ThreadKind::RecordingOf && t.to_name == "Cloud Study"));
    assert_eq!(work(&subject, &Value::Null, &Value::Null), Lookup::default());
}
