import Cocoa
import FlutterMacOS

/// The window has no native title bar: the query line takes its place, with
/// the window buttons inset at its left. `meret/window` lets the query line
/// move and zoom the window, and tells it when full screen hides the buttons.
class MainFlutterWindow: NSWindow {
  private var channel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

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

    super.awakeFromNib()
  }
}
