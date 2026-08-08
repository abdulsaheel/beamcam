import Foundation
import CoreMediaIO
import IOKit.audio
import CoreImage
import os.log

let kFrameRate: Int32 = 30
// The virtual camera publishes a single fixed format, so this is the ceiling for
// the whole pipeline regardless of what the phone sends. 1080p is the highest
// resolution every consumer (Meet, Zoom, FaceTime, Brave) handles without
// negotiation trouble; lower phone resolutions are letterboxed up by the bridge.
// Raising this requires reinstalling the extension.
let kWidth: Int32 = 1920
let kHeight: Int32 = 1080

/// Name shown in Brave, Meet, FaceTime, and every other camera picker.
let kDeviceName = "BeamCam"

// MARK: - Provider

class BeamCamProviderSource: NSObject, CMIOExtensionProviderSource {

    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: BeamCamDeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = BeamCamDeviceSource(localizedName: kDeviceName)
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("Failed to add device: \(error.localizedDescription)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {}

    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> {
        [.providerManufacturer]
    }

    func providerProperties(
        forProperties properties: Set<CMIOExtensionProperty>
    ) throws -> CMIOExtensionProviderProperties {
        let providerProperties = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) {
            providerProperties.manufacturer = "Jovaris Tech"
        }
        return providerProperties
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}

// MARK: - Device

class BeamCamDeviceSource: NSObject, CMIOExtensionDeviceSource {

    private(set) var device: CMIOExtensionDevice!

    private var _streamSource: BeamCamStreamSource!
    private var _sinkSource: BeamCamSinkStreamSource!
    private var _streamingCounter: UInt32 = 0
    private var _timer: DispatchSourceTimer?
    private let _timerQueue = DispatchQueue(
        label: "beamcam.timer", qos: .userInteractive)

    private var _videoDescription: CMFormatDescription!
    private var _bufferPool: CVPixelBufferPool!
    private var _bufferAuxAttributes: NSDictionary!

    /// Set by the sink stream whenever the container app hands us a real frame.
    /// Until then the source stream falls back to a placeholder so consumers
    /// always see a valid, correctly-sized signal instead of a stalled stream.
    private var _lastClientFrame: CVPixelBuffer?
    private var _lastClientFrameAt: Date?
    private let _frameLock = NSLock()

    init(localizedName: String) {
        super.init()

        let deviceID = UUID()
        device = CMIOExtensionDevice(
            localizedName: localizedName,
            deviceID: deviceID,
            legacyDeviceID: deviceID.uuidString,
            source: self)

        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_32BGRA,
            width: kWidth, height: kHeight,
            extensions: nil,
            formatDescriptionOut: &_videoDescription)

        let pixelBufferAttributes: NSDictionary = [
            kCVPixelBufferWidthKey: kWidth,
            kCVPixelBufferHeightKey: kHeight,
            kCVPixelBufferPixelFormatTypeKey: _videoDescription.mediaSubType,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary,
        ]
        CVPixelBufferPoolCreate(
            kCFAllocatorDefault, nil, pixelBufferAttributes, &_bufferPool)

        let videoStreamFormat = CMIOExtensionStreamFormat(
            formatDescription: _videoDescription,
            maxFrameDuration: CMTime(value: 1, timescale: kFrameRate),
            minFrameDuration: CMTime(value: 1, timescale: kFrameRate),
            validFrameDurations: nil)

        _bufferAuxAttributes = [kCVPixelBufferPoolAllocationThresholdKey: 5]

        _streamSource = BeamCamStreamSource(
            localizedName: "BeamCam.Video",
            streamID: UUID(),
            streamFormat: videoStreamFormat,
            device: device)

        _sinkSource = BeamCamSinkStreamSource(
            localizedName: "BeamCam.Sink",
            streamID: UUID(),
            streamFormat: videoStreamFormat,
            device: device,
            deviceSource: self)

