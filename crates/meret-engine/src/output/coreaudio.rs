//! CoreAudio HAL output for macOS.
//!
//! Opening a stream:
//! 1. Find the device (by UID, or the system default) and its first
//!    output stream.
//! 2. Exclusive: take hog mode, then set the stream's physical format to
//!    integer PCM at the source rate, at the source's bit depth or the
//!    smallest one above it. The HAL's mixer is out of the path. The IOProc
//!    still sees Float32, but a float holds 24-bit integers exactly, so 16-
//!    and 24-bit sources reach the DAC unchanged.
//!    Shared: set only the nominal rate. Other apps' audio mixes in.
//! 3. If the device can't run at the source rate, refuse. There's no
//!    resampler yet.
//! 4. Install an IOProc. It reads the ring (after honouring a pending flush),
//!    converts to the virtual format, and advances the clock with the time the
//!    last frame will reach the speaker (`mHostTime` of the output timestamp,
//!    plus device and stream latency).
//!
//! On close it stops the IOProc and puts back the original format and rate,
//! then releases hog mode.
//!
//! A listener on `kAudioDevicePropertyDeviceIsAlive` marks the stream lost
//! when its device goes away (a DAC unplugged, a display disconnected); the
//! engine then pauses where the device stopped. Default-device changes aren't
//! followed while a stream is open.

use std::ffi::c_void;
use std::ptr::{self, NonNull};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::thread;
use std::time::Duration;

use objc2_core_audio::{
    AudioDeviceCreateIOProcID, AudioDeviceDestroyIOProcID, AudioDeviceIOProcID, AudioDeviceStart, AudioDeviceStop,
    AudioObjectAddPropertyListener, AudioObjectGetPropertyData, AudioObjectGetPropertyDataSize, AudioObjectHasProperty, AudioObjectID,
    AudioObjectIsPropertySettable, AudioObjectPropertyAddress, AudioObjectPropertyScope, AudioObjectPropertySelector,
    AudioObjectRemovePropertyListener, AudioObjectSetPropertyData,
    AudioStreamRangedDescription, AudioConvertHostTimeToNanos, AudioGetCurrentHostTime,
    kAudioDevicePropertyAvailableNominalSampleRates, kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyDeviceUID,
    kAudioDevicePropertyHogMode, kAudioDevicePropertyLatency, kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyStreams,
    kAudioDevicePropertyMute, kAudioDevicePropertyVolumeScalar,
    kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices, kAudioObjectPropertyElementMain,
    kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyScopeOutput,
    kAudioObjectSystemObject, kAudioStreamPropertyAvailablePhysicalFormats, kAudioStreamPropertyLatency,
    kAudioStreamPropertyPhysicalFormat, kAudioStreamPropertyVirtualFormat,
};
use objc2_core_audio_types::{
    AudioBuffer, AudioBufferList, AudioStreamBasicDescription, AudioTimeStamp, AudioValueRange,
    kAudioFormatFlagIsBigEndian, kAudioFormatFlagIsFloat, kAudioFormatFlagIsNonInterleaved,
    kAudioFormatFlagIsSignedInteger, kAudioFormatLinearPCM,
};
use objc2_core_foundation::{CFRetained, CFString};

use super::{DeviceInfo, DeviceVolume, Opened, OutputBackend, OutputError, OutputRequest, OutputStream};
use crate::clock::{SharedClock, now_ns};
use crate::ring::RingReader;
use crate::Sample;

const SYSTEM: AudioObjectID = kAudioObjectSystemObject as AudioObjectID;
const GLOBAL: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal;
const OUTPUT: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput;
/// `kAudioTimeStampHostTimeValid`.
const HOST_TIME_VALID: u32 = 1 << 1;
/// The largest IOProc buffer handled in one pass; bigger ones loop.
const SCRATCH_FRAMES: usize = 8192;
/// Gain ramp at a discontinuity: start, resume, a flushed ring, an underrun,
/// and before a stop. Short enough to be inaudible as a fade, long enough
/// that a step edge mid-waveform no longer clicks.
const RAMP_MS: f64 = 8.0;
/// How long a pause waits for the ramp down before stopping the device.
const RAMP_WAIT: Duration = Duration::from_millis(60);
const STANDARD_RATES: [u32; 8] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000];

pub struct CoreAudioBackend;

impl OutputBackend for CoreAudioBackend {
    fn name(&self) -> &'static str {
        "coreaudio"
    }

    fn devices(&self) -> Result<Vec<DeviceInfo>, OutputError> {
        let ids: Vec<AudioObjectID> = get_vec(SYSTEM, kAudioHardwarePropertyDevices, GLOBAL).map_err(platform)?;
        let default: AudioObjectID = get(SYSTEM, kAudioHardwarePropertyDefaultOutputDevice, GLOBAL).map_err(platform)?;
        Ok(ids.into_iter().filter_map(|id| {
            let mut info = Device(id).info()?;
            info.is_default = id == default;
            Some(info)
        }).collect())
    }

    fn volume(&self, wanted: Option<&str>) -> Result<DeviceVolume, OutputError> {
        find_device(wanted)?.volume()
    }

    fn set_volume(&self, wanted: Option<&str>, scalar: f32) -> Result<DeviceVolume, OutputError> {
        let device = find_device(wanted)?;
        let elements = device.volume_elements();
        if elements.is_empty() {
            return Err(OutputError::Refused("this device has no settable hardware volume; use its DAC or amplifier".into()));
        }
        for element in elements {
            set_at(device.0, volume_address(element), &scalar).map_err(platform)?;
        }
        // Moving the volume unmutes, as the volume keys and Control Centre do.
        if device.muted() == Some(true) {
            device.set_muted(false)?;
        }
        device.volume()
    }

    fn set_mute(&self, wanted: Option<&str>, muted: bool) -> Result<DeviceVolume, OutputError> {
        let device = find_device(wanted)?;
        if device.muted().is_none() {
            return Err(OutputError::Refused("this device has no mute".into()));
        }
        device.set_muted(muted)?;
        device.volume()
    }

    fn open(
        &self,
        req: &OutputRequest,
        source: RingReader,
        clock: Arc<SharedClock>,
    ) -> Result<Box<dyn OutputStream>, OutputError> {
        let device = find_device(req.device.as_deref())?;
        Ok(Box::new(CoreAudioStream::open(device, req, source, clock)?))
    }
}

