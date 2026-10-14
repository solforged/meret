use std::collections::HashMap;

use crate::walk::FileStat;

#[derive(Debug, Default, PartialEq)]
pub struct Diff {
    pub added: Vec<FileStat>,
    /// Same path, different size or mtime: re-read tags, keep identity.
    pub changed: Vec<FileStat>,
    pub removed: Vec<FileStat>,
    /// (old, new): same content, new path. History and notes follow.
    pub moved: Vec<(FileStat, FileStat)>,
}

impl Diff {
    pub fn is_empty(&self) -> bool {
        self.added.is_empty() && self.changed.is_empty() && self.removed.is_empty() && self.moved.is_empty()
    }
}

/// Compares what the store knows with what the walk found.
///
/// A removal and an addition with the same size and mtime are taken as a
/// move. The caller confirms with the head hash before trusting it, since
/// two rips can share a size.
pub fn diff(known: &[FileStat], found: &[FileStat]) -> Diff {
    let known_by_path: HashMap<&str, &FileStat> = known.iter().map(|f| (f.rel_path.as_str(), f)).collect();
    let found_by_path: HashMap<&str, &FileStat> = found.iter().map(|f| (f.rel_path.as_str(), f)).collect();

    let mut out = Diff::default();
    let mut added = vec![];
    for f in found {
        match known_by_path.get(f.rel_path.as_str()) {
            None => added.push(f.clone()),
            Some(k) if k.size != f.size || k.mtime_ns != f.mtime_ns => out.changed.push(f.clone()),
            Some(_) => {}
        }
    }

    let mut removed: HashMap<(u64, i128), Vec<FileStat>> = HashMap::new();
    for k in known {
        if !found_by_path.contains_key(k.rel_path.as_str()) {
            removed.entry((k.size, k.mtime_ns)).or_default().push(k.clone());
        }
    }

    for a in added {
        match removed.get_mut(&(a.size, a.mtime_ns)).and_then(|v| v.pop()) {
            Some(old) => out.moved.push((old, a)),
            None => out.added.push(a),
        }
    }
    out.removed = removed.into_values().flatten().collect();
    out.removed.sort_by(|a, b| a.rel_path.cmp(&b.rel_path));
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn f(path: &str, size: u64, mtime: i128) -> FileStat {
        FileStat { rel_path: path.into(), size, mtime_ns: mtime, inode: None }
    }

    #[test]
    fn finds_adds_changes_removals_and_moves() {
        let known = [
            f("Xenogears/2-17.flac", 70_000_000, 1),
            f("Xenogears/2-16.flac", 55_000_000, 1),
            f("Chrono Trigger/2-12.spc", 66_000, 1),
            f("Old/gone.mp3", 4_000_000, 1),
        ];
        let found = [
            f("Xenogears/2-17.flac", 70_000_000, 1),
            f("Xenogears/2-16.flac", 55_000_100, 2),
            f("Games/Chrono Trigger/2-12.spc", 66_000, 1),
            f("Celeste/07.flac", 90_000_000, 3),
        ];
        let d = diff(&known, &found);
        assert_eq!(d.added, vec![f("Celeste/07.flac", 90_000_000, 3)]);
        assert_eq!(d.changed, vec![f("Xenogears/2-16.flac", 55_000_100, 2)]);
        assert_eq!(d.moved.len(), 1);
        assert_eq!(d.moved[0].1.rel_path, "Games/Chrono Trigger/2-12.spc");
        assert_eq!(d.removed, vec![f("Old/gone.mp3", 4_000_000, 1)]);
    }

    #[test]
    fn an_unchanged_library_diffs_to_nothing() {
        let files: Vec<_> = (0..1000).map(|i| f(&format!("a/{i}.flac"), i, i as i128)).collect();
        assert!(diff(&files, &files).is_empty());
    }
}
