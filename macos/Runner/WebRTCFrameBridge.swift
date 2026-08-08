import Accelerate
import CoreImage
import CoreVideo
import Foundation
import WebRTC
import flutter_webrtc

/// Taps the remote WebRTC video track as a plain `RTCVideoRenderer`, normalises
/// every frame to the extension's format (32BGRA, 1280x720, upright), and hands
/// it to `CMIOSinkClient`.
///
/// Two frame-buffer shapes arrive in practice:
///   * `RTCCVPixelBuffer` — the VideoToolbox decoder path; already a
///     CVPixelBuffer (NV12 in the common case), used directly.
///   * an I420 planar buffer — the software decoder path; converted to BGRA with
///     vImage before anything else touches it.
/// Both then go through Core Image for rotation (`frame.rotation`) and
/// aspect-fit letterboxing into the fixed extension frame size.
final class WebRTCFrameBridge: NSObject, RTCVideoRenderer {

    static let shared = WebRTCFrameBridge()

    /// Must match BeamCamProvider's kWidth / kHeight.
    private static let outputWidth = 1920
    private static let outputHeight = 1080

    private let sink = CMIOSinkClient()
    private let convertQueue = DispatchQueue(label: "beamcam.frames", qos: .userInitiated)

    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var outputPool: CVPixelBufferPool?
    private var scratchPool: CVPixelBufferPool?
    private var scratchSize: (Int, Int) = (0, 0)

    private var track: RTCVideoTrack?
    private var trackId: String?
    private var converting = false
    private let stateLock = NSLock()

    private var yuvConversion: vImage_YpCbCrToARGB = {
        var info = vImage_YpCbCrToARGB()
        // WebRTC decodes to video-range (limited) I420 with BT.601 coefficients.
        var pixelRange = vImage_YpCbCrPixelRange(
            Yp_bias: 16, CbCr_bias: 128,
            YpRangeMax: 235, CbCrRangeMax: 240,
            YpMax: 255, YpMin: 0, CbCrMax: 255, CbCrMin: 0)
        vImageConvert_YpCbCrToARGB_GenerateConversion(
            kvImage_YpCbCrToARGBMatrix_ITU_R_601_4,
            &pixelRange, &info,
            kvImage420Yp8_Cb8_Cr8, kvImageARGB8888,
            vImage_Flags(kvImageNoFlags))
        return info
    }()

    var onStatusChange: ((String) -> Void)? {
        get { sink.onStatusChange }
        set { sink.onStatusChange = newValue }
    }

    var statusText: String { sink.statusText }

    // MARK: - Control

    /// Opens the sink at launch rather than on first frame. Finding the device
    /// costs a DAL round trip and the extension may not even be installed yet,
    /// so doing it up front means the first phone frame goes straight out.
    /// The extension keeps showing its placeholder until frames actually arrive,
    /// so an idle-but-connected sink is harmless.
    func prepare() {
        sink.start()
    }

    /// Attaches to the remote track with `trackId`. Returns false only when the
    /// plugin has no such track.
    @discardableResult
    func start(trackId: String) -> Bool {
        stop()

        guard let plugin = FlutterWebRTCPlugin.sharedSingleton() else {
            BeamCamLog.write("bridge: FlutterWebRTCPlugin.sharedSingleton is nil")
            return false
        }
        // A nil peerConnectionId makes the plugin search every peer connection's
        // remote tracks and transceiver receivers, which is where a track handed
        // to us by Dart's onTrack lives.
        guard let mediaTrack = plugin.track(forId: trackId, peerConnectionId: nil),
              let videoTrack = mediaTrack as? RTCVideoTrack
        else {
            BeamCamLog.write("bridge: no video track for id \(trackId)")
            return false
        }

        stateLock.lock()
        track = videoTrack
        self.trackId = trackId
        stateLock.unlock()

        videoTrack.add(self)
        sink.start()  // no-op if prepare() already opened it
        BeamCamLog.write("bridge: attached to track \(trackId)")
        return true
    }

    func stop() {
        stateLock.lock()
        let attached = track
        track = nil
        trackId = nil
        stateLock.unlock()

        // The CMIO connection stays up; only the frame source goes away. The
        // extension falls back to its placeholder after two idle seconds.
        attached?.remove(self)
        if attached != nil {
            BeamCamLog.write("bridge: detached")
        }
    }