fn find_device(wanted: Option<&str>) -> Result<Device, OutputError> {
    let Some(wanted) = wanted else {
        let id: AudioObjectID = get(SYSTEM, kAudioHardwarePropertyDefaultOutputDevice, GLOBAL).map_err(platform)?;
        return Ok(Device(id));
    };
    let ids: Vec<AudioObjectID> = get_vec(SYSTEM, kAudioHardwarePropertyDevices, GLOBAL).map_err(platform)?;
    ids.into_iter()
        .map(Device)
        .find(|d| d.uid().as_deref() == Some(wanted))
        .ok_or_else(|| OutputError::NoDevice(wanted.into()))
}

#[derive(Clone, Copy)]
struct Device(AudioObjectID);

impl Device {
    fn name(self) -> Option<String> {
        get_string(self.0, kAudioObjectPropertyName)
    }

    fn uid(self) -> Option<String> {
        get_string(self.0, kAudioDevicePropertyDeviceUID)
    }

    fn output_streams(self) -> Vec<AudioObjectID> {
        get_vec(self.0, kAudioDevicePropertyStreams, OUTPUT).unwrap_or_default()
    }

    fn rate_ranges(self) -> Vec<AudioValueRange> {
        get_vec(self.0, kAudioDevicePropertyAvailableNominalSampleRates, GLOBAL).unwrap_or_default()
    }

    fn supports_rate(self, rate: u32) -> bool {
        let r = rate as f64;
        self.rate_ranges().iter().any(|v| v.mMinimum - 0.5 <= r && r <= v.mMaximum + 0.5)
    }

    fn nominal_rate(self) -> Result<f64, OutputError> {
        get(self.0, kAudioDevicePropertyNominalSampleRate, GLOBAL).map_err(platform)
    }

    fn hog_owner(self) -> Option<i32> {
        get(self.0, kAudioDevicePropertyHogMode, GLOBAL).ok()
    }


    fn volume_elements(self) -> Vec<u32> {
        let settable = |element| {
            let address = volume_address(element);
            let mut yes = 0u8;
            unsafe {
                AudioObjectHasProperty(self.0, NonNull::from(&address))
                    && AudioObjectIsPropertySettable(self.0, NonNull::from(&address), NonNull::from(&mut yes)) == 0
                    && yes != 0
            }
        };
        if settable(kAudioObjectPropertyElementMain) {
            return vec![kAudioObjectPropertyElementMain];
        }
        let channels: u32 = self.output_streams().into_iter().filter_map(|stream| {
            get::<AudioStreamBasicDescription>(stream, kAudioStreamPropertyVirtualFormat, GLOBAL).ok()
        }).map(|format| format.mChannelsPerFrame).sum();
        (1..=channels).filter(|&channel| settable(channel)).collect()
    }

    fn volume(self) -> Result<DeviceVolume, OutputError> {
        let elements = self.volume_elements();
        if elements.is_empty() {
            return Ok(DeviceVolume { device: self.uid(), ..DeviceVolume::unsupported("No volume control on this output") });
        }
        let mut scalar = 0.0f32;
        for &element in &elements {
            scalar += get_at::<f32>(self.0, volume_address(element)).map_err(platform)?;
        }
        Ok(DeviceVolume {
            device: self.uid(),
            scalar: Some(scalar / elements.len() as f32),
            settable: true,
            muted: self.muted(),
            reason: None,
        })
    }

    /// The main element's mute, when it can be set.
    fn muted(self) -> Option<bool> {
        let address = mute_address();
        let mut yes = 0u8;
        let settable = unsafe {
            AudioObjectHasProperty(self.0, NonNull::from(&address))
                && AudioObjectIsPropertySettable(self.0, NonNull::from(&address), NonNull::from(&mut yes)) == 0
                && yes != 0
        };
        if !settable {
            return None;
        }
        get_at::<u32>(self.0, address).ok().map(|muted| muted != 0)
    }

    fn set_muted(self, muted: bool) -> Result<(), OutputError> {
        set_at(self.0, mute_address(), &u32::from(muted)).map_err(platform)
    }

    fn info(self) -> Option<DeviceInfo> {
        let streams = self.output_streams();
        let first = *streams.first()?;
        let formats: Vec<AudioStreamRangedDescription> =
            get_vec(first, kAudioStreamPropertyAvailablePhysicalFormats, GLOBAL).unwrap_or_default();
        let mut sample_rates: Vec<u32> = STANDARD_RATES.into_iter().filter(|&r| self.supports_rate(r)).collect();
        sample_rates.dedup();
        Some(DeviceInfo {
            id: self.uid()?,
            name: self.name().unwrap_or_else(|| format!("Device {}", self.0)),
            is_default: false,
            sample_rates,
            max_bits: formats
                .iter()
                .map(|f| effective_bits(&f.mFormat))
                .max()
                .unwrap_or(0),
            can_be_exclusive: has(self.0, kAudioDevicePropertyHogMode, GLOBAL),
            dop: false,
        })
    }
}

/// How the IOProc lays out samples.
#[derive(Clone, Copy, Debug, PartialEq)]
enum Encoding {
    F32,
    I16,
    I24Packed,
    I32,
}

