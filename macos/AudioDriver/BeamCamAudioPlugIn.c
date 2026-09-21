/*
 * BeamCamAudioPlugIn.c
 *
 * A minimal AudioServerPlugIn (legacy HAL driver, not a System Extension —
 * see add_audio_driver.rb). Publishes one virtual *input* device,
 * "BeamCam Microphone", with a single Float32 48kHz stereo stream. No output
 * stream, no controls — ponytail: the minimum for a selectable input device;
 * add volume/mute only if a real conferencing app needs it.
 *
 * Frames come from a shared-memory ring (BeamCamAudioRing.h) written by the
 * Runner app (AudioRingBuffer.swift / WebRTCAudioBridge.swift); this driver
 * only reads it in DoIOOperation. The device UID is a fixed constant string,
 * not a per-launch UUID, so reinstalling the driver keeps the same device
 * identity across a coreaudiod restart instead of macOS treating it as new.
 */

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreAudio/AudioHardware.h>
#include <math.h>
#include <CoreFoundation/CoreFoundation.h>
#include <pthread.h>
#include <mach/mach_time.h>
#include <string.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>

#include "BeamCamAudioRing.h"
#include <os/log.h>

static void DebugLog(const char* msg) {
    os_log(OS_LOG_DEFAULT, "BeamCamAudioPlugIn: %{public}s", msg);
}

#pragma mark - Object IDs

enum {
    kObjectID_PlugIn        = kAudioObjectPlugInObject,
    kObjectID_Device        = 2,
    kObjectID_Stream_Input  = 3,
};

static const char* const kDeviceUID        = "com.abdulsaheel.beamcam.audio";
static const char* const kDeviceModelUID   = "com.abdulsaheel.beamcam.audio.model";
static const char* const kDeviceName       = "BeamCam Microphone";
static const char* const kManufacturer     = "Jovaris Tech";
static const char* const kBundleID         = "com.abdulsaheel.beamcam.AudioDriver";

/// Frames per IO cycle we advertise; coreaudiod may ask for other sizes but
/// this is the nominal/default.
static const UInt32 kDefaultIOBufferFrameSize = 512;

/// kAudioDevicePropertyZeroTimeStampPeriod: sample frames between successive
/// GetZeroTimeStamp() times. NOT optional — the HAL sizes its IO ring from
/// this value, so answering 0 produces a zero-capacity queue and an
/// AVFoundation -11800 (kCMSimpleQueueError_ParameterOutOfRange) with
/// StartIO never reached. 16384 matches Apple's sample drivers and fits the
/// ring's 96000-frame capacity; GetZeroTimeStamp() must advance in this step.
static const UInt32 kZeroTimeStampPeriod = 16384;

#pragma mark - Driver state

typedef struct {
    pthread_mutex_t lock;

    AudioServerPlugInHostRef host;

    Boolean deviceIsAlive;
    UInt32  startCount;          // number of clients that have called StartIO
    Float64 sampleRate;          // fixed at kBeamCamAudioSampleRate

    // GetZeroTimeStamp bookkeeping — a simple free-running clock anchored the
    // first time IO starts, matching the shape of Apple's own sample drivers.
    Float64 hostTicksPerFrame;
    UInt64  anchorHostTime;
    Float64 anchorSampleTime;
    UInt32  ioBufferFrameSize;

    // Shared-memory ring, mapped read-only from this side.
    int       ringFD;
    void*     ringMap;
    uint64_t  ringMapSize;
    uint64_t  readIndex;         // this driver's own consumer cursor
    Boolean   readIndexValid;
} BeamCamAudioDriverState;

static BeamCamAudioDriverState gState;

#pragma mark - Ring buffer (consumer side)

static Boolean OpenRingIfNeeded(void) {
    if (gState.ringMap != NULL) return true;

    int fd = open(kBeamCamAudioRingPath, O_RDONLY);
    if (fd < 0) return false;

    uint64_t size = BeamCamAudioRingTotalBytes();
    void* map = mmap(NULL, (size_t)size, PROT_READ, MAP_SHARED, fd, 0);
    if (map == MAP_FAILED) {
        close(fd);
        return false;
    }

    const BeamCamAudioRingHeader* header = (const BeamCamAudioRingHeader*)map;
    if (header->magic != kBeamCamAudioRingMagic
        || header->channels != kBeamCamAudioChannels
        || header->frameCapacity != kBeamCamAudioFrameCapacity) {
        munmap(map, (size_t)size);
        close(fd);
        return false;
    }

    gState.ringFD = fd;
    gState.ringMap = map;
    gState.ringMapSize = size;
    gState.readIndexValid = false;
    return true;
}

static void CloseRing(void) {
    if (gState.ringMap != NULL) {
        munmap(gState.ringMap, (size_t)gState.ringMapSize);
        gState.ringMap = NULL;
    }
    if (gState.ringFD >= 0) {
        close(gState.ringFD);
        gState.ringFD = -1;
    }
}

