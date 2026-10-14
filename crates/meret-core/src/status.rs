//! The status line: every source's state, every running job, and how many
//! identities are guesses. Always visible on desktop.

use meret_jobs::JobGroupStatus;
use meret_library::{Phase, ScanProgress};
use meret_provider::{Health, Registry};

#[derive(Clone, Debug, PartialEq)]
pub struct SourceStatus {
    /// "This Mac", "Music Assistant", "Spotify".
    pub name: String,
    /// "48,210", "6 providers", "Connect", "1 of 2 zones".
    pub detail: String,
    pub ok: bool,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct StatusState {
    pub sources: Vec<SourceStatus>,
    pub jobs: Vec<JobGroupStatus>,
    pub guessed: u64,
    pub new_leads: u64,
    /// Tracks in the table: those with a file that's present.
    pub tracks: u64,
    /// Bumped whenever the library's rows change, so lists know to refetch.
    pub library_version: u64,
}

const SCAN_VERBS: [&str; 2] = ["scanning", "reading tags"];

pub(crate) fn initial(registry: &Registry) -> StatusState {
    let mut sources = vec![SourceStatus { name: local_name().into(), detail: "0".into(), ok: true }];
    for (name, health) in registry.health() {
        let (detail, ok) = match health {
            Health::Ok { detail } => (detail, true),
            Health::Degraded { reason } => (reason, false),
            Health::NeedsAuth => ("sign in".into(), false),
            Health::Offline { reason } => (reason, false),
            Health::Disabled => continue,
        };
        sources.push(SourceStatus { name: name.into(), detail, ok });
    }
    StatusState { sources, ..Default::default() }
}

pub(crate) fn set_library(s: &mut StatusState, tracks: u64) {
    s.tracks = tracks;
    s.library_version += 1;
    if let Some(local) = s.sources.iter_mut().find(|x| x.name == local_name()) {
        local.detail = thousands(tracks);
    }
}

/// Shows a scan's progress as a job, or clears it with None.
pub(crate) fn set_scan(s: &mut StatusState, progress: Option<ScanProgress>) {
    s.jobs.retain(|j| !SCAN_VERBS.contains(&j.verb.as_str()));
    if let Some(p) = progress {
        let verb = match p.phase {
            Phase::Walking => SCAN_VERBS[0],
            Phase::Reading => SCAN_VERBS[1],
        };
        s.jobs.push(JobGroupStatus { verb: verb.into(), done: p.done, total: p.total, paused_because: None });
    }
}

fn local_name() -> &'static str {
    if cfg!(target_os = "macos") { "This Mac" } else { "This device" }
}

/// 48210 → "48,210", as the status line writes counts.
fn thousands(n: u64) -> String {
    let digits = n.to_string();
    let mut out = String::with_capacity(digits.len() + digits.len() / 3);
    for (i, c) in digits.chars().enumerate() {
        if i > 0 && (digits.len() - i).is_multiple_of(3) {
            out.push(',');
        }
        out.push(c);
    }
    out
}
