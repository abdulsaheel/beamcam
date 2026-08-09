import Foundation
import SystemExtensions
import os.log


final class SystemExtensionInstaller: NSObject {

    static let shared = SystemExtensionInstaller()

    static let extensionIdentifier = "com.abdulsaheel.beamcam.CameraExtension"

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
