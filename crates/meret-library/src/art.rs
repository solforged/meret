//! Content-addressed covers and the restrained colour they lend to Now.

use std::fs::{self, File, OpenOptions};
use std::io::BufWriter;
use std::path::{Path, PathBuf};

use image::codecs::jpeg::JpegEncoder;
use image::imageops::FilterType;
use image::{DynamicImage, RgbImage};
use lofty::picture::PictureType;
use lofty::prelude::*;
use meret_model::ReleaseId;
use meret_store::{COVER_SIZES, Store, cover_file};
use rayon::prelude::*;
use rusqlite::params;

use crate::{Phase, ScanError, ScanProgress};

const CHUNK: usize = 64;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct CoverReport {
    /// Releases whose first present file was checked.
    pub checked: usize,
    /// Releases given a cover.
    pub found: usize,
    /// New size files; existing content-addressed files are left alone.
    pub files: usize,
    pub unreadable: usize,
}

struct Rendered {
    hash: blake3::Hash,
    width: u32,
    height: u32,
    light: Option<u32>,
    files: usize,
}

/// Reads and renders off the store writer, committing one chunk at a time.
pub fn covers(store: &Store, art_dir: &Path, progress: &(dyn Fn(ScanProgress) + Sync)) -> Result<CoverReport, ScanError> {
    let candidates = store.read(|c| {
        let mut stmt = c.prepare(
            "SELECT release_id, path FROM (
                 SELECT rl.id AS release_id, r.path || '/' || f.rel_path AS path,
                        ROW_NUMBER() OVER (PARTITION BY rl.id ORDER BY m.position, t.position, t.id, s.lossless DESC, s.id) AS n
                 FROM release rl JOIN edition e ON e.release_id = rl.id
                 JOIN medium m ON m.edition_id = e.id JOIN track t ON t.medium_id = m.id
                 JOIN source s ON s.track_id = t.id AND s.kind = 'file'
                 JOIN file f ON f.id = s.file_id JOIN root r ON r.id = f.root_id
                 WHERE f.state = 'present' AND r.state <> 'removed' AND rl.art_checked = 0
                   AND NOT EXISTS (SELECT 1 FROM entity_artwork ea WHERE ea.entity_kind = 3 AND ea.entity_id = rl.id)
             ) WHERE n = 1 ORDER BY release_id",
        )?;
        stmt.query_map([], |r| Ok((ReleaseId(r.get(0)?), PathBuf::from(r.get::<_, String>(1)?))))?
            .collect::<rusqlite::Result<Vec<_>>>()
    })?;
    let mut report = CoverReport::default();
    let total = candidates.len() as u64;
    progress(ScanProgress { phase: Phase::ReadingCovers, done: 0, total });
    if candidates.is_empty() {
        return Ok(report);
    }
    fs::create_dir_all(art_dir)?;
    for chunk in candidates.chunks(CHUNK) {
        let read: Vec<_> = chunk
            .par_iter()
            .map(|(release, path)| {
                let bytes = match source(path) {
                    Ok(bytes) => bytes,
                    Err(e) => {
                        tracing::warn!(path = %path.display(), error = %e, "could not read cover");
                        return Ok((*release, None, true));
                    }
                };
                let Some(bytes) = bytes else { return Ok((*release, None, false)) };
                let image = match image::load_from_memory(&bytes) {
                    Ok(image) => image,
                    Err(e) => {
                        tracing::warn!(path = %path.display(), error = %e, "could not decode cover");
                        return Ok((*release, None, true));
                    }
                };
                render(image, blake3::hash(&bytes), art_dir).map(|art| (*release, Some(art), false))
            })
            .collect::<Result<_, std::io::Error>>()?;
        report.checked += read.len();
        report.found += read.iter().filter(|(_, art, _)| art.is_some()).count();
        report.files += read.iter().filter_map(|(_, art, _)| art.as_ref()).map(|a| a.files).sum::<usize>();
        report.unreadable += read.iter().filter(|(_, _, bad)| *bad).count();
        store.writer.write(move |tx| {
            for (release, art, _) in read {
                if let Some(art) = art {
                    let wash = art.light.map(|c| (c & 0x00ff_ffff) | 0x1400_0000);
                    let dim = art.light.map(|c| (c & 0x00ff_ffff) | 0x5500_0000);
                    tx.execute(
                        "INSERT OR IGNORE INTO artwork (hash, width, height, light, light_wash, light_dim)
                         VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                        params![art.hash.as_bytes().as_slice(), art.width, art.height, art.light.map(i64::from), wash.map(i64::from), dim.map(i64::from)],
                    )?;
                    tx.execute(
                        "INSERT OR REPLACE INTO entity_artwork (entity_kind, entity_id, hash) VALUES (3, ?1, ?2)",
                        params![release.0, art.hash.as_bytes().as_slice()],
                    )?;
                }
                tx.execute("UPDATE release SET art_checked = 1 WHERE id = ?1", [release.0])?;
            }
            Ok(())
        })?;
        progress(ScanProgress { phase: Phase::ReadingCovers, done: report.checked as u64, total });
    }
    Ok(report)
}