        do {
            try device.addStream(_streamSource.stream)
            try device.addStream(_sinkSource.stream)
        } catch {
            fatalError("Failed to add stream: \(error.localizedDescription)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel]
    }

    func deviceProperties(
        forProperties properties: Set<CMIOExtensionProperty>
    ) throws -> CMIOExtensionDeviceProperties {
        let deviceProperties = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            deviceProperties.transportType = kIOAudioDeviceTransportTypeVirtual
        }
        if properties.contains(.deviceModel) {
            deviceProperties.model = "BeamCam Virtual Camera"
        }
        return deviceProperties
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    /// Called from the sink stream once per frame delivered by the container app.
    func receive(_ pixelBuffer: CVPixelBuffer) {
        _frameLock.lock()
        _lastClientFrame = pixelBuffer
        _lastClientFrameAt = Date()
        _frameLock.unlock()
    }

    private func currentClientFrame() -> CVPixelBuffer? {
        _frameLock.lock()
        defer { _frameLock.unlock() }
        // Treat a stale frame as no frame, so unplugging the phone shows the
        // placeholder rather than freezing on the last image forever.
        guard let at = _lastClientFrameAt, Date().timeIntervalSince(at) < 2.0 else {
            return nil
        }
        return _lastClientFrame
    }

    func startStreaming() {
        guard _bufferPool != nil else { return }

        _streamingCounter += 1
        guard _timer == nil else { return }

        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: _timerQueue)
        timer.schedule(
            deadline: .now(),
            repeating: Double(1.0) / Double(kFrameRate),
            leeway: .seconds(0))

        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.emitFrame()
        }
        timer.resume()
        _timer = timer
    }

    func stopStreaming() {
        guard _streamingCounter > 0 else { return }
        _streamingCounter -= 1
        if _streamingCounter == 0 {
            _timer?.cancel()
            _timer = nil
        }
    }

    private func emitFrame() {
        var err: OSStatus = 0
        let now = CMClockGetTime(CMClockGetHostTimeClock())

        let outBuffer: CVPixelBuffer
        if let clientFrame = currentClientFrame() {
            outBuffer = clientFrame
        } else {
            var pixelBuffer: CVPixelBuffer?
            err = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
                kCFAllocatorDefault,
                _bufferPool,
                _bufferAuxAttributes,
                &pixelBuffer)
            guard err == 0, let pixelBuffer else { return }
            drawPlaceholder(into: pixelBuffer)
            outBuffer = pixelBuffer
        }

        var sbuf: CMSampleBuffer!
        var timingInfo = CMSampleTimingInfo()
        timingInfo.presentationTimeStamp = now

        var formatDescription: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: outBuffer,
            formatDescriptionOut: &formatDescription)
        guard let formatDescription else { return }

        err = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: outBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sbuf)
        guard err == 0, let sbuf else { return }

        _streamSource.stream.send(
            sbuf,
            discontinuity: [],
            hostTimeInNanoseconds: UInt64(
                timingInfo.presentationTimeStamp.seconds * Double(NSEC_PER_SEC)))
    }

    /// A dark frame with a moving accent bar: proves the pipeline is alive and
    /// makes it obvious at a glance that no phone is connected yet.
    private func drawPlaceholder(into pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        guard let context = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: UInt32(CGImageAlphaInfo.premultipliedFirst.rawValue)
                | UInt32(CGBitmapInfo.byteOrder32Little.rawValue))
        else { return }

        context.setFillColor(CGColor(red: 0.05, green: 0.06, blue: 0.09, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let phase = Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 3.0) / 3.0
        let barWidth = Double(width) * 0.18
        let x = phase * (Double(width) + barWidth) - barWidth
        context.setFillColor(CGColor(red: 0.31, green: 0.55, blue: 1.0, alpha: 1))
        context.fill(CGRect(
            x: x,
            y: Double(height) * 0.48,
            width: barWidth,
            height: Double(height) * 0.04))
    }
}

// MARK: - Source stream (what apps consume)

