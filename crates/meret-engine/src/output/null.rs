//! An output that plays to nowhere at real-time pace (or faster), for tests,
//! CI, and measuring the decode side without a device.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use super::{DeviceInfo, Opened, OutputBackend, OutputError, OutputRequest, OutputStream};
use crate::clock::{SharedClock, now_ns};
use crate::ring::RingReader;

pub struct NullBackend {
    /// 1.0 is real time; tests use 50.0 or more.
    pub speed: f64,
}

impl OutputBackend for NullBackend {
    fn name(&self) -> &'static str {
        "null"
    }

    fn devices(&self) -> Result<Vec<DeviceInfo>, OutputError> {
        Ok(vec![DeviceInfo {
            id: "null".into(),
            name: "Nowhere".into(),
            sample_rates: vec![44_100, 48_000, 88_200, 96_000, 176_400, 192_000],
            max_bits: 32,
            can_be_exclusive: true,
            dop: true,
        }])
    }

    fn open(
        &self,
        req: &OutputRequest,
        mut source: RingReader,
        clock: Arc<SharedClock>,
    ) -> Result<Box<dyn OutputStream>, OutputError> {
        let opened = Opened {
            device_name: "Nowhere".into(),
            sample_rate: req.spec.sample_rate,
            bits: req.spec.bits,
            channels: req.spec.channels,
            exclusive: req.exclusive,
            latency_frames: 0,
        };
        let running = Arc::new(AtomicBool::new(false));
        let alive = Arc::new(AtomicBool::new(true));
        let period_frames = 512usize;
        let period = Duration::from_secs_f64(period_frames as f64 / req.spec.sample_rate as f64 / self.speed);

        let (r, a) = (running.clone(), alive.clone());
        let handle = thread::Builder::new()
            .name("meret-null-out".into())
            .spawn(move || {
                // Stands in for the device callback: same rules, no allocation in the loop.
                // Paced against absolute deadlines, as a device clock is, so
                // sleep overshoot doesn't accumulate into drift.
                let mut buf = vec![0i32; period_frames * source.channels()];
                let mut deadline = Instant::now();
                while a.load(Ordering::Acquire) {
                    if let Some(generation) = clock.flush_pending() {
                        source.clear();
                        clock.ack_flush(generation);
                    }
                    if r.load(Ordering::Acquire) {
                        let got = source.read(&mut buf);
                        if got < period_frames {
                            clock.underrun();
                        }
                        clock.advance(got as u64, now_ns());
                    }
                    deadline += period;
                    let now = Instant::now();
                    if deadline > now {
                        thread::sleep(deadline - now);
                    } else if now - deadline > period * 8 {
                        // Fell far behind (paused, or the machine slept): don't burst to catch up.
                        deadline = now;
                    }
                }
            })
            .map_err(|e| OutputError::Platform(e.to_string()))?;

        Ok(Box::new(NullStream { opened, running, alive, handle: Some(handle) }))
    }
}

struct NullStream {
    opened: Opened,
    running: Arc<AtomicBool>,
    alive: Arc<AtomicBool>,
    handle: Option<JoinHandle<()>>,
}

impl OutputStream for NullStream {
    fn opened(&self) -> &Opened {
        &self.opened
    }

    fn start(&mut self) -> Result<(), OutputError> {
        self.running.store(true, Ordering::Release);
        Ok(())
    }

    fn pause(&mut self) -> Result<(), OutputError> {
        self.running.store(false, Ordering::Release);
        Ok(())
    }
}

impl Drop for NullStream {
    fn drop(&mut self) {
        self.alive.store(false, Ordering::Release);
        if let Some(h) = self.handle.take() {
            let _ = h.join();
        }
    }
}
