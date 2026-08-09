import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // The channel has to be bound to the same engine Dart runs on. Doing this
    // in AppDelegate.applicationDidFinishLaunching bound it to the wrong
    // messenger and every call came back as MissingPluginException.
    let channel = FlutterMethodChannel(
      name: "beamcam/extension",
      binaryMessenger: flutterViewController.engine.binaryMessenger)

    SystemExtensionInstaller.shared.observe { status in
      channel.invokeMethod("status", arguments: status)
    }

    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "install":
        SystemExtensionInstaller.shared.install()
        result(nil)
      case "uninstall":
        SystemExtensionInstaller.shared.uninstall()
        result(nil)
      case "status":
        result(SystemExtensionInstaller.shared.status)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    // Frame bridge: WebRTC remote track -> CoreMediaIO sink stream. Same
    // engine messenger as above, for the same MissingPluginException reason.
    let sinkChannel = FlutterMethodChannel(
      name: "beamcam/sink",
      binaryMessenger: flutterViewController.engine.binaryMessenger)

    WebRTCFrameBridge.shared.onStatusChange = { status in
      DispatchQueue.main.async { sinkChannel.invokeMethod("status", arguments: status) }
    }

    sinkChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "startSink":
        let args = call.arguments as? [String: Any]
        guard let trackId = args?["trackId"] as? String, !trackId.isEmpty else {
          result(FlutterError(
            code: "bad-args", message: "startSink needs a trackId", details: nil))
          return
        }
        result(WebRTCFrameBridge.shared.start(trackId: trackId))
      case "setTransform":
        let args = call.arguments as? [String: Any]
        WebRTCFrameBridge.shared.setTransform(
          mirror: args?["mirror"] as? Bool ?? false,
          flip: args?["flip"] as? Bool ?? false)
        result(nil)
      case "setPairing":
        // Handed to the extension through the shared app group so its
        // placeholder can render the pairing code.
        let uri = (call.arguments as? [String: Any])?["uri"] as? String ?? ""
        UserDefaults(suiteName: "2U62X3RF3R.com.abdulsaheel.beamcam")?
          .set(uri, forKey: "pairing")
        result(nil)
      case "stopSink":
        WebRTCFrameBridge.shared.stop()
        result(nil)
      case "status":
        result(WebRTCFrameBridge.shared.statusText)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    SystemExtensionInstaller.shared.install()
    WebRTCFrameBridge.shared.prepare()

    super.awakeFromNib()
  }
}
