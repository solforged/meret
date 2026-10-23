import Cocoa
import FlutterMacOS

/// The window has no native title bar: the query line takes its place, with
/// the window buttons inset at its left. `meret/window` lets the query line
/// move and zoom the window, and tells it when full screen hides the buttons.
/// Closing hides the window; the music, the menu bar item and the media
/// keys go on without it (`AppDelegate`).
class MainFlutterWindow: NSWindow {
  private var channel: FlutterMethodChannel?
  private var settingsVisible = false
  private var outside: Outside?

  @IBAction func showSettings(_ sender: Any?) {
    channel?.invokeMethod("showSettings", arguments: nil)
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
    // An empty compact toolbar centres the buttons in a 38-point bar,
    // which matches the query line's height.
    toolbar = NSToolbar()
    toolbarStyle = .unifiedCompact

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

    outside = Outside(messenger: flutterViewController.engine.binaryMessenger) { [weak self] in
      NSApp.activate(ignoringOtherApps: true)
      self?.makeKeyAndOrderFront(nil)
    }

    super.awakeFromNib()
  }
}
