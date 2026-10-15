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
