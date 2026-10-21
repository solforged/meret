use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::UNIX_EPOCH;

use ignore::{WalkBuilder, WalkState};

/// What the walk learns about a file without opening it.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct FileStat {
    /// Relative to the root, with `/` separators.
    pub rel_path: String,
    pub size: u64,
    pub mtime_ns: i128,
    pub inode: Option<u64>,
}

const AUDIO: &[&str] = &[
    "flac", "alac", "m4a", "mp4", "wav", "aif", "aiff", "aifc", "wv", "ape", "dsf", "dff", "mp3", "aac", "ogg", "oga",
    "opus", "mka", "caf", // native game formats
    "spc", "nsf", "nsfe", "vgm", "vgz", "gbs", "psf", "minipsf", "psf2", "minipsf2", "usf", "miniusf", "gsf",
    "minigsf", "2sf", "mini2sf", "hes", "kss", "ay", "sap", // images and sheets
    "cue",
];

pub fn is_audio(path: &Path) -> bool {
    path.extension()
        .and_then(|e| e.to_str())
        .is_some_and(|e| AUDIO.iter().any(|a| a.eq_ignore_ascii_case(e)))
}

/// What one walk saw: every audio file's stat, and the folders it couldn't
/// list. A file under an unreadable folder may still be there; macOS refuses
/// `~/Music/Music` to an app without Media & Apple Music access.
#[derive(Debug, Default)]
pub struct Walk {
    pub files: Vec<FileStat>,
    /// Relative to the root, with `/` separators; "" when the root itself.
    pub unreadable: Vec<String>,
}

impl Walk {
    /// Whether `rel_path` lies under a folder this walk couldn't list.
    pub fn unseen(&self, rel_path: &str) -> bool {
        self.unreadable.iter().any(|dir| dir.is_empty() || rel_path.strip_prefix(dir.as_str()).is_some_and(|rest| rest.starts_with('/')))
    }
}

/// Walks `root` in parallel.
/// Hidden files and `.ignore` rules are honoured; `.gitignore` is not.
pub fn walk(root: &Path) -> Walk {
    let out = Mutex::new(Vec::new());
    let unreadable = Mutex::new(Vec::new());
    let root_buf: PathBuf = root.to_path_buf();
    let rel = |path: &Path| path.strip_prefix(root).unwrap_or(path).to_string_lossy().replace('\\', "/");
    WalkBuilder::new(root)
        .git_ignore(false)
        .git_global(false)
        .git_exclude(false)
        .follow_links(false)
        .build_parallel()
        .run(|| {
            let out = &out;
            let unreadable = &unreadable;
            let rel = &rel;
            let root = root_buf.clone();
            let mut local = Flush { buf: Vec::with_capacity(1024), out };
            Box::new(move |entry| {
                let entry = match entry {
                    Ok(entry) => entry,
                    Err(err) => {
                        // A folder deleted mid-walk is gone; any other failure leaves it unseen.
                        let gone = err.io_error().is_some_and(|e| e.kind() == std::io::ErrorKind::NotFound);
                        if let (false, Some(path)) = (gone, error_path(&err)) {
                            unreadable.lock().expect("unreadable folders").push(rel(path));
                        }
                        return WalkState::Continue;
                    }
                };
                if entry.file_type().is_some_and(|t| t.is_file()) && is_audio(entry.path()) {
                    if let Ok(meta) = entry.metadata() {
                        let rel = entry.path().strip_prefix(&root).unwrap_or(entry.path());
                        local.buf.push(FileStat {
                            rel_path: rel.to_string_lossy().replace('\\', "/"),
                            size: meta.len(),
                            mtime_ns: meta
                                .modified()
                                .ok()
                                .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                                .map(|d| d.as_nanos() as i128)
                                .unwrap_or(0),
                            inode: inode(&meta),
                        });
                    }
                    if local.buf.len() >= 1024 {
                        local.flush();
                    }
                }
                WalkState::Continue
            })
        });
    Walk {
        files: out.into_inner().expect("walk results"),
        unreadable: unreadable.into_inner().expect("unreadable folders"),
    }
}

/// The folder or file an error is about, through ignore's wrappers.
fn error_path(err: &ignore::Error) -> Option<&Path> {
    match err {
        ignore::Error::WithPath { path, .. } => Some(path),
        ignore::Error::WithDepth { err, .. } | ignore::Error::WithLineNumber { err, .. } => error_path(err),
        ignore::Error::Loop { child, .. } => Some(child),
        _ => None,
    }
}

/// A walker thread's batch, handed over when full and when the thread ends.
struct Flush<'a> {
    buf: Vec<FileStat>,
    out: &'a Mutex<Vec<FileStat>>,
}

impl Flush<'_> {
    fn flush(&mut self) {
        self.out.lock().expect("walk results").append(&mut self.buf);
    }
}

impl Drop for Flush<'_> {
    fn drop(&mut self) {
        self.flush();
    }
}

#[cfg(unix)]
fn inode(meta: &std::fs::Metadata) -> Option<u64> {
    use std::os::unix::fs::MetadataExt;
    Some(meta.ino())
}

#[cfg(not(unix))]
fn inode(_meta: &std::fs::Metadata) -> Option<u64> {
    None
}
