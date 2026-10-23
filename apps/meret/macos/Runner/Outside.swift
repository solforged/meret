import Cocoa
import FlutterMacOS
import MediaPlayer

/// What Now looks like from outside the window. Dart sends one of these per
/// change (`Outside.now` in `shell/outside.dart`); the position is
/// extrapolated here from the anchor so nothing ticks across the channel.
struct NowOutside {
  var loaded = false
  var title = ""
  var subtitle = ""
  var cover: String?
  var why: String?
  var lengthMs: Double?
  var anchorMs: Double = 0
  var rate: Double = 0
  var receivedAt = Date()
  var verdict: String?
  var warn = false
  var error: String?

  init() {}

  init(_ m: [String: Any]) {
    loaded = m["loaded"] as? Bool ?? false
    title = m["title"] as? String ?? ""
    subtitle = m["subtitle"] as? String ?? ""
    cover = m["cover"] as? String
    why = m["why"] as? String
    lengthMs = (m["lengthMs"] as? NSNumber)?.doubleValue
    anchorMs = (m["positionMs"] as? NSNumber)?.doubleValue ?? 0
    rate = (m["rate"] as? NSNumber)?.doubleValue ?? 0
    verdict = m["verdict"] as? String
    warn = m["warn"] as? Bool ?? false
    error = m["error"] as? String
  }

  var playing: Bool { rate > 0 }

  var positionMs: Double {
    let ms = anchorMs + rate * Date().timeIntervalSince(receivedAt) * 1000
    if let length = lengthMs { return min(max(ms, 0), length) }
    return max(ms, 0)
  }
}

/// Plate 10: the menu bar item shows the title and time; its panel has the
/// controls, the signal path, three things to pick up, and Play something.
/// Media keys and the system's Now Playing go through `MediaPlayer`.
final class Outside: NSObject, NSMenuDelegate {
  private let channel: FlutterMethodChannel
  private let showMain: () -> Void
  private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  private let menu = NSMenu()
  private var open = false
  private var claimed = false
  private let panel: PanelViewController
  private var now = NowOutside()
  private var tick: Timer?
  private var artwork: (path: String, image: MPMediaItemArtwork)?

