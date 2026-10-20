//! What changed under the roots, from FSEvents on macOS: while Meret runs,
//! and since it last ran. Each root keeps the event id its files are current
//! to, so a launch replays the volume's event history instead of walking.
//! A missing id, or an FSEvents database with a new UUID (its history was
//! reset), means a full walk instead.
//!
//! Events are folder-level: a path says something in that folder changed,
//! so the folder is walked again, with everything under it, and diffed
//! against the store.

use std::collections::{BTreeSet, HashMap};
use std::path::{Path, PathBuf};

use meret_model::RootId;
use meret_store::Store;
use rusqlite::params;

use crate::ingest::ScanError;

/// Event flags, as FSEvents.h defines them.
pub mod flags {
    /// Coalesced or dropped events: walk this path and everything under it.
    pub const MUST_SCAN_SUB_DIRS: u32 = 0x1;
    pub const EVENT_IDS_WRAPPED: u32 = 0x8;
    /// The replay of history has caught up with now.
    pub const HISTORY_DONE: u32 = 0x10;
    /// A watched path itself was created, deleted, moved or remounted.
    pub const ROOT_CHANGED: u32 = 0x20;
    pub const MOUNT: u32 = 0x40;
    pub const UNMOUNT: u32 = 0x80;
}

/// Replays nothing: only changes from the moment a stream starts.
pub const SINCE_NOW: u64 = u64::MAX;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Event {
    pub path: PathBuf,
    pub flags: u32,
    pub id: u64,
}

/// A root, and the event id and FSEvents database its files are current to.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Mark {
    pub root: RootId,
    pub path: PathBuf,
    pub id: Option<u64>,
    pub uuid: Option<String>,
}

/// Every root not removed, offline ones included, so a remount is seen.
pub fn marks(store: &Store) -> Result<Vec<Mark>, ScanError> {
    Ok(store.read(|c| {
        let mut stmt = c.prepare("SELECT id, path, fsevents_id, fsevents_uuid FROM root WHERE state <> 'removed' ORDER BY id")?;
        stmt.query_map([], |r| Ok(Mark {
            root: RootId(r.get(0)?),
            path: PathBuf::from(r.get::<_, String>(1)?),
            id: r.get::<_, Option<i64>>(2)?.map(|id| id as u64),
            uuid: r.get(3)?,
        }))?.collect()
    })?)
}

/// Records that every change up to each id is in the store.
pub fn set_marks(store: &Store, marks: Vec<(RootId, u64, String)>) -> Result<(), ScanError> {
    if marks.is_empty() {
        return Ok(());
    }
    store.writer.write(move |tx| {
        for (root, id, uuid) in &marks {
            tx.execute("UPDATE root SET fsevents_id = ?2, fsevents_uuid = ?3 WHERE id = ?1", params![root.0, *id as i64, uuid])?;
        }
        Ok(())
    })?;
    Ok(())
}

/// What a batch of events asks the scanner to do.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Changes {
    /// Roots to walk whole: mounted, unmounted, history lost, or a change in
    /// the root folder itself.
    pub full: Vec<RootId>,
    /// Folders to walk again, relative to their root, none inside another.
    pub dirs: Vec<(RootId, Vec<String>)>,
    /// The newest event id in the batch; every change up to it is covered.
    pub through: Option<u64>,
}