impl Encoding {
    fn bytes(self) -> usize {
        match self {
            Encoding::I16 => 2,
            Encoding::I24Packed => 3,
            Encoding::F32 | Encoding::I32 => 4,
        }
    }

    fn of(f: &AudioStreamBasicDescription) -> Option<Self> {
        if f.mFormatID != kAudioFormatLinearPCM || f.mFormatFlags & kAudioFormatFlagIsBigEndian != 0 {
            return None;
        }
        let per_channel = if f.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 {
            f.mBytesPerFrame
        } else {
            f.mBytesPerFrame / f.mChannelsPerFrame.max(1)
        };
        if f.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            return (f.mBitsPerChannel == 32).then_some(Encoding::F32);
        }
        if f.mFormatFlags & kAudioFormatFlagIsSignedInteger == 0 {
            return None;
        }
        match per_channel {
            2 => Some(Encoding::I16),
            3 => Some(Encoding::I24Packed),
            // 24-in-32 or 32: either way the top bits are the sample when aligned high.
            4 => Some(Encoding::I32),
            _ => None,
        }
    }

    /// Writes one left-justified sample at `dst`. Realtime-safe.
    #[inline]
    unsafe fn write(self, dst: *mut u8, s: Sample) {
        unsafe {
            match self {
                Encoding::F32 => (dst as *mut f32).write_unaligned(s as f32 * (1.0 / 2_147_483_648.0)),
                Encoding::I16 => (dst as *mut i16).write_unaligned((s >> 16) as i16),
                Encoding::I24Packed => {
                    let b = s.to_le_bytes();
                    ptr::copy_nonoverlapping(b[1..].as_ptr(), dst, 3);
                }
                Encoding::I32 => (dst as *mut i32).write_unaligned(s),
            }
        }
    }
}

/// The gain ramp, shared by the stream (engine thread) and the IOProc.
/// `gain` is the ramp's position as f32 bits; the IOProc owns it while the
/// device runs, the stream resets it to zero while the device is stopped.
struct Fade {
    gain: AtomicU32,
    /// The stream asks for a ramp down; the IOProc reports silence reached.
    out: AtomicBool,
    silent: AtomicBool,
}

impl Fade {
    fn new() -> Arc<Self> {
        Arc::new(Self { gain: AtomicU32::new(0f32.to_bits()), out: AtomicBool::new(false), silent: AtomicBool::new(false) })
    }
}

/// Everything the IOProc touches. Owned by the stream and only ever used by
/// the IOProc while the device runs.
struct IoState {
    reader: RingReader,
    clock: Arc<SharedClock>,
    fade: Arc<Fade>,
    /// Gain change per output frame while ramping.
    step: f32,
    scratch: Vec<Sample>,
    src_channels: usize,
    encoding: Encoding,
    interleaved: bool,
    /// Channels in the device's first output stream.
    channels: usize,
    rate: f64,
    latency_frames: u32,
}

impl IoState {
    /// Which source channel feeds device channel `c`. Mono goes to the first two.
    #[inline]
    fn source_for(&self, c: usize) -> Option<usize> {
        if self.src_channels == 1 {
            (c < 2).then_some(0)
        } else {
            (c < self.src_channels).then_some(c)
        }
    }
}

/// `s` at `gain`, exact at 1.0.
#[inline]
fn scaled(s: Sample, gain: f32) -> Sample {
    if gain >= 1.0 { s } else { (s as f64 * gain as f64) as Sample }
}

unsafe extern "C-unwind" fn io_proc(
    _device: AudioObjectID,
    _now: NonNull<AudioTimeStamp>,
    _input: NonNull<AudioBufferList>,
    _input_time: NonNull<AudioTimeStamp>,
    output: NonNull<AudioBufferList>,
    output_time: NonNull<AudioTimeStamp>,
    client: *mut c_void,
) -> i32 {
    // SAFETY: `client` is the `IoState` the stream boxed for this IOProc, and
    // the HAL calls it from one thread at a time.
    let st = unsafe { &mut *(client as *mut IoState) };
    let list = output.as_ptr();
    let buffers: &mut [AudioBuffer] = unsafe {
        let n = (*list).mNumberBuffers as usize;
        std::slice::from_raw_parts_mut((&raw mut (*list).mBuffers).cast::<AudioBuffer>(), n)
    };
    for b in buffers.iter_mut() {
        if !b.mData.is_null() {
            unsafe { ptr::write_bytes(b.mData as *mut u8, 0, b.mDataByteSize as usize) };
        }
    }
    let mut gain = f32::from_bits(st.fade.gain.load(Ordering::Relaxed));
    if let Some(generation) = st.clock.flush_pending() {
        st.reader.clear();
        st.clock.ack_flush(generation);
        // Whatever comes next starts mid-waveform.
        gain = 0.0;
    }
    let Some(first) = buffers.first() else { return 0 };
    if first.mData.is_null() {
        return 0;
    }
    let bytes = st.encoding.bytes();
    let frames = if st.interleaved {
        first.mDataByteSize as usize / (bytes * st.channels)
    } else {
        first.mDataByteSize as usize / bytes
    };
    let planes = if st.interleaved { 1 } else { st.channels.min(buffers.len()) };
    let out = st.fade.out.load(Ordering::Acquire);
    if out && gain <= 0.0 {
        // Ramped down: leave the ring alone so a resume continues from here.
        st.fade.silent.store(true, Ordering::Release);
        st.fade.gain.store(gain.to_bits(), Ordering::Relaxed);
        return 0;
    }

    let mut done = 0;
    while done < frames {
        let mut chunk = (frames - done).min(SCRATCH_FRAMES);
        if out {
            // Only what the ramp needs; the rest of the ring waits for the resume.
            chunk = chunk.min(((gain / st.step).ceil() as usize).max(1));
        }
        let n = chunk * st.src_channels;
        let got = st.reader.read(&mut st.scratch[..n]);
        for f in 0..got {
            let src = &st.scratch[f * st.src_channels..(f + 1) * st.src_channels];
            for c in 0..st.channels {
                let Some(sc) = st.source_for(c) else { continue };
                let frame = done + f;
                let dst = if st.interleaved {
                    unsafe { (buffers[0].mData as *mut u8).add((frame * st.channels + c) * bytes) }
                } else if c < planes {
                    unsafe { (buffers[c].mData as *mut u8).add(frame * bytes) }
                } else {
                    continue;
                };
                unsafe { st.encoding.write(dst, scaled(src[sc], gain)) };
            }
            if out {
                gain = (gain - st.step).max(0.0);
            } else if gain < 1.0 {
                gain = (gain + st.step).min(1.0);
            }
        }
        done += got;
        if out && gain <= 0.0 {
            break;
        }
        if got < chunk {
            st.clock.underrun();
            // The next samples, whenever they come, start mid-waveform.
            gain = 0.0;
            break;
        }
    }
    st.fade.gain.store(gain.to_bits(), Ordering::Relaxed);

    // When the last frame handed over reaches the speaker, on now_ns()'s clock.
    let ts = unsafe { output_time.as_ref() };
    let mut at = now_ns() as i64;
    if ts.mFlags.0 & HOST_TIME_VALID != 0 {
        let (out_ns, host_now) =
            unsafe { (AudioConvertHostTimeToNanos(ts.mHostTime), AudioConvertHostTimeToNanos(AudioGetCurrentHostTime())) };
        at += out_ns as i64 - host_now as i64;
    }
    at += ((done as u64 + st.latency_frames as u64) as f64 / st.rate * 1e9) as i64;
    st.clock.advance(done as u64, at.max(0) as u64);
    0
}