/// Fills `outFrames` with the next `frameCount` frames from the ring, or
/// silence when the ring isn't open yet or the driver has fallen behind.
///
/// ponytail: no jitter buffer, no timestamp alignment — just "give me
/// whatever the writer has, or silence." Revisit if real audio glitches.
/// Locked against gState.lock: StartIO/StopIO mutate ringMap/ringFD/readIndex
/// under the same lock, since CloseRing on the last StopIO could otherwise
/// munmap mid-flight while this IO thread is still reading.
static void ReadFrames(Float32* outFrames, UInt32 frameCount) {
    pthread_mutex_lock(&gState.lock);
    if (!OpenRingIfNeeded()) {
        pthread_mutex_unlock(&gState.lock);
        memset(outFrames, 0, (size_t)frameCount * kBeamCamAudioChannels * sizeof(Float32));
        return;
    }

    BeamCamAudioRingHeader* header = (BeamCamAudioRingHeader*)gState.ringMap;
    Float32* data = (Float32*)((uint8_t*)gState.ringMap + kBeamCamAudioHeaderBytes);
    uint64_t writeIndex = header->writeIndex;

    if (!gState.readIndexValid) {
        // First read: start a little behind the writer so we are not racing
        // it immediately, then let the steady-state logic below take over.
        uint64_t lookback = kBeamCamAudioFrameCapacity / 4;
        gState.readIndex = (writeIndex > lookback) ? (writeIndex - lookback) : 0;
        gState.readIndexValid = true;
    }

    uint64_t available = (writeIndex > gState.readIndex) ? (writeIndex - gState.readIndex) : 0;
    if (available > kBeamCamAudioFrameCapacity) {
        // We fell behind by more than the ring holds (writer lapped us).
        // Catch up rather than replaying stale/overwritten frames.
        gState.readIndex = writeIndex - (kBeamCamAudioFrameCapacity / 2);
        available = kBeamCamAudioFrameCapacity / 2;
    }

    UInt32 toCopy = (UInt32)((available < frameCount) ? available : frameCount);
    for (UInt32 i = 0; i < toCopy; i++) {
        uint64_t ringFrame = (gState.readIndex + i) % kBeamCamAudioFrameCapacity;
        memcpy(&outFrames[i * kBeamCamAudioChannels],
               &data[ringFrame * kBeamCamAudioChannels],
               kBeamCamAudioChannels * sizeof(Float32));
    }
    if (toCopy < frameCount) {
        // Underrun (nothing pushed recently, e.g. mic toggled off) — silence
        // fills the rest rather than repeating old audio.
        memset(&outFrames[toCopy * kBeamCamAudioChannels], 0,
               (size_t)(frameCount - toCopy) * kBeamCamAudioChannels * sizeof(Float32));
    }
    gState.readIndex += toCopy;
    pthread_mutex_unlock(&gState.lock);
}

#pragma mark - CFString / CFDictionary helpers

static CFStringRef CopyCFString(const char* s) {
    return CFStringCreateWithCString(kCFAllocatorDefault, s, kCFStringEncodingUTF8);
}

#pragma mark - IUnknown

static HRESULT BeamCamAudio_QueryInterface(void* driver, REFIID uuid, LPVOID* outInterface);
static ULONG   BeamCamAudio_AddRef(void* driver);
static ULONG   BeamCamAudio_Release(void* driver);

#pragma mark - Basic operations

static OSStatus BeamCamAudio_Initialize(AudioServerPlugInDriverRef driver, AudioServerPlugInHostRef host);
static OSStatus BeamCamAudio_CreateDevice(AudioServerPlugInDriverRef driver, CFDictionaryRef desc,
    const AudioServerPlugInClientInfo* clientInfo, AudioObjectID* outDeviceObjectID);
static OSStatus BeamCamAudio_DestroyDevice(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID);
static OSStatus BeamCamAudio_AddDeviceClient(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID,
    const AudioServerPlugInClientInfo* clientInfo);
static OSStatus BeamCamAudio_RemoveDeviceClient(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID,
    const AudioServerPlugInClientInfo* clientInfo);
static OSStatus BeamCamAudio_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef driver,
    AudioObjectID deviceObjectID, UInt64 changeAction, void* changeInfo);
static OSStatus BeamCamAudio_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef driver,
    AudioObjectID deviceObjectID, UInt64 changeAction, void* changeInfo);

#pragma mark - Property operations

static Boolean BeamCamAudio_HasProperty(AudioServerPlugInDriverRef driver, AudioObjectID objectID,
    pid_t clientPID, const AudioObjectPropertyAddress* address);
static OSStatus BeamCamAudio_IsPropertySettable(AudioServerPlugInDriverRef driver, AudioObjectID objectID,
    pid_t clientPID, const AudioObjectPropertyAddress* address, Boolean* outIsSettable);
static OSStatus BeamCamAudio_GetPropertyDataSize(AudioServerPlugInDriverRef driver, AudioObjectID objectID,
    pid_t clientPID, const AudioObjectPropertyAddress* address, UInt32 qualifierSize,
    const void* qualifierData, UInt32* outDataSize);
static OSStatus BeamCamAudio_GetPropertyData(AudioServerPlugInDriverRef driver, AudioObjectID objectID,
    pid_t clientPID, const AudioObjectPropertyAddress* address, UInt32 qualifierSize,
    const void* qualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus BeamCamAudio_SetPropertyData(AudioServerPlugInDriverRef driver, AudioObjectID objectID,
    pid_t clientPID, const AudioObjectPropertyAddress* address, UInt32 qualifierSize,
    const void* qualifierData, UInt32 dataSize, const void* data);

#pragma mark - IO operations

static OSStatus BeamCamAudio_StartIO(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID);
static OSStatus BeamCamAudio_StopIO(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID);
static OSStatus BeamCamAudio_GetZeroTimeStamp(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID,
    UInt32 clientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed);
static OSStatus BeamCamAudio_WillDoIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID,
    UInt32 clientID, UInt32 operationID, Boolean* outWillDo, Boolean* outWillDoInPlace);