fn source(track: &Path) -> std::io::Result<Option<Vec<u8>>> {
    if let Ok(file) = lofty::read_from_path(track) {
        let pictures = || file.tags().iter().flat_map(|t| t.pictures());
        if let Some(picture) = pictures().find(|p| p.pic_type() == PictureType::CoverFront).or_else(|| pictures().next()) {
            return Ok(Some(picture.data().to_vec()));
        }
    }
    let Some(folder) = track.parent() else { return Ok(None) };
    let mut images = fs::read_dir(folder)?
        .filter_map(|entry| entry.ok())
        .map(|entry| entry.path())
        .filter(|path| {
            path.is_file() && path.extension().and_then(|e| e.to_str()).is_some_and(|e| {
                ["jpg", "jpeg", "png"].iter().any(|ext| e.eq_ignore_ascii_case(ext))
            })
        })
        .collect::<Vec<_>>();
    const STEMS: [&str; 5] = ["cover", "folder", "front", "album", "albumart"];
    images.sort_by(|a, b| {
        let rank = |p: &Path| {
            p.file_stem().and_then(|s| s.to_str()).and_then(|s| STEMS.iter().position(|stem| s.eq_ignore_ascii_case(stem))).unwrap_or(STEMS.len())
        };
        rank(a).cmp(&rank(b)).then_with(|| a.file_name().cmp(&b.file_name()))
    });
    images.first().map(fs::read).transpose()
}

fn sized(image: &DynamicImage, size: u32) -> RgbImage {
    if image.width().max(image.height()) <= size {
        image.to_rgb8()
    } else {
        image.resize(size, size, FilterType::Lanczos3).to_rgb8()
    }
}

fn render(image: DynamicImage, hash: blake3::Hash, art_dir: &Path) -> std::io::Result<Rendered> {
    let mut pixels = sized(&image, COVER_SIZES[0]);
    let light = light(&pixels);
    let hash_text = hash.to_hex();
    let mut files = 0;
    for size in COVER_SIZES {
        let path = cover_file(art_dir, hash_text.as_str(), size);
        // Two releases can share the same bytes and be rendered in parallel.
        let file = match OpenOptions::new().write(true).create_new(true).open(&path) {
            Ok(file) => file,
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(e),
        };
        if pixels.width().max(pixels.height()) != size.min(image.width().max(image.height())) {
            pixels = sized(&image, size);
        }
        if let Err(e) = write_jpeg(file, &pixels) {
            let _ = fs::remove_file(&path);
            return Err(e);
        }
        files += 1;
    }
    Ok(Rendered { hash, width: image.width(), height: image.height(), light, files })
}

fn write_jpeg(file: File, image: &RgbImage) -> std::io::Result<()> {
    use std::io::Write;
    let mut writer = BufWriter::new(file);
    JpegEncoder::new_with_quality(&mut writer, 88).encode_image(image).map_err(std::io::Error::other)?;
    writer.flush()
}