/// Marks the stream lost when its device stops being alive. Runs on a HAL
/// notification thread, never the IOProc's.
unsafe extern "C-unwind" fn alive_changed(
    device: AudioObjectID,
    _count: u32,
    _addresses: NonNull<AudioObjectPropertyAddress>,
    client: *mut c_void,
) -> i32 {
    // SAFETY: `client` is the stream's `alive` flag, which the stream keeps
    // until after it removes this listener.
    let alive = unsafe { &*(client as *const AtomicBool) };
    if !get::<u32>(device, kAudioDevicePropertyDeviceIsAlive, GLOBAL).is_ok_and(|v| v != 0) {
        tracing::warn!(device, "output device is gone");
        alive.store(false, Ordering::Release);
    }
    0
}

/// What the device was doing before we changed it.
struct Restore {
    stream: AudioObjectID,
    physical: Option<AudioStreamBasicDescription>,
    rate: f64,
    hogged: bool,
}

pub struct CoreAudioStream {
    device: Device,
    proc_id: AudioDeviceIOProcID,
    state: *mut IoState,
    fade: Arc<Fade>,
    opened: Opened,
    restore: Restore,
    running: bool,
    /// Cleared by `alive_changed` when the device goes away.
    alive: Arc<AtomicBool>,
    listening: bool,
}

// SAFETY: `state` is only dereferenced by the IOProc; the stream just owns it
// and frees it after the IOProc is destroyed.
unsafe impl Send for CoreAudioStream {}

impl CoreAudioStream {
    fn open(
        device: Device,
        req: &OutputRequest,
        reader: RingReader,
        clock: Arc<SharedClock>,
    ) -> Result<Self, OutputError> {
        let name = device.name().unwrap_or_else(|| "Output".into());
        let uid = device.uid().unwrap_or_default();
        let default_before = find_device(None).ok().and_then(Device::uid);
        tracing::info!(device_uid = %uid, device_name = %name, ?default_before, exclusive = req.exclusive, "opening output");
        let stream = *device.output_streams().first().ok_or_else(|| OutputError::NoDevice(name.clone()))?;
        let rate = req.spec.sample_rate;
        if !device.supports_rate(rate) {
            return Err(OutputError::Refused(format!("{} kHz on {name} (no resampler yet)", rate as f64 / 1000.0)));
        }
        // Make sure the clock's epoch exists before the IOProc reads it.
        let _ = now_ns();

        let mut restore = Restore {
            stream,
            physical: get(stream, kAudioStreamPropertyPhysicalFormat, GLOBAL).ok(),
            rate: device.nominal_rate()?,
            hogged: false,
        };

        let pid = std::process::id() as i32;
        if req.exclusive && has(device.0, kAudioDevicePropertyHogMode, GLOBAL) {
            match device.hog_owner() {
                Some(owner) if owner == pid => restore.hogged = true,
                Some(-1) => {
                    // Setting our pid while it's free takes it.
                    restore.hogged = set(device.0, kAudioDevicePropertyHogMode, GLOBAL, &pid).is_ok()
                        && device.hog_owner() == Some(pid);
                }
                _ => tracing::warn!(device = %name, "another process has the device; playing shared"),
            }
        }
        let default_after = find_device(None).ok().and_then(Device::uid);
        tracing::info!(device_uid = %uid, ?default_before, ?default_after, hogged = restore.hogged, "output hog resolved");

        // From here on, failures must undo what was changed.
        let mut this = Self {
            device,
            proc_id: None,
            state: ptr::null_mut(),
            fade: Fade::new(),
            opened: Opened {
                device_uid: uid,
                device_name: name,
                sample_rate: rate,
                bits: 0,
                channels: req.spec.channels,
                exclusive: restore.hogged,
                latency_frames: 0,
            },
            restore,
            running: false,
            alive: Arc::new(AtomicBool::new(true)),
            listening: false,
        };
        this.listen();
        this.configure(req)?;
        this.install(reader, clock)?;
        Ok(this)
    }