static OSStatus BeamCamAudio_BeginIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID,
    UInt32 clientID, UInt32 operationID, UInt32 ioBufferFrameSize, const AudioServerPlugInIOCycleInfo* cycleInfo);
static OSStatus BeamCamAudio_DoIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID,
    AudioObjectID streamObjectID, UInt32 clientID, UInt32 operationID, UInt32 ioBufferFrameSize,
    const AudioServerPlugInIOCycleInfo* cycleInfo, void* mainBuffer, void* secondaryBuffer);
static OSStatus BeamCamAudio_EndIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID,
    UInt32 clientID, UInt32 operationID, UInt32 ioBufferFrameSize, const AudioServerPlugInIOCycleInfo* cycleInfo);

#pragma mark - vtable

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    BeamCamAudio_QueryInterface,
    BeamCamAudio_AddRef,
    BeamCamAudio_Release,
    BeamCamAudio_Initialize,
    BeamCamAudio_CreateDevice,
    BeamCamAudio_DestroyDevice,
    BeamCamAudio_AddDeviceClient,
    BeamCamAudio_RemoveDeviceClient,
    BeamCamAudio_PerformDeviceConfigurationChange,
    BeamCamAudio_AbortDeviceConfigurationChange,
    BeamCamAudio_HasProperty,
    BeamCamAudio_IsPropertySettable,
    BeamCamAudio_GetPropertyDataSize,
    BeamCamAudio_GetPropertyData,
    BeamCamAudio_SetPropertyData,
    BeamCamAudio_StartIO,
    BeamCamAudio_StopIO,
    BeamCamAudio_GetZeroTimeStamp,
    BeamCamAudio_WillDoIOOperation,
    BeamCamAudio_BeginIOOperation,
    BeamCamAudio_DoIOOperation,
    BeamCamAudio_EndIOOperation,
};

static AudioServerPlugInDriverInterface* gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;

#pragma mark - IUnknown implementation

// ponytail/grey-route: macOS 26's Core-Audio-Driver-Service probes an
// undocumented private interface UUID (EEA5773D-CC43-49F1-8E00-8F96E7D23B17,
// not in any public CoreAudio header) as its first QueryInterface call and
// fails the whole load on E_NOINTERFACE — it never falls back to the public
// kAudioServerPlugInTypeUUID. Handing back this same interface for ANY
// requested UUID is the pragmatic fix (BlackHole 2ch hits the same probe and
// tolerates it too); risk is bounded since each driver loads into its own
// isolated Core-Audio-Driver-Service.helper process. Upgrade path: a real
// implementation of that private interface once Apple documents it, or
// AudioDriverKit.
static HRESULT BeamCamAudio_QueryInterface(void* driver, REFIID uuid, LPVOID* outInterface) {
    DebugLog("QueryInterface called");
    if (outInterface == NULL) return E_INVALIDARG;
    BeamCamAudio_AddRef(driver);
    *outInterface = gDriverRef;
    return S_OK;
}

/// ponytail: single static instance, refcount is a no-op counter rather than
/// real teardown — this plugin lives for the lifetime of coreaudiod having it
/// loaded, which is the same lifetime as the process. Nothing meaningfully
/// deallocates until unload.
static ULONG BeamCamAudio_AddRef(void* driver)  { return 1; }
static ULONG BeamCamAudio_Release(void* driver) { return 1; }

#pragma mark - Basic operations

static OSStatus BeamCamAudio_Initialize(AudioServerPlugInDriverRef driver, AudioServerPlugInHostRef host) {
    DebugLog("Initialize called");
    pthread_mutex_init(&gState.lock, NULL);
    gState.host = host;
    gState.deviceIsAlive = true;
    gState.startCount = 0;
    gState.sampleRate = kBeamCamAudioSampleRate;
    gState.ioBufferFrameSize = kDefaultIOBufferFrameSize;
    gState.ringFD = -1;
    gState.ringMap = NULL;
    gState.readIndexValid = false;

    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    // Host ticks per frame at our fixed sample rate, used by GetZeroTimeStamp.
    Float64 nanosPerFrame = 1.0e9 / kBeamCamAudioSampleRate;
    gState.hostTicksPerFrame = nanosPerFrame * (Float64)timebase.denom / (Float64)timebase.numer;
    return kAudioHardwareNoError;
}

// No dynamic device creation/destruction — the one device is always present.
static OSStatus BeamCamAudio_CreateDevice(AudioServerPlugInDriverRef driver, CFDictionaryRef desc,
    const AudioServerPlugInClientInfo* clientInfo, AudioObjectID* outDeviceObjectID) {
    return kAudioHardwareUnsupportedOperationError;
}
static OSStatus BeamCamAudio_DestroyDevice(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID) {
    return kAudioHardwareUnsupportedOperationError;
}
static OSStatus BeamCamAudio_AddDeviceClient(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID,
    const AudioServerPlugInClientInfo* clientInfo) {
    return kAudioHardwareNoError;
}
static OSStatus BeamCamAudio_RemoveDeviceClient(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID,
    const AudioServerPlugInClientInfo* clientInfo) {
    return kAudioHardwareNoError;
}
static OSStatus BeamCamAudio_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef driver,
    AudioObjectID deviceObjectID, UInt64 changeAction, void* changeInfo) {
    return kAudioHardwareNoError;
}
static OSStatus BeamCamAudio_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef driver,
    AudioObjectID deviceObjectID, UInt64 changeAction, void* changeInfo) {
    return kAudioHardwareNoError;
}

