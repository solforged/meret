//! The status line: every source's state, every running job, and how many
//! identities are guesses. Always visible on desktop.

use meret_jobs::JobGroupStatus;
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
}

pub(crate) fn initial(registry: &Registry) -> StatusState {
    let mut sources = vec![SourceStatus { name: "This Mac".into(), detail: "0".into(), ok: true }];
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
