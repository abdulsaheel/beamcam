import Foundation
import SystemExtensions
import os.log


final class SystemExtensionInstaller: NSObject {

    static let shared = SystemExtensionInstaller()

    static let extensionIdentifier = "com.abdulsaheel.beamcam.CameraExtension"

    /// CFBundleVersion of the extension bundled inside this app build. Compared
    /// against what's actually currently active (via a live propertiesRequest,
    /// never a cached flag — a local "already did this" flag survives reinstalls,
    /// uninstalls and even different machines sharing the same CFBundleVersion,
    /// and trusting it once meant the extension silently never installed at all).
    private var bundledExtensionVersion: String? {
        let plistURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/SystemExtensions")
            .appendingPathComponent("\(Self.extensionIdentifier).systemextension")
            .appendingPathComponent("Contents/Info.plist")
        return (NSDictionary(contentsOf: plistURL))?["CFBundleVersion"] as? String
    }

    /// True while the in-flight request is the read-only properties probe, so
    /// the shared delegate callbacks (which fire for every request kind) don't
    /// report a probe as if it were a real install/uninstall outcome.
    private var isProbing = false

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
        // while a duplicate is pending. Ask macOS what's actually active first, live, and
        // only skip activation when a real match is confirmed right now. propertiesRequest
        // needs macOS 12+; below that, just activate every time (deployment target is 10.15
        // from the Podfile, but nothing here has ever run pre-12 in practice).
        guard #available(macOS 12.0, *) else {
            activate()
            return
        }
        isProbing = true
        let probe = OSSystemExtensionRequest.propertiesRequest(
            forExtensionWithIdentifier: Self.extensionIdentifier,
            queue: .main)
        probe.delegate = self
        OSSystemExtensionManager.shared.submitRequest(probe)
    }

    private func activate() {
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

    /// Reply to the propertiesRequest probe from install(). didFinishWithResult
    /// also fires right after this for the same request — isProbing keeps it
    /// from reporting the probe's completion as if it were a real install.
    func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        if #available(macOS 12.0, *),
           let version = bundledExtensionVersion,
           properties.contains(where: { $0.isEnabled && $0.bundleVersion == version }) {
            set("already installed (version \(version))")
        } else {
            activate()
        }
    }

    func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        guard !isProbing else {
            isProbing = false
            return
        }
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
        let wasProbing = isProbing
        isProbing = false
        // A probe fails "not found" the first time there's nothing installed
        // yet — that's expected, not an error; just proceed to activate.
        if wasProbing {
            activate()
            return
        }
        set("failed: \(error.localizedDescription)")
    }
}