    fn listen(&mut self) {
        let address = address(kAudioDevicePropertyDeviceIsAlive, GLOBAL);
        let status = unsafe {
            AudioObjectAddPropertyListener(self.device.0, NonNull::from(&address), Some(alive_changed),
                Arc::as_ptr(&self.alive) as *mut c_void)
        };
        self.listening = status == 0;
        if !self.listening {
            tracing::warn!(status = %fourcc(status), "can't watch the output for removal");
        }
    }

    /// Sets the rate (and in exclusive mode the physical format) and waits for
    /// the device to settle on them.
    fn configure(&mut self, req: &OutputRequest) -> Result<(), OutputError> {
        let rate = req.spec.sample_rate as f64;
        let stream = self.restore.stream;
        if self.restore.hogged {
            let formats: Vec<AudioStreamRangedDescription> =
                get_vec(stream, kAudioStreamPropertyAvailablePhysicalFormats, GLOBAL).unwrap_or_default();
            if let Some(mut f) = pick_physical(&formats, rate, req.spec.bits) {
                f.mSampleRate = rate;
                // Setting a format the device already runs still makes some
                // DACs reconfigure, audibly.
                if self.restore.physical.is_none_or(|p| !same_format(&p, &f))
                    && let Err(s) = set(stream, kAudioStreamPropertyPhysicalFormat, GLOBAL, &f)
                {
                    tracing::warn!(status = %fourcc(s), "physical format refused");
                }
            }
        }
        if (self.device.nominal_rate()? - rate).abs() > 0.5 {
            set(self.device.0, kAudioDevicePropertyNominalSampleRate, GLOBAL, &rate)
                .map_err(|s| OutputError::Refused(format!("{rate} Hz ({})", fourcc(s))))?;
        }
        // Rate changes land asynchronously.
        for _ in 0..100 {
            if (self.device.nominal_rate()? - rate).abs() < 0.5 {
                break;
            }
            thread::sleep(Duration::from_millis(10));
        }
        if (self.device.nominal_rate()? - rate).abs() > 0.5 {
            return Err(OutputError::Refused(format!("{rate} Hz: the device didn't switch")));
        }
        let physical: Option<AudioStreamBasicDescription> = get(stream, kAudioStreamPropertyPhysicalFormat, GLOBAL).ok();
        self.opened.bits = physical.as_ref().map(effective_bits).unwrap_or(24);
        tracing::info!(device_uid = ?self.device.uid(), source_bits = req.spec.bits, physical_bits = self.opened.bits, sample_rate = req.spec.sample_rate, exclusive = self.opened.exclusive, "output format configured");
        Ok(())
    }

    fn install(&mut self, reader: RingReader, clock: Arc<SharedClock>) -> Result<(), OutputError> {
        let stream = self.restore.stream;
        let virt: AudioStreamBasicDescription = get(stream, kAudioStreamPropertyVirtualFormat, GLOBAL).map_err(platform)?;
        let encoding = Encoding::of(&virt)
            .ok_or_else(|| OutputError::Refused(format!("virtual format {:?}", virt)))?;
        let device_latency: u32 = get(self.device.0, kAudioDevicePropertyLatency, OUTPUT).unwrap_or(0);
        let stream_latency: u32 = get(stream, kAudioStreamPropertyLatency, GLOBAL).unwrap_or(0);
        self.opened.latency_frames = device_latency + stream_latency;

        let src_channels = reader.channels();
        let state = Box::new(IoState {
            reader,
            clock,
            fade: self.fade.clone(),
            step: (1000.0 / (virt.mSampleRate.max(1.0) * RAMP_MS)) as f32,
            scratch: vec![0; SCRATCH_FRAMES * src_channels],
            src_channels,
            encoding,
            interleaved: virt.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
            channels: virt.mChannelsPerFrame.max(1) as usize,
            rate: virt.mSampleRate,
            latency_frames: self.opened.latency_frames,
        });
        self.state = Box::into_raw(state);
        let mut id: AudioDeviceIOProcID = None;
        let status = unsafe {
            AudioDeviceCreateIOProcID(self.device.0, Some(io_proc), self.state.cast(), NonNull::from(&mut id))
        };
        if status != 0 {
            return Err(platform(status));
        }
        self.proc_id = id;
        Ok(())
    }
}

/// Bits of integer PCM a format carries unchanged. Built-in Apple Silicon
/// outputs are Float32 only; a 32-bit float holds a 24-bit integer exactly.
fn effective_bits(f: &AudioStreamBasicDescription) -> u8 {
    if f.mFormatID != kAudioFormatLinearPCM {
        0
    } else if f.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
        if f.mBitsPerChannel >= 64 { 32 } else { 24 }
    } else {
        f.mBitsPerChannel as u8
    }
}

/// The integer format at `rate` closest to `bits` without going under, or the
/// deepest one if none reach it.
fn pick_physical(formats: &[AudioStreamRangedDescription], rate: f64, bits: u8) -> Option<AudioStreamBasicDescription> {
    let usable: Vec<AudioStreamBasicDescription> = formats
        .iter()
        .filter(|f| f.mSampleRateRange.mMinimum - 0.5 <= rate && rate <= f.mSampleRateRange.mMaximum + 0.5)
        .map(|f| f.mFormat)
        .filter(|f| {
            f.mFormatID == kAudioFormatLinearPCM
                && f.mFormatFlags & kAudioFormatFlagIsFloat == 0
                && f.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
        })
        .collect();
    let bits = bits as u32;
    usable
        .iter()
        .filter(|f| f.mBitsPerChannel >= bits)
        .min_by_key(|f| (f.mBitsPerChannel, f.mBytesPerFrame))
        .or_else(|| usable.iter().max_by_key(|f| f.mBitsPerChannel))
        .copied()
}

