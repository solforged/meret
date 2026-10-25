import Cocoa
import FlutterMacOS

/// The window has no native title bar: the top line takes its place, with
/// the window buttons inset at its left. `meret/window` lets the top line
/// move and zoom the window, tells it when full screen hides the buttons,
/// and carries the Go and Controls menus' items to the surface.
/// Closing hides the window; the music, the menu bar item and the media
/// keys go on without it (`AppDelegate`).
class MainFlutterWindow: NSWindow {
  private var channel: FlutterMethodChannel?
  private var settingsVisible = false
  private var outside: Outside?

  @IBAction func showSettings(_ sender: Any?) {
    channel?.invokeMethod("showSettings", arguments: nil)
  }

  @objc private func menuItem(_ sender: NSMenuItem) {
    if let id = sender.representedObject as? String { channel?.invokeMethod("menu", arguments: id) }
  }

  /// The key hints live here (navigation.md, plate 04), where Mac users look
  /// for shortcuts and where VoiceOver and menu search reach every action.
  /// Choosing an item runs it through the channel. Only ⌘ keys are real key
  /// equivalents: a plain one would take that letter from the query line
  /// when Flutter passes it on, so those are drawn in the key column and
  /// left to the surface.
  private static let menus: [(String, [(id: String, title: String, key: String, mods: NSEvent.ModifierFlags)?])] = [
    ("Go", [
      ("front", "Front", "1", .command),
      ("table", "Library Table", "l", .command),
      ("search", "Search", "/", []),
      nil,
      ("back", "Back Along the Trail", "[", []),
      ("forward", "Forward", "]", []),
      ("previousBranch", "Previous Branch", "[", .option),
      ("nextBranch", "Next Branch", "]", .option),
      ("tree", "Tree", "t", []),
      nil,
      ("keep", "Keep Trail…", "s", .command),
      ("prune", "Prune Branch", "\u{8}", .command),
    ]),
    ("Controls", [
      ("toggle", "Play or Pause", " ", []),
      ("playSomething", "Play Something", " ", .shift),
      ("fromStart", "From the Start", " ", .option),
      nil,
      ("now", "Now", "n", []),
      ("history", "History", "h", []),
    ]),
  ]

  /// "Tree" with "T" in the key column, right-aligned as AppKit draws ⌘ keys.
  private static func hinted(_ title: String, key: String, mods: NSEvent.ModifierFlags) -> NSAttributedString {
    let glyph = (mods.contains(.option) ? "⌥" : "") + (mods.contains(.shift) ? "⇧" : "") + (key == " " ? "Space" : key.uppercased())
    let style = NSMutableParagraphStyle()
    style.tabStops = [NSTextTab(textAlignment: .right, location: 230)]
    let font = NSFont.menuFont(ofSize: 0)
    let text = NSMutableAttributedString(string: "\(title)\t", attributes: [.font: font, .paragraphStyle: style])
    text.append(NSAttributedString(string: glyph, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style]))
    return text
  }

  private func installMenus() {
    guard let main = NSApp.mainMenu else { return }
    // After Edit, before View, as in the Finder.
    var at = (main.items.firstIndex { $0.submenu?.title == "View" }) ?? max(0, main.items.count - 2)
    for (title, items) in Self.menus where main.items.first(where: { $0.title == title }) == nil {
      let menu = NSMenu(title: title)
      for item in items {
        guard let item else {
          menu.addItem(.separator())
          continue
        }
        let entry: NSMenuItem
        if item.mods.contains(.command) {
          entry = NSMenuItem(title: item.title, action: #selector(menuItem(_:)), keyEquivalent: item.key)
          entry.keyEquivalentModifierMask = item.mods
        } else {
          entry = NSMenuItem(title: item.title, action: #selector(menuItem(_:)), keyEquivalent: "")
          entry.attributedTitle = Self.hinted(item.title, key: item.key, mods: item.mods)
        }
        entry.representedObject = item.id
        entry.target = self
        menu.addItem(entry)
      }
      let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      top.submenu = menu
      main.insertItem(top, at: at)
      at += 1
    }
  }

  override func performClose(_ sender: Any?) {
    if settingsVisible {
      channel?.invokeMethod("closeSettings", arguments: nil)
    } else if styleMask.contains(.fullScreen) {
      toggleFullScreen(nil)
    } else {
      orderOut(sender)
    }
  }

  /// The first launch opens at a laptop width (Now pinned, two panes) that
  /// fits the screen; afterwards the frame is whatever it was last time.
  private func firstFrame() -> NSRect {
    let visible = (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let size = NSSize(width: min(1440, visible.width - 80), height: min(900, visible.height - 60))
    return NSRect(
      x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
      width: size.width, height: size.height)
  }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    isReleasedWhenClosed = false

    // Below 600 pt the layout is the phone's; keep the desktop above it.
    contentMinSize = NSSize(width: 600, height: 480)
    if !setFrameUsingName("MeretMain") { setFrame(firstFrame(), display: false) }
    setFrameAutosaveName("MeretMain")

    styleMask.insert(.fullSizeContentView)
    titlebarAppearsTransparent = true
    titleVisibility = .hidden
    // No toolbar: one would take the clicks meant for the top line. The
    // buttons are moved onto its centre line instead, each time AppKit lays
    // them out again.
    for name in [
      NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
      NSWindow.didExitFullScreenNotification, NSWindow.didEndLiveResizeNotification,
    ] {
      NotificationCenter.default.addObserver(forName: name, object: self, queue: .main) { [weak self] _ in
        self?.placeButtons()
      }
    }

    let channel = FlutterMethodChannel(
      name: "meret/window", binaryMessenger: flutterViewController.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(nil) }
      switch call.method {
      case "drag":
        if let event = NSApp.currentEvent { self.performDrag(with: event) }
        result(nil)
      case "zoom":
        // Honour the "double-click a title bar to" setting.
        let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")
        if action == "Minimize" { self.performMiniaturize(nil) } else if action != "None" { self.performZoom(nil) }
        result(nil)
      case "fullScreen":
        result(self.styleMask.contains(.fullScreen))
      case "settingsVisible":
        self.settingsVisible = call.arguments as? Bool ?? false
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.channel = channel
    for (name, value) in [
      (NSWindow.willEnterFullScreenNotification, true),
      (NSWindow.didExitFullScreenNotification, false),
    ] {
      NotificationCenter.default.addObserver(forName: name, object: self, queue: .main) { [weak self] _ in
        self?.channel?.invokeMethod("fullScreen", arguments: value)
      }
    }

    RegisterGeneratedPlugins(registry: flutterViewController)
    installMenus()

    outside = Outside(messenger: flutterViewController.engine.binaryMessenger) { [weak self] in
      NSApp.activate(ignoringOtherApps: true)
      self?.makeKeyAndOrderFront(nil)
    }

    super.awakeFromNib()
    placeButtons()
  }

  /// The top line is 44 points; the buttons sit on its centre line.
  private static let topLine: CGFloat = 44

  private func placeButtons() {
    guard !styleMask.contains(.fullScreen) else { return }
    for (i, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
      guard let button = standardWindowButton(type), let bar = button.superview else { continue }
      let origin = NSPoint(x: 14 + CGFloat(i) * 20, y: bar.frame.height - Self.topLine / 2 - button.frame.height / 2)
      if button.frame.origin != origin { button.setFrameOrigin(origin) }
    }
  }

  override func layoutIfNeeded() {
    super.layoutIfNeeded()
    placeButtons()
  }
}
