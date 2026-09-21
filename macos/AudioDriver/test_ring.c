// Self-check for the ring-buffer indexing math shared by hand between
// AudioRingBuffer.swift (producer) and BeamCamAudioPlugIn.c's ReadFrames
// (consumer). Exercises the same wraparound/catch-up arithmetic against
// plain memory, without CoreAudio, coreaudiod, or root.
//
// Run: clang -o /tmp/test_ring macos/AudioDriver/test_ring.c && /tmp/test_ring
#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "BeamCamAudioRing.h"

// Mirrors BeamCamAudioPlugIn.c's ReadFrames against a plain in-memory buffer,
// with the read cursor passed in/out instead of held in global state.
static void ReadFrames(
    const float* ringData, uint64_t writeIndex,
    uint64_t* readIndex, int* readIndexValid,
    float* outFrames, uint32_t frameCount) {

    if (!*readIndexValid) {
        uint64_t lookback = kBeamCamAudioFrameCapacity / 4;
        *readIndex = (writeIndex > lookback) ? (writeIndex - lookback) : 0;
        *readIndexValid = 1;
    }

    uint64_t available = (writeIndex > *readIndex) ? (writeIndex - *readIndex) : 0;
    if (available > kBeamCamAudioFrameCapacity) {
        *readIndex = writeIndex - (kBeamCamAudioFrameCapacity / 2);
        available = kBeamCamAudioFrameCapacity / 2;
    }

    uint32_t toCopy = (uint32_t)((available < frameCount) ? available : frameCount);
    for (uint32_t i = 0; i < toCopy; i++) {
        uint64_t ringFrame = (*readIndex + i) % kBeamCamAudioFrameCapacity;
        memcpy(&outFrames[i * kBeamCamAudioChannels],
               &ringData[ringFrame * kBeamCamAudioChannels],
               kBeamCamAudioChannels * sizeof(float));
    }
    if (toCopy < frameCount) {
        memset(&outFrames[toCopy * kBeamCamAudioChannels], 0,
               (size_t)(frameCount - toCopy) * kBeamCamAudioChannels * sizeof(float));
    }
    *readIndex += toCopy;
}

int main(void) {
    static float ring[kBeamCamAudioFrameCapacity * kBeamCamAudioChannels];

    // 1. Header size/offset sanity: AudioRingBuffer.swift hardcodes these
    //    same numbers. Tripwire for the two sides drifting apart.
    assert(kBeamCamAudioHeaderBytes == 32);
    assert(offsetof(BeamCamAudioRingHeader, writeIndex) == 16);
    assert(sizeof(BeamCamAudioRingHeader) <= kBeamCamAudioHeaderBytes);

    // 2. Fresh ring, no writer yet: no crash/garbage, readIndex lands at 0.
    uint64_t readIndex = 0;
    int readIndexValid = 0;
    float out[128 * kBeamCamAudioChannels];
    ReadFrames(ring, /*writeIndex=*/0, &readIndex, &readIndexValid, out, 128);
    assert(readIndexValid == 1);
    assert(readIndex == 0);

    // 3. Writer already ahead by more than a lookback: reader starts
    //    "lookback" behind it rather than falling permanently behind.
    readIndexValid = 0;
    uint64_t lookback = kBeamCamAudioFrameCapacity / 4;
    uint64_t writeIndex = lookback + 10000;
    ReadFrames(ring, writeIndex, &readIndex, &readIndexValid, out, 128);
    uint64_t expectedStart = writeIndex - lookback;
    assert(readIndex == expectedStart + 128);

    // 4. Writer lapped the reader by more than the ring's capacity: the
    //    catch-up branch must fire instead of replaying overwritten frames.
    readIndex = 0;
    readIndexValid = 1;
    writeIndex = (uint64_t)kBeamCamAudioFrameCapacity * 5;
    ReadFrames(ring, writeIndex, &readIndex, &readIndexValid, out, 128);
    assert(readIndex > writeIndex - kBeamCamAudioFrameCapacity);
    assert(readIndex <= writeIndex);

    // 5. Underrun (available == 0): silence-fill, not garbage or div-by-zero.
    readIndex = 500;
    readIndexValid = 1;
    memset(out, 0x7F, sizeof(out)); // poison
    ReadFrames(ring, /*writeIndex=*/500, &readIndex, &readIndexValid, out, 64);
    for (int i = 0; i < 64 * (int)kBeamCamAudioChannels; i++) {
        assert(out[i] == 0.0f);
    }
    assert(readIndex == 500); // nothing consumed on a pure underrun

    // 6. Wraparound: reading across the wrap point stitches frame N-1 and
    //    frame 0 back together correctly.
    memset(ring, 0, sizeof(ring));
    uint64_t lastFrame = kBeamCamAudioFrameCapacity - 1;
    ring[lastFrame * kBeamCamAudioChannels + 0] = 1.0f;
    ring[0 * kBeamCamAudioChannels + 0] = 2.0f; // wrapped position
    readIndex = lastFrame;
    readIndexValid = 1;
    ReadFrames(ring, lastFrame + 2, &readIndex, &readIndexValid, out, 2);
    assert(out[0] == 1.0f);
    assert(out[kBeamCamAudioChannels] == 2.0f);

    printf("test_ring: all checks passed\n");
    return 0;
}
