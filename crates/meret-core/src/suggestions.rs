//! A budgeted quick look at likely music folders, without requesting access.
//!
//! Only metadata is read for protected candidates. Directory symlinks inside
//! a counted folder are not followed. The deadline is shared by all workers;
//! it is checked between filesystem calls, which the OS itself may block.

use std::fs;
use std::path::{Component, Path, PathBuf};
use std::thread;
use std::time::{Duration, Instant};

const QUICK_LOOK: Duration = Duration::from_secs(2);
const ENTRY_CAP: usize = 20_000;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FolderKind {
    Music,
    Steam,
    AppleMusic,
    Volume,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FolderSuggestion {
    pub path: PathBuf,
    pub label: String,
    pub kind: FolderKind,
    /// None when counting would require access to a protected folder.
    pub audio_files: Option<u64>,
    /// The quick look stopped at its entry or time budget.
    pub more: bool,
    pub note: String,
    pub asks_permission: bool,
}

/// Finds existing music folders for the current user and mounted volumes.
///
/// This performs filesystem I/O and waits for parallel quick-look workers;
/// call it off the UI and audio threads. Music's configured media URL is read
/// from its preferences without launching Music or asking for library access.
pub fn suggest(existing_roots: &[PathBuf]) -> Vec<FolderSuggestion> {
    let Some(home) = std::env::home_dir() else { return Vec::new() };
    let deadline = Instant::now() + QUICK_LOOK;
    let volumes = Path::new("/Volumes");
    let access = Access::new(&home, volumes);
    let apple_media_dirs = configured_apple_media(&home, &access, deadline);
    let candidates = candidates(existing_roots, &home, volumes, &apple_media_dirs, &access, &visible_volume, deadline);
    count_candidates(candidates, &access, deadline, ENTRY_CAP, &|_| {})
}

#[cfg(test)]
/// Uses explicit locations, without reading the real user's preferences.
///
/// `apple_media_dirs` contains configured media folders, not guesses at their
/// locations. Each directory immediately under `volumes_root` stands in for a
/// mounted volume, so tests can use an ordinary temporary directory. The boot
/// volume is still excluded. Counting has the same limits as [`suggest`].
pub fn suggest_in(
    existing_roots: &[PathBuf],
    home: &Path,
    volumes_root: &Path,
    apple_media_dirs: &[PathBuf],
) -> Vec<FolderSuggestion> {
    suggest_in_with(existing_roots, home, volumes_root, apple_media_dirs, Instant::now() + QUICK_LOOK, ENTRY_CAP, &|_| {})
}

#[cfg(test)]
fn suggest_in_with(
    existing_roots: &[PathBuf],
    home: &Path,
    volumes_root: &Path,
    apple_media_dirs: &[PathBuf],
    deadline: Instant,
    entry_cap: usize,
    on_read_dir: &(impl Fn(&Path) + Sync),
) -> Vec<FolderSuggestion> {
    let access = Access::new(home, volumes_root);
    let candidates = candidates(existing_roots, home, volumes_root, apple_media_dirs, &access, &|_, _| true, deadline);
    count_candidates(candidates, &access, deadline, entry_cap, on_read_dir)
}

struct Access {
    protected: Vec<PathBuf>,
}

impl Access {
    fn new(home: &Path, volumes_root: &Path) -> Self {
        let mut protected = Vec::new();
        for path in [home.join("Desktop"), home.join("Documents"), home.join("Downloads"), volumes_root.to_path_buf(), PathBuf::from("/Volumes")] {
            protected.push(normalize(&path));
            if let Ok(resolved) = fs::canonicalize(&path)
                && !protected.contains(&resolved)
            {
                protected.push(resolved);
            }
        }
        Self { protected }
    }

    fn contains(&self, path: &Path) -> bool {
        self.protected.iter().any(|root| path.starts_with(root))
    }

    #[cfg(target_os = "macos")]
    fn protects(&self, path: &Path) -> bool {
        self.contains(&normalize(path)) || fs::canonicalize(path).is_ok_and(|path| self.contains(&path))
    }
}

struct Location {
    path: PathBuf,
    resolved: PathBuf,
}

impl Location {
    fn new(path: &Path) -> Self {
        let resolved = fs::canonicalize(path).unwrap_or_else(|_| normalize(path));
        let path = normalize(path);
        Self { path, resolved }
    }

    fn under(&self, root: &Self) -> bool {
        self.path.starts_with(&root.path) || self.resolved.starts_with(&root.resolved)
    }
}

fn normalize(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir if out.file_name().is_some_and(|name| name != "..") => { out.pop(); }
            Component::ParentDir if out.has_root() => {}
            _ => out.push(component.as_os_str()),
        }
    }
    out
}