#[derive(Clone, Copy, Debug, Default)]
struct Lab {
    l: f64,
    a: f64,
    b: f64,
}

fn linear(v: u8) -> f64 {
    let v = f64::from(v) / 255.0;
    if v <= 0.04045 { v / 12.92 } else { ((v + 0.055) / 1.055).powf(2.4) }
}

fn to_lab(rgb: [u8; 3]) -> Lab {
    let [r, g, b] = rgb.map(linear);
    let l = (0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b).cbrt();
    let m = (0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b).cbrt();
    let s = (0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b).cbrt();
    Lab {
        l: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
        a: 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
        b: 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
    }
}

fn to_linear(lab: Lab) -> [f64; 3] {
    let l = (lab.l + 0.3963377774 * lab.a + 0.2158037573 * lab.b).powi(3);
    let m = (lab.l - 0.1055613458 * lab.a - 0.0638541728 * lab.b).powi(3);
    let s = (lab.l - 0.0894841775 * lab.a - 1.2914855480 * lab.b).powi(3);
    [
        4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
        -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
        -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
    ]
}

fn to_argb(lab: Lab) -> u32 {
    let gamut = |scale| to_linear(Lab { a: lab.a * scale, b: lab.b * scale, ..lab });
    let mut rgb = gamut(1.0);
    if rgb.iter().any(|v| !(0.0..=1.0).contains(v)) {
        let (mut lo, mut hi) = (0.0, 1.0);
        for _ in 0..24 {
            let mid = (lo + hi) / 2.0;
            if gamut(mid).iter().all(|v| (0.0..=1.0).contains(v)) {
                lo = mid;
            } else {
                hi = mid;
            }
        }
        rgb = gamut(lo);
    }
    let [r, g, b] = rgb.map(|v| {
        let v = if v <= 0.0031308 { 12.92 * v } else { 1.055 * v.powf(1.0 / 2.4) - 0.055 };
        (v.clamp(0.0, 1.0) * 255.0).round() as u32
    });
    0xff00_0000 | r << 16 | g << 8 | b
}