/// The fields a physical format is chosen by; `mReserved` and packet layout
/// follow from them.
fn same_format(a: &AudioStreamBasicDescription, b: &AudioStreamBasicDescription) -> bool {
    (a.mSampleRate - b.mSampleRate).abs() < 0.5
        && a.mFormatID == b.mFormatID
        && a.mFormatFlags == b.mFormatFlags
        && a.mBitsPerChannel == b.mBitsPerChannel
        && a.mBytesPerFrame == b.mBytesPerFrame
        && a.mChannelsPerFrame == b.mChannelsPerFrame
}

impl OutputStream for CoreAudioStream {
    fn opened(&self) -> &Opened {
        &self.opened
    }

    fn start(&mut self) -> Result<(), OutputError> {
        if !self.running {
            // The IOProc is stopped, so nothing else touches the fade now.
            self.fade.gain.store(0f32.to_bits(), Ordering::Relaxed);
            self.fade.silent.store(false, Ordering::Relaxed);
            self.fade.out.store(false, Ordering::Release);
            let status = unsafe { AudioDeviceStart(self.device.0, self.proc_id) };
            if status != 0 {
                return Err(platform(status));
            }
            self.running = true;
        }
        Ok(())
    }

    fn pause(&mut self) -> Result<(), OutputError> {
        if self.running && self.lost() {
            // Nothing is calling the IOProc any more, and the device can't be stopped.
            self.running = false;
        }
        if self.running {
            // Let the IOProc ramp down first; a stalled device is not waited on.
            self.fade.out.store(true, Ordering::Release);
            let deadline = std::time::Instant::now() + RAMP_WAIT;
            while !self.fade.silent.load(Ordering::Acquire) && std::time::Instant::now() < deadline {
                thread::sleep(Duration::from_millis(1));
            }
            // Synchronous: when this returns the IOProc has stopped.
            let status = unsafe { AudioDeviceStop(self.device.0, self.proc_id) };
            if status != 0 {
                return Err(platform(status));
            }
            self.running = false;
        }
        Ok(())
    }

    fn lost(&self) -> bool {
        !self.alive.load(Ordering::Acquire)
    }

    fn into_source(mut self: Box<Self>) -> RingReader {
        let _ = self.pause();
        if self.proc_id.is_some() {
            unsafe { AudioDeviceDestroyIOProcID(self.device.0, self.proc_id) };
            self.proc_id = None;
        }
        // The callback is stopped and destroyed; only this thread owns state.
        let state = unsafe { Box::from_raw(self.state) };
        self.state = ptr::null_mut();
        state.reader
    }
}

impl Drop for CoreAudioStream {
    fn drop(&mut self) {
        tracing::info!(device_uid = ?self.device.uid(), system_default_uid = ?find_device(None).ok().and_then(Device::uid), hogged = self.restore.hogged, lost = self.lost(), "closing output");
        if self.listening {
            let address = address(kAudioDevicePropertyDeviceIsAlive, GLOBAL);
            unsafe {
                AudioObjectRemovePropertyListener(self.device.0, NonNull::from(&address), Some(alive_changed),
                    Arc::as_ptr(&self.alive) as *mut c_void)
            };
        }
        let _ = self.pause();
        if self.proc_id.is_some() {
            unsafe { AudioDeviceDestroyIOProcID(self.device.0, self.proc_id) };
        }
        if !self.state.is_null() {
            drop(unsafe { Box::from_raw(self.state) });
        }
        let r = &self.restore;
        if r.hogged
            && let Some(p) = &r.physical
            && get::<AudioStreamBasicDescription>(r.stream, kAudioStreamPropertyPhysicalFormat, GLOBAL).is_ok_and(|now| !same_format(&now, p))
        {
            let _ = set(r.stream, kAudioStreamPropertyPhysicalFormat, GLOBAL, p);
        }
        if self.device.nominal_rate().is_ok_and(|now| (now - r.rate).abs() > 0.5) {
            let _ = set(self.device.0, kAudioDevicePropertyNominalSampleRate, GLOBAL, &r.rate);
        }
        if r.hogged {
            let free: i32 = -1;
            let _ = set(self.device.0, kAudioDevicePropertyHogMode, GLOBAL, &free);
        }
    }
}

// Property plumbing.

fn address(selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress { mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain }
}

fn has(object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) -> bool {
    let a = address(selector, scope);
    unsafe { AudioObjectHasProperty(object, NonNull::from(&a)) }
}

fn volume_address(element: u32) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress { mSelector: kAudioDevicePropertyVolumeScalar, mScope: OUTPUT, mElement: element }
}

fn mute_address() -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress { mSelector: kAudioDevicePropertyMute, mScope: OUTPUT, mElement: kAudioObjectPropertyElementMain }
}

fn get<T: Copy>(object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) -> Result<T, i32> {
    get_at(object, address(selector, scope))
}

fn get_at<T: Copy>(object: AudioObjectID, a: AudioObjectPropertyAddress) -> Result<T, i32> {
    let mut value = std::mem::MaybeUninit::<T>::zeroed();
    let mut size = size_of::<T>() as u32;
    let status = unsafe {
        AudioObjectGetPropertyData(object, NonNull::from(&a), 0, ptr::null(), NonNull::from(&mut size), NonNull::from(&mut value).cast())
    };
    if status != 0 {
        return Err(status);
    }
    // SAFETY: the HAL filled `size` bytes of a zeroed plain-data struct.
    Ok(unsafe { value.assume_init() })
}

