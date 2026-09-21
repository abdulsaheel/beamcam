import Foundation

/// Installs BeamCamAudio.driver into /Library/Audio/Plug-Ins/HAL and restarts
/// coreaudiod so it loads it.
///
/// Unlike SystemExtensionInstaller: a legacy AudioServerPlugIn HAL driver is
/// a plain bundle, not a System Extension — no OSSystemExtensionRequest, no
/// sandboxed activation, no per-user approval UI. It just needs to land in a
/// root-owned directory, done via a single `osascript … with administrator
/// privileges` shell command rather than a full SMJobBless/SMAppService
/// helper-tool subsystem.
final class AudioDriverInstaller: NSObject {

    static let shared = AudioDriverInstaller()

    private static let installedDriverPath = "/Library/Audio/Plug-Ins/HAL/BeamCamAudio.driver"
    private static let ringDirectory = "/Library/Application Support/BeamCam"
    private static let ringPath = "/Library/Application Support/BeamCam/beamcam-audio.ring"

    /// header (32 bytes) + 2s of 48kHz stereo Float32 — must match
    /// AudioRingBuffer.swift / BeamCamAudioRing.h exactly.
    private static let ringSizeBytes = 32 + 48_000 * 2 * 2 * 4

    private(set) var status = "idle"
    private var onStatusChange: ((String) -> Void)?

    func observe(_ callback: @escaping (String) -> Void) {
        onStatusChange = callback
    }

    private func set(_ status: String) {
        self.status = status
        BeamCamLog.write("audiodriver: \(status)")
        DispatchQueue.main.async { self.onStatusChange?(status) }
    }

    func currentStatus() -> String {
        FileManager.default.fileExists(atPath: Self.installedDriverPath) ? "installed" : status
    }

    /// Single-quotes a path for safe use as one shell token. Quote everything
    /// interpolated into the admin-authorized command below, constants
    /// included — an unquoted app path could break out into arbitrary root
    /// shell execution.
    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escapes a shell command for embedding inside AppleScript's own
    /// double-quoted string literal (`do shell script "..."`), which has its
    /// own separate escaping rules (backslash and double-quote).
    private static func appleScriptQuote(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    func install() {
        guard let bundled = Bundle.main.url(forResource: "BeamCamAudio", withExtension: "driver") else {
            set("error: BeamCamAudio.driver not found in app bundle")
            return
        }

        set("requesting admin authorization…")

        // One privileged command: create the world r/w ring file (see
        // AudioRingBuffer.swift), replace the driver bundle, restart coreaudiod.
        let shellCommand = "mkdir -p \(Self.shellQuote(Self.ringDirectory)) && "
            + "touch \(Self.shellQuote(Self.ringPath)) && "
            + "truncate -s \(Self.ringSizeBytes) \(Self.shellQuote(Self.ringPath)) && "
            + "chmod 666 \(Self.shellQuote(Self.ringPath)) && "
            + "rm -rf \(Self.shellQuote(Self.installedDriverPath)) && "
            + "cp -R \(Self.shellQuote(bundled.path)) \(Self.shellQuote(Self.installedDriverPath)) && "
            + "chmod -R go+rX \(Self.shellQuote(Self.installedDriverPath)) && "
            + "killall coreaudiod || true"
        let script = "do shell script \"\(Self.appleScriptQuote(shellCommand))\" with administrator privileges"

        var errorDict: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else {
            set("error: could not build install script")
            return
        }
        appleScript.executeAndReturnError(&errorDict)

        if let errorDict {
            let message = errorDict[NSAppleScript.errorMessage] as? String ?? "unknown error"
            // -128 is the user cancelling the admin prompt — not a failure.
            if (errorDict[NSAppleScript.errorNumber] as? Int) == -128 {
                set("cancelled")
            } else {
                set("error: \(message)")
            }
            return
        }

        set(FileManager.default.fileExists(atPath: Self.installedDriverPath)
            ? "installed" : "error: copy did not verify")
    }

    func uninstall() {
        let shellCommand = "rm -rf \(Self.shellQuote(Self.installedDriverPath)) && killall coreaudiod || true"
        let script = "do shell script \"\(Self.appleScriptQuote(shellCommand))\" with administrator privileges"
        var errorDict: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else { return }
        appleScript.executeAndReturnError(&errorDict)
        set(errorDict == nil ? "idle" : "error: \(errorDict?[NSAppleScript.errorMessage] as? String ?? "")")
    }
}