/// Maps events to roots. Events outside every root are ignored, except a
/// mount or unmount above one, which walks it.
pub fn plan(roots: &[(RootId, PathBuf)], events: &[Event]) -> Changes {
    let mut full = BTreeSet::new();
    let mut dirs: HashMap<RootId, BTreeSet<String>> = HashMap::new();
    let mut through = None;
    for event in events {
        through = through.max(Some(event.id));
        if event.flags & flags::EVENT_IDS_WRAPPED != 0 {
            full.extend(roots.iter().map(|(root, _)| *root));
            continue;
        }
        if event.flags & flags::HISTORY_DONE != 0 {
            continue;
        }
        let path = &event.path;
        for (root, root_path) in roots {
            match path.strip_prefix(root_path) {
                Ok(rel) if rel.as_os_str().is_empty() || event.flags & flags::ROOT_CHANGED != 0 => {
                    full.insert(*root);
                }
                Ok(rel) => {
                    dirs.entry(*root).or_default().insert(rel.to_string_lossy().into_owned());
                }
                Err(_) if event.flags & (flags::ROOT_CHANGED | flags::MOUNT | flags::UNMOUNT) != 0
                    && root_path.starts_with(path) => {
                    full.insert(*root);
                }
                Err(_) => {}
            }
        }
    }
    let mut dirs: Vec<(RootId, Vec<String>)> = dirs
        .into_iter()
        .filter(|(root, _)| !full.contains(root))
        .map(|(root, set)| (root, outermost(set)))
        .collect();
    dirs.sort();
    Changes { full: full.into_iter().collect(), dirs, through }
}

/// Drops folders inside another folder of the set.
fn outermost(dirs: BTreeSet<String>) -> Vec<String> {
    let mut kept: Vec<String> = vec![];
    for dir in dirs {
        if !kept.iter().any(|k| Path::new(&dir).starts_with(k)) {
            kept.push(dir);
        }
    }
    kept
}

#[cfg(target_os = "macos")]
pub use fsevents::{Watcher, current_event_id, database_uuid};

#[cfg(target_os = "macos")]
mod fsevents {
    use std::ffi::{CStr, OsStr, c_char, c_void};
    use std::os::unix::ffi::OsStrExt;
    use std::os::unix::fs::MetadataExt;
    use std::path::{Path, PathBuf};
    use std::ptr;

    use objc2_core_foundation::{CFArray, CFRetained, CFString};

    use super::Event;

    /// Seconds FSEvents gathers events before delivering a batch.
    const LATENCY: f64 = 0.3;
    /// `kFSEventStreamCreateFlagWatchRoot`: say when a watched path itself moves.
    const WATCH_ROOT: u32 = 0x4;

    type Stream = *mut c_void;
    type Callback = extern "C" fn(Stream, *mut c_void, usize, *mut c_void, *const u32, *const u64);
    type Sink = Box<dyn Fn(Vec<Event>) + Send + Sync>;

    #[repr(C)]
    struct Context {
        version: isize,
        info: *mut c_void,
        retain: *const c_void,
        release: *const c_void,
        copy_description: *const c_void,
    }

    #[repr(C)]
    struct UuidBytes([u8; 16]);

