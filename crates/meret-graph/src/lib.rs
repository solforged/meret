//! The discovery graph: trails (trees of followed threads) and leads.
//! Threads themselves are rows in the store's `edge` table; this crate holds
//! the logic that has to be right regardless of where they come from.

pub mod leads;
pub mod trail;

pub use leads::{Evidence, LeadStrength, converge};
pub use trail::{Action, Branch, Trail, TrailHistory, Via};
