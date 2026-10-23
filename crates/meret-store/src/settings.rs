use crate::{Result, Store};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum LightLevel {
    Off,
    #[default]
    Accent,
    AccentAndWash,
}

/// Whether Meret may look things up online. Asked once, before the first lookup.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Lookups {
    #[default]
    Unasked,
    Allowed,
    Off,
}

/// Loudness levelling for local playback.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Level {
    #[default]
    Off,
    Track,
    Album,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Settings {
    pub light: LightLevel,
    pub output_device: Option<String>,
    pub exclusive: bool,
    pub level: Level,
    pub lookups: Lookups,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            light: LightLevel::Accent, output_device: None, exclusive: false,
            level: Level::Off, lookups: Lookups::Unasked,
        }
    }
}

impl Store {
    /// None means no settings have been saved; the host's output defaults stay.
    pub fn settings(&self) -> Result<Option<Settings>> {
        self.read(|c| {
            let mut settings = Settings::default();
            let mut found = false;
            let mut stmt = c.prepare("SELECT key, value FROM setting")?;
            for row in stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))? {
                let (key, value) = row?;
                match key.as_str() {
                    "light" => settings.light = match value.as_str() {
                        "off" => LightLevel::Off,
                        "accent_and_wash" => LightLevel::AccentAndWash,
                        _ => LightLevel::Accent,
                    },
                    "output_device" => settings.output_device = (!value.is_empty()).then_some(value),
                    "exclusive" => settings.exclusive = value == "true",
                    "level" => settings.level = match value.as_str() {
                        "track" => Level::Track,
                        "album" => Level::Album,
                        _ => Level::Off,
                    },
                    "lookups" => settings.lookups = match value.as_str() {
                        "allowed" => Lookups::Allowed,
                        "off" => Lookups::Off,
                        _ => Lookups::Unasked,
                    },
                    _ => continue,
                }
                found = true;
            }
            Ok(found.then_some(settings))
        })
    }

    pub fn set_settings(&self, settings: Settings) -> Result<()> {
        self.writer.write(move |tx| {
            let light = match settings.light {
                LightLevel::Off => "off",
                LightLevel::Accent => "accent",
                LightLevel::AccentAndWash => "accent_and_wash",
            };
            for (key, value) in [
                ("light", light),
                ("output_device", settings.output_device.as_deref().unwrap_or("")),
                ("exclusive", if settings.exclusive { "true" } else { "false" }),
                ("level", match settings.level {
                    Level::Off => "off",
                    Level::Track => "track",
                    Level::Album => "album",
                }),
                ("lookups", match settings.lookups {
                    Lookups::Unasked => "unasked",
                    Lookups::Allowed => "allowed",
                    Lookups::Off => "off",
                }),
            ] {
                tx.execute(
                    "INSERT INTO setting (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    [key, value],
                )?;
            }
            Ok(())
        })
    }

    /// This library's device id, a ULID minted on first use and kept in
    /// `setting`. Every row a person makes (listens, trails, resume points)
    /// carries it, so two devices' rows merge without colliding.
    pub fn device_id(&self) -> Result<String> {
        if let Some(id) = self.read(|c| {
            c.query_row("SELECT value FROM setting WHERE key = 'device_id'", [], |r| r.get::<_, String>(0))
                .map(Some)
                .or_else(|e| if e == rusqlite::Error::QueryReturnedNoRows { Ok(None) } else { Err(e) })
        })? {
            return Ok(id);
        }
        let minted = ulid::Ulid::generate().to_string();
        let keep = minted.clone();
        self.writer.write(move |tx| {
            tx.execute("INSERT OR IGNORE INTO setting (key, value) VALUES ('device_id', ?1)", [keep])?;
            Ok(())
        })?;
        // Another writer may have won the race; the row is what counts.
        self.read(|c| c.query_row("SELECT value FROM setting WHERE key = 'device_id'", [], |r| r.get(0)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_and_round_trip_survive_reopen() {
        let dir = std::env::temp_dir().join(format!("meret-settings-{}-{}", std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("library.db");
        let store = Store::open(&path).unwrap();
        assert_eq!(store.settings().unwrap(), None);
        assert_eq!(Settings::default(), Settings {
            light: LightLevel::Accent, output_device: None, exclusive: false,
            level: Level::Off, lookups: Lookups::Unasked,
        });
        let saved = Settings {
            light: LightLevel::AccentAndWash, output_device: Some("test-device".into()),
            exclusive: true, level: Level::Album, lookups: Lookups::Allowed,
        };
        store.set_settings(saved.clone()).unwrap();
        assert_eq!(store.settings().unwrap(), Some(saved.clone()));
        drop(store);
        let store = Store::open(&path).unwrap();
        assert_eq!(store.settings().unwrap(), Some(saved));
        store.set_settings(Settings::default()).unwrap();
        assert_eq!(store.settings().unwrap(), Some(Settings::default()));
        store.set_settings(Settings { light: LightLevel::Off, ..Settings::default() }).unwrap();
        assert_eq!(store.settings().unwrap().unwrap().light, LightLevel::Off);
        store.set_settings(Settings { level: Level::Track, ..Settings::default() }).unwrap();
        assert_eq!(store.settings().unwrap().unwrap().level, Level::Track);
        store.writer.write(|tx| {
            tx.execute("DELETE FROM setting WHERE key = 'level'", [])?;
            Ok(())
        }).unwrap();
        assert_eq!(store.settings().unwrap().unwrap().level, Level::Off);
        drop(store);
        std::fs::remove_dir_all(dir).unwrap();
    }
}
