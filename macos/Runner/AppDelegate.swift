import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {

  private var statusItem: NSStatusItem?

  /// The process owns the WebRTC connection and the CoreMediaIO sink, so quitting
  /// it stops the virtual camera. Closing the window must therefore not terminate
  /// the app — it keeps running from the menu bar instead.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    installStatusItem()
  }

  /// Clicking the Dock icon with no window open brings the window back.
  override func applicationShouldHandleReopen(
    _ sender: NSApplication, hasVisibleWindows flag: Bool
  ) -> Bool {
    showWindow()
    return true
  }

  private func installStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    // SF Symbols need macOS 11; the deployment target is 10.15.
    if #available(macOS 11.0, *) {
      item.button?.image = NSImage(
        systemSymbolName: "video.fill", accessibilityDescription: "BeamCam")
    } else {
      item.button?.title = "BeamCam"
    }
    item.button?.toolTip = "BeamCam — phone as webcam"

    let menu = NSMenu()
    menu.addItem(
      NSMenuItem(title: "Show BeamCam", action: #selector(showWindow), keyEquivalent: ""))
    menu.addItem(.separator())
    menu.addItem(
      NSMenuItem(title: "Quit BeamCam", action: #selector(quit), keyEquivalent: "q"))
    menu.items.forEach { $0.target = self }

    item.menu = menu
    statusItem = item
  }

  @objc private func showWindow() {
    NSApp.activate(ignoringOtherApps: true)
    mainFlutterWindow?.makeKeyAndOrderFront(nil)
  }

  @objc private func quit() {
    NSApp.terminate(nil)
  }
}
