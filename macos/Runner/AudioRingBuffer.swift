import Foundation

/// Producer side of the shared-memory ring the BeamCamAudioPlugIn HAL driver
/// reads from (macos/AudioDriver/BeamCamAudioRing.h — byte layout MUST match
/// that header exactly; kept in sync by hand, no shared source of truth).
///
/// World read/write (see Release.entitlements) so this process and coreaudiod
/// — different users, no XPC/Mach service between them — can both reach it.
/// Writes are silently dropped if the file doesn't exist yet (driver not
/// installed), same tolerance CMIOSinkClient has for the camera extension.
final class AudioRingBuffer {

    static let shared = AudioRingBuffer()

    private static let path = "/Library/Application Support/BeamCam/beamcam-audio.ring"
    private static let headerBytes = 32
    private static let sampleRate: UInt32 = 48_000
    private static let channels: UInt32 = 2
    private static let frameCapacity: UInt32 = 48_000 * 2 // 2 seconds
    private static let magic: UInt32 = 0x52414342 // 'BCAR' little-endian, matches the C header

    private var fd: Int32 = -1
    private var map: UnsafeMutableRawPointer?
    private var mapSize = 0
    private let lock = NSLock()

    private var opened = false

    /// Best-effort open; safe to call repeatedly (fails cheaply while the
    /// driver isn't installed yet).
    private func openIfNeeded() -> Bool {
        if map != nil { return true }
        guard !opened || fd < 0 else { return false }

        let totalBytes = Int(Self.headerBytes) + Int(Self.frameCapacity * Self.channels) * MemoryLayout<Float>.size
        let handle = open(Self.path, O_RDWR)
        guard handle >= 0 else { return false }

        let mapped = mmap(nil, totalBytes, PROT_READ | PROT_WRITE, MAP_SHARED, handle, 0)
        guard mapped != MAP_FAILED, let mapped else {
            Darwin.close(handle)
            return false
        }

        fd = handle
        map = mapped
        mapSize = totalBytes

        // Header is only meaningful once; the driver only ever reads it, and
        // re-stamping on every relaunch is harmless (single writer).
        let header = mapped.assumingMemoryBound(to: UInt32.self)
        header[0] = Self.magic
        header[1] = Self.sampleRate
        header[2] = Self.channels
        header[3] = Self.frameCapacity
        let writeIndexPtr = mapped.advanced(by: 16).assumingMemoryBound(to: UInt64.self)
        writeIndexPtr.pointee = 0

        opened = true
        BeamCamLog.write("audioring: opened \(Self.path)")
        return true
    }

    /// Appends interleaved Float32 frames (kChannels per frame) to the ring.
    /// Never blocks; drops (advances past) data if the driver isn't reading —
    /// same "newest frame wins" policy CMIOSinkClient.push uses for video.
    func write(interleaved frames: UnsafePointer<Float>, frameCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard openIfNeeded(), let map else { return }

        let dataBase = map.advanced(by: Int(Self.headerBytes)).assumingMemoryBound(to: Float.self)
        let writeIndexPtr = map.advanced(by: 16).assumingMemoryBound(to: UInt64.self)
        var index = writeIndexPtr.pointee

        for i in 0..<frameCount {
            let ringFrame = Int(index % UInt64(Self.frameCapacity))
            let dst = dataBase.advanced(by: ringFrame * Int(Self.channels))
            let src = frames.advanced(by: i * Int(Self.channels))
            dst.update(from: src, count: Int(Self.channels))
            index &+= 1
        }
        writeIndexPtr.pointee = index
    }

    /// Called when the audio sink stops so a reinstalled driver or app
    /// relaunch reopens cleanly instead of holding a stale fd.
    func close() {
        lock.lock()
        defer { lock.unlock() }
        if let map { munmap(map, mapSize) }
        map = nil
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
        opened = false
    }
}
