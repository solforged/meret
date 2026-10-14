//! Music Assistant: one websocket API over many streaming providers (Spotify,
//! Tidal, Qobuz, YouTube Music, Plex, Jellyfin, Subsonic) and many players
//! (AirPlay, Chromecast, Sonos, Snapcast). Meret's shortcut to most services.
//!
//! Not connected yet. The plan:
//! 1. Connect to the server's websocket, authenticate, and subscribe to
//!    player and queue events.
//! 2. Expose each player as a `Zone`, with fidelity from what MA reports
//!    (Sonos resamples above 48 kHz; AirPlay is 16/44.1 with ~2 s delay).
//! 3. Expose search and library across MA's providers as `Catalog` and
//!    `LibrarySync`, tagging each claim with the underlying service.
//! 4. Find out whether MA can play on the Mac itself (direction.md, spike 3).

use std::sync::Arc;

use meret_player::Zone;
use meret_provider::*;

pub struct MusicAssistant {
    pub url: Option<String>,
}

impl Provider for MusicAssistant {
    fn key(&self) -> &'static str {
        "music_assistant"
    }
    fn name(&self) -> &'static str {
        "Music Assistant"
    }
    fn capabilities(&self) -> Capabilities {
        Capabilities { catalog: true, library_sync: true, zone_host: true, ..Default::default() }
    }
    fn health(&self) -> Health {
        match &self.url {
            None => Health::Disabled,
            Some(_) => Health::Offline { reason: "not connected yet".into() },
        }
    }
    fn as_zone_host(&self) -> Option<&dyn ZoneHost> {
        Some(self)
    }
}

impl ZoneHost for MusicAssistant {
    fn zones(&self) -> Vec<Arc<dyn Zone>> {
        vec![]
    }
}
