//! The engine thread: owns the decoder, the DSP chain and the output stream,
//! keeps the ring full, splices the next item in gaplessly, and turns the
//! callback's clock into events.

use std::collections::VecDeque;
use std::sync::Arc;
use std::thread::{self, JoinHandle};
use std::time::Duration;

use meret_model::audio::StreamSpec;
use meret_model::signal::{SignalPath, Stage as PathStage};
use crossbeam_channel::{Receiver, RecvTimeoutError, Sender, unbounded};

use crate::clock::{Anchor, SharedClock, now_ns};
use crate::decode::Decoder;
use crate::dsp::Stage;
use crate::output::{Opened, OutputBackend, OutputRequest, OutputStream};
use crate::ring::{RingWriter, ring};
use crate::Sample;

/// The player's handle for a queue item. The engine only compares them.
pub type ItemToken = u64;

pub struct Load {
    pub item: ItemToken,
    pub decoder: Box<dyn Decoder>,
    pub start_frame: u64,
    pub stages: Vec<Box<dyn Stage>>,
}

pub enum Control {
    /// Replace whatever is playing and start this.
    Play(Load),
    /// What follows the current item, opened early for a gapless join.
    SetNext(Option<Load>),
    /// Use this output choice from the next track opened. The current stream,
    /// including pause and resume, stays on its existing output until then.
    SetOutput { device: Option<String>, exclusive: bool },
    Resume,
    Pause,
    Seek(u64),
    Stop,
    Shutdown,
}

#[derive(Clone, Debug, PartialEq)]
pub enum EngineEvent {
    /// `item` became audible. Sent when its first frame reaches the device,
    /// not when it was decoded.
    Started { item: ItemToken, path: SignalPath },
    Anchor(Anchor),
    /// `item` finished: its last frame reached the device.
    Ended { item: ItemToken },
    /// Nothing left to play.
    Idle,
    Error { item: Option<ItemToken>, message: String },
}

pub struct Engine {
    ctl: Sender<Control>,
    events: Receiver<EngineEvent>,
    handle: Option<JoinHandle<()>>,
}

pub struct EngineConfig {
    pub device: Option<String>,
    pub exclusive: bool,
    /// How much audio the ring holds. Larger rides out stalls; smaller makes
    /// device changes quicker. Seeks don't wait on it (they flush).
    pub ring_ms: u32,
    /// Drift beyond this republishes the anchor.
    pub anchor_tolerance_ms: f64,
}

impl Default for EngineConfig {
    fn default() -> Self {
        Self { device: None, exclusive: true, ring_ms: 500, anchor_tolerance_ms: 2.0 }
    }
}

impl Engine {
    pub fn spawn(backend: Arc<dyn OutputBackend>, config: EngineConfig) -> Self {
        let (ctl, ctl_rx) = unbounded();
        let (ev_tx, events) = unbounded();
        let handle = thread::Builder::new()
            .name("meret-engine".into())
            .spawn(move || Worker::new(backend, config, ev_tx).run(ctl_rx))
            .expect("spawn engine thread");
        Self { ctl, events, handle: Some(handle) }
    }

    pub fn send(&self, c: Control) {
        let _ = self.ctl.send(c);
    }

    pub fn events(&self) -> &Receiver<EngineEvent> {
        &self.events
    }
}

impl Drop for Engine {
    fn drop(&mut self) {
        let _ = self.ctl.send(Control::Shutdown);
        if let Some(h) = self.handle.take() {
            let _ = h.join();
        }
    }
}

struct Active {
    item: ItemToken,
    decoder: Box<dyn Decoder>,
    stages: Vec<Box<dyn Stage>>,
    spec: StreamSpec,
}

/// Where an item begins in the output stream, so the clock can say which
/// item the device is playing.
struct Boundary {
    stream_frame: u64,
    item: ItemToken,
    /// The item's own position at that point (non-zero after a seek).
    item_frame: u64,
    path: SignalPath,
}

struct Output {
    stream: Box<dyn OutputStream>,
    writer: RingWriter,
    spec: StreamSpec,
    device: Option<String>,
    exclusive: bool,
}

