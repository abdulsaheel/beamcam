import Foundation
import SystemExtensions
import os.log


final class SystemExtensionInstaller: NSObject {

    static let shared = SystemExtensionInstaller()

    static let extensionIdentifier = "com.abdulsaheel.beamcam.CameraExtension"

    private static let lastActivatedVersionKey = "SystemExtensionInstaller.lastActivatedVersion"

    /// CFBundleVersion of the extension bundled inside this app build. Compared
    /// against the version we last successfully activated so install() can skip
    /// a redundant activationRequest.
    private var bundledExtensionVersion: String? {
        let plistURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/SystemExtensions")
            .appendingPathComponent("\(Self.extensionIdentifier).systemextension")
            .appendingPathComponent("Contents/Info.plist")
        return (NSDictionary(contentsOf: plistURL))?["CFBundleVersion"] as? String
    }

    /// Latest human-readable state, surfaced to Dart over the method channel.
    private(set) var status: String = "idle"

    private var onStatusChange: ((String) -> Void)?

    func observe(_ callback: @escaping (String) -> Void) {
        onStatusChange = callback
    }

    private func set(_ status: String) {
        self.status = status
        BeamCamLog.write("extension: \(status)")
        DispatchQueue.main.async { self.onStatusChange?(status) }
    }

    func install() {
        guard Bundle.main.bundlePath.hasPrefix("/Applications/") else {
            set("error: app must be run from /Applications to install the extension "
                + "(currently \(Bundle.main.bundlePath))")
            return
        }

        // ponytail: activationRequest restages the extension (new /Library/SystemExtensions
        // UUID, old one left "waiting to uninstall on reboot") even when the bundle is
        // byte-identical to what's already active — and the DAL won't register the device
        // while a duplicate is pending. Skip the call once this exact version already went
        // through .completed. Upgrade path: if a future macOS makes activationRequest a true
        // no-op again, this whole guard can go.
        if let version = bundledExtensionVersion,
           UserDefaults.standard.string(forKey: Self.lastActivatedVersionKey) == version {
            set("already installed (version \(version))")
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
        UserDefaults.standard.removeObject(forKey: Self.lastActivatedVersionKey)
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
            if let version = bundledExtensionVersion {
                UserDefaults.standard.set(version, forKey: Self.lastActivatedVersionKey)
            }
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
