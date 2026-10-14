//! Now: what's playing, where, and through what. Fed by engine events.

use std::sync::Arc;
use std::thread;

use meret_engine::{Anchor, EngineEvent};
use meret_model::signal::SignalPath;

use crate::Core;

#[derive(Clone, Debug, Default, PartialEq)]
pub struct NowState {
    pub item: Option<u64>,
    pub title: String,
    pub subtitle: String,
    pub anchor: Option<Anchor>,
    pub length_ms: Option<u64>,
    pub path: Option<SignalPath>,
    pub error: Option<String>,
}

pub(crate) fn spawn_pump(core: Arc<Core>) {
    thread::Builder::new()
        .name("meret-now".into())
        .spawn(move || {
            let events = core.engine.events().clone();
            while let Ok(e) = events.recv() {
                core.now.send_modify(|n| match e {
                    EngineEvent::Started { item, path } => {
                        n.item = Some(item);
                        n.path = Some(path);
                        n.error = None;
                    }
                    EngineEvent::Anchor(a) => n.anchor = Some(a),
                    EngineEvent::Ended { .. } => {}
                    EngineEvent::Idle => {
                        if let Some(a) = &mut n.anchor {
                            a.rate = 0.0;
                        }
                    }
                    EngineEvent::Error { message, .. } => n.error = Some(message),
                });
            }
        })
        .expect("spawn now pump");
}
