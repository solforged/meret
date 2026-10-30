//! A search's filters narrow its hit strip, stay on its trail stop, and a
//! `play` with nothing matching says so. Its own binary because a process
//! starts one core.

use meret_api::{Api, HitDto, ItemDto, SortKeyDto, TargetDto, ViewDto};

fn titles(hits: &[HitDto]) -> Vec<&str> {
    hits.iter().map(|hit| hit.title.as_str()).collect()
}

#[test]
fn filters_narrow_hits_and_refine_the_trail_stop() {
    let dir = std::env::temp_dir().join(format!("meret-api-refine-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let core = meret_core::start(meret_core::CoreConfig {
        data_dir: dir.clone(), output: meret_core::OutputChoice::Null { speed: 1.0 }, contact: "test".into(),
    }).unwrap();
    core.runtime.block_on(core.scans_settled()).unwrap();
    // Tyranny (2017, one disc) has the choir on its track; Tyranny Deluxe (2018) has two discs and no choir.
    core.store.writer.write(|tx| {
        tx.execute_batch("
            INSERT INTO agent (id, kind, name, rev) VALUES (1, 0, 'Tyranny Choir', 1);
            INSERT INTO release (id, title, year, idiom, rev) VALUES (1, 'Tyranny', 2017, 1, 1), (2, 'Tyranny Deluxe', 2018, 1, 1);
            INSERT INTO edition (id, release_id, rev) VALUES (1, 1, 1), (2, 2, 1);
            INSERT INTO medium (id, edition_id, position) VALUES (1, 1, 1), (2, 2, 1), (3, 2, 2);
            INSERT INTO recording (id, title, length_ms, rev) VALUES (1, 'Opening', 100000, 1), (2, 'Second', 100000, 1), (3, 'Third', 100000, 1);
            INSERT INTO track (id, medium_id, position, recording_id, length_ms, rev) VALUES (1, 1, 1, 1, 100000, 1), (2, 2, 1, 2, 100000, 1), (3, 3, 1, 3, 100000, 1);
            INSERT INTO credit (subject_kind, subject_id, agent_id, role, rev) VALUES (2, 1, 1, 'artist', 1);
            INSERT INTO root (id, label, path, kind, state) VALUES (1, 'Test root', '/test', 'local', 'online');
            INSERT INTO file (id, root_id, rel_path, size, mtime_ns, state, added_at, rev) VALUES
                (1, 1, 'a.flac', 1, 1, 'present', 1000, 1), (2, 1, 'b.flac', 1, 1, 'present', 1000, 1), (3, 1, 'c.flac', 1, 1, 'present', 1000, 1);
            INSERT INTO source (id, recording_id, track_id, kind, file_id, codec, sample_rate, bits, lossless, rev) VALUES
                (1, 1, 1, 'file', 1, 'FLAC', 44100, 16, 1, 1), (2, 2, 2, 'file', 2, 'FLAC', 44100, 16, 1, 1), (3, 3, 3, 'file', 3, 'FLAC', 44100, 16, 1, 1);
        ")?;
        for release in [1, 2] {
            meret_store::search::index_release(tx, release)?;
        }
        meret_store::search::index_agent(tx, 1)?;
        for recording in [1, 2, 3] {
            meret_store::search::index_recording(tx, recording)?;
        }
        Ok(())
    }).unwrap();
    *core.columns.write() = core.store.load_columns().unwrap();
    let api = Api::new(core.clone());

    let plain = api.search("tyranny").unwrap();
    let mut releases = titles(&plain.releases);
    releases.sort_unstable();
    assert_eq!((releases, titles(&plain.people)), (vec!["Tyranny", "Tyranny Deluxe"], vec!["Tyranny Choir"]));

    // 06: a filter that drops a release's tracks drops its hit, and a person's.
    let narrowed = api.search("tyranny year:2018").unwrap();
    assert_eq!((narrowed.tracks, titles(&narrowed.releases), narrowed.releases_total), (2, vec!["Tyranny Deluxe"], 1));
    assert_eq!((titles(&narrowed.people), narrowed.people_total), (vec![], 0));
    let empty = api.search("tyranny year:1900").unwrap();
    assert_eq!((empty.tracks, empty.releases.len(), empty.people.len()), (0, 0, 0));

    // Q3: the trail's search takes the filters, so the stop comes back with them.
    let root = api.start_trail(TargetDto::Search { query: "tyranny".into() });
    let followed = api.follow(root.current, TargetDto::Release { id: 1 }, meret_api::ThreadKind::Matched, "library").unwrap();
    assert_eq!(followed.stops.len(), 2);
    let refined = api.refine_search("tyranny year:2018").unwrap();
    assert_eq!(refined.root_query.as_deref(), Some("tyranny year:2018"));
    assert_eq!((refined.stops[0].title.as_str(), refined.current, refined.stops.len()), ("tyranny year:2018", followed.current, 2));
    assert_eq!(refined.stops[0].target, TargetDto::Search { query: "tyranny year:2018".into() });
    assert_eq!(api.trail().unwrap(), refined);
    assert!(api.refine_search("play tyranny").is_err(), "a command isn't a search");
    api.start_trail(TargetDto::Release { id: 1 });
    assert!(api.refine_search("tyranny").is_err(), "only a search's trail has one to refine");

    // 18b: a track knows its release's disc count, so the table labels it like the release page.
    let rows = api.rows("", ViewDto { sort: SortKeyDto::Library, descending: false, group: false }, 0, 10).unwrap();
    let discs: Vec<_> = rows.items.iter().map(|item| match item {
        ItemDto::Track { row, discs, .. } => (row.title.as_str(), row.disc, *discs),
        ItemDto::Group(_) => panic!("ungrouped"),
    }).collect();
    assert_eq!(discs, [("Opening", 1, 1), ("Second", 1, 2), ("Third", 2, 2)]);

    // Q7: nothing matched, so nothing plays and the caller is told.
    assert_eq!(api.run_command("play zzzzqqq").unwrap_err(), "No tracks match");
    drop(api);
    drop(core);
    std::fs::remove_dir_all(dir).unwrap();
}