  init(messenger: FlutterBinaryMessenger, showMain: @escaping () -> Void) {
    channel = FlutterMethodChannel(name: "meret/outside", binaryMessenger: messenger)
    self.showMain = showMain
    panel = PanelViewController()
    super.init()

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(nil) }
      switch call.method {
      case "now":
        self.apply(NowOutside(call.arguments as? [String: Any] ?? [:]))
        result(nil)
      case "pickUp":
        self.panel.showPickUp(call.arguments as? [[String: Any]] ?? [])
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    item.button?.image = Outside.mark()
    item.button?.imagePosition = .imageLeading
    menu.delegate = self
    menu.appearance = NSAppearance(named: .darkAqua)
    let entry = NSMenuItem()
    entry.view = panel.view
    menu.addItem(entry)
    let actions = NSMenuItem()
    actions.view = ActionsRow { [weak self] key in self?.panelKey(key) }
    menu.addItem(actions)
    // An open menu matches key equivalents on plain items only, never on
    // buttons inside a view, so the two keys live on hidden items.
    for (title, action, key, mods) in [
      ("Open Meret", #selector(openKey), "o", NSEvent.ModifierFlags.command),
      ("Play something", #selector(playSomethingKey), " ", .shift),
    ] {
      let hidden = NSMenuItem(title: title, action: action, keyEquivalent: key)
      hidden.keyEquivalentModifierMask = mods
      hidden.target = self
      hidden.isHidden = true
      hidden.allowsKeyEquivalentWhenHidden = true
      menu.addItem(hidden)
    }
    item.menu = menu
    panel.onCommand = { [weak self] method, args in self?.send(method, args) }
    panel.onClose = { [weak self] in self?.menu.cancelTracking() }

    registerRemoteCommands()
    apply(NowOutside())
  }

  // MARK: Now

  private func apply(_ n: NowOutside) {
    now = n
    refreshTitle()
    publishNowPlaying()
    if open { panel.show(now) }
    tick?.invalidate()
    tick = nil
    if now.playing {
      let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
        guard let self else { return }
        self.refreshTitle()
        if self.open { self.panel.tick(self.now) }
      }
      RunLoop.main.add(timer, forMode: .common)
      tick = timer
    }
  }

  private func refreshTitle() {
    guard let button = item.button else { return }
    if !now.loaded {
      button.title = ""
      button.toolTip = "Meret"
      return
    }
    let title = now.title.count > 32 ? String(now.title.prefix(31)).trimmingCharacters(in: .whitespaces) + "…" : now.title
    // Paused reads dimmer than playing; the string itself is the same.
    button.attributedTitle = NSAttributedString(
      string: " \(title) · \(Outside.clock(now.positionMs))",
      attributes: [
        .font: NSFont.menuBarFont(ofSize: 0),
        .foregroundColor: now.playing ? NSColor.labelColor : NSColor.secondaryLabelColor,
      ])
    button.toolTip = "\(now.title)\n\(now.subtitle)"
  }

  private func publishNowPlaying() {
    let center = MPNowPlayingInfoCenter.default()
    guard now.loaded else {
      center.nowPlayingInfo = nil
      center.playbackState = .stopped
      return
    }
    var info: [String: Any] = [
      MPMediaItemPropertyTitle: now.title,
      MPMediaItemPropertyArtist: now.subtitle,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: now.positionMs / 1000,
      MPNowPlayingInfoPropertyPlaybackRate: now.rate,
      MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
      MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
    ]
    if let length = now.lengthMs { info[MPMediaItemPropertyPlaybackDuration] = length / 1000 }
    if let path = now.cover {
      if artwork?.path != path, let image = NSImage(contentsOfFile: path) {
        artwork = (path, MPMediaItemArtwork(boundsSize: image.size) { _ in image })
      }
      if artwork?.path == path, let art = artwork?.image { info[MPMediaItemPropertyArtwork] = art }
    } else {
      artwork = nil
    }
    center.nowPlayingInfo = info
    // macOS hands the media keys to the app that last went to `.playing`;
    // a paused restore never would, and F8 would open Music instead of
    // resuming Meret. Claim once, then tell the truth.
    if !claimed {
      claimed = true
      center.playbackState = .playing
    }
    center.playbackState = now.playing ? .playing : .paused
  }

  // MARK: Commands

  private func registerRemoteCommands() {
    let c = MPRemoteCommandCenter.shared()
    c.playCommand.addTarget { [weak self] _ in self?.send("play"); return .success }
    c.pauseCommand.addTarget { [weak self] _ in self?.send("pause"); return .success }
    c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.send("toggle"); return .success }
    c.nextTrackCommand.addTarget { [weak self] _ in self?.send("next"); return .success }
    c.previousTrackCommand.addTarget { [weak self] _ in self?.send("previous"); return .success }
    c.changePlaybackPositionCommand.addTarget { [weak self] event in
      guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
      self?.send("seek", event.positionTime * 1000)
      return .success
    }
    for off in [c.stopCommand, c.seekForwardCommand, c.seekBackwardCommand, c.skipForwardCommand, c.skipBackwardCommand] {
      off.isEnabled = false
    }
  }

  private func send(_ method: String, _ args: Any? = nil) {
    channel.invokeMethod(method, arguments: args)
  }

  /// A panel button or key.
  private func panelKey(_ key: PanelKey) {
    menu.cancelTracking()
    switch key {
    case .open: showMain()
    case .playSomething: send("playSomething")
    }
  }

  @objc private func openKey() { panelKey(.open) }
  @objc private func playSomethingKey() { panelKey(.playSomething) }

  // MARK: Panel

  /// The panel is the status item's menu with two views in it, so AppKit
  /// tracks it: no activation, closes on a click outside; the panel's own
  /// keys come back through `onKey`. The rows are already built; opening
  /// only writes the strings.
  func menuWillOpen(_ menu: NSMenu) {
    open = true
    panel.show(now)
  }

  func menuDidClose(_ menu: NSMenu) {
    open = false
  }

  // MARK: Drawing

  /// The mark from the plates: a gold ring with a dot, as a template so the
  /// menu bar tints it.
  static func mark() -> NSImage {
    let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
      let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1.25, dy: 1.25))
      ring.lineWidth = 1.5
      NSColor.black.setStroke()
      ring.stroke()
      NSBezierPath(ovalIn: rect.insetBy(dx: 4.5, dy: 4.5)).fill()
      return true
    }
    image.isTemplate = true
    return image
  }

  /// "3:46" or "1:12:05", as `clockLength` writes it in Dart.
  static func clock(_ ms: Double) -> String {
    let s = Int(ms / 1000)
    return s >= 3600
      ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
      : String(format: "%d:%02d", s / 60 % 60, s % 60)
  }
}
