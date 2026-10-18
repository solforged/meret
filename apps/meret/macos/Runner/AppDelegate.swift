import Cocoa
import FlutterMacOS

/// Playback lives in the process, not in the window: closing the window
/// hides it (`MainFlutterWindow.performClose`), the menu bar item and the
/// media keys keep working, and the Dock icon or "Open Meret" brings the
/// window back. `⌘Q` quits.
@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag { mainFlutterWindow?.makeKeyAndOrderFront(nil) }
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