    // MARK: - RTCVideoRenderer

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }

        stateLock.lock()
        // Drop rather than queue: the sink only wants the newest frame, and
        // backing up here would just add latency on the decoder thread.
        if converting {
            stateLock.unlock()
            return
        }
        converting = true
        stateLock.unlock()

        convertQueue.async { [weak self] in
            guard let self else { return }
            if let pixelBuffer = self.normalise(frame) {
                self.sink.push(pixelBuffer)
            }
            self.stateLock.lock()
            self.converting = false
            self.stateLock.unlock()
        }
    }

    // MARK: - Conversion

    private func normalise(_ frame: RTCVideoFrame) -> CVPixelBuffer? {
        guard var image = sourceImage(for: frame) else { return nil }

        image = image.oriented(orientation(for: frame.rotation))
        image = image.transformed(
            by: CGAffineTransform(translationX: -image.extent.origin.x,
                                  y: -image.extent.origin.y))

        let outWidth = CGFloat(Self.outputWidth)
        let outHeight = CGFloat(Self.outputHeight)
        let sourceWidth = image.extent.width
        let sourceHeight = image.extent.height
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }

        let scale = min(outWidth / sourceWidth, outHeight / sourceHeight)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let centred = scaled.transformed(
            by: CGAffineTransform(
                translationX: ((outWidth - scaled.extent.width) / 2).rounded(),
                y: ((outHeight - scaled.extent.height) / 2).rounded()))

        let canvas = CGRect(x: 0, y: 0, width: outWidth, height: outHeight)
        let composited = centred.composited(
            over: CIImage(color: .black).cropped(to: canvas))

        guard let output = makeOutputBuffer() else { return nil }
        ciContext.render(
            composited,
            to: output,
            bounds: canvas,
            colorSpace: CGColorSpaceCreateDeviceRGB())
        return output
    }

    private func sourceImage(for frame: RTCVideoFrame) -> CIImage? {
        if let cvBuffer = frame.buffer as? RTCCVPixelBuffer {
            let pixelBuffer = cvBuffer.pixelBuffer
            let image = CIImage(cvPixelBuffer: pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            guard cvBuffer.requiresCropping() else { return image }
            // RTCCVPixelBuffer's crop rect is top-left based; Core Image is
            // bottom-left based, so the Y origin has to be flipped.
            let crop = CGRect(
                x: CGFloat(cvBuffer.cropX),
                y: CGFloat(height - Int(cvBuffer.cropY) - Int(cvBuffer.cropHeight)),
                width: CGFloat(cvBuffer.cropWidth),
                height: CGFloat(cvBuffer.cropHeight))
            return image.cropped(to: crop)
        }

        let i420 = frame.buffer.toI420()
        guard let bgra = convertI420ToBGRA(i420) else { return nil }
        return CIImage(cvPixelBuffer: bgra)
    }

    private func convertI420ToBGRA(_ buffer: any RTCI420BufferProtocol) -> CVPixelBuffer? {
        // vImage's 420 converter requires even dimensions.
        let width = Int(buffer.width) & ~1
        let height = Int(buffer.height) & ~1
        guard width > 0, height > 0 else { return nil }

        guard let destination = makeScratchBuffer(width: width, height: height) else { return nil }
        CVPixelBufferLockBaseAddress(destination, [])
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }
        guard let base = CVPixelBufferGetBaseAddress(destination) else { return nil }

        var srcY = vImage_Buffer(
            data: UnsafeMutableRawPointer(mutating: buffer.dataY),
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: Int(buffer.strideY))
        var srcU = vImage_Buffer(
            data: UnsafeMutableRawPointer(mutating: buffer.dataU),
            height: vImagePixelCount(buffer.chromaHeight),
            width: vImagePixelCount(buffer.chromaWidth),
            rowBytes: Int(buffer.strideU))
        var srcV = vImage_Buffer(
            data: UnsafeMutableRawPointer(mutating: buffer.dataV),
            height: vImagePixelCount(buffer.chromaHeight),
            width: vImagePixelCount(buffer.chromaWidth),
            rowBytes: Int(buffer.strideV))
        var dest = vImage_Buffer(
            data: base,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: CVPixelBufferGetBytesPerRow(destination))

        // The converter emits ARGB; [3,2,1,0] permutes it to the BGRA byte order
        // that kCVPixelFormatType_32BGRA expects.
        var permuteMap: [UInt8] = [3, 2, 1, 0]
        let error = vImageConvert_420Yp8_Cb8_Cr8ToARGB8888(
            &srcY, &srcU, &srcV, &dest,
            &yuvConversion, &permuteMap, 255,
            vImage_Flags(kvImageDoNotTile))
        guard error == kvImageNoError else { return nil }
        return destination
    }

    private func orientation(for rotation: RTCVideoRotation) -> CGImagePropertyOrientation {
        switch rotation {
        case ._90: return .right
        case ._180: return .down
        case ._270: return .left
        default: return .up
        }
    }

    // MARK: - Buffer pools

    private func makeOutputBuffer() -> CVPixelBuffer? {
        if outputPool == nil {
            outputPool = Self.makePool(
                width: Self.outputWidth,
                height: Self.outputHeight)
        }
        guard let pool = outputPool else { return nil }
        var pixelBuffer: CVPixelBuffer?
        // The threshold keeps the pool from growing without bound if the sink
        // ever holds on to buffers longer than expected.
        let auxAttributes: NSDictionary = [kCVPixelBufferPoolAllocationThresholdKey: 6]
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault, pool, auxAttributes, &pixelBuffer)
        guard status == kCVReturnSuccess else { return nil }
        return pixelBuffer
    }

    private func makeScratchBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if scratchPool == nil || scratchSize != (width, height) {
            scratchPool = Self.makePool(width: width, height: height)
            scratchSize = (width, height)
        }
        guard let pool = scratchPool else { return nil }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault, pool, &pixelBuffer) == kCVReturnSuccess
        else { return nil }
        return pixelBuffer
    }

    /// IOSurface backing is not optional: buffers enqueued on the sink cross a
    /// process boundary into the extension.
    private static func makePool(width: Int, height: Int) -> CVPixelBufferPool? {
        let attributes: NSDictionary = [
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary,
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(
            kCFAllocatorDefault, nil, attributes, &pool) == kCVReturnSuccess
        else { return nil }
        return pool
    }
}
