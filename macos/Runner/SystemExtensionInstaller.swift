import Foundation
import SystemExtensions
import os.log

/// Drives installation of the bundled camera extension.
///
/// Two things reliably go wrong here and are worth knowing before reading the
/// delegate callbacks: macOS refuses to install an extension unless the
/// containing app lives in /Applications, and the very first install always
/// requires the user to approve it in System Settings. Neither shows up as an
/// error you can catch — the request simply sits in "needs user approval".
final class SystemExtensionInstaller: NSObject {

    static let shared = SystemExtensionInstaller()

    static let extensionIdentifier = "com.jovaristech.beamcam.CameraExtension"

    /// Latest human-readable state, surfaced to Dart over the method channel.
    private(set) var status: String = "idle"

    private var onStatusChange: ((String) -> Void)?

    func observe(_ callback: @escaping (String) -> Void) {
        onStatusChange = callback
    }

    /// Sandboxed and launched by LaunchServices, this process has no usable
    /// stderr and its os_log output is awkward to read back, so progress also
    /// goes to a file inside the app group container.
    private static let logURL: URL = {
        let base = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "2U62X3RF3R.com.jovaristech.beamcam")
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("beamcam-extension.log")
    }()

    private func set(_ status: String) {
        self.status = status
        NSLog("BeamCam extension: %@", status)

        let line = "\(Date()) \(status)\n"
        if let data = line.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: Self.logURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: Self.logURL)
            }
        }

        DispatchQueue.main.async { self.onStatusChange?(status) }
    }

    var logPath: String { Self.logURL.path }

    func install() {
        guard Bundle.main.bundlePath.hasPrefix("/Applications/") else {
            set("error: app must be run from /Applications to install the extension "
                + "(currently \(Bundle.main.bundlePath))")
            return
        }

        set("requesting activation…")
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: Self.extensionIdentifier,
            queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func uninstall() {
        set("requesting deactivation…")
        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: Self.extensionIdentifier,
            queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }
}

extension SystemExtensionInstaller: OSSystemExtensionRequestDelegate {

    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        // Always take the freshly built copy; during development the version
        // string rarely changes even though the code did.
        set("replacing \(existing.bundleVersion) with \(ext.bundleVersion)")
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        set("awaiting approval — open System Settings › General › "
            + "Login Items & Extensions and allow BeamCam")
    }

    func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        switch result {
        case .completed:
            set("installed")
        case .willCompleteAfterReboot:
            set("installed — reboot required before the camera appears")
        @unknown default:
            set("finished with unknown result")
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        set("failed: \(error.localizedDescription)")
    }
}