struct Worker {
    backend: Arc<dyn OutputBackend>,
    config: EngineConfig,
    events: Sender<EngineEvent>,
    clock: Arc<SharedClock>,
    out: Option<Output>,
    current: Option<Active>,
    next: Option<Load>,
    /// Decoded samples not yet in the ring.
    pending: Vec<Sample>,
    pending_at: usize,
    /// Frames written to the ring since the stream opened.
    written: u64,
    boundaries: VecDeque<Boundary>,
    audible: Option<Boundary>,
    playing: bool,
    /// The current item has finished decoding; waiting for the next or a drain.
    draining: bool,
    last_anchor: Option<Anchor>,
}

impl Worker {
    fn new(backend: Arc<dyn OutputBackend>, config: EngineConfig, events: Sender<EngineEvent>) -> Self {
        Self {
            backend,
            config,
            events,
            clock: Arc::new(SharedClock::default()),
            out: None,
            current: None,
            next: None,
            pending: Vec::with_capacity(1 << 16),
            pending_at: 0,
            written: 0,
            boundaries: VecDeque::new(),
            audible: None,
            playing: false,
            draining: false,
            last_anchor: None,
        }
    }

    fn run(mut self, ctl: Receiver<Control>) {
        loop {
            // Idle: block on control. Busy: poll every couple of milliseconds.
            let wait = if self.current.is_some() || self.audible.is_some() {
                Duration::from_millis(2)
            } else {
                Duration::from_millis(250)
            };
            match ctl.recv_timeout(wait) {
                Ok(Control::Shutdown) | Err(RecvTimeoutError::Disconnected) => break,
                Ok(c) => self.handle(c),
                Err(RecvTimeoutError::Timeout) => {}
            }
            for c in ctl.try_iter().collect::<Vec<_>>() {
                if matches!(c, Control::Shutdown) {
                    return;
                }
                self.handle(c);
            }
            if self.playing {
                self.fill();
            }
            self.publish();
        }
    }

    fn handle(&mut self, c: Control) {
        match c {
            Control::Play(load) => {
                self.flush();
                self.next = None;
                self.start(load);
                self.playing = true;
                // Prefill so the device's first callback has audio.
                self.fill();
                self.resume_output();
            }
            Control::SetNext(load) => self.next = load,
            Control::SetOutput { device, exclusive } => {
                self.config.device = device;
                self.config.exclusive = exclusive;
            }
            Control::Resume => {
                self.playing = true;
                self.resume_output();
            }
            Control::Pause => {
                self.playing = false;
                if let Some(o) = &mut self.out {
                    let _ = o.stream.pause();
                }
                self.clock.set_playing(false);
            }
            Control::Seek(frame) => {
                let Some(cur) = &mut self.current else { return };
                let item = cur.item;
                match cur.decoder.seek(frame) {
                    Ok(reached) => {
                        self.flush();
                        let path = self.audible.as_ref().map(|b| b.path.clone()).unwrap_or_default();
                        self.boundaries.push_back(Boundary { stream_frame: self.written, item, item_frame: reached, path });
                        self.draining = false;
                    }
                    Err(e) => self.error(Some(item), e.to_string()),
                }
            }
            Control::Stop => {
                self.flush();
                self.current = None;
                self.next = None;
                self.playing = false;
                self.release_output();
                if let Some(b) = self.audible.take() {
                    let _ = self.events.send(EngineEvent::Ended { item: b.item });
                }
                let _ = self.events.send(EngineEvent::Idle);
            }
            Control::Shutdown => unreachable!("handled by run"),
        }
    }

    fn resume_output(&mut self) {
        if let Some(o) = &mut self.out {
            let _ = o.stream.start();
            self.clock.set_playing(true);
        }
    }

    /// Closes the device so other apps can have it (and hog mode, the
    /// sample rate and the format go back to how they were).
    fn release_output(&mut self) {
        self.out = None;
        self.clock.set_playing(false);
    }

    /// Makes `load` current, reopening if the format or output choice differs.
    fn start(&mut self, mut load: Load) {
        let spec = load.decoder.spec();
        if load.start_frame > 0
            && let Err(e) = load.decoder.seek(load.start_frame)
        {
            self.error(Some(load.item), e.to_string());
        }
        if !self.output_matches(spec) && !self.open_output(spec) {
            self.error(Some(load.item), "the output device could not be opened".into());
            return;
        }
        let opened = self.out.as_ref().expect("opened above").stream.opened().clone();
        let path = signal_path(spec, &load.stages, &opened);
        self.boundaries.push_back(Boundary {
            stream_frame: self.written,
            item: load.item,
            item_frame: load.start_frame,
            path,
        });
        self.current = Some(Active { item: load.item, decoder: load.decoder, stages: load.stages, spec });
        self.draining = false;
    }