fn get_vec<T: Copy>(object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) -> Result<Vec<T>, i32> {
    let a = address(selector, scope);
    let mut size = 0u32;
    let status = unsafe { AudioObjectGetPropertyDataSize(object, NonNull::from(&a), 0, ptr::null(), NonNull::from(&mut size)) };
    if status != 0 {
        return Err(status);
    }
    let n = size as usize / size_of::<T>();
    let mut out: Vec<T> = Vec::with_capacity(n);
    if n == 0 {
        return Ok(out);
    }
    let status = unsafe {
        AudioObjectGetPropertyData(object, NonNull::from(&a), 0, ptr::null(), NonNull::from(&mut size), NonNull::new_unchecked(out.as_mut_ptr().cast()))
    };
    if status != 0 {
        return Err(status);
    }
    // SAFETY: the HAL wrote `size` bytes of plain data.
    unsafe { out.set_len((size as usize / size_of::<T>()).min(n)) };
    Ok(out)
}

fn set<T>(object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope, value: &T) -> Result<(), i32> {
    set_at(object, address(selector, scope), value)
}

fn set_at<T>(object: AudioObjectID, a: AudioObjectPropertyAddress, value: &T) -> Result<(), i32> {
    let status = unsafe {
        AudioObjectSetPropertyData(object, NonNull::from(&a), 0, ptr::null(), size_of::<T>() as u32, NonNull::from(value).cast())
    };
    if status == 0 { Ok(()) } else { Err(status) }
}

fn get_string(object: AudioObjectID, selector: AudioObjectPropertySelector) -> Option<String> {
    let raw: *const CFString = get(object, selector, GLOBAL).ok()?;
    // SAFETY: these properties return a +1 CFString the caller releases.
    let s = unsafe { CFRetained::from_raw(NonNull::new(raw as *mut CFString)?) };
    Some(s.to_string())
}

/// HAL statuses are usually four-character codes ('!dev', 'nope').
fn fourcc(status: i32) -> String {
    let b = status.to_be_bytes();
    if b.iter().all(|c| c.is_ascii_graphic() || *c == b' ') {
        format!("'{}'", String::from_utf8_lossy(&b))
    } else {
        status.to_string()
    }
}

