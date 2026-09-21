#ifndef BeamCamAudioRing_h
#define BeamCamAudioRing_h

#include <stdint.h>

/*
 * Shared-memory transport between the Runner app (producer, see
 * AudioRingBuffer.swift) and this AudioServerPlugIn driver (consumer, see
 * BeamCamAudioPlugIn.c). A fixed-path, world-readable/writable file that both
 * this process and coreaudiod (its own user) can mmap — no XPC/Mach service
 * between them.
 *
 * ponytail: single-producer/single-consumer ring, plain (non-atomic)
 * uint32/uint64 fields. Relies on aligned 4/8-byte loads/stores being atomic
 * on arm64/x86_64 and exactly one writer + one reader. No memory fences, no
 * wraparound version counter. Upgrade to _Atomic with explicit ordering if
 * real hardware shows audible glitches.
 *
 * Layout, must match exactly on both sides:
 *   offset  0: uint32 magic           ('B','C','A','R' packed little-endian)
 *   offset  4: uint32 sampleRate      (fixed at kBeamCamAudioSampleRate)
 *   offset  8: uint32 channels        (fixed at kBeamCamAudioChannels)
 *   offset 12: uint32 frameCapacity   (ring length in frames, not bytes)
 *   offset 16: uint64 writeIndex      (frames written, monotonically increasing)
 *   offset 24: uint64 reserved        (padding to a 32-byte header)
 *   offset 32: frameCapacity * channels * sizeof(float) bytes of interleaved
 *              Float32 PCM, indexed as data[(frameIndex % frameCapacity) *
 *              channels + channel]
 */

#define kBeamCamAudioRingMagic     0x52414342u /* 'BCAR' little-endian */
#define kBeamCamAudioSampleRate    48000u
#define kBeamCamAudioChannels      2u
#define kBeamCamAudioRingSeconds   2u
#define kBeamCamAudioFrameCapacity (kBeamCamAudioSampleRate * kBeamCamAudioRingSeconds)
#define kBeamCamAudioHeaderBytes   32u
#define kBeamCamAudioRingPath      "/Library/Application Support/BeamCam/beamcam-audio.ring"

typedef struct {
    uint32_t magic;
    uint32_t sampleRate;
    uint32_t channels;
    uint32_t frameCapacity;
    uint64_t writeIndex;
    uint64_t reserved;
} BeamCamAudioRingHeader;

static inline uint64_t BeamCamAudioRingTotalBytes(void) {
    return (uint64_t)kBeamCamAudioHeaderBytes
        + (uint64_t)kBeamCamAudioFrameCapacity * kBeamCamAudioChannels * sizeof(float);
}

#endif /* BeamCamAudioRing_h */