    fn output_matches(&self, spec: StreamSpec) -> bool {
        self.out.as_ref().is_some_and(|o| {
            o.spec == spec && o.device == self.config.device && o.exclusive == self.config.exclusive
        })
    }

    fn open_output(&mut self, spec: StreamSpec) -> bool {
        // Drop the old stream (and its callback) before opening a new one.
        self.out = None;
        let frames = (spec.sample_rate as usize * self.config.ring_ms as usize / 1000).max(4096);
        let (writer, reader) = ring(frames, spec.channels);
        self.clock = Arc::new(SharedClock::default());
        self.clock.reset();
        self.written = 0;
        self.boundaries.clear();
        let req = OutputRequest { device: self.config.device.clone(), spec, exclusive: self.config.exclusive };
        match self.backend.open(&req, reader, self.clock.clone()) {
            Ok(stream) => {
                self.out = Some(Output { stream, writer, spec, device: req.device, exclusive: req.exclusive });
                true
            }
            Err(e) => {
                tracing::error!(error = %e, "output open failed");
                false
            }
        }
    }

    /// Drops everything buffered and waits for the callback to confirm.
    fn flush(&mut self) {
        self.pending.clear();
        self.pending_at = 0;
        self.boundaries.clear();
        let Some(_) = &self.out else { return };
        let generation = self.clock.request_flush();
        // A running callback acknowledges within one period. A paused one
        // acknowledges when it next runs, and `fill` holds off until then.
        let running = self.clock.read().2;
        for _ in 0..if running { 200 } else { 0 } {
            if self.clock.flushed(generation) {
                break;
            }
            thread::sleep(Duration::from_micros(500));
        }
        self.written = self.clock.read().0;
    }

    /// Keeps the ring full, splicing in the next item at the end of this one.
    fn fill(&mut self) {
        // Anything written now would be thrown away by the flush.
        if self.clock.flush_outstanding() {
            return;
        }
        loop {
            // Write what's pending first.
            if self.pending_at < self.pending.len() {
                let Some(out) = &mut self.out else { return };
                let wrote = out.writer.write(&self.pending[self.pending_at..]);
                self.written += wrote as u64;
                self.pending_at += wrote * out.spec.channels as usize;
                if self.pending_at < self.pending.len() {
                    return; // ring is full
                }
            }
            self.pending.clear();
            self.pending_at = 0;

            let Some(cur) = &mut self.current else { return };
            match cur.decoder.read(&mut self.pending) {
                Ok(0) => {
                    if !self.advance() {
                        return;
                    }
                }
                Ok(_) => {
                    let ch = cur.spec.channels;
                    for s in &mut cur.stages {
                        s.process(&mut self.pending, ch);
                    }
                }
                Err(e) => {
                    let item = cur.item;
                    self.error(Some(item), e.to_string());
                    if !self.advance() {
                        return;
                    }
                }
            }
        }
    }

    /// The current item has run out. Returns whether filling can continue.
    fn advance(&mut self) -> bool {
        let can_join = self.next.as_ref().is_some_and(|n| self.output_matches(n.decoder.spec()));

        if can_join {
            // Gapless: the next item's first frame follows this one's last.
            let load = self.next.take().expect("checked");
            self.start(load);
            return true;
        }

        // Either nothing follows, or the format/output choice changes and the
        // device must reopen. Both wait for the ring to drain first.
        self.draining = true;
        let played = self.clock.read().0;
        if played < self.written {
            return false;
        }
        self.current = None;
        match self.next.take() {
            Some(load) => {
                self.start(load);
                self.resume_output();
                true
            }
            None => false,
        }
    }

