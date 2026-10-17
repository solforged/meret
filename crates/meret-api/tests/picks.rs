//! Play something's ranking against a real store. Its own binary because a
//! process starts one core.

use std::sync::Arc;

use meret_api::{Api, PickDto, ReleaseDto, TargetDto, ThreadKind, ZoneDto};
use meret_core::{Core, Why};
use meret_model::ReleaseId;

const DAY: i64 = 86_400_000;

/// Four playable releases: 1 dormant, 2 reached on the newest trail but
/// never played, 3 and 4 never played; 5 has no file and is never offered.
fn fixture() -> (Arc<Core>, std::path::PathBuf) {
    let dir = std::env::temp_dir().join(format!("meret-api-picks-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let core = meret_core::start(meret_core::CoreConfig {
        data_dir: dir.clone(), output: meret_core::OutputChoice::Null { speed: 1.0 }, contact: "test".into(),
    }).unwrap();
    core.runtime.block_on(core.scans_settled()).unwrap();
    core.store.writer.write(|tx| {
        tx.execute_batch("
            INSERT INTO release (id, title, idiom, rev) VALUES (1, 'Vanguard', 4, 1), (2, 'Reached', 5, 1), (3, 'Fresh', 1, 1), (4, 'Fresher', 1, 1), (5, 'Gone', 1, 1);
            INSERT INTO edition (id, release_id, rev) VALUES (1, 1, 1), (2, 2, 1), (3, 3, 1), (4, 4, 1), (5, 5, 1);
            INSERT INTO medium (id, edition_id, position) VALUES (1, 1, 1), (2, 2, 1), (3, 3, 1), (4, 4, 1), (5, 5, 1);
            INSERT INTO recording (id, title, length_ms, rev) VALUES (1, 'A', 100000, 1), (2, 'B', 100000, 1), (3, 'C', 100000, 1), (4, 'D', 100000, 1), (5, 'E', 100000, 1);
            INSERT INTO track (id, medium_id, position, recording_id, length_ms, rev) VALUES (1, 1, 1, 1, 100000, 1), (2, 2, 1, 2, 100000, 1), (3, 3, 1, 3, 100000, 1), (4, 4, 1, 4, 100000, 1), (5, 5, 1, 5, 100000, 1);
            INSERT INTO root (id, label, path, kind, state) VALUES (1, 'Test root', '/test', 'local', 'online');
            INSERT INTO file (id, root_id, rel_path, size, mtime_ns, state, added_at, rev) VALUES (1, 1, 'a.flac', 1, 1, 'present', 1000, 1), (2, 1, 'b.flac', 1, 1, 'present', 1000, 1), (3, 1, 'c.flac', 1, 1, 'present', 1000, 1), (4, 1, 'd.flac', 1, 1, 'present', 1000, 1);
            INSERT INTO source (id, recording_id, track_id, kind, file_id, codec, sample_rate, bits, lossless, rev) VALUES (1, 1, 1, 'file', 1, 'FLAC', 44100, 16, 1, 1), (2, 2, 2, 'file', 2, 'FLAC', 44100, 16, 1, 1), (3, 3, 3, 'file', 3, 'AAC', NULL, NULL, 0, 1), (4, 4, 4, 'file', 4, 'FLAC', 44100, 16, 1, 1);
        ")?;
        Ok(())
    }).unwrap();
    (core, dir)
}

fn listen(core: &Core, recording: i64, at: i64, played: u64) {
    let uid = meret_model::ListenUid::new();
    core.store.start_listen(uid, meret_model::RecordingId(recording), None, "local".into(), at, None, core.store.device_id().unwrap()).unwrap();
    core.store.finish_listen(uid, played).unwrap();
}

#[test]
fn picks_rank_dormant_then_the_trail_then_never_played_by_the_day() {
    let (core, dir) = fixture();
    let now = 400 * DAY;
    for at in 1..=5 { listen(&core, 1, at * DAY, 60_000); }
    listen(&core, 2, 390 * DAY, 10_000);
    let api = Api::new(core.clone());
    let root = api.start_trail(TargetDto::Search { query: "reached".into() });
    api.follow(root.current, TargetDto::Release { id: 2 }, ThreadKind::Matched).unwrap();

    let picks = core.picks(5, now).unwrap();
    assert_eq!(picks.iter().map(|p| p.release.0).collect::<Vec<_>>(), [1, 2, 3, 4], "no fifth: it has no file");
    assert_eq!(picks[0].why, Why::Dormant { plays: 5, last_played_ms: 5 * DAY });
    assert_eq!(picks[1].why, Why::FromTrail { trail: "reached".into(), latest: true });
    assert_eq!(picks[2].why, Why::NeverPlayed { added_ms: Some(1000) });
    assert_eq!(core.picks(5, now + DAY).unwrap().iter().map(|p| p.release.0).collect::<Vec<_>>(), [1, 2, 4, 3], "the never-played order rotates daily");
    assert_eq!(core.picks(1, now).unwrap().len(), 1);

    let dto = |i: usize, id: i64| PickDto::new(picks[i].clone(), ReleaseDto::from_page(core.store.release_page(ReleaseId(id)).unwrap().unwrap(), &core.art_dir()), now);
    let dormant = dto(0, 1);
    assert_eq!((dormant.label.as_str(), dormant.reason.as_str(), dormant.plan.as_str(), dormant.meta.as_str()),
        ("Dormant · 1 year", "5 plays, then nothing for 1 year.", "The whole date, in order.", "1 track · 1 min · FLAC 16/44.1"));
    assert_eq!(dormant.why(), "Dormant · 1 year · 5 plays, then nothing for 1 year");
    let reached = dto(1, 2);
    assert_eq!((reached.label.as_str(), reached.reason.as_str(), reached.plan.as_str()),
        ("From your latest trail", "You reached it on reached and haven't played it through.", "The whole score, in order."));
    let fresh = dto(2, 3);
    assert_eq!((fresh.label.as_str(), fresh.reason.as_str(), fresh.meta.as_str()),
        ("Never played", "In your library for 1 year, never played through.", "1 track · 1 min · AAC"));

    // A second, newer trail that reaches nothing new: the first one's release is still offered, as recent.
    api.start_trail(TargetDto::Search { query: "newer".into() });
    assert_eq!(core.picks(5, now).unwrap()[1].why, Why::FromTrail { trail: "reached".into(), latest: false });

    // Playing the trail's release through retires it from the picks.
    listen(&core, 2, now, 60_000);
    assert_eq!(core.picks(5, now).unwrap().iter().map(|p| p.release.0).collect::<Vec<_>>(), [1, 3, 4]);
    drop(api);
    drop(core);
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn zone_verdicts_follow_the_fidelity() {
    use meret_player::{ZoneFidelity, ZoneInfo};
    let zone = |fidelity| ZoneDto::from(meret_core::ZoneRow {
        info: ZoneInfo { id: "local:x".into(), name: "DAC".into(), detail: "This Mac".into(), host: "local".into(), fidelity, decodes_here: true },
        current: true,
    });
    assert_eq!((zone(ZoneFidelity::BitPerfect).verdict.as_str(), zone(ZoneFidelity::BitPerfect).warn), ("● bit-perfect", false));
    assert_eq!((zone(ZoneFidelity::Shared).verdict.as_str(), zone(ZoneFidelity::Shared).warn), ("◐ shared with macOS", true));
    assert_eq!(zone(ZoneFidelity::RefusesAbove { hz: 96_000 }).verdict, "◐ refuses above 96 kHz");
    assert_eq!(zone(ZoneFidelity::RefusesAbove { hz: 44_100 }).verdict, "◐ refuses above 44.1 kHz");
    assert_eq!(zone(ZoneFidelity::Fixed { description: "16/44.1".into(), delay_ms: 2_000 }).verdict, "◐ 16/44.1 · ~2 s delay");
}
