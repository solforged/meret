use crate::{Result, Store};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum LightLevel {
    Off,
    #[default]
    Accent,
    AccentAndWash,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Settings {
    pub light: LightLevel,
    pub output_device: Option<String>,
    pub exclusive: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Self { light: LightLevel::Accent, output_device: None, exclusive: true }
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
                    "exclusive" => settings.exclusive = value != "false",
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
            ] {
                tx.execute(
                    "INSERT INTO setting (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    [key, value],
                )?;
            }
            Ok(())
        })
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
        assert_eq!(Settings::default(), Settings { light: LightLevel::Accent, output_device: None, exclusive: true });
        let saved = Settings { light: LightLevel::AccentAndWash, output_device: Some("test-device".into()), exclusive: false };
        store.set_settings(saved.clone()).unwrap();
        assert_eq!(store.settings().unwrap(), Some(saved.clone()));
        drop(store);
        let store = Store::open(&path).unwrap();
        assert_eq!(store.settings().unwrap(), Some(saved));
        store.set_settings(Settings::default()).unwrap();
        assert_eq!(store.settings().unwrap(), Some(Settings::default()));
        store.set_settings(Settings { light: LightLevel::Off, ..Settings::default() }).unwrap();
        assert_eq!(store.settings().unwrap().unwrap().light, LightLevel::Off);
        drop(store);
        std::fs::remove_dir_all(dir).unwrap();
    }
}