    /// Turns the callback's clock into Started, Ended, Anchor and Idle events.
    fn publish(&mut self) {
        let (played, at_ns, running) = self.clock.read();

        while self.boundaries.front().is_some_and(|b| b.stream_frame <= played) {
            let b = self.boundaries.pop_front().expect("checked");
            let same_item = self.audible.as_ref().is_some_and(|a| a.item == b.item);
            if !same_item {
                if let Some(prev) = &self.audible {
                    let _ = self.events.send(EngineEvent::Ended { item: prev.item });
                }
                let _ = self.events.send(EngineEvent::Started { item: b.item, path: b.path.clone() });
            }
            self.audible = Some(b);
        }

        // Everything written has played and nothing is coming: finished.
        if self.draining && self.current.is_none() && played >= self.written && self.audible.is_some() {
            if let Some(prev) = self.audible.take() {
                let _ = self.events.send(EngineEvent::Ended { item: prev.item });
            }
            let _ = self.events.send(EngineEvent::Idle);
            self.playing = false;
            self.draining = false;
            self.last_anchor = None;
            self.release_output();
            return;
        }
        if self.draining && self.current.is_some() {
            // Output change pending: try to move on once drained.
            if played >= self.written && self.playing {
                self.fill();
            }
        }

        let (Some(b), Some(out)) = (&self.audible, &self.out) else { return };
        let anchor = Anchor {
            item: b.item,
            position_frames: b.item_frame + played.saturating_sub(b.stream_frame),
            sample_rate: out.spec.sample_rate,
            at_ns: if at_ns == 0 { now_ns() } else { at_ns },
            rate: if running && self.playing { 1.0 } else { 0.0 },
        };
        let send = self.last_anchor.is_none_or(|last| last.differs(&anchor, self.config.anchor_tolerance_ms));
        if send {
            self.last_anchor = Some(anchor);
            let _ = self.events.send(EngineEvent::Anchor(anchor));
        }
    }

    fn error(&self, item: Option<ItemToken>, message: String) {
        tracing::warn!(?item, %message, "engine error");
        let _ = self.events.send(EngineEvent::Error { item, message });
    }
}