class BeamCamStreamSource: NSObject, CMIOExtensionStreamSource {

    private(set) var stream: CMIOExtensionStream!
    let device: CMIOExtensionDevice
    private let _streamFormat: CMIOExtensionStreamFormat

    init(
        localizedName: String,
        streamID: UUID,
        streamFormat: CMIOExtensionStreamFormat,
        device: CMIOExtensionDevice
    ) {
        self.device = device
        self._streamFormat = streamFormat
        super.init()
        self.stream = CMIOExtensionStream(
            localizedName: localizedName,
            streamID: streamID,
            direction: .source,
            clockType: .hostTime,
            source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [_streamFormat] }

    var activeFormatIndex: Int = 0 {
        didSet {
            if activeFormatIndex >= 1 {
                os_log(.error, "Invalid format index")
            }
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration]
    }

    func streamProperties(
        forProperties properties: Set<CMIOExtensionProperty>
    ) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = 0
        }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = CMTime(value: 1, timescale: kFrameRate)
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let activeFormatIndex = streamProperties.activeFormatIndex {
            self.activeFormatIndex = activeFormatIndex
        }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    func startStream() throws {
        guard let deviceSource = device.source as? BeamCamDeviceSource else {
            fatalError("Unexpected device source type")
        }
        deviceSource.startStreaming()
    }

    func stopStream() throws {
        guard let deviceSource = device.source as? BeamCamDeviceSource else {
            fatalError("Unexpected device source type")
        }
        deviceSource.stopStreaming()
    }
}

// MARK: - Sink stream (what the container app pushes into)

class BeamCamSinkStreamSource: NSObject, CMIOExtensionStreamSource {

    private(set) var stream: CMIOExtensionStream!
    let device: CMIOExtensionDevice
    private let _streamFormat: CMIOExtensionStreamFormat
    private weak var _deviceSource: BeamCamDeviceSource?
    private var _consuming = false
    /// consumeSampleBuffer needs the client that opened the sink, so hold on to
    /// whichever one gets authorized.
    private var _client: CMIOExtensionClient?

    init(
        localizedName: String,
        streamID: UUID,
        streamFormat: CMIOExtensionStreamFormat,
        device: CMIOExtensionDevice,
        deviceSource: BeamCamDeviceSource
    ) {
        self.device = device
        self._streamFormat = streamFormat
        self._deviceSource = deviceSource
        super.init()
        self.stream = CMIOExtensionStream(
            localizedName: localizedName,
            streamID: streamID,
            direction: .sink,
            clockType: .hostTime,
            source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [_streamFormat] }

    var activeFormatIndex: Int = 0

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamSinkBufferQueueSize,
         .streamSinkBuffersRequiredForStartup]
    }

    func streamProperties(
        forProperties properties: Set<CMIOExtensionProperty>
    ) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = 0
        }
        if properties.contains(.streamSinkBufferQueueSize) {
            streamProperties.sinkBufferQueueSize = 3
        }
        if properties.contains(.streamSinkBuffersRequiredForStartup) {
            streamProperties.sinkBuffersRequiredForStartup = 1
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let activeFormatIndex = streamProperties.activeFormatIndex {
            self.activeFormatIndex = activeFormatIndex
        }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        _client = client
        return true
    }

    func startStream() throws {
        guard let client = _client else { return }
        _consuming = true
        consumeNext(from: client)
    }

    func stopStream() throws {
        _consuming = false
    }

    /// The sink is pull-based: each consumed buffer must be followed by another
    /// request, so this re-arms itself until the stream stops.
    private func consumeNext(from client: CMIOExtensionClient) {
        guard _consuming else { return }
        stream.consumeSampleBuffer(from: client) { [weak self] sbuf, _, _, _, error in
            guard let self else { return }
            if let sbuf, error == nil,
               let imageBuffer = CMSampleBufferGetImageBuffer(sbuf) {
                self._deviceSource?.receive(imageBuffer)
            }
            self.consumeNext(from: client)
        }
    }
}
