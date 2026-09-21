import AVFoundation
import Foundation
import WebRTC
import flutter_webrtc

/// Taps the remote WebRTC audio track like WebRTCFrameBridge taps video —
/// a renderer attached directly to the track — but feeds the shared-memory
/// ring (AudioRingBuffer) instead of CoreMediaIO.
///
/// WebRTC's audio device module plays remote audio to the default output
/// device automatically, so without intervention the phone's mic would come
/// out the Mac's speakers as well as the virtual mic (feedback risk).
/// `RTCAudioSource.volume = 0` and `stopPlayout()` both gate the renderer
/// too, going silent instead of just muting the speakers — the fix is
/// `setManualRenderingMode(true)`: flutter_webrtc's AVAudioEngine keeps
/// pulling the mixer (so renderers keep receiving) but stops routing to
/// hardware output.
final class WebRTCAudioBridge: NSObject, RTCAudioRenderer {

    static let shared = WebRTCAudioBridge()

    private static let targetSampleRate: Double = 48_000
    private static let targetChannels: AVAudioChannelCount = 2

    private var track: RTCAudioTrack?
    private let stateLock = NSLock()
    private var renderedFrames = 0

    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: targetSampleRate,
        channels: targetChannels,
        interleaved: true)!

    private(set) var statusText = "idle"
    var onStatusChange: ((String) -> Void)?

    // MARK: - Control

    @discardableResult
    func start(trackId: String) -> Bool {
        stop()

        guard let plugin = FlutterWebRTCPlugin.sharedSingleton() else {
            BeamCamLog.write("audiobridge: FlutterWebRTCPlugin.sharedSingleton is nil")
            return false
        }
        guard let mediaTrack = plugin.track(forId: trackId, peerConnectionId: nil),
              let audioTrack = mediaTrack as? RTCAudioTrack
        else {
            BeamCamLog.write("audiobridge: no audio track for id \(trackId)")
            return false
        }

        stateLock.lock()
        track = audioTrack
        stateLock.unlock()

        audioTrack.add(self)
        plugin.peerConnectionFactory?.audioDeviceModule.setManualRenderingMode(true)
        setStatus("streaming")
        BeamCamLog.write("audiobridge: attached to track \(trackId), playout detached from speakers")
        return true
    }

    func stop() {
        stateLock.lock()
        let attached = track
        track = nil
        stateLock.unlock()

        attached?.remove(self)
        if attached != nil {
            FlutterWebRTCPlugin.sharedSingleton()?
                .peerConnectionFactory?.audioDeviceModule.setManualRenderingMode(false)
            AudioRingBuffer.shared.close()
            BeamCamLog.write("audiobridge: detached")
        }
        setStatus("stopped")
    }

    // MARK: - RTCAudioRenderer

    func render(pcmBuffer: AVAudioPCMBuffer) {
        guard let converted = convert(pcmBuffer) else { return }
        guard let channelData = converted.floatChannelData else {
            BeamCamLog.write("audiobridge: converted buffer has no floatChannelData")
            return
        }
        // Interleaved target format: all channels live in channelData[0].
        AudioRingBuffer.shared.write(
            interleaved: channelData[0],
            frameCount: Int(converted.frameLength))
        renderedFrames += Int(converted.frameLength)
        if renderedFrames % 48_000 < Int(converted.frameLength) {
            BeamCamLog.write("audiobridge: \(renderedFrames) frames rendered")
        }
    }

    // MARK: - Conversion

    /// Rebuilt only when the incoming format changes (e.g. a different
    /// phone mic sample rate).
    private func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let inputFormat = input.format
        if converter == nil || converterInputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
            converterInputFormat = inputFormat
            if converter == nil {
                BeamCamLog.write("audiobridge: could not build converter for \(inputFormat)")
                return nil
            }
        }
        guard let converter else { return nil }

        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else {
            return nil
        }

        var delivered = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if delivered {
                outStatus.pointee = .noDataNow
                return nil
            }
            delivered = true
            outStatus.pointee = .haveData
            return input
        }

        guard status != .error, error == nil else {
            BeamCamLog.write("audiobridge: convert failed — \(error?.localizedDescription ?? "unknown")")
            return nil
        }
        return output
    }

    private func setStatus(_ text: String) {
        statusText = text
        onStatusChange?(text)
    }
}