#pragma mark - Property helpers

static Boolean IsPlugIn(AudioObjectID id) { return id == kObjectID_PlugIn; }
static Boolean IsDevice(AudioObjectID id) { return id == kObjectID_Device; }
static Boolean IsStream(AudioObjectID id) { return id == kObjectID_Stream_Input; }

static void FillStreamFormat(AudioStreamBasicDescription* fmt) {
    memset(fmt, 0, sizeof(AudioStreamBasicDescription));
    fmt->mSampleRate       = kBeamCamAudioSampleRate;
    fmt->mFormatID         = kAudioFormatLinearPCM;
    fmt->mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    fmt->mBytesPerPacket   = kBeamCamAudioChannels * sizeof(Float32);
    fmt->mFramesPerPacket  = 1;
    fmt->mBytesPerFrame    = kBeamCamAudioChannels * sizeof(Float32);
    fmt->mChannelsPerFrame = kBeamCamAudioChannels;
    fmt->mBitsPerChannel   = 32;
}

#pragma mark - HasProperty

static Boolean BeamCamAudio_HasProperty(AudioServerPlugInDriverRef driver, AudioObjectID objectID,
    pid_t clientPID, const AudioObjectPropertyAddress* address) {
    if (address == NULL) return false;
    UInt32 sel = address->mSelector;
    // Deliberately not logged per-call (unlike Factory/Initialize/
    // QueryInterface below): HasProperty fires constantly during normal
    // operation, not just at load, and would flood the system log. Add a
    // temporary DebugLog here again if diagnosing a future load issue.

    if (sel == kAudioObjectPropertyBaseClass || sel == kAudioObjectPropertyClass
        || sel == kAudioObjectPropertyOwner || sel == kAudioObjectPropertyName
        || sel == kAudioObjectPropertyManufacturer || sel == kAudioObjectPropertyOwnedObjects) {
        return true;
    }

    if (IsPlugIn(objectID)) {
        return sel == kAudioPlugInPropertyBundleID || sel == kAudioPlugInPropertyDeviceList
            || sel == kAudioPlugInPropertyTranslateUIDToDevice;
    }
    if (IsDevice(objectID)) {
        return sel == kAudioDevicePropertyDeviceUID || sel == kAudioDevicePropertyModelUID
            || sel == kAudioDevicePropertyTransportType || sel == kAudioDevicePropertyRelatedDevices
            || sel == kAudioDevicePropertyClockDomain || sel == kAudioDevicePropertyDeviceIsAlive
            || sel == kAudioDevicePropertyDeviceIsRunning || sel == kAudioObjectPropertyControlList
            || sel == kAudioDevicePropertyNominalSampleRate || sel == kAudioDevicePropertyAvailableNominalSampleRates
            || sel == kAudioDevicePropertyIsHidden || sel == kAudioDevicePropertyStreams
            || sel == kAudioDevicePropertyStreamConfiguration || sel == kAudioDevicePropertyLatency
            || sel == kAudioDevicePropertySafetyOffset || sel == kAudioDevicePropertyBufferFrameSize
            || sel == kAudioDevicePropertyBufferFrameSizeRange
            || sel == kAudioDevicePropertyUsesVariableBufferFrameSizes
            || sel == kAudioDevicePropertyDeviceCanBeDefaultDevice
            || sel == kAudioDevicePropertyDeviceCanBeDefaultSystemDevice
            || sel == kAudioDevicePropertyZeroTimeStampPeriod
            || sel == kAudioDevicePropertyIcon;
    }
    if (IsStream(objectID)) {
        return sel == kAudioStreamPropertyIsActive || sel == kAudioStreamPropertyDirection
            || sel == kAudioStreamPropertyTerminalType || sel == kAudioStreamPropertyStartingChannel
            || sel == kAudioStreamPropertyLatency || sel == kAudioStreamPropertyVirtualFormat
            || sel == kAudioStreamPropertyPhysicalFormat
            || sel == kAudioStreamPropertyAvailableVirtualFormats
            || sel == kAudioStreamPropertyAvailablePhysicalFormats;
    }
    // ponytail/grey-route: macOS 26's driver host also probes undocumented
    // private selectors (observed: 0x7369736f "siso" on the device object)
    // before asking for kAudioPlugInPropertyDeviceList. Answering "false"
    // (the technically correct answer) makes the host silently abandon
    // enumeration instead of moving on. Answering "true" for anything
    // unrecognized matches the permissive QueryInterface above; safe because
    // GetPropertyDataSize/GetPropertyData below fall back to a zeroed
    // minimal-size value rather than promising real data.
    return true;
}

static OSStatus BeamCamAudio_IsPropertySettable(AudioServerPlugInDriverRef driver, AudioObjectID objectID,
    pid_t clientPID, const AudioObjectPropertyAddress* address, Boolean* outIsSettable) {
    if (address == NULL || outIsSettable == NULL) return kAudioHardwareIllegalOperationError;
    // Nothing in this driver is host-settable: no controls, fixed format,
    // fixed sample rate. Everything answers "exists, but read-only."
    *outIsSettable = false;
    return kAudioHardwareNoError;
}

#pragma mark - GetPropertyDataSize / GetPropertyData

