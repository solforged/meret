//! Why Play something has nothing to offer, and the missing-files list, against
//! a real store. Its own binary because a process starts one core.

use meret_api::{Api, NothingToPlayKind};
use meret_core::{CoreConfig, OutputChoice};

fn kind(api: &Api) -> Option<NothingToPlayKind> {
    api.nothing_to_play().unwrap().map(|nothing| nothing.kind)
}

#[test]
fn nothing_to_play_names_whether_music_is_absent_offline_or_played() {
    let dir = std::env::temp_dir().join(format!("meret-api-nothing-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let core = meret_core::start(CoreConfig { data_dir: dir.clone(), output: OutputChoice::Null { speed: 1.0 }, contact: "test".into() }).unwrap();
    core.runtime.block_on(core.scans_settled()).unwrap();
    let api = Api::new(core.clone());
    let reload = || *core.columns.write() = core.store.load_columns().unwrap();

    assert_eq!(kind(&api), Some(NothingToPlayKind::NoMusic));
    assert_eq!(api.nothing_to_play().unwrap().unwrap().label, "Add a music folder");

    // One release, in a folder that isn't mounted, and one file that has gone.
    core.store.writer.write(|tx| tx.execute_batch("
        INSERT INTO release (id, title, idiom, rev) VALUES (1, 'Away', 1, 1);
        INSERT INTO edition (id, release_id, rev) VALUES (1, 1, 1);
        INSERT INTO medium (id, edition_id, position) VALUES (1, 1, 1);
        INSERT INTO recording (id, title, length_ms, rev) VALUES (1, 'Far', 100000, 1), (2, 'Gone', 100000, 1);
        INSERT INTO track (id, medium_id, position, recording_id, title, length_ms, rev) VALUES (1, 1, 1, 1, 'Far', 100000, 1), (2, 1, 2, 2, 'Gone', 100000, 1);
        INSERT INTO root (id, label, path, kind, state) VALUES (1, 'Archive', '/archive', 'local', 'offline'), (2, 'Music', '/music', 'local', 'online');
        INSERT INTO file (id, root_id, rel_path, size, mtime_ns, state, added_at, rev) VALUES
            (1, 1, 'far.flac', 1, 1, 'present', 1000, 1), (2, 2, 'disc 1/gone.flac', 1, 1, 'missing', 1000, 1);
        INSERT INTO source (id, recording_id, track_id, kind, file_id, codec, sample_rate, bits, lossless, rev) VALUES
            (1, 1, 1, 'file', 1, 'FLAC', 44100, 16, 1, 1), (2, 2, 2, 'file', 2, 'FLAC', 44100, 16, 1, 1);
    ")).unwrap();
    reload();
    assert_eq!(kind(&api), Some(NothingToPlayKind::FoldersOffline), "the library holds tracks, and the folder with them is away");
    assert_eq!(api.nothing_to_play().unwrap().unwrap().label, "Folders offline");

    let missing = api.missing_files().unwrap();
    assert_eq!(missing.len(), 1);
    assert_eq!((missing[0].track_id, missing[0].title.as_str(), missing[0].file.as_str(), missing[0].folder.as_str()),
        (2, "Gone", "disc 1/gone.flac", "Music"));
    let front = api.front().unwrap();
    let line = front.needs_you.iter().find(|line| line.missing_files).unwrap();
    assert_eq!((line.label.as_str(), line.count), ("Missing files", missing.len() as u64));
    assert_eq!(front.releases, 1, "an offline release counts, as its tracks do in All tracks");
    let roots: Vec<_> = front.roots.iter().map(|r| (r.label.as_str(), r.missing)).collect();
    assert_eq!(roots, [("Archive", 0), ("Music", 1)]);

    // The folder comes back: there is something to play.
    core.store.writer.write(|tx| tx.execute_batch("UPDATE root SET state = 'online' WHERE id = 1;")).unwrap();
    reload();
    assert_eq!(kind(&api), None);

    // Played through, with every folder mounted: nothing left but to wait.
    let uid = meret_model::ListenUid::new();
    core.store.start_listen(uid, meret_model::RecordingId(1), None, "local".into(), 1, None, core.store.device_id().unwrap()).unwrap();
    core.store.update_listen(uid, 100_000).unwrap();
    assert_eq!(kind(&api), Some(NothingToPlayKind::PlayedAll));
    assert_eq!(api.nothing_to_play().unwrap().unwrap().label, "Nothing to play yet");
    drop(api);
    drop(core);
    let _ = std::fs::remove_dir_all(dir);
}