fn platform(status: i32) -> OutputError {
    OutputError::Platform(format!("CoreAudio status {}", fourcc(status)))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lpcm(bits: u32, bytes: u32, float: bool, lo: f64, hi: f64) -> AudioStreamRangedDescription {
        AudioStreamRangedDescription {
            mFormat: AudioStreamBasicDescription {
                mSampleRate: 0.0,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: if float { kAudioFormatFlagIsFloat } else { kAudioFormatFlagIsSignedInteger },
                mBytesPerPacket: bytes * 2,
                mFramesPerPacket: 1,
                mBytesPerFrame: bytes * 2,
                mChannelsPerFrame: 2,
                mBitsPerChannel: bits,
                mReserved: 0,
            },
            mSampleRateRange: AudioValueRange { mMinimum: lo, mMaximum: hi },
        }
    }

    #[test]
    fn picks_the_shallowest_integer_format_that_holds_the_source() {
        let formats =
            [lpcm(32, 4, true, 44_100.0, 192_000.0), lpcm(16, 2, false, 44_100.0, 96_000.0), lpcm(24, 4, false, 44_100.0, 192_000.0)];
        assert_eq!(pick_physical(&formats, 44_100.0, 16).unwrap().mBitsPerChannel, 16);
        assert_eq!(pick_physical(&formats, 96_000.0, 24).unwrap().mBitsPerChannel, 24);
        // 16-bit isn't offered at 192k, so a 16-bit source rides in 24.
        assert_eq!(pick_physical(&formats, 192_000.0, 16).unwrap().mBitsPerChannel, 24);
        // Nothing integer at 384k.
        assert!(pick_physical(&formats, 384_000.0, 16).is_none());
    }

    #[test]
    fn float_holds_24_bit_samples_exactly() {
        let mut out = [0f32; 1];
        for s in [0x7FFF_FF00, i32::MIN, 0x0000_0100, -0x0000_0100, 0x1234_5600] {
            unsafe { Encoding::F32.write(out.as_mut_ptr().cast(), s) };
            assert_eq!((out[0] as f64 * 2_147_483_648.0) as i64, s as i64);
        }
    }

    #[test]
    fn packs_24_bit_little_endian() {
        let mut out = [0u8; 3];
        unsafe { Encoding::I24Packed.write(out.as_mut_ptr(), 0x1234_5600) };
        assert_eq!(out, [0x56, 0x34, 0x12]);
    }

    /// Touches real hardware; run with `cargo test -p meret-engine -- --ignored devices`.
    #[test]
    #[ignore]
    fn lists_devices() {
        let devices = CoreAudioBackend.devices().unwrap();
        for d in &devices {
            println!("{} · {:?} · {} bit · exclusive {}", d.name, d.sample_rates, d.max_bits, d.can_be_exclusive);
            let dev = find_device(Some(&d.id)).unwrap();
            for stream in dev.output_streams() {
                let formats: Vec<AudioStreamRangedDescription> =
                    get_vec(stream, kAudioStreamPropertyAvailablePhysicalFormats, GLOBAL).unwrap_or_default();
                for f in formats {
                    let m = f.mFormat;
                    println!(
                        "  physical {}–{} Hz · {} ch · {} bit in {} bytes · flags {:#x}",
                        f.mSampleRateRange.mMinimum, f.mSampleRateRange.mMaximum, m.mChannelsPerFrame,
                        m.mBitsPerChannel, m.mBytesPerFrame, m.mFormatFlags
                    );
                }
            }
        }
        assert!(!devices.is_empty());
    }

    /// Unplugs a device under a playing engine: a private aggregate of the
    /// system default output plays silence, shared, until it's destroyed.
    /// Touches real hardware; run with
    /// `cargo test -p meret-engine -- --ignored unplugged --nocapture`.
    #[test]
    #[ignore]
    fn an_unplugged_device_pauses_playback_and_resume_moves_to_the_default() {
        use crate::decode::Tone;
        use crate::engine::{Control, Engine, EngineConfig, EngineEvent, Load};
        use meret_model::audio::{Codec, StreamSpec};
        use objc2_core_audio::{
            AudioHardwareCreateAggregateDevice, AudioHardwareDestroyAggregateDevice, kAudioAggregateDeviceIsPrivateKey,
            kAudioAggregateDeviceMainSubDeviceKey, kAudioAggregateDeviceNameKey, kAudioAggregateDeviceSubDeviceListKey,
            kAudioAggregateDeviceUIDKey, kAudioSubDeviceUIDKey,
        };
        use objc2_core_foundation::{CFArray, CFDictionary, CFNumber, CFType};
        use std::time::Instant;

        fn cf(value: &CFType) -> &CFType { value }
        let key = |k: &std::ffi::CStr| CFString::from_str(k.to_str().unwrap());
        let wait = |what: &str, ready: &mut dyn FnMut() -> bool| {
            let deadline = Instant::now() + Duration::from_secs(5);
            while !ready() {
                assert!(Instant::now() < deadline, "timed out waiting for {what}");
                thread::sleep(Duration::from_millis(10));
            }
        };

        let default = find_device(None).unwrap();
        let (default_uid, default_name) = (default.uid().unwrap(), default.name().unwrap());
        let rate = default.nominal_rate().unwrap() as u32;
        let aggregate_uid = format!("io.sowilo.meret.test-unplug-{}", std::process::id());
        let (uid, name, private, sub_uid) = (CFString::from_str(&aggregate_uid), CFString::from_static_str("Meret unplug test"),
            CFNumber::new_i32(1), CFString::from_str(&default_uid));
        let sub_key = key(kAudioSubDeviceUIDKey);
        let sub = CFDictionary::<CFString, CFType>::from_slices(&[&sub_key], &[cf(&sub_uid)]);
        let subs = CFArray::from_objects(&[&*sub]);
        let keys = [key(kAudioAggregateDeviceUIDKey), key(kAudioAggregateDeviceNameKey), key(kAudioAggregateDeviceIsPrivateKey),
            key(kAudioAggregateDeviceSubDeviceListKey), key(kAudioAggregateDeviceMainSubDeviceKey)];
        let description = CFDictionary::<CFString, CFType>::from_slices(
            &[&keys[0], &keys[1], &keys[2], &keys[3], &keys[4]],
            &[cf(&uid), cf(&name), cf(&private), cf(&subs), cf(&sub_uid)],
        );
        let mut id: AudioObjectID = 0;
        let status = unsafe { AudioHardwareCreateAggregateDevice(description.as_opaque(), NonNull::from(&mut id)) };
        assert_eq!(status, 0, "create aggregate: {}", fourcc(status));
        wait("the aggregate to appear", &mut || find_device(Some(&aggregate_uid)).is_ok());

        let engine = Engine::spawn(Arc::new(CoreAudioBackend),
            EngineConfig { device: Some(aggregate_uid.clone()), exclusive: false, ..Default::default() });
        let spec = StreamSpec { sample_rate: rate, channels: 2, bits: 16, codec: Codec::Flac };
        engine.send(Control::Play(Load { item: 1, decoder: Box::new(Tone::new(spec, 60.0, 0.0)), start_frame: 0, gain_db: 0.0, stages: vec![] }));
        let next = |what: &str, wanted: &dyn Fn(&EngineEvent) -> bool| -> EngineEvent {
            let deadline = Instant::now() + Duration::from_secs(5);
            loop {
                let left = deadline.saturating_duration_since(Instant::now());
                let event = engine.events().recv_timeout(left).unwrap_or_else(|_| panic!("timed out waiting for {what}"));
                println!("{event:?}");
                if wanted(&event) {
                    return event;
                }
            }
        };
        let EngineEvent::Started { path, .. } = next("start", &|e| matches!(e, EngineEvent::Started { item: 1, .. })) else { unreachable!() };
        assert!(path.stages.last().unwrap().detail.starts_with("Meret unplug test"));
        thread::sleep(Duration::from_millis(500));

        let unplugged = Instant::now();
        assert_eq!(unsafe { AudioHardwareDestroyAggregateDevice(id) }, 0);
        next("the disconnect", &|e| matches!(e, EngineEvent::Error { item: Some(1), message } if message == "Meret unplug test disconnected"));
        let EngineEvent::Anchor(paused) = next("a paused anchor", &|e| matches!(e, EngineEvent::Anchor(a) if a.rate == 0.0)) else { unreachable!() };
        println!("paused {:?} after the unplug at {} ms", unplugged.elapsed(), paused.position_frames * 1000 / rate as u64);
        assert!(paused.position_frames >= rate as u64 / 4, "played before the unplug");

        engine.send(Control::Resume);
        let EngineEvent::OutputChanged { path } = next("the move to the default", &|e| matches!(e, EngineEvent::OutputChanged { .. })) else { unreachable!() };
        assert!(path.stages.last().unwrap().detail.starts_with(&default_name), "{path:?}");
        let EngineEvent::Anchor(resumed) = next("playback on the default",
            &|e| matches!(e, EngineEvent::Anchor(a) if a.rate > 0.0)) else { unreachable!() };
        assert!(resumed.position_frames >= paused.position_frames, "resumed where it stopped");
        engine.send(Control::Stop);
        next("idle", &|e| matches!(e, EngineEvent::Idle));
    }
}
