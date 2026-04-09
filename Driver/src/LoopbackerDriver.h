#pragma once

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <atomic>
#include <memory>
#include <mutex>
#include "RingBuffer.h"
#include "LoopbackerTypes.h"

/// Per-device state for each virtual loopback device.
struct DeviceState {
    const char* name;
    const char* uid;
    AudioObjectID deviceID;
    AudioObjectID inputStreamID;
    AudioObjectID outputStreamID;
    AudioObjectID volumeControlID;
    AudioObjectID inputVolumeControlID;

    Float64 sampleRate;
    std::atomic<UInt32> ioIsRunning;       // number of active IO clients
    UInt64  ioCycleCount;                  // counts IO cycles for timestamp synthesis

    Float32 volume;
    bool    mute;

    std::unique_ptr<RingBuffer> ringBuffer;

    UInt64  anchorHostTime;                // mach_absolute_time at IO start
    Float64 hostTicksPerFrame;             // host ticks per sample frame

    DeviceState()
        : name(nullptr)
        , uid(nullptr)
        , deviceID(0)
        , inputStreamID(0)
        , outputStreamID(0)
        , volumeControlID(0)
        , inputVolumeControlID(0)
        , sampleRate(kDefaultSampleRate)
        , ioIsRunning(0)
        , ioCycleCount(0)
        , volume(1.0f)
        , mute(false)
        , anchorHostTime(0)
        , hostTicksPerFrame(0.0)
    {
    }
};

/// The Loopbacker audio driver object. Implements AudioServerPlugInDriverInterface.
struct LoopbackerDriver {
    // COM-style vtable pointer — MUST be the first field.
    AudioServerPlugInDriverInterface* mInterface;

    // Reference count for IUnknown
    std::atomic<UInt32> mRefCount;

    // Host interface (provided by coreaudiod)
    AudioServerPlugInHostRef mHost;

    // Per-device state array
    DeviceState mDevices[kMaxDevices];

    // Mutex for non-realtime property changes (shared across all devices)
    std::mutex mMutex;

    // Static vtable
    static AudioServerPlugInDriverInterface sInterface;

    // ---------------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------------
    LoopbackerDriver();

    // ---------------------------------------------------------------------------
    // Helper: find the DeviceState that owns a given object ID
    // (device, stream, or volume control)
    // ---------------------------------------------------------------------------
    DeviceState* FindDeviceByObjectID(AudioObjectID inObjectID);

    // ---------------------------------------------------------------------------
    // IUnknown
    // ---------------------------------------------------------------------------
    static HRESULT  QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface);
    static ULONG    AddRef(void* inDriver);
    static ULONG    Release(void* inDriver);

    // ---------------------------------------------------------------------------
    // Basic operations
    // ---------------------------------------------------------------------------
    static OSStatus Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
    static OSStatus CreateDevice(AudioServerPlugInDriverRef inDriver,
                                 CFDictionaryRef inDescription,
                                 const AudioServerPlugInClientInfo* inClientInfo,
                                 AudioObjectID* outDeviceObjectID);
    static OSStatus DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);

    // ---------------------------------------------------------------------------
    // Property operations
    // ---------------------------------------------------------------------------
    static OSStatus AddDeviceClient(AudioServerPlugInDriverRef inDriver,
                                    AudioObjectID inDeviceObjectID,
                                    const AudioServerPlugInClientInfo* inClientInfo);
    static OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef inDriver,
                                       AudioObjectID inDeviceObjectID,
                                       const AudioServerPlugInClientInfo* inClientInfo);
    static OSStatus PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                      AudioObjectID inDeviceObjectID,
                                                      UInt64 inChangeAction,
                                                      void* inChangeInfo);
    static OSStatus AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                    AudioObjectID inDeviceObjectID,
                                                    UInt64 inChangeAction,
                                                    void* inChangeInfo);

    static Boolean  HasProperty(AudioServerPlugInDriverRef inDriver,
                                AudioObjectID inObjectID,
                                pid_t inClientPID,
                                const AudioObjectPropertyAddress* inAddress);
    static OSStatus IsPropertySettable(AudioServerPlugInDriverRef inDriver,
                                       AudioObjectID inObjectID,
                                       pid_t inClientPID,
                                       const AudioObjectPropertyAddress* inAddress,
                                       Boolean* outIsSettable);
    static OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef inDriver,
                                        AudioObjectID inObjectID,
                                        pid_t inClientPID,
                                        const AudioObjectPropertyAddress* inAddress,
                                        UInt32 inQualifierDataSize,
                                        const void* inQualifierData,
                                        UInt32* outDataSize);
    static OSStatus GetPropertyData(AudioServerPlugInDriverRef inDriver,
                                    AudioObjectID inObjectID,
                                    pid_t inClientPID,
                                    const AudioObjectPropertyAddress* inAddress,
                                    UInt32 inQualifierDataSize,
                                    const void* inQualifierData,
                                    UInt32 inDataSize,
                                    UInt32* outDataSize,
                                    void* outData);
    static OSStatus SetPropertyData(AudioServerPlugInDriverRef inDriver,
                                    AudioObjectID inObjectID,
                                    pid_t inClientPID,
                                    const AudioObjectPropertyAddress* inAddress,
                                    UInt32 inQualifierDataSize,
                                    const void* inQualifierData,
                                    UInt32 inDataSize,
                                    const void* inData);

    // ---------------------------------------------------------------------------
    // IO operations
    // ---------------------------------------------------------------------------
    static OSStatus StartIO(AudioServerPlugInDriverRef inDriver,
                            AudioObjectID inDeviceObjectID,
                            UInt32 inClientID);
    static OSStatus StopIO(AudioServerPlugInDriverRef inDriver,
                           AudioObjectID inDeviceObjectID,
                           UInt32 inClientID);
    static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver,
                                     AudioObjectID inDeviceObjectID,
                                     UInt32 inClientID,
                                     Float64* outSampleTime,
                                     UInt64* outHostTime,
                                     UInt64* outSeed);
    static OSStatus WillDoIOOperation(AudioServerPlugInDriverRef inDriver,
                                      AudioObjectID inDeviceObjectID,
                                      UInt32 inClientID,
                                      UInt32 inOperationID,
                                      Boolean* outWillDo,
                                      Boolean* outIsInput);
    static OSStatus BeginIOOperation(AudioServerPlugInDriverRef inDriver,
                                     AudioObjectID inDeviceObjectID,
                                     UInt32 inClientID,
                                     UInt32 inOperationID,
                                     UInt32 inIOBufferFrameSize,
                                     const AudioServerPlugInIOCycleInfo* inIOCycleInfo);
    static OSStatus DoIOOperation(AudioServerPlugInDriverRef inDriver,
                                  AudioObjectID inDeviceObjectID,
                                  AudioObjectID inStreamObjectID,
                                  UInt32 inClientID,
                                  UInt32 inOperationID,
                                  UInt32 inIOBufferFrameSize,
                                  const AudioServerPlugInIOCycleInfo* inIOCycleInfo,
                                  void* ioMainBuffer,
                                  void* ioSecondaryBuffer);
    static OSStatus EndIOOperation(AudioServerPlugInDriverRef inDriver,
                                   AudioObjectID inDeviceObjectID,
                                   UInt32 inClientID,
                                   UInt32 inOperationID,
                                   UInt32 inIOBufferFrameSize,
                                   const AudioServerPlugInIOCycleInfo* inIOCycleInfo);
};

/// Creates the singleton driver and returns the interface pointer.
LoopbackerDriver* LoopbackerDriver_GetInstance();
