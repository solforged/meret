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

/// Walks `root` in parallel and returns every audio file's stat.
/// Hidden files and `.ignore` rules are honoured; `.gitignore` is not.
pub fn walk(root: &Path) -> Vec<FileStat> {
    let out = Mutex::new(Vec::new());
    let root_buf: PathBuf = root.to_path_buf();
    WalkBuilder::new(root)
        .git_ignore(false)
        .git_global(false)
        .git_exclude(false)
        .follow_links(false)
        .build_parallel()
        .run(|| {
            let out = &out;
            let root = root_buf.clone();
            let mut local = Flush { buf: Vec::with_capacity(1024), out };
            Box::new(move |entry| {
                let Ok(entry) = entry else { return WalkState::Continue };
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
    out.into_inner().expect("walk results")
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