    #[link(name = "CoreServices", kind = "framework")]
    unsafe extern "C" {
        fn FSEventStreamCreate(allocator: *const c_void, callback: Callback, context: *const Context, paths: *const c_void,
            since: u64, latency: f64, flags: u32) -> Stream;
        fn FSEventStreamSetDispatchQueue(stream: Stream, queue: *mut c_void);
        fn FSEventStreamStart(stream: Stream) -> u8;
        fn FSEventStreamStop(stream: Stream);
        fn FSEventStreamInvalidate(stream: Stream);
        fn FSEventStreamRelease(stream: Stream);
        fn FSEventsGetCurrentEventId() -> u64;
        fn FSEventsCopyUUIDForDevice(dev: i32) -> *const c_void;
    }

    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        fn CFUUIDGetUUIDBytes(uuid: *const c_void) -> UuidBytes;
        fn CFRelease(object: *const c_void);
    }

    unsafe extern "C" {
        fn dispatch_queue_create(label: *const c_char, attr: *const c_void) -> *mut c_void;
        fn dispatch_sync_f(queue: *mut c_void, context: *mut c_void, work: extern "C" fn(*mut c_void));
        fn dispatch_release(object: *mut c_void);
    }

    /// The newest event id on this Mac.
    pub fn current_event_id() -> u64 {
        unsafe { FSEventsGetCurrentEventId() }
    }

    /// The FSEvents database for the volume `path` is on; None when the
    /// path is gone or the volume keeps no history.
    pub fn database_uuid(path: &Path) -> Option<String> {
        let dev = std::fs::metadata(path).ok()?.dev();
        let uuid = unsafe { FSEventsCopyUUIDForDevice(i32::try_from(dev).ok()?) };
        if uuid.is_null() {
            return None;
        }
        let UuidBytes(b) = unsafe { CFUUIDGetUUIDBytes(uuid) };
        unsafe { CFRelease(uuid) };
        let hex: String = b.iter().map(|x| format!("{x:02X}")).collect();
        Some(format!("{}-{}-{}-{}-{}", &hex[..8], &hex[8..12], &hex[12..16], &hex[16..20], &hex[20..]))
    }

    /// An FSEvents stream on a serial dispatch queue. Dropping it stops the
    /// stream and waits for a delivery in progress.
    pub struct Watcher {
        stream: Stream,
        queue: *mut c_void,
        sink: *mut Sink,
    }

    // SAFETY: the stream and queue are thread-safe CoreServices/libdispatch
    // objects; the sink is only read by the callback, and freed after it stops.
    unsafe impl Send for Watcher {}

    impl Watcher {
        /// Watches `paths`, replaying events after `since` first (ending in one
        /// flagged `HISTORY_DONE`), or only new ones with `SINCE_NOW`.
        pub fn start(paths: &[PathBuf], since: u64, sink: impl Fn(Vec<Event>) + Send + Sync + 'static) -> Option<Self> {
            if paths.is_empty() {
                return None;
            }
            let strings: Vec<CFRetained<CFString>> = paths.iter().map(|p| CFString::from_str(&p.to_string_lossy())).collect();
            let array = CFArray::from_retained_objects(&strings);
            let sink: *mut Sink = Box::into_raw(Box::new(Box::new(sink)));
            let context = Context { version: 0, info: sink.cast(), retain: ptr::null(), release: ptr::null(), copy_description: ptr::null() };
            let array_ref: *const CFArray<CFString> = &*array;
            let stream = unsafe {
                FSEventStreamCreate(ptr::null(), deliver, &context, array_ref.cast(), since, LATENCY, WATCH_ROOT)
            };
            if stream.is_null() {
                drop(unsafe { Box::from_raw(sink) });
                return None;
            }
            let queue = unsafe { dispatch_queue_create(c"io.sowilo.meret.fsevents".as_ptr(), ptr::null()) };
            unsafe { FSEventStreamSetDispatchQueue(stream, queue) };
            let watcher = Self { stream, queue, sink };
            if unsafe { FSEventStreamStart(stream) } == 0 {
                tracing::warn!(?paths, "FSEvents would not start");
                return None;
            }
            Some(watcher)
        }
    }

    impl Drop for Watcher {
        fn drop(&mut self) {
            extern "C" fn nothing(_: *mut c_void) {}
            unsafe {
                FSEventStreamStop(self.stream);
                FSEventStreamInvalidate(self.stream);
                // The queue is serial: once this runs, no delivery is in flight.
                dispatch_sync_f(self.queue, ptr::null_mut(), nothing);
                FSEventStreamRelease(self.stream);
                dispatch_release(self.queue);
                drop(Box::from_raw(self.sink));
            }
        }
    }

    extern "C" fn deliver(_stream: Stream, info: *mut c_void, count: usize, paths: *mut c_void, flags: *const u32, ids: *const u64) {
        // SAFETY: FSEvents passes `count` C strings, flags and ids, and the
        // context's `info`, which is the watcher's sink until it's dropped.
        let (sink, paths, flags, ids) = unsafe {
            (&*(info as *const Sink), std::slice::from_raw_parts(paths as *const *const c_char, count),
                std::slice::from_raw_parts(flags, count), std::slice::from_raw_parts(ids, count))
        };
        let events = (0..count).map(|i| Event {
            path: PathBuf::from(OsStr::from_bytes(unsafe { CStr::from_ptr(paths[i]) }.to_bytes())),
            flags: flags[i],
            id: ids[i],
        }).collect();
        sink(events);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn event(path: &str, flags: u32, id: u64) -> Event {
        Event { path: path.into(), flags, id }
    }

    #[test]
    fn plans_outermost_folders_per_root_and_whole_walks_where_history_or_the_root_changed() {
        let roots = [(RootId(1), PathBuf::from("/Music")), (RootId(2), PathBuf::from("/Volumes/Drive/Rips")), (RootId(3), PathBuf::from("/Games"))];
        let changes = plan(&roots, &[
            event("/Music/A/Album/", 0, 10),
            event("/Music/A/", 0, 11),
            event("/Music/A B/", 0, 12),
            event("/Music/Other/Disc 2/", flags::MUST_SCAN_SUB_DIRS, 13),
            event("/Musical/x/", 0, 14),
            event("/Volumes/Drive", flags::UNMOUNT, 15),
            event("/Games/", 0, 16),
            event("", flags::HISTORY_DONE, 17),
        ]);
        assert_eq!(changes, Changes {
            full: vec![RootId(2), RootId(3)],
            dirs: vec![(RootId(1), vec!["A".into(), "A B".into(), "Other/Disc 2".into()])],
            through: Some(17),
        });
        let wrapped = plan(&roots, &[event("/", flags::EVENT_IDS_WRAPPED, 1)]);
        assert_eq!(wrapped.full, [RootId(1), RootId(2), RootId(3)]);
        assert_eq!(plan(&roots, &[event("/Music", flags::ROOT_CHANGED, 2)]).full, [RootId(1)]);
        assert_eq!(plan(&roots, &[]), Changes::default());
    }
}