fn candidates(
    existing_roots: &[PathBuf],
    home: &Path,
    volumes_root: &Path,
    apple_media_dirs: &[PathBuf],
    access: &Access,
    visible_volume: &impl Fn(&Path, &Path) -> bool,
    deadline: Instant,
) -> Vec<FolderSuggestion> {
    let roots: Vec<_> = existing_roots.iter().map(|path| Location::new(path)).collect();
    let music_path = home.join("Music");
    let music = Location::new(&music_path);
    let mut out = Vec::new();
    let mut locations = Vec::<Location>::new();
    let mut add = |path: &Path, label: String, kind: FolderKind, note: String| {
        if !path.is_dir() {
            return;
        }
        let location = Location::new(path);
        if roots.iter().any(|root| location.under(root)) || locations.iter().any(|other| location.resolved == other.resolved) {
            return;
        }
        let asks_permission = access.contains(&location.path) || access.contains(&location.resolved);
        let suggestion = FolderSuggestion {
            path: path.to_path_buf(), label, kind, audio_files: None, more: false, note, asks_permission,
        };
        locations.push(location);
        out.push(suggestion);
    };

    let apple_inside = ["Music/Media.localized", "Music/Media"]
        .iter().any(|path| music_path.join(path).is_dir())
        || apple_media_dirs.iter().any(|path| path.is_dir() && Location::new(path).under(&music));
    let itunes_inside = ["iTunes/iTunes Media", "iTunes/iTunes Music"]
        .iter().any(|path| music_path.join(path).is_dir());
    let note = match (apple_inside, itunes_inside) {
        (true, true) => "Includes Apple Music and iTunes media.",
        (true, false) => "Includes Apple Music media.",
        (false, true) => "Includes iTunes media.",
        (false, false) => "",
    };
    add(&music_path, "Music".into(), FolderKind::Music, note.into());
    add(&home.join("Library/Application Support/Steam/steamapps/music"), "Steam soundtracks".into(), FolderKind::Steam, String::new());
    for path in apple_media_dirs {
        if !Location::new(path).under(&music) {
            add(path, "Apple Music".into(), FolderKind::AppleMusic, String::new());
        }
    }

    // Enumerate mount names only. Never open a directory inside a volume.
    if let Ok(entries) = fs::read_dir(volumes_root) {
        let mut volumes = Vec::new();
        for entry in entries.take(ENTRY_CAP) {
            if Instant::now() >= deadline {
                break;
            }
            let Ok(entry) = entry else { continue };
            let path = entry.path();
            if path.is_dir() && !is_boot_volume(&path) && visible_volume(&path, volumes_root) {
                volumes.push(path);
            }
        }
        volumes.sort();
        for path in volumes {
            let label = path.file_name().unwrap_or_default().to_string_lossy().into_owned();
            add(&path, label, FolderKind::Volume, String::new());
        }
    }
    out
}

fn is_boot_volume(path: &Path) -> bool {
    fs::canonicalize(path).is_ok_and(|path| path == Path::new("/") || path == Path::new("/System/Volumes/Data"))
}

#[cfg(unix)]
fn is_mount(path: &Path, parent: &Path) -> bool {
    use std::os::unix::fs::MetadataExt;
    match (fs::metadata(path), fs::metadata(parent)) {
        (Ok(path), Ok(parent)) => path.dev() != parent.dev(),
        _ => false,
    }
}

