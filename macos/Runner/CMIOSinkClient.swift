import AVFoundation
import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation

enum BeamCamLog {


    private static let url: URL = {
        let base = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "2U62X3RF3R.com.abdulsaheel.beamcam")
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("beamcam-extension.log")
    }()

    private static let lock = NSLock()

    static func write(_ message: String) {
        NSLog("BeamCam: %@", message)
        lock.lock()
        defer { lock.unlock() }
        guard let data = "\(Date()) \(message)\n".data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

/// Pushes CVPixelBuffers into the camera extension's sink stream over the
/// CoreMediaIO DAL (`CMIO*` C API).
///
/// The two traps worth knowing before reading the rest:
///
///   1. `kCMIODevicePropertyStreams` → the device's `CMIOStreamID`s. Pick the
///      sink by **name** ("BeamCam.Sink"), never by
///      `kCMIOStreamPropertyDirection`. Direction is a trap: measured on this
///      device, "BeamCam.Video" (the source) reports direction=1 and
///      "BeamCam.Sink" reports direction=0, i.e. the header's "0 means output"
///      is relative to the client, not the extension. Picking the source stream
///      by mistake makes the very first enqueue return -12773
///      (kCMSimpleQueueError_QueueIsFull) forever, with the extension never
///      seeing a frame.
///   2. `CMIODeviceStartStream(deviceID, sinkStreamID)` — this is what triggers
///      `startStream()` (and therefore `consumeSampleBuffer`) on the extension's
///      sink. Enqueueing without it fills the queue and delivers nothing.
final class CMIOSinkClient {

    private let lock = NSLock()
    private let queueLabel = DispatchQueue(label: "beamcam.cmio.sink", qos: .userInitiated)

    private var running = false
    private var deviceID: CMIODeviceID = 0
    private var sinkStreamID: CMIOStreamID = 0
    private var sinkQueue: CMSimpleQueue?

    /// Closed after every enqueue, reopened by the queue-altered callback.
    /// cmiod only drains the queue into the extension when the client respects
    /// this handshake; enqueueing ahead of the ack pins the queue at capacity
    /// while the extension receives nothing.
    private var gateOpen = true
    private var enqueuedCount: UInt64 = 0
    private var lastEnqueueAt: TimeInterval = 0
    private let ackTimeout: TimeInterval = 1.5

    private var discoveryTimer: DispatchSourceTimer?
    private var discoveryTicks: UInt64 = 0
    private var formatDescription: CMFormatDescription?

    private(set) var statusText = "idle"

    /// The device's localized name as published by BeamCamProvider.
    private let deviceName = "BeamCam"

    // MARK: - Lifecycle

    func start() {
        lock.lock()
        if running {
            lock.unlock()
            return
        }
        running = true
        lock.unlock()

        setStatus("starting")

        // Opening a CMIO device is camera access as far as TCC is concerned.
        // Fire and forget: discovery retries on a timer either way, so a denied
        // or still-pending prompt never wedges startup.
        AVCaptureDevice.requestAccess(for: .video) { _ in }

        queueLabel.async { [weak self] in
            self?.allowVirtualDeviceVisibility()
            self?.scheduleDiscovery()
        }
    }

    func stop() {
        lock.lock()
        running = false
        let oldDevice = deviceID
        let oldStream = sinkStreamID
        sinkQueue = nil
        deviceID = 0
        sinkStreamID = 0
        gateOpen = true
        enqueuedCount = 0
        lastEnqueueAt = 0
        lock.unlock()

        queueLabel.async { [weak self] in
            self?.discoveryTimer?.cancel()
            self?.discoveryTimer = nil
        }

        if oldDevice != 0 && oldStream != 0 {
            CMIODeviceStopStream(oldDevice, oldStream)
        }
        setStatus("stopped")
    }

    // MARK: - Frame push

    /// Wraps `pixelBuffer` (32BGRA, extension-sized) in a CMSampleBuffer and
    /// enqueues it. Safe to call from any thread; drops frames rather than
    /// blocking whenever the sink is not ready.
    func push(_ pixelBuffer: CVPixelBuffer) {
        let now = Date().timeIntervalSince1970

        lock.lock()
        let isRunning = running
        let queue = sinkQueue
        let canEnqueue = gateOpen
        let stalled = !gateOpen && lastEnqueueAt > 0 && (now - lastEnqueueAt) > ackTimeout
        if stalled {
            // cmiod never acked. Either the extension's sink is not consuming or
            // we latched onto the wrong stream — rediscover rather than pile up.
            lock.unlock()
            resetConnection(reason: "no queue-altered ack within \(ackTimeout)s")
            return
        }
        lock.unlock()

        guard isRunning, let queue, canEnqueue else { return }

        let capacity = CMSimpleQueueGetCapacity(queue)
        let depth = CMSimpleQueueGetCount(queue)
        guard capacity > 0, depth < capacity else {
            resetConnection(reason: "sink queue full before enqueue (depth=\(depth) cap=\(capacity))")
            return
        }

        guard let sampleBuffer = makeSampleBuffer(from: pixelBuffer) else { return }

        let unmanaged = Unmanaged.passRetained(sampleBuffer)
        let status = CMSimpleQueueEnqueue(queue, element: unmanaged.toOpaque())
        guard status == noErr else {
            unmanaged.release()
            resetConnection(reason: "CMSimpleQueueEnqueue failed status=\(status)")
            return
        }

        lock.lock()
        gateOpen = false
        enqueuedCount &+= 1
        let count = enqueuedCount
        lastEnqueueAt = now
        lock.unlock()

        if count == 1 {
            setStatus("streaming")
            BeamCamLog.write("sink: first frame enqueued")
        } else if count % 300 == 0 {
            BeamCamLog.write("sink: \(count) frames enqueued")
        }
    }

    private func makeSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        if formatDescription == nil
            || !CMVideoFormatDescriptionMatchesImageBuffer(
                formatDescription!, imageBuffer: pixelBuffer) {
            var description: CMFormatDescription?
            let status = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &description)
            guard status == noErr, description != nil else { return nil }
            formatDescription = description
        }

        var timingInfo = CMSampleTimingInfo()
        timingInfo.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock())
        timingInfo.duration = .invalid
        timingInfo.decodeTimeStamp = .invalid

        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription!,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer)
        guard status == noErr else { return nil }
        return sampleBuffer
    }

    // MARK: - Discovery

    private func scheduleDiscovery() {
        discoveryTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queueLabel)
        timer.schedule(deadline: .now(), repeating: 1.0)
        timer.setEventHandler { [weak self] in self?.discoverTick() }
        timer.resume()
        discoveryTimer = timer
    }

    private func discoverTick() {
        lock.lock()
        let isRunning = running
        let alreadyConnected = sinkQueue != nil
        lock.unlock()

        guard isRunning else { return }
        if alreadyConnected {
            discoveryTimer?.cancel()
            discoveryTimer = nil
            return
        }

        discoveryTicks &+= 1
        // Discovery retries for the life of the app (the extension may not be
        // installed yet), so keep the dump to the first attempt and then a
        // once-a-minute heartbeat rather than filling the log at 1 Hz.
        let verbose = discoveryTicks == 1 || discoveryTicks % 60 == 0

        allowVirtualDeviceVisibility()

        guard let device = findDevice(verbose: verbose) else {
            if verbose {
                BeamCamLog.write("sink: no CMIO device named \"\(deviceName)\" yet (tick \(discoveryTicks))")
            }
            return
        }

        guard let stream = findSinkStream(deviceID: device, verbose: verbose) else {
            if verbose {
                BeamCamLog.write("sink: device 0x\(String(device, radix: 16)) has no sink stream yet")
            }
            return
        }

        guard let queue = copyBufferQueue(streamID: stream) else {
            BeamCamLog.write("sink: CMIOStreamCopyBufferQueue failed for stream \(stream)")
            return
        }

        let startStatus = CMIODeviceStartStream(device, stream)
        guard startStatus == noErr else {
            BeamCamLog.write("sink: CMIODeviceStartStream failed status=\(startStatus)")
            return
        }

        lock.lock()
        deviceID = device
        sinkStreamID = stream
        sinkQueue = queue
        gateOpen = true
        enqueuedCount = 0
        lastEnqueueAt = 0
        lock.unlock()

        discoveryTimer?.cancel()
        discoveryTimer = nil
        discoveryTicks = 0

        BeamCamLog.write(
            "sink: connected device=0x\(String(device, radix: 16)) stream=\(stream) "
            + "queue cap=\(CMSimpleQueueGetCapacity(queue))")
        setStatus("connected")
    }

    private func resetConnection(reason: String) {
        lock.lock()
        let shouldRestart = running
        let oldDevice = deviceID
        let oldStream = sinkStreamID
        sinkQueue = nil
        deviceID = 0
        sinkStreamID = 0
        gateOpen = true
        enqueuedCount = 0
        lastEnqueueAt = 0
        lock.unlock()

        if oldDevice != 0 && oldStream != 0 {
            CMIODeviceStopStream(oldDevice, oldStream)
        }
        BeamCamLog.write("sink: reset — \(reason)")
        setStatus("reconnecting")

        if shouldRestart {
            queueLabel.async { [weak self] in
                self?.discoveryTicks = 0
                self?.scheduleDiscovery()
            }
        }
    }

    // MARK: - CMIO plumbing

    /// Without this the DAL will not list virtual / system-extension cameras in
    /// this process' device enumeration, so discovery finds nothing at all.
    private func allowVirtualDeviceVisibility() {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var allow: UInt32 = 1
        CMIOObjectSetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject),
            &address, 0, nil,
            UInt32(MemoryLayout<UInt32>.size),
            &allow)
    }

    private func findDevice(verbose: Bool) -> CMIODeviceID? {
        // A second identifier to match on, in case the localized name that
        // reaches the DAL differs from what the extension published.
        let avUniqueID = avCaptureUniqueID()

        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))

        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(
            CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &dataSize) == noErr,
            dataSize > 0
        else { return nil }

        let count = Int(dataSize) / MemoryLayout<CMIODeviceID>.size
        var devices = [CMIODeviceID](repeating: 0, count: count)
        var dataUsed: UInt32 = 0
        guard CMIOObjectGetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil,
            dataSize, &dataUsed, &devices) == noErr
        else { return nil }

        var match: CMIODeviceID?
        for device in devices {
            let name = stringProperty(
                object: device,
                selector: CMIOObjectPropertySelector(kCMIOObjectPropertyName)) ?? ""
            let uid = stringProperty(
                object: device,
                selector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID)) ?? ""
            if verbose {
                BeamCamLog.write("sink: HAL device 0x\(String(device, radix: 16)) name=\"\(name)\" uid=\"\(uid)\"")
            }
            guard match == nil else { continue }
            if name == deviceName || name.hasPrefix(deviceName) {
                match = device
            } else if let avUniqueID, !avUniqueID.isEmpty, uid == avUniqueID {
                match = device
            }
        }
        return match
    }

    private func avCaptureUniqueID() -> String? {
        var types: [AVCaptureDevice.DeviceType] = []
        if #available(macOS 14.0, *) {
            types.append(.external)
        }
        types.append(.externalUnknown)
        types.append(.builtInWideAngleCamera)

        // DiscoverySession buckets virtual cameras inconsistently across macOS
        // releases, hence the wide type list. This is only a secondary matcher —
        // the HAL name comparison above is what normally finds the device.
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: types, mediaType: .video, position: .unspecified)
        return session.devices
            .first(where: { $0.localizedName.hasPrefix(deviceName) })?.uniqueID
    }

    private func findSinkStream(deviceID: CMIODeviceID, verbose: Bool) -> CMIOStreamID? {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyStreams),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))

        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0
        else { return nil }

        let count = Int(dataSize) / MemoryLayout<CMIOStreamID>.size
        var streams = [CMIOStreamID](repeating: 0, count: count)
        var dataUsed: UInt32 = 0
        guard CMIOObjectGetPropertyData(
            deviceID, &address, 0, nil, dataSize, &dataUsed, &streams) == noErr
        else { return nil }

        var byName: CMIOStreamID?

        for (index, stream) in streams.enumerated() {
            let name = stringProperty(
                object: stream,
                selector: CMIOObjectPropertySelector(kCMIOObjectPropertyName)) ?? "<noname>"
            let direction = uint32Property(
                object: stream,
                selector: CMIOObjectPropertySelector(kCMIOStreamPropertyDirection))
            if verbose {
                BeamCamLog.write(
                    "sink: stream candidate index=\(index) id=\(stream) name=\"\(name)\" "
                    + "direction=\(direction.map(String.init) ?? "nil")")
            }
            if byName == nil, name.range(of: "sink", options: .caseInsensitive) != nil {
                byName = stream
            }
        }

        return byName
    }

    private func copyBufferQueue(streamID: CMIOStreamID) -> CMSimpleQueue? {
        var queue: Unmanaged<CMSimpleQueue>?
        let refCon = Unmanaged.passUnretained(self).toOpaque()
        let alteredProc: CMIODeviceStreamQueueAlteredProc = { _, _, refCon in
            guard let refCon else { return }
            Unmanaged<CMIOSinkClient>.fromOpaque(refCon).takeUnretainedValue().onQueueAltered()
        }
        let status = CMIOStreamCopyBufferQueue(streamID, alteredProc, refCon, &queue)
        guard status == noErr else { return nil }
        return queue?.takeRetainedValue()
    }

    /// cmiod calls this once it has removed a buffer from the sink queue and
    /// handed it to the extension. That is the signal to send the next frame.
    private func onQueueAltered() {
        lock.lock()
        gateOpen = true
        lock.unlock()
    }

    // MARK: - Property helpers

    private func stringProperty(
        object: CMIOObjectID,
        selector: CMIOObjectPropertySelector
    ) -> String? {
        var address = CMIOObjectPropertyAddress(
            mSelector: selector,
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0
        else { return nil }

        var value: CFString?
        var dataUsed: UInt32 = 0
        let status = withUnsafeMutablePointer(to: &value) { pointer -> OSStatus in
            CMIOObjectGetPropertyData(object, &address, 0, nil, dataSize, &dataUsed, pointer)
        }
        guard status == noErr else { return nil }
        return value as String?
    }

    private func uint32Property(
        object: CMIOObjectID,
        selector: CMIOObjectPropertySelector
    ) -> UInt32? {
        var address = CMIOObjectPropertyAddress(
            mSelector: selector,
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var value: UInt32 = 0
        var dataUsed: UInt32 = 0
        let status = CMIOObjectGetPropertyData(
            object, &address, 0, nil,
            UInt32(MemoryLayout<UInt32>.size), &dataUsed, &value)
        guard status == noErr else { return nil }
        return value
    }

    private func setStatus(_ text: String) {
        lock.lock()
        statusText = text
        lock.unlock()
        onStatusChange?(text)
    }

    var onStatusChange: ((String) -> Void)?
}