/// File → Decode → Out, each saying whether it changes the samples.
pub fn signal_path(src: StreamSpec, stages: &[Box<dyn Stage>], out: &Opened) -> SignalPath {
    let mut path = SignalPath::default();
    path.stages.push(PathStage {
        name: "File".into(),
        detail: src.describe(),
        alters: false,
        lossy: !src.codec.is_lossless(),
    });
    let dsp: Vec<PathStage> = stages.iter().map(|s| s.describe()).filter(|s| s.alters).collect();
    if dsp.is_empty() {
        path.stages.push(PathStage { name: "Decode".into(), detail: "no DSP".into(), alters: false, lossy: false });
    } else {
        path.stages.extend(dsp);
    }
    let resampled = out.sample_rate != src.sample_rate;
    let truncated = out.bits < src.bits;
    let khz = out.sample_rate as f64 / 1000.0;
    path.stages.push(PathStage {
        name: "Out".into(),
        detail: format!("{} · {}", out.device_name, if khz.fract() == 0.0 { format!("{khz:.0}") } else { format!("{khz:.1}") }),
        alters: resampled || truncated || !out.exclusive,
        lossy: false,
    });
    path
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::decode::Tone;
    use crate::output::null::NullBackend;
    use crate::output::{DeviceInfo, OutputError};
    use crate::ring::RingReader;
    use meret_model::audio::Codec;
    use meret_model::signal::Fidelity;

    fn cd() -> StreamSpec {
        StreamSpec { sample_rate: 44_100, channels: 2, bits: 16, codec: Codec::Flac }
    }

    fn load(item: u64, spec: StreamSpec, secs: f64) -> Load {
        Load { item, decoder: Box::new(Tone::new(spec, secs, 440.0)), start_frame: 0, stages: vec![] }
    }

    fn collect_until_idle(engine: &Engine) -> Vec<EngineEvent> {
        let mut out = vec![];
        while let Ok(e) = engine.events().recv_timeout(Duration::from_secs(5)) {
            let idle = e == EngineEvent::Idle;
            if !matches!(e, EngineEvent::Anchor(_)) {
                out.push(e);
            }
            if idle {
                break;
            }
        }
        out
    }

    #[derive(Debug, PartialEq)]
    enum OutputAction {
        Open { device: Option<String>, exclusive: bool },
        Start,
        Pause,
        Drop,
    }

    struct RecordingBackend(Sender<OutputAction>);

    impl OutputBackend for RecordingBackend {
        fn name(&self) -> &'static str { "recording" }

        fn devices(&self) -> Result<Vec<DeviceInfo>, OutputError> { Ok(vec![]) }

        fn open(
            &self,
            req: &OutputRequest,
            source: RingReader,
            _clock: Arc<SharedClock>,
        ) -> Result<Box<dyn OutputStream>, OutputError> {
            self.0.send(OutputAction::Open { device: req.device.clone(), exclusive: req.exclusive }).unwrap();
            if req.device.as_deref() == Some("missing") {
                return Err(OutputError::NoDevice("missing".into()));
            }
            Ok(Box::new(RecordingStream {
                actions: self.0.clone(),
                _source: source,
                opened: Opened {
                    device_name: req.device.clone().unwrap_or_else(|| "default".into()),
                    sample_rate: req.spec.sample_rate,
                    bits: req.spec.bits,
                    channels: req.spec.channels,
                    exclusive: req.exclusive,
                    latency_frames: 0,
                },
            }))
        }
    }

    struct RecordingStream {
        actions: Sender<OutputAction>,
        _source: RingReader,
        opened: Opened,
    }

    impl OutputStream for RecordingStream {
        fn opened(&self) -> &Opened { &self.opened }

        fn start(&mut self) -> Result<(), OutputError> {
            self.actions.send(OutputAction::Start).unwrap();
            Ok(())
        }

        fn pause(&mut self) -> Result<(), OutputError> {
            self.actions.send(OutputAction::Pause).unwrap();
            Ok(())
        }
    }

    impl Drop for RecordingStream {
        fn drop(&mut self) {
            let _ = self.actions.send(OutputAction::Drop);
        }
    }

    fn recording_worker() -> (Worker, Receiver<OutputAction>, Receiver<EngineEvent>) {
        let (actions_tx, actions) = unbounded();
        let (events_tx, events) = unbounded();
        let worker = Worker::new(Arc::new(RecordingBackend(actions_tx)), EngineConfig::default(), events_tx);
        (worker, actions, events)
    }

    #[test]
    fn output_choice_waits_for_the_current_track_to_drain_even_across_pause_resume() {
        for (device, exclusive) in [(Some("dac"), true), (None, false), (Some("dac"), false)] {
            let (mut worker, actions, _events) = recording_worker();
            worker.handle(Control::Play(load(1, cd(), 0.01)));
            assert_eq!(actions.try_iter().collect::<Vec<_>>(), [
                OutputAction::Open { device: None, exclusive: true },
                OutputAction::Start,
            ]);
            worker.handle(Control::SetNext(Some(load(2, cd(), 0.01))));
            let device = device.map(str::to_owned);
            worker.handle(Control::SetOutput { device: device.clone(), exclusive });
            assert_eq!(worker.config.device, device);
            assert_eq!(worker.config.exclusive, exclusive);
            assert!(actions.is_empty());
            worker.handle(Control::Pause);
            worker.handle(Control::Resume);
            assert_eq!(actions.try_iter().collect::<Vec<_>>(), [OutputAction::Pause, OutputAction::Start]);
            worker.fill();
            assert!(actions.is_empty());
            assert_eq!(worker.current.as_ref().unwrap().item, 1);
            assert_eq!(worker.next.as_ref().unwrap().item, 2);
            assert!(worker.written > 0);
            assert_eq!(worker.clock.read().0, 0);

            // Stand in for the callback consuming every old-output frame.
            worker.clock.advance(worker.written, now_ns());
            worker.fill();
            assert_eq!(actions.try_iter().collect::<Vec<_>>(), [
                OutputAction::Drop,
                OutputAction::Open { device, exclusive },
                OutputAction::Start,
            ]);
            assert_eq!(worker.current.as_ref().unwrap().item, 2);
            assert_eq!(worker.out.as_ref().unwrap().spec, cd());
        }
    }

    #[test]
    fn unchanged_output_choice_keeps_same_format_tracks_gapless() {
        let (mut worker, actions, _events) = recording_worker();
        worker.handle(Control::Play(load(1, cd(), 0.01)));
        actions.try_iter().for_each(drop);
        worker.handle(Control::SetOutput { device: None, exclusive: true });
        worker.handle(Control::SetNext(Some(load(2, cd(), 0.01))));
        worker.fill();
        assert!(actions.is_empty());
        assert_eq!(worker.clock.read().0, 0);
        assert_eq!(worker.current.as_ref().unwrap().item, 2);
        assert!(worker.next.is_none());
    }

    #[test]
    fn explicit_play_reopens_same_format_for_a_changed_choice_and_back_to_default() {
        let (mut worker, actions, _events) = recording_worker();
        worker.handle(Control::Play(load(1, cd(), 0.01)));
        actions.try_iter().for_each(drop);
        for (item, device, exclusive) in [(2, Some("dac"), false), (3, None, true)] {
            worker.handle(Control::Pause);
            assert_eq!(actions.try_recv().unwrap(), OutputAction::Pause);
            let device = device.map(str::to_owned);
            worker.handle(Control::SetOutput { device: device.clone(), exclusive });
            assert!(actions.is_empty());
            worker.handle(Control::Play(load(item, cd(), 0.01)));
            assert_eq!(actions.try_iter().collect::<Vec<_>>(), [
                OutputAction::Drop,
                OutputAction::Open { device, exclusive },
                OutputAction::Start,
            ]);
            assert_eq!(worker.current.as_ref().unwrap().item, item);
        }
    }

    #[test]
    fn rejected_output_choice_reports_an_error_only_when_the_next_track_opens() {
        let (mut worker, actions, events) = recording_worker();
        worker.handle(Control::Play(load(1, cd(), 0.01)));
        worker.publish();
        actions.try_iter().for_each(drop);
        events.try_iter().for_each(drop);
        worker.handle(Control::SetOutput { device: Some("missing".into()), exclusive: false });
        worker.handle(Control::SetNext(Some(load(2, cd(), 0.01))));
        worker.fill();
        assert!(actions.is_empty());
        assert!(events.is_empty());
        assert!(worker.out.is_some());
        worker.clock.advance(worker.written, now_ns());
        worker.fill();
        assert_eq!(actions.try_iter().collect::<Vec<_>>(), [
            OutputAction::Drop,
            OutputAction::Open { device: Some("missing".into()), exclusive: false },
        ]);
        assert!(worker.out.is_none());
        assert_eq!(events.try_iter().collect::<Vec<_>>(), [
            EngineEvent::Error { item: Some(2), message: "the output device could not be opened".into() },
        ]);
    }

    #[test]
    fn joins_two_items_gaplessly_and_reports_them_in_order() {
        let engine = Engine::spawn(Arc::new(NullBackend { speed: 40.0 }), EngineConfig::default());
        engine.send(Control::Play(load(1, cd(), 0.5)));
        engine.send(Control::SetNext(Some(load(2, cd(), 0.5))));
        let events = collect_until_idle(&engine);
        let kinds: Vec<_> = events
            .iter()
            .map(|e| match e {
                EngineEvent::Started { item, path } => {
                    assert_eq!(path.fidelity(), Fidelity::BitPerfect);
                    format!("start {item}")
                }
                EngineEvent::Ended { item } => format!("end {item}"),
                EngineEvent::Idle => "idle".into(),
                other => format!("{other:?}"),
            })
            .collect();
        assert_eq!(kinds, ["start 1", "end 1", "start 2", "end 2", "idle"]);
    }

    #[test]
    fn a_format_change_reopens_the_device_between_items() {
        let engine = Engine::spawn(Arc::new(NullBackend { speed: 40.0 }), EngineConfig::default());
        let hires = StreamSpec { sample_rate: 96_000, bits: 24, ..cd() };
        engine.send(Control::Play(load(1, cd(), 0.3)));
        engine.send(Control::SetNext(Some(load(2, hires, 0.3))));
        let events = collect_until_idle(&engine);
        let second = events.iter().find_map(|e| match e {
            EngineEvent::Started { item: 2, path } => Some(path.clone()),
            _ => None,
        });
        let path = second.expect("item 2 started");
        assert_eq!(path.stages[0].detail, "FLAC 24/96");
        assert_eq!(path.stages.last().unwrap().detail, "Nowhere · 96");
    }

    #[test]
    fn anchors_track_position_and_seeks() {
        let engine = Engine::spawn(Arc::new(NullBackend { speed: 20.0 }), EngineConfig::default());
        engine.send(Control::Play(load(7, cd(), 5.0)));
        thread::sleep(Duration::from_millis(30));
        engine.send(Control::Seek(44_100 * 4));
        let mut saw_after_seek = false;
        while let Ok(e) = engine.events().recv_timeout(Duration::from_secs(5)) {
            if let EngineEvent::Anchor(a) = e
                && a.item == 7
                && a.position_frames >= 44_100 * 4
            {
                saw_after_seek = true;
                break;
            }
        }
        assert!(saw_after_seek);
    }
}