#[cfg(not(unix))]
fn is_mount(_path: &Path, _parent: &Path) -> bool {
    true
}

fn visible_volume(path: &Path, parent: &Path) -> bool {
    if !is_mount(path, parent) {
        return false;
    }
    #[cfg(target_os = "macos")]
    {
        use std::ffi::CString;
        use std::mem::MaybeUninit;
        use std::os::unix::ffi::OsStrExt;

        let Ok(path) = CString::new(path.as_os_str().as_bytes()) else { return false };
        let mut info = MaybeUninit::<libc::statfs>::uninit();
        // SAFETY: the path is NUL-terminated and statfs initializes info on success.
        if unsafe { libc::statfs(path.as_ptr(), info.as_mut_ptr()) } != 0 {
            return false;
        }
        let info = unsafe { info.assume_init() };
        browsable_mount(info.f_flags)
    }
    #[cfg(not(target_os = "macos"))]
    true
}

#[cfg(target_os = "macos")]
fn browsable_mount(flags: u32) -> bool {
    flags & libc::MNT_DONTBROWSE as u32 == 0
}

fn count_candidates(
    mut candidates: Vec<FolderSuggestion>,
    access: &Access,
    deadline: Instant,
    entry_cap: usize,
    on_read_dir: &(impl Fn(&Path) + Sync),
) -> Vec<FolderSuggestion> {
    thread::scope(|scope| {
        for candidate in &mut candidates {
            if candidate.asks_permission {
                continue;
            }
            scope.spawn(move || {
                let count = count(&candidate.path, access, deadline, entry_cap, on_read_dir);
                candidate.audio_files = Some(count.files);
                candidate.more = count.more;
                if count.needs_access {
                    candidate.audio_files = None;
                    candidate.asks_permission = true;
                }
                if count.unreadable {
                    append_note(&mut candidate.note, "Some files could not be counted.");
                }
            });
        }
    });
    candidates
}

#[derive(Default)]
struct Count {
    files: u64,
    more: bool,
    unreadable: bool,
    needs_access: bool,
}

fn count(path: &Path, access: &Access, deadline: Instant, entry_cap: usize, on_read_dir: &(impl Fn(&Path) + Sync)) -> Count {
    let mut count = Count::default();
    // Resolve the starting path once, then never recurse through symlinks.
    let path = match fs::canonicalize(path) {
        Ok(path) => path,
        Err(_) => { count.unreadable = true; return count; }
    };
    if access.contains(&path) {
        count.needs_access = true;
        return count;
    }
    if Instant::now() >= deadline || entry_cap == 0 {
        count.more = true;
        return count;
    }
    on_read_dir(&path);
    let entries = match fs::read_dir(&path) {
        Ok(entries) => entries,
        Err(_) => { count.unreadable = true; return count; }
    };
    let mut stack = vec![entries];
    let mut seen = 0;
    while let Some(entries) = stack.last_mut() {
        if Instant::now() >= deadline || seen >= entry_cap {
            count.more = true;
            break;
        }
        let Some(entry) = entries.next() else { stack.pop(); continue };
        seen += 1;
        let Ok(entry) = entry else { count.unreadable = true; continue };
        let Ok(kind) = entry.file_type() else { count.unreadable = true; continue };
        let path = entry.path();
        if kind.is_dir() {
            if access.contains(&path) {
                count.needs_access = true;
                continue;
            }
            if Instant::now() >= deadline || seen >= entry_cap {
                count.more = true;
                break;
            }
            on_read_dir(&path);
            match fs::read_dir(&path) {
                Ok(entries) => stack.push(entries),
                Err(_) => count.unreadable = true,
            }
        } else if kind.is_file() && meret_library::is_audio(&path) {
            count.files += 1;
        }
    }
    count
}

fn append_note(note: &mut String, addition: &str) {
    if !note.is_empty() {
        note.push(' ');
    }
    note.push_str(addition);
}