static OSStatus BeamCamAudio_GetPropertyDataSize(AudioServerPlugInDriverRef driver, AudioObjectID objectID,
    pid_t clientPID, const AudioObjectPropertyAddress* address, UInt32 qualifierSize,
    const void* qualifierData, UInt32* outDataSize) {
    if (address == NULL || outDataSize == NULL) return kAudioHardwareIllegalOperationError;
    UInt32 sel = address->mSelector;

    if (sel == kAudioObjectPropertyBaseClass || sel == kAudioObjectPropertyClass
        || sel == kAudioObjectPropertyOwner) {
        *outDataSize = sizeof(AudioClassID);
        return kAudioHardwareNoError;
    }
    if (sel == kAudioObjectPropertyName || sel == kAudioObjectPropertyManufacturer
        || sel == kAudioDevicePropertyDeviceUID || sel == kAudioDevicePropertyModelUID
        || sel == kAudioPlugInPropertyBundleID) {
        *outDataSize = sizeof(CFStringRef);
        return kAudioHardwareNoError;
    }
    if (sel == kAudioObjectPropertyOwnedObjects || sel == kAudioDevicePropertyRelatedDevices) {
        *outDataSize = IsPlugIn(objectID) ? sizeof(AudioObjectID) : sizeof(AudioObjectID);
        return kAudioHardwareNoError;
    }
    if (sel == kAudioPlugInPropertyDeviceList) {
        *outDataSize = sizeof(AudioObjectID);
        return kAudioHardwareNoError;
    }
    if (sel == kAudioPlugInPropertyTranslateUIDToDevice) {
        *outDataSize = sizeof(AudioObjectID);
        return kAudioHardwareNoError;
    }
    if (sel == kAudioDevicePropertyStreams) {
        *outDataSize = sizeof(AudioObjectID);
        return kAudioHardwareNoError;
    }
    if (sel == kAudioObjectPropertyControlList) {
        *outDataSize = 0;
        return kAudioHardwareNoError;
    }
    if (sel == kAudioDevicePropertyStreamConfiguration) {
        *outDataSize = sizeof(UInt32) + sizeof(AudioBuffer);
        return kAudioHardwareNoError;
    }
    if (sel == kAudioDevicePropertyTransportType || sel == kAudioDevicePropertyClockDomain
        || sel == kAudioDevicePropertyDeviceIsAlive || sel == kAudioDevicePropertyDeviceIsRunning
        || sel == kAudioDevicePropertyIsHidden || sel == kAudioDevicePropertyLatency
        || sel == kAudioDevicePropertySafetyOffset || sel == kAudioDevicePropertyBufferFrameSize
        || sel == kAudioDevicePropertyUsesVariableBufferFrameSizes
        || sel == kAudioDevicePropertyDeviceCanBeDefaultDevice
        || sel == kAudioDevicePropertyDeviceCanBeDefaultSystemDevice
        || sel == kAudioDevicePropertyZeroTimeStampPeriod
        || sel == kAudioStreamPropertyIsActive || sel == kAudioStreamPropertyDirection
        || sel == kAudioStreamPropertyTerminalType || sel == kAudioStreamPropertyStartingChannel
        || sel == kAudioStreamPropertyLatency) {
        *outDataSize = sizeof(UInt32);
        return kAudioHardwareNoError;
    }
    if (sel == kAudioDevicePropertyNominalSampleRate) {
        *outDataSize = sizeof(Float64);
        return kAudioHardwareNoError;
    }
    if (sel == kAudioDevicePropertyAvailableNominalSampleRates) {
        *outDataSize = sizeof(AudioValueRange);
        return kAudioHardwareNoError;
    }
    if (sel == kAudioDevicePropertyBufferFrameSizeRange) {
        *outDataSize = sizeof(AudioValueRange);
        return kAudioHardwareNoError;
    }
    if (sel == kAudioStreamPropertyVirtualFormat || sel == kAudioStreamPropertyPhysicalFormat) {
        *outDataSize = sizeof(AudioStreamBasicDescription);
        return kAudioHardwareNoError;
    }
    if (sel == kAudioStreamPropertyAvailableVirtualFormats
        || sel == kAudioStreamPropertyAvailablePhysicalFormats) {
        *outDataSize = sizeof(AudioStreamRangedDescription);
        return kAudioHardwareNoError;
    }
    if (sel == kAudioDevicePropertyIcon) {
        *outDataSize = sizeof(CFURLRef);
        return kAudioHardwareUnknownPropertyError; // not implemented
    }

    // ponytail/grey-route: mirrors HasProperty's permissive default — a
    // zeroed UInt32 for anything unrecognized rather than an error.
    *outDataSize = sizeof(UInt32);
    return kAudioHardwareNoError;
}

