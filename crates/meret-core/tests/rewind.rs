//! A listen that counted keeps counting when the playhead goes back. Its own
//! binary because a process starts one core.

use std::time::{Duration, Instant};

use meret_core::{CoreConfig, OutputChoice};

fn wait_for(what: &str, mut ready: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !ready() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn rewinding_a_paused_counted_listen_leaves_its_play_in_every_total() {
    let dir = std::env::temp_dir().join(format!("meret-core-rewind-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(dir.join("music")).unwrap();
    // The fixture is eight seconds long, so half is four; at 2x the pause lands at about 2.5 s of the 4 s it takes.
    std::fs::copy(concat!(env!("CARGO_MANIFEST_DIR"), "/../../apps/meret/test/fixtures/tone-16-44.flac"), dir.join("music/tone.flac")).unwrap();
    let core = meret_core::start(CoreConfig {
        data_dir: dir.clone(), output: OutputChoice::Null { speed: 2.0 }, contact: "test".into(),
    }).unwrap();
    core.add_root(&dir.join("music")).unwrap();
    core.runtime.block_on(core.scans_settled()).unwrap();
    let track = core.columns.read().track[0];
    let release = core.store.track_rows(&[track]).unwrap()[0].release;

    core.play_release(release, 0).unwrap();
    wait_for("past halfway", || core.now().borrow().anchor.is_some_and(|a| a.rate > 0.0
        && a.seconds_at(meret_engine::clock::now_ns()) >= 4.5));
    core.pause();
    wait_for("the pause to count the listen", || core.columns.read().plays[0] == 1);
    let played = core.store.history(1).unwrap()[0].played_ms;
    assert!((4_000..8_000).contains(&played), "{played}");

    core.previous().unwrap();
    wait_for("the rewind", || core.now().borrow().anchor.is_some_and(|a| a.rate == 0.0 && a.position_frames == 0));
    // The checkpoint the rewind triggers runs on the event pump.
    std::thread::sleep(Duration::from_millis(300));

    let history = core.store.history(10).unwrap();
    assert_eq!(history.len(), 1);
    assert!(history[0].counted, "the listen still counts: {} ms", history[0].played_ms);
    assert!(history[0].played_ms >= played, "{} < {played}", history[0].played_ms);
    assert_eq!(core.columns.read().plays, [1]);
    assert_eq!(core.store.most_played(0, 5).unwrap().iter().map(|p| (p.track, p.plays)).collect::<Vec<_>>(), [(track, 1)]);
    assert_eq!(core.store.release_plays(release).unwrap().0, 1);
    drop(core);
    let _ = std::fs::remove_dir_all(dir);
}
