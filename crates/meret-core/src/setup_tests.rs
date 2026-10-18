use super::*;

fn directory(name: &str) -> PathBuf {
    std::env::temp_dir().join(format!("meret-{name}-{}-{}", std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()))
}

#[test]
fn removing_and_readding_a_root_hides_and_restores_rows_without_deleting_them() {
    let dir = directory("root-removal");
    let music = dir.join("music");
    std::fs::create_dir_all(&music).unwrap();
    std::fs::copy(concat!(env!("CARGO_MANIFEST_DIR"), "/../../apps/meret/test/fixtures/tone-16-44.flac"), music.join("tone.flac")).unwrap();
    let (scans, requests) = crossbeam_channel::unbounded();
    let core = Core::new(CoreConfig { data_dir: dir.clone(), output: OutputChoice::Null { speed: 1.0 }, contact: "test".into() }, scans).unwrap();
    std::thread::scope(|scope| {
        scope.spawn(|| {
            for _ in 0..5 {
                scan::handle(&core, requests.recv().unwrap());
            }
        });
        let root = core.add_root(&music).unwrap();
        core.runtime.block_on(core.scans_settled()).unwrap();
        let before = core.status.borrow().library_version;
        let original = core.rows("", &View::default(), 0, 10).unwrap();
        assert_eq!(original.tracks, 1);
        let track = core.columns.read().track[0];
        let front = core.front().unwrap();
        assert_eq!(front.roots[0].tracks, 1);
        assert_eq!(front.roots[0].label, "music");
        core.remove_root(root).unwrap();
        assert!(core.status.borrow().library_version > before);
        assert_eq!(core.rows("", &View::default(), 0, 10).unwrap().tracks, 0);
        assert_eq!(core.facets("").unwrap().idioms.tracks, 0);
        assert_eq!(core.search("", 0, 10).unwrap().tracks, 0);
        let removed = core.front().unwrap();
        assert_eq!((removed.tracks, removed.facts.added_lately.len(), removed.roots.len()), (0, 0, 0));
        assert!(removed.facts.releases_by_idiom.iter().all(|n| *n == 0));
        core.store.read(|c| {
            assert_eq!(c.query_row("SELECT state FROM root WHERE id = ?1", [root.0], |r| r.get::<_, String>(0))?, "removed");
            assert_eq!(c.query_row("SELECT COUNT(*) FROM track", [], |r| r.get::<_, i64>(0))?, 1);
            assert_eq!(c.query_row("SELECT COUNT(*) FROM file", [], |r| r.get::<_, i64>(0))?, 1);
            Ok(())
        }).unwrap();
        let removed_version = core.status.borrow().library_version;
        assert_eq!(core.add_root(&music).unwrap(), root);
        core.runtime.block_on(core.scans_settled()).unwrap();
        assert!(core.status.borrow().library_version > removed_version);
        assert_eq!(core.rows("", &View::default(), 0, 10).unwrap().tracks, 1);
        assert_eq!(core.columns.read().track[0], track);
        assert_eq!(core.front().unwrap().roots[0].tracks, 1);
    });
    drop(core);
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn saved_settings_override_startup_output_but_absent_settings_keep_host_defaults() {
    let dir = directory("startup-settings");
    let config = CoreConfig { data_dir: dir.clone(), output: OutputChoice::System { device: Some("host-default".into()), exclusive: false }, contact: "test".into() };
    let (scans, _) = crossbeam_channel::unbounded();
    let core = Core::new(config.clone(), scans).unwrap();
    assert_eq!(core.settings(), Settings { output_device: Some("host-default".into()), exclusive: false, ..Settings::default() });
    let saved = Settings { light: LightLevel::AccentAndWash, output_device: Some("saved-device".into()), exclusive: true };
    core.set_settings(saved.clone()).unwrap();
    drop(core);
    let (scans, _) = crossbeam_channel::unbounded();
    let core = Core::new(config, scans).unwrap();
    assert_eq!(core.settings(), saved);
    assert!(matches!(&core.config.output, OutputChoice::System { device: Some(device), exclusive: true } if device == "saved-device"));
    core.set_settings(Settings::default()).unwrap();
    drop(core);
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn front_format_counts_match_any_copy_queries() {
    let dir = directory("front-formats");
    let (scans, _) = crossbeam_channel::unbounded();
    let core = Core::new(CoreConfig { data_dir: dir.clone(), output: OutputChoice::Null { speed: 1.0 }, contact: "test".into() }, scans).unwrap();
    core.store.writer.write(|tx| {
        tx.execute_batch(
            "INSERT INTO release(id,title,rev) VALUES(1,'Mixed copies',1);
             INSERT INTO edition(id,release_id,rev) VALUES(1,1,1);
             INSERT INTO medium(id,edition_id,position) VALUES(1,1,1);
             INSERT INTO recording(id,title,rev) VALUES
                 (1,'FLAC and MP3',1),(2,'CD and hi-res',1),(3,'DSD',1),
                 (4,'Chiptune',1),(5,'Lossy',1),(6,'Unknown',1);
             INSERT INTO track(id,medium_id,recording_id,position,rev) VALUES
                 (1,1,1,1,1),(2,1,2,2,1),(3,1,3,3,1),
                 (4,1,4,4,1),(5,1,5,5,1),(6,1,6,6,1);
             INSERT INTO root(id,label,path,kind) VALUES(1,'test','/test','local');
             INSERT INTO file(id,root_id,rel_path,size,mtime_ns,rev) VALUES
                 (1,1,'1.flac',1,1,1),(2,1,'1.mp3',1,1,1),(3,1,'1.unknown',1,1,1),
                 (4,1,'2.flac',1,1,1),(5,1,'2-hires.flac',1,1,1),(6,1,'3.dsd',1,1,1),
                 (7,1,'4.spc',1,1,1),(8,1,'5.mp3',1,1,1),(9,1,'6.unknown',1,1,1);
             INSERT INTO source(track_id,kind,file_id,codec,sample_rate,bits,lossless,rev) VALUES
                 (1,'file',1,'FLAC',44100,16,1,1),(1,'file',2,'MP3',44100,NULL,0,1),
                 (1,'file',3,NULL,NULL,NULL,0,1),
                 (2,'file',4,'FLAC',44100,16,1,1),(2,'file',5,'FLAC',96000,24,1,1),
                 (3,'file',6,'DSD',2822400,1,1,1),(4,'file',7,'SPC',32000,16,1,1),
                 (5,'file',8,'MP3',44100,NULL,0,1),(6,'file',9,NULL,NULL,NULL,0,1);"
        )?;
        Ok(())
    }).unwrap();
    *core.columns.write() = core.store.load_columns().unwrap();
    let front = core.front().unwrap();
    let lossy_matches = core.list("format:lossy", &View::default()).unwrap().tracks.len() as u64;
    assert_eq!(lossy_matches, 2);
    let count = |query| front.formats.iter().find(|f| f.query == query).unwrap().count;
    assert_eq!(count(Some("format:lossy")), lossy_matches,
        "Lossy includes the MP3 copy even when playback chooses FLAC");
    for (query, expected) in [
        ("format:flac -format:hires", 1),
        ("format:hires", 1),
        ("format:dsd", 1),
        ("format:chiptune", 1),
        ("format:lossy", 2),
    ] {
        let count = count(Some(query));
        assert_eq!(count, expected, "{query}");
        assert_eq!(count, core.list(query, &View::default()).unwrap().tracks.len() as u64, "{query}");
    }
    assert_eq!(count(None), 1,
        "Unknown format counts only the best copy, not the unknown extra copy of track 1");
    assert_eq!(front.tracks, 6);
    assert_eq!(front.formats.iter().map(|f| f.count).sum::<u64>(), 7,
        "format doors overlap rather than partitioning the collection");
    drop(core);
    std::fs::remove_dir_all(dir).unwrap();
}
