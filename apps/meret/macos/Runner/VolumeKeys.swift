import ApplicationServices
import Cocoa
import CoreAudio

/// The volume keys change macOS's default output. While Meret holds a
/// device in hog mode, macOS moves its default output to another device
/// and ignores any attempt to move it back, so the keys would change
/// speakers nobody is listening to. While Meret plays on a device other
/// than the default, it takes the keys for that device instead.
///
/// Taking them needs an event tap, and an event tap needs Accessibility
/// access. Until Meret has it, a listen-only monitor waits for the first
/// volume key that goes astray, and only then does macOS ask.
final class VolumeKeys {
  enum Key: String { case up, down, mute }

  /// A press: the key, and whether ⌥⇧ asks for a quarter step.
  var onKey: (Key, Bool) -> Void = { _, _ in }

  private var device: String?
  private var mute = false
  private var playing = false
  private var tap: CFMachPort?
  private var monitor: Any?
  private var asked = false

  /// The device Meret plays on, when its volume can be set, and whether it
  /// has a mute.
  func target(device: String?, mute: Bool) {
    self.device = device
    self.mute = mute
    arm()
  }

  func playing(_ playing: Bool) {
    self.playing = playing
    arm()
  }

  /// Whether a volume key pressed now belongs to Meret.
  private var claiming: Bool {
    guard playing, let device else { return false }
    return VolumeKeys.defaultOutput() != device
  }

  private func arm() {
    guard tap == nil, monitor == nil, claiming else { return }
    if install() { return }
    monitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
      guard let self, !self.asked, self.claiming, VolumeKeys.key(event) != nil else { return }
      self.ask()
    }
  }

  private func ask() {
    asked = true
    let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    // Access granted in System Settings applies without a relaunch.
    RunLoop.main.add(Timer(timeInterval: 2, repeats: true) { [weak self] timer in
      if self?.install() != false { timer.invalidate() }
    }, forMode: .common)
  }

  private func install() -> Bool {
    guard tap == nil else { return true }
    guard AXIsProcessTrusted() else { return false }
    let systemDefined = CGEventMask(1) << 14  // NX_SYSDEFINED
    guard let tap = CGEvent.tapCreate(
      tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
      eventsOfInterest: systemDefined,
      callback: { _, type, event, info in
        Unmanaged<VolumeKeys>.fromOpaque(info!).takeUnretainedValue().handle(type, event)
      },
      userInfo: Unmanaged.passUnretained(self).toOpaque()
    ) else { return false }
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    self.tap = tap
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    return true
  }

  /// Runs on the main thread. Returning nil swallows the event.
  private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
      return Unmanaged.passUnretained(event)
    }
    guard let ns = NSEvent(cgEvent: event), let key = VolumeKeys.key(ns), key != .mute || mute, claiming else {
      return Unmanaged.passUnretained(event)
    }
    let flags = ns.data1 & 0xFFFF
    let down = (flags & 0xFF00) >> 8 == 0xA
    let repeated = flags & 0x1 != 0
    if down && !(key == .mute && repeated) {
      onKey(key, ns.modifierFlags.contains([.option, .shift]))
    }
    return nil
  }

  /// NX_KEYTYPE_SOUND_UP, _SOUND_DOWN and _MUTE, from an auxiliary
  /// control button event.
  private static func key(_ event: NSEvent) -> Key? {
    guard event.type == .systemDefined, event.subtype.rawValue == 8 else { return nil }
    switch (event.data1 & 0xFFFF_0000) >> 16 {
    case 0: return .up
    case 1: return .down
    case 7: return .mute
    default: return nil
    }
  }

  /// The UID of macOS's default output device.
  private static func defaultOutput() -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var id = AudioObjectID(0)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr else {
      return nil
    }
    address.mSelector = kAudioDevicePropertyDeviceUID
    var uid: Unmanaged<CFString>?
    size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &uid) == noErr, let uid else { return nil }
    return uid.takeRetainedValue() as String
  }
}