static OSStatus BeamCamAudio_GetPropertyData(AudioServerPlugInDriverRef driver, AudioObjectID objectID,
    pid_t clientPID, const AudioObjectPropertyAddress* address, UInt32 qualifierSize,
    const void* qualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    if (address == NULL || outData == NULL || outDataSize == NULL) return kAudioHardwareIllegalOperationError;
    UInt32 sel = address->mSelector;

    // --- generic AudioObject properties -----------------------------------
    if (sel == kAudioObjectPropertyBaseClass) {
        *(AudioClassID*)outData = IsStream(objectID) ? kAudioStreamClassID
            : IsDevice(objectID) ? kAudioDeviceClassID : kAudioObjectClassID;
        *outDataSize = sizeof(AudioClassID);
        return kAudioHardwareNoError;
    }
    if (sel == kAudioObjectPropertyClass) {
        *(AudioClassID*)outData = IsPlugIn(objectID) ? kAudioPlugInClassID
            : IsStream(objectID) ? kAudioStreamClassID
            : IsDevice(objectID) ? kAudioDeviceClassID : kAudioObjectClassID;
        *outDataSize = sizeof(AudioClassID);
        return kAudioHardwareNoError;
    }
    if (sel == kAudioObjectPropertyOwner) {
        *(AudioObjectID*)outData = IsPlugIn(objectID) ? kAudioObjectUnknown
            : IsDevice(objectID) ? (AudioObjectID)kObjectID_PlugIn
            : (AudioObjectID)kObjectID_Device;
        *outDataSize = sizeof(AudioObjectID);
        return kAudioHardwareNoError;
    }
    if (sel == kAudioObjectPropertyName) {
        CFStringRef name = IsDevice(objectID) ? CopyCFString(kDeviceName)
            : IsStream(objectID) ? CopyCFString("BeamCam Microphone Input")
            : CopyCFString("BeamCam");
        *(CFStringRef*)outData = name;
        *outDataSize = sizeof(CFStringRef);
        return kAudioHardwareNoError;
    }
    if (sel == kAudioObjectPropertyManufacturer) {
        *(CFStringRef*)outData = CopyCFString(kManufacturer);
        *outDataSize = sizeof(CFStringRef);
        return kAudioHardwareNoError;
    }
    if (sel == kAudioObjectPropertyOwnedObjects) {
        if (IsPlugIn(objectID) && inDataSize >= sizeof(AudioObjectID)) {
            *(AudioObjectID*)outData = kObjectID_Device;
            *outDataSize = sizeof(AudioObjectID);
        } else if (IsDevice(objectID) && inDataSize >= sizeof(AudioObjectID)) {
            *(AudioObjectID*)outData = kObjectID_Stream_Input;
            *outDataSize = sizeof(AudioObjectID);
        } else {
            *outDataSize = 0;
        }
        return kAudioHardwareNoError;
    }
    if (sel == kAudioObjectPropertyControlList) {
        *outDataSize = 0; // no controls
        return kAudioHardwareNoError;
    }

    // --- plug-in level -------------------------------------------------
    if (sel == kAudioPlugInPropertyBundleID) {
        *(CFStringRef*)outData = CopyCFString(kBundleID);
        *outDataSize = sizeof(CFStringRef);
        return kAudioHardwareNoError;
    }
    if (sel == kAudioPlugInPropertyDeviceList) {
        if (inDataSize >= sizeof(AudioObjectID)) {
            *(AudioObjectID*)outData = kObjectID_Device;
            *outDataSize = sizeof(AudioObjectID);
        } else {
            *outDataSize = 0;
        }
        return kAudioHardwareNoError;
    }
    if (sel == kAudioPlugInPropertyTranslateUIDToDevice) {
        AudioObjectID result = kAudioObjectUnknown;
        if (qualifierData != NULL && qualifierSize >= sizeof(CFStringRef)) {
            CFStringRef uid = *(const CFStringRef*)qualifierData;
            CFStringRef mine = CopyCFString(kDeviceUID);
            if (uid != NULL && CFStringCompare(uid, mine, 0) == kCFCompareEqualTo) {
                result = kObjectID_Device;
            }
            CFRelease(mine);
        }
        *(AudioObjectID*)outData = result;
        *outDataSize = sizeof(AudioObjectID);
        return kAudioHardwareNoError;
    }

    // --- device level ----------------------------------------------------
    if (sel == kAudioDevicePropertyDeviceUID) {
        *(CFStringRef*)outData = CopyCFString(kDeviceUID);
        *outDataSize = sizeof(CFStringRef);
        return kAudioHardwareNoError;
    }
    if (sel == kAudioDevicePropertyModelUID) {
        *(CFStringRef*)outData = CopyCFString(kDeviceModelUID);
        *outDataSize = sizeof(CFStringRef);
        return kAudioHardwareNoError;
    }
    if (sel == kAudioDevicePropertyTransportType) {
        *(UInt32*)outData = kAudioDeviceTransportTypeVirtual;
        *outDataSize = sizeof(UInt32);
        return kAudioHardwareNoError;
    }
    if (sel == kAudioDevicePropertyRelatedDevices) {
        if (inDataSize >= sizeof(AudioObjectID)) {
            *(AudioObjectID*)outData = kObjectID_Device;
            *outDataSize = sizeof(AudioObjectID);
        } else {
            *outDataSize = 0;
        }
        return kAudioHardwareNoError;
    }
    if (sel == kAudioDevicePropertyClockDomain) {
        *(UInt32*)outData = 0;
        *outDataSize = sizeof(UInt32);
        return kAudioHardwareNoError;
    }
    if (sel == kAudioDevicePropertyDeviceIsAlive) {
        *(UInt32*)outData = gState.deviceIsAlive ? 1 : 0;
        *outDataSize = sizeof(UInt32);
        return kAudioHardwareNoError;
    }
    if (sel == kAudioDevicePropertyDeviceIsRunning) {
        *(UInt32*)outData = (gState.startCount > 0) ? 1 : 0;
        *outDataSize = sizeof(UInt32);
        return kAudioHardwareNoError;
    }
    if (sel == kAudioDevicePropertyIsHidden) {
        *(UInt32*)outData = 0;
        *outDataSize = sizeof(UInt32);
        return kAudioHardwareNoError;
    }
    if (sel == kAudioDevicePropertyDeviceCanBeDefaultDevice || sel == kAudioDevicePropertyDeviceCanBeDefaultSystemDevice) {
        *(UInt32*)outData = (address->mScope == kAudioObjectPropertyScopeInput) ? 1 : 0;
        *outDataSize = sizeof(UInt32);
        return kAudioHardwareNoError;
    }
    if (sel == kAudioDevicePropertyStreams) {
        if (address->mScope == kAudioObjectPropertyScopeOutput) {
            *outDataSize = 0;
        } else if (inDataSize >= sizeof(AudioObjectID)) {
            *(AudioObjectID*)outData = kObjectID_Stream_Input;
            *outDataSize = sizeof(AudioObjectID);
        } else {
            *outDataSize = 0;
        }
        return kAudioHardwareNoError;
    }
    if (sel == kAudioDevicePropertyStreamConfiguration) {
        AudioBufferList* list = (AudioBufferList*)outData;
        if (address->mScope == kAudioObjectPropertyScopeOutput) {
            list->mNumberBuffers = 0;
        } else {
            list->mNumberBuffers = 1;
            list->mBuffers[0].mNumberChannels = kBeamCamAudioChannels;
            list->mBuffers[0].mDataByteSize = kBeamCamAudioChannels * sizeof(Float32);
            list->mBuffers[0].mData = NULL; // the host supplies the buffer during IO
        }
        *outDataSize = sizeof(UInt32) + list->mNumberBuffers * sizeof(AudioBuffer);
        return kAudioHardwareNoError;
    }
    if (sel == kAudioDevicePropertyNominalSampleRate) {
        *(Float64*)outData = gState.sampleRate;
        *outDataSize = sizeof(Float64);
        return kAudioHardwareNoError;
    }
    if (sel == kAudioDevicePropertyAvailableNominalSampleRates) {
        AudioValueRange* range = (AudioValueRange*)outData;
        range->mMinimum = kBeamCamAudioSampleRate;
        range->mMaximum = kBeamCamAudioSampleRate;
        *outDataSize = sizeof(AudioValueRange);
        return kAudioHardwareNoError;
    }
    if (sel == kAudioDevicePropertyLatency || sel == kAudioDevicePropertySafetyOffset) {
        *(UInt32*)outData = 0;
        *outDataSize = sizeof(UInt32);
        return kAudioHardwareNoError;
    }
    if (sel == kAudioDevicePropertyBufferFrameSize) {
        *(UInt32*)outData = gState.ioBufferFrameSize;
        *outDataSize = sizeof(UInt32);
        return kAudioHardwareNoError;
    }
    if (sel == kAudioDevicePropertyBufferFrameSizeRange) {
        AudioValueRange* range = (AudioValueRange*)outData;
        range->mMinimum = 1;
        range->mMaximum = kBeamCamAudioFrameCapacity;
        *outDataSize = sizeof(AudioValueRange);
        return kAudioHardwareNoError;
    }
    if (sel == kAudioDevicePropertyUsesVariableBufferFrameSizes) {
        *(UInt32*)outData = 0;
        *outDataSize = sizeof(UInt32);
        return kAudioHardwareNoError;
    }
    if (sel == kAudioDevicePropertyZeroTimeStampPeriod) {
        *(UInt32*)outData = kZeroTimeStampPeriod;
        *outDataSize = sizeof(UInt32);
        return kAudioHardwareNoError;
    }

    // --- stream level ------------------------------------------------------
    if (sel == kAudioStreamPropertyIsActive) {
        *(UInt32*)outData = 1;
        *outDataSize = sizeof(UInt32);
        return kAudioHardwareNoError;
    }
    if (sel == kAudioStreamPropertyDirection) {
        // Ordinary kAudioStreamPropertyDirection semantics (0 = output, 1 =
        // input) — NOT the CoreMediaIO property CMIOSinkClient works around
        // (BeamCam invariant #5), which is a different framework and, on
        // that framework, inverted relative to this one. Do not "fix" this
        // to match the CMIO quirk; they are unrelated properties.
        *(UInt32*)outData = 1;
        *outDataSize = sizeof(UInt32);
        return kAudioHardwareNoError;
    }
    if (sel == kAudioStreamPropertyTerminalType) {
        *(UInt32*)outData = kAudioStreamTerminalTypeMicrophone;
        *outDataSize = sizeof(UInt32);
        return kAudioHardwareNoError;
    }
    if (sel == kAudioStreamPropertyStartingChannel) {
        *(UInt32*)outData = 1;
        *outDataSize = sizeof(UInt32);
        return kAudioHardwareNoError;
    }
    if (sel == kAudioStreamPropertyLatency) {
        *(UInt32*)outData = 0;
        *outDataSize = sizeof(UInt32);
        return kAudioHardwareNoError;
    }
    if (sel == kAudioStreamPropertyVirtualFormat || sel == kAudioStreamPropertyPhysicalFormat) {
        FillStreamFormat((AudioStreamBasicDescription*)outData);
        *outDataSize = sizeof(AudioStreamBasicDescription);
        return kAudioHardwareNoError;
    }
    if (sel == kAudioStreamPropertyAvailableVirtualFormats
        || sel == kAudioStreamPropertyAvailablePhysicalFormats) {
        AudioStreamRangedDescription* desc = (AudioStreamRangedDescription*)outData;
        FillStreamFormat(&desc->mFormat);
        desc->mSampleRateRange.mMinimum = kBeamCamAudioSampleRate;
        desc->mSampleRateRange.mMaximum = kBeamCamAudioSampleRate;
        *outDataSize = sizeof(AudioStreamRangedDescription);
        return kAudioHardwareNoError;
    }

    // ponytail/grey-route: matches HasProperty/GetPropertyDataSize's
    // permissive default — a zeroed UInt32 rather than an error.
    if (inDataSize >= sizeof(UInt32)) {
        *(UInt32*)outData = 0;
        *outDataSize = sizeof(UInt32);
    } else {
        *outDataSize = 0;
    }
    return kAudioHardwareNoError;
}