#[cfg(target_os = "macos")]
fn configured_apple_media(home: &Path, access: &Access, deadline: Instant) -> Vec<PathBuf> {
    use std::process::{Command, Stdio};

    let preferences = home.join("Library/Preferences/com.apple.Music.plist");
    if Instant::now() >= deadline || !preferences.is_file() || access.protects(&preferences) {
        return Vec::new();
    }
    // plutil handles both XML and binary property lists. This key is the
    // media directory, unlike library-url, which points to the database.
    let Ok(mut child) = Command::new("/usr/bin/plutil")
        .args(["-extract", "media-folder-url", "raw", "-o", "-"])
        .arg(preferences)
        .stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null())
        .spawn() else { return Vec::new() };
    loop {
        match child.try_wait() {
            Ok(Some(status)) if status.success() => {
                return child.wait_with_output().ok()
                    .and_then(|output| file_url_path(&output.stdout))
                    .into_iter().collect();
            }
            Ok(Some(_)) => return Vec::new(),
            Ok(None) if Instant::now() < deadline => thread::sleep(Duration::from_millis(5)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return Vec::new();
            }
        }
    }
}

#[cfg(not(target_os = "macos"))]
fn configured_apple_media(_home: &Path, _access: &Access, _deadline: Instant) -> Vec<PathBuf> {
    Vec::new()
}