fn light(image: &RgbImage) -> Option<u32> {
    #[derive(Clone, Copy, Default)]
    struct Bucket {
        count: usize,
        weight: f64,
        sum: Lab,
    }
    let mut buckets = [Bucket::default(); 24];
    for pixel in image.pixels() {
        let lab = to_lab(pixel.0);
        let chroma = lab.a.hypot(lab.b);
        if lab.l < 0.25 || lab.l > 0.92 || chroma < 0.04 {
            continue;
        }
        let hue = lab.b.atan2(lab.a).rem_euclid(std::f64::consts::TAU);
        let bucket = &mut buckets[(hue / std::f64::consts::TAU * 24.0) as usize];
        bucket.count += 1;
        bucket.weight += chroma;
        bucket.sum.l += lab.l * chroma;
        bucket.sum.a += lab.a * chroma;
        bucket.sum.b += lab.b * chroma;
    }
    let minimum = f64::from(image.width()) * f64::from(image.height()) * 0.05;
    let winner = buckets.iter().filter(|b| b.weight > 0.0 && b.count as f64 >= minimum)
        .max_by(|a, b| a.weight.total_cmp(&b.weight))?;
    let mut lab = Lab { l: winner.sum.l / winner.weight, a: winner.sum.a / winner.weight, b: winner.sum.b / winner.weight };
    // Leave an 8-bit rounding margin so the stored colour stays in band.
    lab.l = lab.l.clamp(0.682, 0.798);
    let chroma = lab.a.hypot(lab.b);
    if chroma > 0.138 {
        lab.a *= 0.138 / chroma;
        lab.b *= 0.138 / chroma;
    }
    Some(to_argb(lab))
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::Rgb;
    use lofty::config::WriteOptions;
    use lofty::picture::{MimeType, Picture};
    use lofty::tag::{Tag, TagType};
    use std::time::{SystemTime, UNIX_EPOCH};

    const TONE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../apps/meret/test/fixtures/tone-16-44.flac");

    fn colour(rgb: [u8; 3]) -> RgbImage {
        RgbImage::from_pixel(64, 64, Rgb(rgb))
    }

    fn lab(argb: u32) -> Lab {
        to_lab([(argb >> 16) as u8, (argb >> 8) as u8, argb as u8])
    }

    #[test]
    fn grey_keeps_the_instrument_accent() {
        assert_eq!(light(&colour([128, 128, 128])), None);
        assert_eq!(light(&colour([250, 250, 250])), None);
    }

    #[test]
    fn orange_is_inside_the_light_band() {
        let light = light(&colour([255, 100, 0])).unwrap();
        let lab = lab(light);
        assert!((0.68..=0.80).contains(&lab.l), "{lab:?}");
        assert!(lab.a.hypot(lab.b) <= 0.14, "{lab:?}");
        assert_eq!(light >> 24, 0xff);
    }

    #[test]
    fn oxblood_is_lifted() {
        let rgb = [96, 15, 32];
        assert!(to_lab(rgb).l < 0.4);
        let lab = lab(light(&colour(rgb)).unwrap());
        assert!(lab.l >= 0.68, "{lab:?}");
    }

    #[test]
    fn saturated_hues_stay_in_band_after_gamut_mapping() {
        for rgb in [[255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 0, 255], [0, 255, 255]] {
            let lab = lab(light(&colour(rgb)).unwrap());
            assert!((0.68..=0.80).contains(&lab.l), "{rgb:?}: {lab:?}");
            assert!(lab.a.hypot(lab.b) <= 0.14, "{rgb:?}: {lab:?}");
        }
    }

    #[test]
    fn a_small_colour_patch_does_not_win() {
        let mut image = colour([128, 128, 128]);
        for pixel in image.pixels_mut().take(64) {
            *pixel = Rgb([255, 100, 0]);
        }
        assert_eq!(light(&image), None);
    }

    fn library() -> (PathBuf, Store, meret_model::RootId) {
        static NEXT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let t = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir = std::env::temp_dir().join(format!("meret-art-{}-{t}-{n}", std::process::id()));
        let music = dir.join("music");
        fs::create_dir_all(&music).unwrap();
        put_track(&music.join("1.flac"), 1);
        let store = Store::open(&dir.join("library.db")).unwrap();
        let root = crate::add_root(&store, &music).unwrap();
        crate::scan(&store, root, &|_| {}).unwrap();
        (dir, store, root)
    }

    fn put_track(path: &Path, number: u32) {
        fs::copy(TONE, path).unwrap();
        let mut tag = Tag::new(TagType::VorbisComments);
        tag.set_title(format!("Track {number}"));
        tag.set_album("The cover".into());
        tag.set_artist("Artist".into());
        tag.set_track(number);
        tag.save_to_path(path, WriteOptions::default()).unwrap();
    }

    #[test]
    fn a_cover_is_written_at_every_size_once_even_after_rescan() {
        let (dir, store, root) = library();
        let image = RgbImage::from_pixel(300, 150, Rgb([255, 100, 0]));
        image.save(dir.join("music/cover.png")).unwrap();
        let art_dir = dir.join("art");
        let progress = parking_lot::Mutex::new(Vec::new());
        let first = covers(&store, &art_dir, &|p| progress.lock().push(p)).unwrap();
        assert_eq!((first.checked, first.found, first.files, first.unreadable), (1, 1, 4, 0));
        assert_eq!(progress.lock().last(), Some(&ScanProgress { phase: Phase::ReadingCovers, done: 1, total: 1 }));
        let release = store.track_rows(&store.load_columns().unwrap().track).unwrap()[0].release;
        let art = store.release_art(&[release]).unwrap().remove(&release).unwrap();
        let light = art.light.unwrap();
        assert_eq!(art.light_wash, Some((light & 0xffffff) | 0x14000000));
        assert_eq!(art.light_dim, Some((light & 0xffffff) | 0x55000000));
        assert_eq!(store.release_page(release).unwrap().unwrap().cover, Some(art.clone()));
        let modified: Vec<_> = COVER_SIZES.into_iter().map(|size| {
            let path = cover_file(&art_dir, &art.hash, size);
            let image = image::open(&path).unwrap();
            assert_eq!((image.width(), image.height()), (size.min(300), size.min(300) / 2));
            fs::metadata(path).unwrap().modified().unwrap()
        }).collect();
        assert_eq!(covers(&store, &art_dir, &|_| {}).unwrap(), CoverReport::default());
        let scan = crate::scan(&store, root, &|_| {}).unwrap();
        assert_eq!((scan.added, scan.changed), (0, 0));
        assert_eq!(covers(&store, &art_dir, &|_| {}).unwrap(), CoverReport::default());
        for (size, modified) in COVER_SIZES.into_iter().zip(modified) {
            assert_eq!(fs::metadata(cover_file(&art_dir, &art.hash, size)).unwrap().modified().unwrap(), modified);
        }
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn missing_art_is_not_rechecked_until_a_track_is_ingested() {
        let (dir, store, root) = library();
        let art_dir = dir.join("art");
        assert_eq!(covers(&store, &art_dir, &|_| {}).unwrap().checked, 1);
        colour([255, 100, 0]).save(dir.join("music/cover.png")).unwrap();
        crate::scan(&store, root, &|_| {}).unwrap();
        assert_eq!(covers(&store, &art_dir, &|_| {}).unwrap(), CoverReport::default());
        put_track(&dir.join("music/2.flac"), 2);
        crate::scan(&store, root, &|_| {}).unwrap();
        let report = covers(&store, &art_dir, &|_| {}).unwrap();
        assert_eq!((report.checked, report.found, report.files), (1, 1, 4));
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn tiny_originals_are_never_upscaled() {
        let (dir, store, _) = library();
        RgbImage::from_pixel(32, 16, Rgb([255, 100, 0])).save(dir.join("music/cover.png")).unwrap();
        let art_dir = dir.join("art");
        assert_eq!(covers(&store, &art_dir, &|_| {}).unwrap().files, 4);
        let release = store.track_rows(&store.load_columns().unwrap().track).unwrap()[0].release;
        let art = store.release_art(&[release]).unwrap().remove(&release).unwrap();
        for size in COVER_SIZES {
            let image = image::open(cover_file(&art_dir, &art.hash, size)).unwrap();
            assert_eq!((image.width(), image.height()), (32, 16));
        }
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn embedded_front_cover_wins_then_folder_names() {
        let (dir, _, _) = library();
        let folder = dir.join("music");
        colour([10, 20, 30]).save(folder.join("a.png")).unwrap();
        colour([30, 40, 50]).save(folder.join("FOLDER.PNG")).unwrap();
        colour([50, 60, 70]).save(folder.join("CoVeR.png")).unwrap();
        let front = fs::read(folder.join("a.png")).unwrap();
        let back = fs::read(folder.join("FOLDER.PNG")).unwrap();
        let track = folder.join("1.flac");
        assert_eq!(source(&track).unwrap().unwrap(), fs::read(folder.join("CoVeR.png")).unwrap());
        let mut tag = Tag::new(TagType::VorbisComments);
        tag.push_picture(Picture::unchecked(back.clone()).pic_type(PictureType::CoverBack).mime_type(MimeType::Png).build());
        tag.save_to_path(&track, WriteOptions::default()).unwrap();
        assert_eq!(source(&track).unwrap(), Some(back));
        tag.push_picture(Picture::unchecked(front.clone()).pic_type(PictureType::CoverFront).mime_type(MimeType::Png).build());
        tag.save_to_path(&track, WriteOptions::default()).unwrap();
        assert_eq!(source(&track).unwrap(), Some(front));
        fs::remove_dir_all(dir).unwrap();
    }
}