static OSStatus BeamCamAudio_SetPropertyData(AudioServerPlugInDriverRef driver, AudioObjectID objectID,
    pid_t clientPID, const AudioObjectPropertyAddress* address, UInt32 qualifierSize,
    const void* qualifierData, UInt32 dataSize, const void* data) {
    // Nothing is settable (see IsPropertySettable) — fixed format, fixed
    // sample rate, no controls.
    return kAudioHardwareUnsupportedOperationError;
}

#pragma mark - IO operations

static OSStatus BeamCamAudio_StartIO(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID) {
    DebugLog("StartIO called");
    pthread_mutex_lock(&gState.lock);
    if (gState.startCount == 0) {
        gState.anchorHostTime = mach_absolute_time();
        gState.anchorSampleTime = 0;
        gState.readIndexValid = false; // re-sync to the ring's current writer position
    }
    gState.startCount++;
    pthread_mutex_unlock(&gState.lock);
    return kAudioHardwareNoError;
}

static OSStatus BeamCamAudio_StopIO(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID) {
    pthread_mutex_lock(&gState.lock);
    if (gState.startCount > 0) gState.startCount--;
    if (gState.startCount == 0) CloseRing();
    pthread_mutex_unlock(&gState.lock);
    return kAudioHardwareNoError;
}