#[cfg(any(target_os = "macos", test))]
fn file_url_path(bytes: &[u8]) -> Option<PathBuf> {
    let url = std::str::from_utf8(bytes).ok()?.trim_end_matches(['\r', '\n']);
    let path = url.strip_prefix("file://localhost/")
        .or_else(|| url.strip_prefix("file:///"))?;
    let mut decoded = Vec::with_capacity(path.len() + 1);
    decoded.push(b'/');
    let mut bytes = path.as_bytes().iter().copied();
    while let Some(byte) = bytes.next() {
        match byte {
            b'%' => {
                let high = (bytes.next()? as char).to_digit(16)?;
                let low = (bytes.next()? as char).to_digit(16)?;
                let byte = (high * 16 + low) as u8;
                if byte == 0 { return None; }
                decoded.push(byte);
            }
            b'?' | b'#' | 0 => return None,
            _ => decoded.push(byte),
        }
    }
    #[cfg(unix)]
    {
        use std::os::unix::ffi::OsStringExt;
        Some(PathBuf::from(std::ffi::OsString::from_vec(decoded)))
    }
    #[cfg(not(unix))]
    {
        String::from_utf8(decoded).ok().map(PathBuf::from)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(unix)]
    use parking_lot::Mutex;
    use std::sync::atomic::{AtomicU64, Ordering};

    static NEXT_DIR: AtomicU64 = AtomicU64::new(0);

    struct Fixture {
        root: PathBuf,
        home: PathBuf,
        volumes: PathBuf,
    }

    impl Fixture {
        fn new() -> Self {
            let root = std::env::temp_dir().join(format!("meret-suggestions-{}-{}", std::process::id(), NEXT_DIR.fetch_add(1, Ordering::Relaxed)));
            fs::create_dir(&root).unwrap();
            let root = fs::canonicalize(root).unwrap();
            let home = root.join("home");
            let volumes = root.join("Volumes");
            fs::create_dir(&home).unwrap();
            fs::create_dir(&volumes).unwrap();
            Self { root, home, volumes }
        }

        fn dir(&self, path: impl AsRef<Path>) -> PathBuf {
            let path = self.root.join(path);
            fs::create_dir_all(&path).unwrap();
            path
        }

        fn audio(&self, path: impl AsRef<Path>) {
            let path = self.root.join(path);
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(path, []).unwrap();
        }

        fn suggest(&self, roots: &[PathBuf], media: &[PathBuf]) -> Vec<FolderSuggestion> {
            suggest_in(roots, &self.home, &self.volumes, media)
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    #[test]
    fn skips_missing_existing_and_descendant_roots() {
        let fixture = Fixture::new();
        assert!(fixture.suggest(&[], &[]).is_empty());
        let music = fixture.dir("home/Music");
        let steam = fixture.dir("home/Library/Application Support/Steam/steamapps/music");
        let external = fixture.dir("other/Apple media");
        let volume = fixture.dir("Volumes/Archive");
        let roots = [music, fixture.home.join("Library"), fixture.root.join("other"), volume];
        assert!(fixture.suggest(&roots, &[external]).is_empty());
        let found = fixture.suggest(&[fixture.home.join("Mus")], &[]);
        assert!(found.iter().any(|suggestion| suggestion.path == steam));
        assert!(found.iter().any(|suggestion| suggestion.kind == FolderKind::Music));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn excludes_hidden_mount_flags_without_filtering_volume_names() {
        let fixture = Fixture::new();
        let recovery = fixture.dir("Volumes/Recovery");
        let hidden_uuid = fixture.dir("Volumes/A925F813-0F1E-4F3B-B571-5DC572CD3113");
        let visible_uuid = fixture.dir("Volumes/EB82BB3B-ED8A-48FB-9475-3D12B9760941");
        let archive = fixture.dir("Volumes/Archive");
        let access = Access::new(&fixture.home, &fixture.volumes);
        let visible = |path: &Path, _: &Path| {
            let flags = if path == recovery || path == hidden_uuid { libc::MNT_DONTBROWSE as u32 } else { 0 };
            browsable_mount(flags)
        };
        let found = candidates(&[], &fixture.home, &fixture.volumes, &[], &access, &visible, Instant::now() + QUICK_LOOK);
        let paths = found.iter().map(|folder| folder.path.clone()).collect::<Vec<_>>();
        assert_eq!(paths, [archive, visible_uuid]);
        assert!(found.iter().all(|folder| folder.asks_permission && folder.audio_files.is_none()));
    }

    #[test]
    fn counts_scanner_formats_and_notes_media_without_duplicate_candidates() {
        let fixture = Fixture::new();
        fixture.audio("home/Music/song.FLAC");
        fixture.audio("home/Music/Music/Media.localized/game.spc");
        fixture.audio("home/Music/iTunes/iTunes Media/disc.cue");
        fixture.audio("home/Music/readme.txt");
        fixture.audio("home/Library/Application Support/Steam/steamapps/music/score.OpUs");
        fixture.audio("other/Apple media/song.m4a");
        let external = fixture.root.join("other/Apple media");
        let found = fixture.suggest(&[], &[fixture.home.join("Music/Music/Media.localized"), external.clone(), external]);
        assert_eq!(found.len(), 3);
        assert_eq!(found[0].kind, FolderKind::Music);
        assert_eq!(found[0].audio_files, Some(3));
        assert!(!found[0].more);
        assert!(found[0].note.contains("Apple Music and iTunes"));
        assert_eq!(found[1].kind, FolderKind::Steam);
        assert_eq!(found[1].audio_files, Some(1));
        assert_eq!(found[2].kind, FolderKind::AppleMusic);
        assert_eq!(found[2].audio_files, Some(1));
    }

    #[test]
    fn entry_cap_marks_a_partial_count() {
        let fixture = Fixture::new();
        for name in ["one.mp3", "two.flac", "three.wav"] {
            fixture.audio(Path::new("home/Music").join(name));
        }
        let found = suggest_in_with(&[], &fixture.home, &fixture.volumes, &[], Instant::now() + QUICK_LOOK, 2, &|_| {});
        assert_eq!(found[0].audio_files, Some(2));
        assert!(found[0].more);
    }

    #[test]
    fn expired_shared_deadline_does_not_open_candidates() {
        let fixture = Fixture::new();
        fixture.audio("home/Music/one.mp3");
        fixture.audio("home/Library/Application Support/Steam/steamapps/music/two.flac");
        let found = suggest_in_with(&[], &fixture.home, &fixture.volumes, &[], Instant::now(), ENTRY_CAP, &|path| panic!("opened {}", path.display()));
        assert_eq!(found.len(), 2);
        assert!(found.iter().all(|suggestion| suggestion.audio_files == Some(0) && suggestion.more));
    }

    #[test]
    fn protected_candidates_are_never_opened() {
        let fixture = Fixture::new();
        let media: Vec<_> = ["Desktop", "Documents", "Downloads"].iter().map(|name| {
            let path = fixture.home.join(name).join("Media");
            fixture.audio(path.join("must-not-read.mp3"));
            path
        }).collect();
        fixture.audio("Volumes/NAS/must-not-read.flac");
        let found = suggest_in_with(&[], &fixture.home, &fixture.volumes, &media, Instant::now() + QUICK_LOOK, ENTRY_CAP, &|path| panic!("opened {}", path.display()));
        assert_eq!(found.len(), 4);
        assert!(found.iter().all(|suggestion| suggestion.asks_permission && suggestion.audio_files.is_none() && !suggestion.more));
    }

    #[cfg(unix)]
    #[test]
    fn symlink_aliases_cannot_bypass_protection_or_existing_roots() {
        use std::os::unix::fs::symlink;
        let fixture = Fixture::new();
        let documents = fixture.dir("home/Documents");
        fixture.audio("home/Documents/one.mp3");
        symlink(&documents, fixture.home.join("Music")).unwrap();
        let found = suggest_in_with(&[], &fixture.home, &fixture.volumes, &[], Instant::now() + QUICK_LOOK, ENTRY_CAP, &|path| panic!("opened {}", path.display()));
        assert_eq!(found.len(), 1);
        assert!(found[0].asks_permission);
        assert_eq!(found[0].audio_files, None);
        assert!(fixture.suggest(&[documents], &[]).is_empty());
    }

    #[cfg(unix)]
    #[test]
    fn protected_directory_aliases_and_boot_volume_are_not_walked() {
        use std::os::unix::fs::symlink;
        let fixture = Fixture::new();
        let media = fixture.dir("elsewhere/Media");
        fixture.audio("elsewhere/Media/one.mp3");
        symlink(fixture.root.join("elsewhere"), fixture.home.join("Downloads")).unwrap();
        symlink("/", fixture.volumes.join("Boot")).unwrap();
        let found = suggest_in_with(&[], &fixture.home, &fixture.volumes, &[media], Instant::now() + QUICK_LOOK, ENTRY_CAP, &|path| panic!("opened {}", path.display()));
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].kind, FolderKind::AppleMusic);
        assert!(found[0].asks_permission);
    }

    #[cfg(unix)]
    #[test]
    fn nested_symlink_directories_and_files_are_not_followed() {
        use std::os::unix::fs::symlink;
        let fixture = Fixture::new();
        let music = fixture.dir("home/Music");
        fixture.audio("home/Music/one.mp3");
        fixture.audio("home/Documents/hidden.flac");
        symlink(fixture.home.join("Documents"), music.join("private")).unwrap();
        symlink(&music, music.join("loop")).unwrap();
        symlink(fixture.home.join("Documents/hidden.flac"), music.join("alias.flac")).unwrap();
        let opened = Mutex::new(Vec::new());
        let found = suggest_in_with(&[], &fixture.home, &fixture.volumes, &[], Instant::now() + QUICK_LOOK, ENTRY_CAP, &|path| opened.lock().push(path.to_path_buf()));
        assert_eq!(found[0].audio_files, Some(1));
        assert!(!found[0].more);
        assert_eq!(*opened.lock(), [music]);
    }

    #[test]
    fn decodes_only_local_absolute_file_urls() {
        assert_eq!(file_url_path(b"file:///Volumes/Music%20Drive/Bj%C3%B6rk/\n"), Some(PathBuf::from("/Volumes/Music Drive/Bj\u{f6}rk/")));
        assert_eq!(file_url_path(b"file://localhost/Users/a/Media"), Some(PathBuf::from("/Users/a/Media")));
        for invalid in ["https://example.com/music", "file://server/share", "file:///a%", "file:///a%00b", "file:///a?b"] {
            assert!(file_url_path(invalid.as_bytes()).is_none());
        }
    }
}