#[cfg(all(test, target_os = "macos"))]
mod fsevents_tests {
    use super::*;
    use std::time::Duration;

    fn until(rx: &crossbeam_channel::Receiver<Vec<Event>>, what: &str, done: impl Fn(&Event) -> bool) -> Vec<Event> {
        let mut seen = vec![];
        let deadline = std::time::Instant::now() + Duration::from_secs(10);
        loop {
            let left = deadline.saturating_duration_since(std::time::Instant::now());
            let batch = rx.recv_timeout(left).unwrap_or_else(|_| panic!("no {what} in {seen:?}"));
            let found = batch.iter().any(&done);
            seen.extend(batch);
            if found {
                return seen;
            }
        }
    }

    #[test]
    fn reports_changed_folders_live_and_replays_them_after_a_restart() {
        let dir = std::env::temp_dir().join(format!("meret-watch-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let dir = dir.canonicalize().unwrap();
        assert!(database_uuid(&dir).is_some());
        // Folders made up front, so the events below are about their files only.
        std::fs::create_dir_all(dir.join("Album")).unwrap();
        std::fs::create_dir_all(dir.join("Later")).unwrap();
        let roots = [(RootId(1), dir.clone())];
        let only = |dir: &str| Changes { full: vec![], dirs: vec![(RootId(1), vec![dir.into()])], through: None };
        let (tx, rx) = crossbeam_channel::unbounded();
        let watcher = Watcher::start(std::slice::from_ref(&dir), SINCE_NOW, move |events| { let _ = tx.send(events); }).unwrap();
        std::fs::write(dir.join("Album/01.flac"), b"live").unwrap();
        let album = dir.join("Album");
        let live = until(&rx, "live event", |e| e.path.starts_with(&album));
        assert_eq!(Changes { through: None, ..plan(&roots, &live) }, only("Album"), "{live:?}");
        let caught_up = live.iter().map(|e| e.id).max().unwrap();
        drop(watcher);

        // Changed while nobody watched: the replay brings it, then says it's done.
        std::fs::write(dir.join("Later/02.flac"), b"offline").unwrap();
        let (tx, rx) = crossbeam_channel::unbounded();
        let _watcher = Watcher::start(std::slice::from_ref(&dir), caught_up, move |events| { let _ = tx.send(events); }).unwrap();
        let replayed = until(&rx, "history done", |e| e.flags & flags::HISTORY_DONE != 0);
        let changes = plan(&roots, &replayed);
        assert!(changes.through.is_some_and(|id| id > caught_up));
        assert_eq!(Changes { through: None, ..changes }, only("Later"), "{replayed:?}");
        assert!(current_event_id() >= caught_up);
        std::fs::remove_dir_all(dir).unwrap();
    }
}