static OSStatus BeamCamAudio_GetZeroTimeStamp(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID,
    UInt32 clientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed) {
    if (outSampleTime == NULL || outHostTime == NULL || outSeed == NULL) {
        return kAudioHardwareIllegalOperationError;
    }
    pthread_mutex_lock(&gState.lock);
    UInt64 now = mach_absolute_time();
    Float64 framesSinceAnchor = (Float64)(now - gState.anchorHostTime) / gState.hostTicksPerFrame;
    // Quantize to kZeroTimeStampPeriod — the host is told via
    // kAudioDevicePropertyZeroTimeStampPeriod that successive sample times
    // differ by exactly this, so stepping by anything else (this used to step
    // by ioBufferFrameSize) desynchronises the HAL's clock model.
    Float64 periods = floor(framesSinceAnchor / kZeroTimeStampPeriod);
    Float64 sampleTime = periods * kZeroTimeStampPeriod;
    UInt64 hostTime = gState.anchorHostTime + (UInt64)(sampleTime * gState.hostTicksPerFrame);
    *outSampleTime = sampleTime;
    *outHostTime = hostTime;
    *outSeed = 1;
    pthread_mutex_unlock(&gState.lock);
    return kAudioHardwareNoError;
}

static OSStatus BeamCamAudio_WillDoIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID,
    UInt32 clientID, UInt32 operationID, Boolean* outWillDo, Boolean* outWillDoInPlace) {
    Boolean willDo = (operationID == kAudioServerPlugInIOOperationReadInput);
    if (outWillDo != NULL) *outWillDo = willDo;
    if (outWillDoInPlace != NULL) *outWillDoInPlace = true;
    return kAudioHardwareNoError;
}

static OSStatus BeamCamAudio_BeginIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID,
    UInt32 clientID, UInt32 operationID, UInt32 ioBufferFrameSize, const AudioServerPlugInIOCycleInfo* cycleInfo) {
    gState.ioBufferFrameSize = ioBufferFrameSize;
    return kAudioHardwareNoError;
}

static OSStatus BeamCamAudio_DoIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID,
    AudioObjectID streamObjectID, UInt32 clientID, UInt32 operationID, UInt32 ioBufferFrameSize,
    const AudioServerPlugInIOCycleInfo* cycleInfo, void* mainBuffer, void* secondaryBuffer) {
    static int callCount = 0;
    if (callCount < 3 || callCount % 500 == 0) {
        char msg[128];
        snprintf(msg, sizeof(msg), "DoIOOperation call=%d op=%u isStream=%d bufNULL=%d",
            callCount, (unsigned)operationID, (int)IsStream(streamObjectID), mainBuffer == NULL);
        DebugLog(msg);
    }
    callCount++;
    if (operationID != kAudioServerPlugInIOOperationReadInput || !IsStream(streamObjectID) || mainBuffer == NULL) {
        return kAudioHardwareNoError;
    }
    ReadFrames((Float32*)mainBuffer, ioBufferFrameSize);
    return kAudioHardwareNoError;
}

static OSStatus BeamCamAudio_EndIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID,
    UInt32 clientID, UInt32 operationID, UInt32 ioBufferFrameSize, const AudioServerPlugInIOCycleInfo* cycleInfo) {
    return kAudioHardwareNoError;
}

#pragma mark - Factory

void* BeamCamAudioPlugIn_Create(CFAllocatorRef allocator, CFUUIDRef typeUUID);

void* BeamCamAudioPlugIn_Create(CFAllocatorRef allocator, CFUUIDRef typeUUID) {
    DebugLog("Factory called");
    if (!CFEqual(typeUUID, kAudioServerPlugInTypeUUID)) {
        DebugLog("Factory: typeUUID mismatch");
        return NULL;
    }
    BeamCamAudio_AddRef(NULL);
    DebugLog("Factory returning driver ref");
    return gDriverRef;
}
