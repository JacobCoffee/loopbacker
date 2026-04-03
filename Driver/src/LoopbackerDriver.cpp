#include "LoopbackerDriver.h"
#include "LoopbackerTypes.h"

#include <CoreAudio/AudioHardware.h>
#include <CoreAudio/AudioHardwareBase.h>
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <cmath>
#include <cstring>

// =============================================================================
// Helper: recover LoopbackerDriver* from the AudioServerPlugInDriverRef.
// The ref is a pointer to the mInterface field, which is the first member.
// =============================================================================

static inline LoopbackerDriver* AsDriver(AudioServerPlugInDriverRef inDriver)
{
    return reinterpret_cast<LoopbackerDriver*>(inDriver);
}

// =============================================================================
// Static vtable
// =============================================================================

AudioServerPlugInDriverInterface LoopbackerDriver::sInterface = {
    // Reserved
    nullptr,

    // IUnknown
    LoopbackerDriver::QueryInterface,
    LoopbackerDriver::AddRef,
    LoopbackerDriver::Release,

    // Basic operations
    LoopbackerDriver::Initialize,
    LoopbackerDriver::CreateDevice,
    LoopbackerDriver::DestroyDevice,
    LoopbackerDriver::AddDeviceClient,
    LoopbackerDriver::RemoveDeviceClient,
    LoopbackerDriver::PerformDeviceConfigurationChange,
    LoopbackerDriver::AbortDeviceConfigurationChange,

    // Property operations
    LoopbackerDriver::HasProperty,
    LoopbackerDriver::IsPropertySettable,
    LoopbackerDriver::GetPropertyDataSize,
    LoopbackerDriver::GetPropertyData,
    LoopbackerDriver::SetPropertyData,

    // IO operations
    LoopbackerDriver::StartIO,
    LoopbackerDriver::StopIO,
    LoopbackerDriver::GetZeroTimeStamp,
    LoopbackerDriver::WillDoIOOperation,
    LoopbackerDriver::BeginIOOperation,
    LoopbackerDriver::DoIOOperation,
    LoopbackerDriver::EndIOOperation,
};


// =============================================================================
// Singleton
// =============================================================================

LoopbackerDriver* LoopbackerDriver_GetInstance()
{
    // Use a function-local static to guarantee proper initialization order.
    // The driver is never deallocated — it lives for the lifetime of the process.
    static LoopbackerDriver sDriver;
    return &sDriver;
}

// =============================================================================
// Construction
// =============================================================================

LoopbackerDriver::LoopbackerDriver()
    : mInterface(&sInterface)
    , mRefCount(1)
    , mHost(nullptr)
    , mSampleRate(kDefaultSampleRate)
    , mIOIsRunning(0)
    , mIOCycleCount(0)
    , mVolume(1.0f)
    , mMute(false)
    , mRingBuffer(std::make_unique<RingBuffer>(kRingBufferFrames, kBytesPerFrame))
    , mAnchorHostTime(0)
    , mHostTicksPerFrame(0.0)
{
}

// =============================================================================
// Helper: get host ticks per frame
// =============================================================================

static Float64 ComputeHostTicksPerFrame(Float64 sampleRate)
{
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    Float64 hostTicksPerSecond = (1000000000.0 * static_cast<Float64>(timebase.denom))
                                / static_cast<Float64>(timebase.numer);
    return hostTicksPerSecond / sampleRate;
}

// =============================================================================
// IUnknown
// =============================================================================

HRESULT LoopbackerDriver::QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface)
{
    // kAudioServerPlugInTypeUUID — 443ABAB8-E7B3-491A-B985-BEB9187030DB
    CFUUIDRef audioPlugInTypeUUID = CFUUIDGetConstantUUIDWithBytes(
        nullptr,
        0x44, 0x3A, 0xBA, 0xB8,
        0xE7, 0xB3,
        0x49, 0x1A,
        0xB9, 0x85,
        0xBE, 0xB9, 0x18, 0x70, 0x30, 0xDB);

    // kAudioServerPlugInDriverInterfaceUUID — EEA5773D-CC43-49F1-8E00-8F96E7D23B17
    CFUUIDRef driverInterfaceUUID = CFUUIDGetConstantUUIDWithBytes(
        nullptr,
        0xEE, 0xA5, 0x77, 0x3D,
        0xCC, 0x43,
        0x49, 0xF1,
        0x8E, 0x00,
        0x8F, 0x96, 0xE7, 0xD2, 0x3B, 0x17);

    // IUnknown UUID — 00000000-0000-0000-C000-000000000046
    CFUUIDRef iUnknownUUID = CFUUIDGetConstantUUIDWithBytes(
        nullptr,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0xC0, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x46);

    CFUUIDRef requestedUUID = CFUUIDCreateFromUUIDBytes(nullptr, inUUID);

    if (CFEqual(requestedUUID, audioPlugInTypeUUID) ||
        CFEqual(requestedUUID, driverInterfaceUUID) ||
        CFEqual(requestedUUID, iUnknownUUID)) {
        CFRelease(requestedUUID);
        auto* driver = static_cast<LoopbackerDriver*>(inDriver);
        driver->mRefCount.fetch_add(1, std::memory_order_relaxed);
        *outInterface = inDriver;
        return S_OK;
    }

    CFRelease(requestedUUID);
    *outInterface = nullptr;
    return E_NOINTERFACE;
}

ULONG LoopbackerDriver::AddRef(void* inDriver)
{
    auto* driver = static_cast<LoopbackerDriver*>(inDriver);
    return driver->mRefCount.fetch_add(1, std::memory_order_relaxed) + 1;
}

ULONG LoopbackerDriver::Release(void* inDriver)
{
    auto* driver = static_cast<LoopbackerDriver*>(inDriver);
    UInt32 prev = driver->mRefCount.fetch_sub(1, std::memory_order_acq_rel);
    return prev - 1;
}

// =============================================================================
// Basic operations
// =============================================================================

OSStatus LoopbackerDriver::Initialize(AudioServerPlugInDriverRef inDriver,
                                      AudioServerPlugInHostRef inHost)
{
    auto* driver = AsDriver(inDriver);
    driver->mHost = inHost;
    driver->mHostTicksPerFrame = ComputeHostTicksPerFrame(driver->mSampleRate);
    return kAudioHardwareNoError;
}

OSStatus LoopbackerDriver::CreateDevice(AudioServerPlugInDriverRef /*inDriver*/,
                                        CFDictionaryRef /*inDescription*/,
                                        const AudioServerPlugInClientInfo* /*inClientInfo*/,
                                        AudioObjectID* /*outDeviceObjectID*/)
{
    return kAudioHardwareUnsupportedOperationError;
}

OSStatus LoopbackerDriver::DestroyDevice(AudioServerPlugInDriverRef /*inDriver*/,
                                         AudioObjectID /*inDeviceObjectID*/)
{
    return kAudioHardwareUnsupportedOperationError;
}

OSStatus LoopbackerDriver::AddDeviceClient(AudioServerPlugInDriverRef /*inDriver*/,
                                           AudioObjectID /*inDeviceObjectID*/,
                                           const AudioServerPlugInClientInfo* /*inClientInfo*/)
{
    return kAudioHardwareNoError;
}

OSStatus LoopbackerDriver::RemoveDeviceClient(AudioServerPlugInDriverRef /*inDriver*/,
                                              AudioObjectID /*inDeviceObjectID*/,
                                              const AudioServerPlugInClientInfo* /*inClientInfo*/)
{
    return kAudioHardwareNoError;
}

OSStatus LoopbackerDriver::PerformDeviceConfigurationChange(AudioServerPlugInDriverRef /*inDriver*/,
                                                            AudioObjectID /*inDeviceObjectID*/,
                                                            UInt64 /*inChangeAction*/,
                                                            void* /*inChangeInfo*/)
{
    return kAudioHardwareNoError;
}

OSStatus LoopbackerDriver::AbortDeviceConfigurationChange(AudioServerPlugInDriverRef /*inDriver*/,
                                                          AudioObjectID /*inDeviceObjectID*/,
                                                          UInt64 /*inChangeAction*/,
                                                          void* /*inChangeInfo*/)
{
    return kAudioHardwareNoError;
}

// =============================================================================
// Property helpers
// =============================================================================

static AudioStreamBasicDescription MakeStreamDescription(Float64 sampleRate)
{
    AudioStreamBasicDescription desc = {};
    desc.mSampleRate       = sampleRate;
    desc.mFormatID         = kAudioFormatLinearPCM;
    desc.mFormatFlags      = kAudioFormatFlagIsFloat
                           | kAudioFormatFlagsNativeEndian
                           | kAudioFormatFlagIsPacked;
    desc.mBitsPerChannel   = kBitsPerChannel;
    desc.mChannelsPerFrame = kChannelCount;
    desc.mBytesPerFrame    = kBytesPerFrame;
    desc.mFramesPerPacket  = 1;
    desc.mBytesPerPacket   = kBytesPerFrame;
    return desc;
}

static AudioStreamRangedDescription MakeRangedDescription(Float64 sampleRate)
{
    AudioStreamRangedDescription ranged = {};
    ranged.mFormat = MakeStreamDescription(sampleRate);
    ranged.mSampleRateRange.mMinimum = sampleRate;
    ranged.mSampleRateRange.mMaximum = sampleRate;
    return ranged;
}

#define WRITE_PROP(type, value)                                      \
    do {                                                             \
        if (inDataSize < sizeof(type)) return kAudioHardwareBadPropertySizeError; \
        *outDataSize = sizeof(type);                                 \
        *static_cast<type*>(outData) = (value);                      \
        return kAudioHardwareNoError;                                \
    } while (0)

// =============================================================================
// HasProperty
// =============================================================================

Boolean LoopbackerDriver::HasProperty(AudioServerPlugInDriverRef /*inDriver*/,
                                      AudioObjectID inObjectID,
                                      pid_t /*inClientPID*/,
                                      const AudioObjectPropertyAddress* inAddress)
{
    switch (inObjectID) {
        case kAudioObjectPlugInObject:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyManufacturer:
                case kAudioObjectPropertyOwnedObjects:
                case kAudioPlugInPropertyDeviceList:
                case kAudioPlugInPropertyTranslateUIDToDevice:
                case kAudioPlugInPropertyResourceBundle:
                    return true;
            }
            break;

        case kDeviceObjectID:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyName:
                case kAudioObjectPropertyManufacturer:
                case kAudioObjectPropertyOwnedObjects:
                case kAudioDevicePropertyDeviceUID:
                case kAudioDevicePropertyModelUID:
                case kAudioDevicePropertyTransportType:
                case kAudioDevicePropertyRelatedDevices:
                case kAudioDevicePropertyClockDomain:
                case kAudioDevicePropertyDeviceIsAlive:
                case kAudioDevicePropertyDeviceIsRunning:
                case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                case kAudioDevicePropertyLatency:
                case kAudioDevicePropertyStreams:
                case kAudioObjectPropertyControlList:
                case kAudioDevicePropertyNominalSampleRate:
                case kAudioDevicePropertyAvailableNominalSampleRates:
                case kAudioDevicePropertyIsHidden:
                case kAudioDevicePropertyZeroTimeStampPeriod:
                case kAudioDevicePropertySafetyOffset:
                case kAudioDevicePropertyPreferredChannelsForStereo:
                case kAudioDevicePropertyPreferredChannelLayout:
                case kAudioDevicePropertyBufferFrameSize:
                case kAudioDevicePropertyBufferFrameSizeRange:
                    return true;
            }
            break;

        case kInputStreamObjectID:
        case kOutputStreamObjectID:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioStreamPropertyIsActive:
                case kAudioStreamPropertyDirection:
                case kAudioStreamPropertyTerminalType:
                case kAudioStreamPropertyStartingChannel:
                case kAudioStreamPropertyLatency:
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat:
                case kAudioStreamPropertyAvailableVirtualFormats:
                case kAudioStreamPropertyAvailablePhysicalFormats:
                    return true;
            }
            break;

        case kVolumeControlObjectID:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioControlPropertyScope:
                case kAudioControlPropertyElement:
                case kAudioLevelControlPropertyScalarValue:
                case kAudioLevelControlPropertyDecibelValue:
                case kAudioLevelControlPropertyDecibelRange:
                case kAudioBooleanControlPropertyValue:
                    return true;
            }
            break;
    }
    return false;
}

// =============================================================================
// IsPropertySettable
// =============================================================================

OSStatus LoopbackerDriver::IsPropertySettable(AudioServerPlugInDriverRef /*inDriver*/,
                                              AudioObjectID inObjectID,
                                              pid_t /*inClientPID*/,
                                              const AudioObjectPropertyAddress* inAddress,
                                              Boolean* outIsSettable)
{
    switch (inObjectID) {
        case kDeviceObjectID:
            switch (inAddress->mSelector) {
                case kAudioDevicePropertyNominalSampleRate:
                case kAudioDevicePropertyBufferFrameSize:
                    *outIsSettable = true;
                    return kAudioHardwareNoError;
            }
            break;

        case kInputStreamObjectID:
        case kOutputStreamObjectID:
            switch (inAddress->mSelector) {
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat:
                    *outIsSettable = true;
                    return kAudioHardwareNoError;
            }
            break;

        case kVolumeControlObjectID:
            switch (inAddress->mSelector) {
                case kAudioLevelControlPropertyScalarValue:
                case kAudioLevelControlPropertyDecibelValue:
                case kAudioBooleanControlPropertyValue:
                    *outIsSettable = true;
                    return kAudioHardwareNoError;
            }
            break;
    }

    *outIsSettable = false;
    return kAudioHardwareNoError;
}

// =============================================================================
// GetPropertyDataSize
// =============================================================================

OSStatus LoopbackerDriver::GetPropertyDataSize(AudioServerPlugInDriverRef inDriver,
                                               AudioObjectID inObjectID,
                                               pid_t /*inClientPID*/,
                                               const AudioObjectPropertyAddress* inAddress,
                                               UInt32 /*inQualifierDataSize*/,
                                               const void* /*inQualifierData*/,
                                               UInt32* outDataSize)
{
    switch (inObjectID) {
        // ---- Plug-in object ----
        case kAudioObjectPlugInObject:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                    *outDataSize = sizeof(AudioClassID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyOwner:
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyManufacturer:
                case kAudioPlugInPropertyResourceBundle:
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyOwnedObjects:
                case kAudioPlugInPropertyDeviceList:
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                case kAudioPlugInPropertyTranslateUIDToDevice:
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
            }
            break;

        // ---- Device object ----
        case kDeviceObjectID:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                    *outDataSize = sizeof(AudioClassID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyOwner:
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyName:
                case kAudioObjectPropertyManufacturer:
                case kAudioDevicePropertyDeviceUID:
                case kAudioDevicePropertyModelUID:
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyTransportType:
                case kAudioDevicePropertyClockDomain:
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyRelatedDevices:
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyDeviceIsAlive:
                case kAudioDevicePropertyDeviceIsRunning:
                case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                case kAudioDevicePropertyIsHidden:
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyLatency:
                case kAudioDevicePropertySafetyOffset:
                case kAudioDevicePropertyZeroTimeStampPeriod:
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyStreams:
                    if (inAddress->mScope == kAudioObjectPropertyScopeGlobal)
                        *outDataSize = 2 * sizeof(AudioObjectID);
                    else
                        *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyControlList:
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyOwnedObjects:
                    *outDataSize = 3 * sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyNominalSampleRate:
                    *outDataSize = sizeof(Float64);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyAvailableNominalSampleRates:
                    *outDataSize = kNumSampleRates * sizeof(AudioValueRange);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyPreferredChannelsForStereo:
                    *outDataSize = 2 * sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyPreferredChannelLayout:
                    *outDataSize = offsetof(AudioChannelLayout, mChannelDescriptions) +
                                   kChannelCount * sizeof(AudioChannelDescription);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyBufferFrameSize:
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyBufferFrameSizeRange:
                    *outDataSize = sizeof(AudioValueRange);
                    return kAudioHardwareNoError;
            }
            break;

        // ---- Stream objects ----
        case kInputStreamObjectID:
        case kOutputStreamObjectID:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                    *outDataSize = sizeof(AudioClassID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyOwner:
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                case kAudioStreamPropertyIsActive:
                case kAudioStreamPropertyDirection:
                case kAudioStreamPropertyTerminalType:
                case kAudioStreamPropertyStartingChannel:
                case kAudioStreamPropertyLatency:
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat:
                    *outDataSize = sizeof(AudioStreamBasicDescription);
                    return kAudioHardwareNoError;
                case kAudioStreamPropertyAvailableVirtualFormats:
                case kAudioStreamPropertyAvailablePhysicalFormats:
                    *outDataSize = kNumSampleRates * sizeof(AudioStreamRangedDescription);
                    return kAudioHardwareNoError;
            }
            break;

        // ---- Volume control ----
        case kVolumeControlObjectID:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                    *outDataSize = sizeof(AudioClassID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyOwner:
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                case kAudioControlPropertyScope:
                    *outDataSize = sizeof(AudioObjectPropertyScope);
                    return kAudioHardwareNoError;
                case kAudioControlPropertyElement:
                    *outDataSize = sizeof(AudioObjectPropertyElement);
                    return kAudioHardwareNoError;
                case kAudioLevelControlPropertyScalarValue:
                    *outDataSize = sizeof(Float32);
                    return kAudioHardwareNoError;
                case kAudioLevelControlPropertyDecibelValue:
                    *outDataSize = sizeof(Float32);
                    return kAudioHardwareNoError;
                case kAudioLevelControlPropertyDecibelRange:
                    *outDataSize = sizeof(AudioValueRange);
                    return kAudioHardwareNoError;
                case kAudioBooleanControlPropertyValue:
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
            }
            break;
    }

    return kAudioHardwareUnknownPropertyError;
}

// =============================================================================
// GetPropertyData
// =============================================================================

OSStatus LoopbackerDriver::GetPropertyData(AudioServerPlugInDriverRef inDriver,
                                           AudioObjectID inObjectID,
                                           pid_t /*inClientPID*/,
                                           const AudioObjectPropertyAddress* inAddress,
                                           UInt32 inQualifierDataSize,
                                           const void* inQualifierData,
                                           UInt32 inDataSize,
                                           UInt32* outDataSize,
                                           void* outData)
{
    auto* driver = AsDriver(inDriver);

    switch (inObjectID) {
        // =====================================================================
        // Plug-in object
        // =====================================================================
        case kAudioObjectPlugInObject:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                    WRITE_PROP(AudioClassID, kAudioObjectClassID);

                case kAudioObjectPropertyClass:
                    WRITE_PROP(AudioClassID, kAudioPlugInClassID);

                case kAudioObjectPropertyOwner:
                    WRITE_PROP(AudioObjectID, kAudioObjectUnknown);

                case kAudioObjectPropertyManufacturer: {
                    if (inDataSize < sizeof(CFStringRef))
                        return kAudioHardwareBadPropertySizeError;
                    *outDataSize = sizeof(CFStringRef);
                    *static_cast<CFStringRef*>(outData) =
                        CFStringCreateWithCString(nullptr, kDeviceManufacturer, kCFStringEncodingUTF8);
                    return kAudioHardwareNoError;
                }

                case kAudioObjectPropertyOwnedObjects:
                case kAudioPlugInPropertyDeviceList: {
                    if (inDataSize < sizeof(AudioObjectID))
                        return kAudioHardwareBadPropertySizeError;
                    *outDataSize = sizeof(AudioObjectID);
                    *static_cast<AudioObjectID*>(outData) = kDeviceObjectID;
                    return kAudioHardwareNoError;
                }

                case kAudioPlugInPropertyTranslateUIDToDevice: {
                    if (inQualifierDataSize < sizeof(CFStringRef) || inQualifierData == nullptr)
                        return kAudioHardwareBadPropertySizeError;
                    CFStringRef uid = *static_cast<const CFStringRef*>(inQualifierData);
                    CFStringRef ourUID = CFStringCreateWithCString(nullptr, kDeviceUID, kCFStringEncodingUTF8);
                    AudioObjectID result = kAudioObjectUnknown;
                    if (CFStringCompare(uid, ourUID, 0) == kCFCompareEqualTo) {
                        result = kDeviceObjectID;
                    }
                    CFRelease(ourUID);
                    *outDataSize = sizeof(AudioObjectID);
                    *static_cast<AudioObjectID*>(outData) = result;
                    return kAudioHardwareNoError;
                }

                case kAudioPlugInPropertyResourceBundle: {
                    if (inDataSize < sizeof(CFStringRef))
                        return kAudioHardwareBadPropertySizeError;
                    *outDataSize = sizeof(CFStringRef);
                    *static_cast<CFStringRef*>(outData) = CFSTR("");
                    return kAudioHardwareNoError;
                }
            }
            break;

        // =====================================================================
        // Device object
        // =====================================================================
        case kDeviceObjectID:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                    WRITE_PROP(AudioClassID, kAudioObjectClassID);

                case kAudioObjectPropertyClass:
                    WRITE_PROP(AudioClassID, kAudioDeviceClassID);

                case kAudioObjectPropertyOwner:
                    WRITE_PROP(AudioObjectID, kAudioObjectPlugInObject);

                case kAudioObjectPropertyName: {
                    if (inDataSize < sizeof(CFStringRef))
                        return kAudioHardwareBadPropertySizeError;
                    *outDataSize = sizeof(CFStringRef);
                    *static_cast<CFStringRef*>(outData) =
                        CFStringCreateWithCString(nullptr, kDeviceName, kCFStringEncodingUTF8);
                    return kAudioHardwareNoError;
                }

                case kAudioObjectPropertyManufacturer: {
                    if (inDataSize < sizeof(CFStringRef))
                        return kAudioHardwareBadPropertySizeError;
                    *outDataSize = sizeof(CFStringRef);
                    *static_cast<CFStringRef*>(outData) =
                        CFStringCreateWithCString(nullptr, kDeviceManufacturer, kCFStringEncodingUTF8);
                    return kAudioHardwareNoError;
                }

                case kAudioDevicePropertyDeviceUID: {
                    if (inDataSize < sizeof(CFStringRef))
                        return kAudioHardwareBadPropertySizeError;
                    *outDataSize = sizeof(CFStringRef);
                    *static_cast<CFStringRef*>(outData) =
                        CFStringCreateWithCString(nullptr, kDeviceUID, kCFStringEncodingUTF8);
                    return kAudioHardwareNoError;
                }

                case kAudioDevicePropertyModelUID: {
                    if (inDataSize < sizeof(CFStringRef))
                        return kAudioHardwareBadPropertySizeError;
                    *outDataSize = sizeof(CFStringRef);
                    *static_cast<CFStringRef*>(outData) =
                        CFStringCreateWithCString(nullptr, kDeviceModelUID, kCFStringEncodingUTF8);
                    return kAudioHardwareNoError;
                }

                case kAudioDevicePropertyTransportType:
                    WRITE_PROP(UInt32, kAudioDeviceTransportTypeVirtual);

                case kAudioDevicePropertyRelatedDevices: {
                    if (inDataSize < sizeof(AudioObjectID))
                        return kAudioHardwareBadPropertySizeError;
                    *outDataSize = sizeof(AudioObjectID);
                    *static_cast<AudioObjectID*>(outData) = kDeviceObjectID;
                    return kAudioHardwareNoError;
                }

                case kAudioDevicePropertyClockDomain:
                    WRITE_PROP(UInt32, 0);

                case kAudioDevicePropertyDeviceIsAlive:
                    WRITE_PROP(UInt32, 1);

                case kAudioDevicePropertyDeviceIsRunning:
                    WRITE_PROP(UInt32, driver->mIOIsRunning.load(std::memory_order_relaxed) > 0 ? 1 : 0);

                case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                    WRITE_PROP(UInt32, 1);

                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                    WRITE_PROP(UInt32, 1);

                case kAudioDevicePropertyLatency:
                    WRITE_PROP(UInt32, 0);

                case kAudioDevicePropertySafetyOffset:
                    WRITE_PROP(UInt32, 0);

                case kAudioDevicePropertyZeroTimeStampPeriod:
                    WRITE_PROP(UInt32, kDefaultIOBufferFrames);

                case kAudioDevicePropertyIsHidden:
                    WRITE_PROP(UInt32, 0);

                case kAudioDevicePropertyStreams: {
                    if (inAddress->mScope == kAudioObjectPropertyScopeInput) {
                        if (inDataSize < sizeof(AudioObjectID))
                            return kAudioHardwareBadPropertySizeError;
                        *outDataSize = sizeof(AudioObjectID);
                        *static_cast<AudioObjectID*>(outData) = kInputStreamObjectID;
                    } else if (inAddress->mScope == kAudioObjectPropertyScopeOutput) {
                        if (inDataSize < sizeof(AudioObjectID))
                            return kAudioHardwareBadPropertySizeError;
                        *outDataSize = sizeof(AudioObjectID);
                        *static_cast<AudioObjectID*>(outData) = kOutputStreamObjectID;
                    } else {
                        UInt32 needed = 2 * sizeof(AudioObjectID);
                        if (inDataSize < needed)
                            return kAudioHardwareBadPropertySizeError;
                        *outDataSize = needed;
                        auto* ids = static_cast<AudioObjectID*>(outData);
                        ids[0] = kInputStreamObjectID;
                        ids[1] = kOutputStreamObjectID;
                    }
                    return kAudioHardwareNoError;
                }

                case kAudioObjectPropertyControlList: {
                    if (inDataSize < sizeof(AudioObjectID))
                        return kAudioHardwareBadPropertySizeError;
                    *outDataSize = sizeof(AudioObjectID);
                    *static_cast<AudioObjectID*>(outData) = kVolumeControlObjectID;
                    return kAudioHardwareNoError;
                }

                case kAudioObjectPropertyOwnedObjects: {
                    UInt32 needed = 3 * sizeof(AudioObjectID);
                    if (inDataSize < needed)
                        return kAudioHardwareBadPropertySizeError;
                    *outDataSize = needed;
                    auto* ids = static_cast<AudioObjectID*>(outData);
                    ids[0] = kInputStreamObjectID;
                    ids[1] = kOutputStreamObjectID;
                    ids[2] = kVolumeControlObjectID;
                    return kAudioHardwareNoError;
                }

                case kAudioDevicePropertyNominalSampleRate: {
                    if (inDataSize < sizeof(Float64))
                        return kAudioHardwareBadPropertySizeError;
                    *outDataSize = sizeof(Float64);
                    std::lock_guard<std::mutex> lock(driver->mMutex);
                    *static_cast<Float64*>(outData) = driver->mSampleRate;
                    return kAudioHardwareNoError;
                }

                case kAudioDevicePropertyAvailableNominalSampleRates: {
                    UInt32 needed = kNumSampleRates * sizeof(AudioValueRange);
                    if (inDataSize < needed)
                        return kAudioHardwareBadPropertySizeError;
                    *outDataSize = needed;
                    auto* ranges = static_cast<AudioValueRange*>(outData);
                    for (UInt32 i = 0; i < kNumSampleRates; ++i) {
                        ranges[i].mMinimum = kSampleRates[i];
                        ranges[i].mMaximum = kSampleRates[i];
                    }
                    return kAudioHardwareNoError;
                }

                case kAudioDevicePropertyPreferredChannelsForStereo: {
                    if (inDataSize < 2 * sizeof(UInt32))
                        return kAudioHardwareBadPropertySizeError;
                    *outDataSize = 2 * sizeof(UInt32);
                    auto* channels = static_cast<UInt32*>(outData);
                    channels[0] = 1;
                    channels[1] = 2;
                    return kAudioHardwareNoError;
                }

                case kAudioDevicePropertyPreferredChannelLayout: {
                    UInt32 needed = offsetof(AudioChannelLayout, mChannelDescriptions) +
                                    kChannelCount * sizeof(AudioChannelDescription);
                    if (inDataSize < needed)
                        return kAudioHardwareBadPropertySizeError;
                    *outDataSize = needed;
                    auto* layout = static_cast<AudioChannelLayout*>(outData);
                    memset(layout, 0, needed);
                    layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
                    layout->mNumberChannelDescriptions = kChannelCount;
                    layout->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Left;
                    layout->mChannelDescriptions[1].mChannelLabel = kAudioChannelLabel_Right;
                    return kAudioHardwareNoError;
                }

                case kAudioDevicePropertyBufferFrameSize:
                    WRITE_PROP(UInt32, kDefaultIOBufferFrames);

                case kAudioDevicePropertyBufferFrameSizeRange: {
                    if (inDataSize < sizeof(AudioValueRange))
                        return kAudioHardwareBadPropertySizeError;
                    *outDataSize = sizeof(AudioValueRange);
                    auto* range = static_cast<AudioValueRange*>(outData);
                    range->mMinimum = kDefaultIOBufferFrames;
                    range->mMaximum = kDefaultIOBufferFrames;
                    return kAudioHardwareNoError;
                }
            }
            break;

        // =====================================================================
        // Stream objects
        // =====================================================================
        case kInputStreamObjectID:
        case kOutputStreamObjectID:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                    WRITE_PROP(AudioClassID, kAudioObjectClassID);

                case kAudioObjectPropertyClass:
                    WRITE_PROP(AudioClassID, kAudioStreamClassID);

                case kAudioObjectPropertyOwner:
                    WRITE_PROP(AudioObjectID, kDeviceObjectID);

                case kAudioStreamPropertyIsActive:
                    WRITE_PROP(UInt32, 1);

                case kAudioStreamPropertyDirection:
                    WRITE_PROP(UInt32, (inObjectID == kInputStreamObjectID) ? 1 : 0);

                case kAudioStreamPropertyTerminalType:
                    WRITE_PROP(UInt32, (inObjectID == kInputStreamObjectID)
                               ? kAudioStreamTerminalTypeMicrophone
                               : kAudioStreamTerminalTypeSpeaker);

                case kAudioStreamPropertyStartingChannel:
                    WRITE_PROP(UInt32, 1);

                case kAudioStreamPropertyLatency:
                    WRITE_PROP(UInt32, 0);

                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat: {
                    if (inDataSize < sizeof(AudioStreamBasicDescription))
                        return kAudioHardwareBadPropertySizeError;
                    *outDataSize = sizeof(AudioStreamBasicDescription);
                    std::lock_guard<std::mutex> lock(driver->mMutex);
                    *static_cast<AudioStreamBasicDescription*>(outData) =
                        MakeStreamDescription(driver->mSampleRate);
                    return kAudioHardwareNoError;
                }

                case kAudioStreamPropertyAvailableVirtualFormats:
                case kAudioStreamPropertyAvailablePhysicalFormats: {
                    UInt32 needed = kNumSampleRates * sizeof(AudioStreamRangedDescription);
                    if (inDataSize < needed)
                        return kAudioHardwareBadPropertySizeError;
                    *outDataSize = needed;
                    auto* descs = static_cast<AudioStreamRangedDescription*>(outData);
                    for (UInt32 i = 0; i < kNumSampleRates; ++i) {
                        descs[i] = MakeRangedDescription(kSampleRates[i]);
                    }
                    return kAudioHardwareNoError;
                }
            }
            break;

        // =====================================================================
        // Volume control
        // =====================================================================
        case kVolumeControlObjectID:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                    WRITE_PROP(AudioClassID, kAudioLevelControlClassID);

                case kAudioObjectPropertyClass:
                    WRITE_PROP(AudioClassID, kAudioVolumeControlClassID);

                case kAudioObjectPropertyOwner:
                    WRITE_PROP(AudioObjectID, kDeviceObjectID);

                case kAudioControlPropertyScope:
                    WRITE_PROP(AudioObjectPropertyScope, kAudioObjectPropertyScopeOutput);

                case kAudioControlPropertyElement:
                    WRITE_PROP(AudioObjectPropertyElement, kAudioObjectPropertyElementMain);

                case kAudioLevelControlPropertyScalarValue: {
                    if (inDataSize < sizeof(Float32))
                        return kAudioHardwareBadPropertySizeError;
                    *outDataSize = sizeof(Float32);
                    std::lock_guard<std::mutex> lock(driver->mMutex);
                    *static_cast<Float32*>(outData) = driver->mVolume;
                    return kAudioHardwareNoError;
                }

                case kAudioLevelControlPropertyDecibelValue: {
                    if (inDataSize < sizeof(Float32))
                        return kAudioHardwareBadPropertySizeError;
                    *outDataSize = sizeof(Float32);
                    std::lock_guard<std::mutex> lock(driver->mMutex);
                    Float32 scalar = driver->mVolume;
                    Float32 dB = (scalar > 0.0f) ? (20.0f * log10f(scalar)) : -96.0f;
                    if (dB < -96.0f) dB = -96.0f;
                    *static_cast<Float32*>(outData) = dB;
                    return kAudioHardwareNoError;
                }

                case kAudioLevelControlPropertyDecibelRange: {
                    if (inDataSize < sizeof(AudioValueRange))
                        return kAudioHardwareBadPropertySizeError;
                    *outDataSize = sizeof(AudioValueRange);
                    auto* range = static_cast<AudioValueRange*>(outData);
                    range->mMinimum = -96.0;
                    range->mMaximum = 0.0;
                    return kAudioHardwareNoError;
                }

                case kAudioBooleanControlPropertyValue: {
                    if (inDataSize < sizeof(UInt32))
                        return kAudioHardwareBadPropertySizeError;
                    *outDataSize = sizeof(UInt32);
                    std::lock_guard<std::mutex> lock(driver->mMutex);
                    *static_cast<UInt32*>(outData) = driver->mMute ? 1 : 0;
                    return kAudioHardwareNoError;
                }
            }
            break;
    }

    return kAudioHardwareUnknownPropertyError;
}

#undef WRITE_PROP

// =============================================================================
// SetPropertyData
// =============================================================================

OSStatus LoopbackerDriver::SetPropertyData(AudioServerPlugInDriverRef inDriver,
                                           AudioObjectID inObjectID,
                                           pid_t /*inClientPID*/,
                                           const AudioObjectPropertyAddress* inAddress,
                                           UInt32 /*inQualifierDataSize*/,
                                           const void* /*inQualifierData*/,
                                           UInt32 inDataSize,
                                           const void* inData)
{
    auto* driver = AsDriver(inDriver);

    switch (inObjectID) {
        case kDeviceObjectID:
            switch (inAddress->mSelector) {
                case kAudioDevicePropertyBufferFrameSize: {
                    // We support a fixed buffer size only, so accept it but ignore the value
                    return kAudioHardwareNoError;
                }

                case kAudioDevicePropertyNominalSampleRate: {
                    if (inDataSize < sizeof(Float64))
                        return kAudioHardwareBadPropertySizeError;
                    Float64 newRate = *static_cast<const Float64*>(inData);
                    bool valid = false;
                    for (UInt32 i = 0; i < kNumSampleRates; ++i) {
                        if (kSampleRates[i] == newRate) { valid = true; break; }
                    }
                    if (!valid)
                        return kAudioDeviceUnsupportedFormatError;

                    {
                        std::lock_guard<std::mutex> lock(driver->mMutex);
                        driver->mSampleRate = newRate;
                        driver->mHostTicksPerFrame = ComputeHostTicksPerFrame(newRate);
                        driver->mRingBuffer->reset();
                    }

                    if (driver->mHost) {
                        AudioObjectPropertyAddress addr = {
                            kAudioDevicePropertyNominalSampleRate,
                            kAudioObjectPropertyScopeGlobal,
                            kAudioObjectPropertyElementMain
                        };
                        driver->mHost->PropertiesChanged(driver->mHost, kDeviceObjectID, 1, &addr);
                    }
                    return kAudioHardwareNoError;
                }
            }
            break;

        case kInputStreamObjectID:
        case kOutputStreamObjectID:
            switch (inAddress->mSelector) {
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat: {
                    if (inDataSize < sizeof(AudioStreamBasicDescription))
                        return kAudioHardwareBadPropertySizeError;
                    const auto* fmt = static_cast<const AudioStreamBasicDescription*>(inData);
                    bool validRate = false;
                    for (UInt32 i = 0; i < kNumSampleRates; ++i) {
                        if (kSampleRates[i] == fmt->mSampleRate) { validRate = true; break; }
                    }
                    if (!validRate)
                        return kAudioDeviceUnsupportedFormatError;
                    {
                        std::lock_guard<std::mutex> lock(driver->mMutex);
                        driver->mSampleRate = fmt->mSampleRate;
                        driver->mHostTicksPerFrame = ComputeHostTicksPerFrame(fmt->mSampleRate);
                        driver->mRingBuffer->reset();
                    }
                    return kAudioHardwareNoError;
                }
            }
            break;

        case kVolumeControlObjectID:
            switch (inAddress->mSelector) {
                case kAudioLevelControlPropertyScalarValue: {
                    if (inDataSize < sizeof(Float32))
                        return kAudioHardwareBadPropertySizeError;
                    Float32 val = *static_cast<const Float32*>(inData);
                    if (val < 0.0f) val = 0.0f;
                    if (val > 1.0f) val = 1.0f;
                    {
                        std::lock_guard<std::mutex> lock(driver->mMutex);
                        driver->mVolume = val;
                    }
                    return kAudioHardwareNoError;
                }

                case kAudioLevelControlPropertyDecibelValue: {
                    if (inDataSize < sizeof(Float32))
                        return kAudioHardwareBadPropertySizeError;
                    Float32 dB = *static_cast<const Float32*>(inData);
                    if (dB < -96.0f) dB = -96.0f;
                    if (dB > 0.0f) dB = 0.0f;
                    Float32 scalar = powf(10.0f, dB / 20.0f);
                    {
                        std::lock_guard<std::mutex> lock(driver->mMutex);
                        driver->mVolume = scalar;
                    }
                    return kAudioHardwareNoError;
                }

                case kAudioBooleanControlPropertyValue: {
                    if (inDataSize < sizeof(UInt32))
                        return kAudioHardwareBadPropertySizeError;
                    UInt32 val = *static_cast<const UInt32*>(inData);
                    {
                        std::lock_guard<std::mutex> lock(driver->mMutex);
                        driver->mMute = (val != 0);
                    }
                    return kAudioHardwareNoError;
                }
            }
            break;
    }

    return kAudioHardwareUnknownPropertyError;
}

// =============================================================================
// IO operations
// =============================================================================

OSStatus LoopbackerDriver::StartIO(AudioServerPlugInDriverRef inDriver,
                                   AudioObjectID /*inDeviceObjectID*/,
                                   UInt32 /*inClientID*/)
{
    auto* driver = AsDriver(inDriver);
    UInt32 prev = driver->mIOIsRunning.fetch_add(1, std::memory_order_acq_rel);
    if (prev == 0) {
        driver->mIOCycleCount = 0;
        driver->mAnchorHostTime = mach_absolute_time();
        driver->mRingBuffer->reset();
    }
    return kAudioHardwareNoError;
}

OSStatus LoopbackerDriver::StopIO(AudioServerPlugInDriverRef inDriver,
                                  AudioObjectID /*inDeviceObjectID*/,
                                  UInt32 /*inClientID*/)
{
    auto* driver = AsDriver(inDriver);
    UInt32 prev = driver->mIOIsRunning.fetch_sub(1, std::memory_order_acq_rel);
    if (prev == 1) {
        driver->mRingBuffer->reset();
    }
    return kAudioHardwareNoError;
}

OSStatus LoopbackerDriver::GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver,
                                            AudioObjectID /*inDeviceObjectID*/,
                                            UInt32 /*inClientID*/,
                                            Float64* outSampleTime,
                                            UInt64* outHostTime,
                                            UInt64* outSeed)
{
    auto* driver = AsDriver(inDriver);

    UInt64 currentHostTime = mach_absolute_time();
    Float64 ticksPerPeriod = driver->mHostTicksPerFrame * static_cast<Float64>(kDefaultIOBufferFrames);

    UInt64 hostElapsed = currentHostTime - driver->mAnchorHostTime;
    UInt64 periodCount = static_cast<UInt64>(static_cast<Float64>(hostElapsed) / ticksPerPeriod);

    *outSampleTime = static_cast<Float64>(periodCount * kDefaultIOBufferFrames);
    *outHostTime = driver->mAnchorHostTime +
                   static_cast<UInt64>(static_cast<Float64>(periodCount) * ticksPerPeriod);
    *outSeed = 1;

    return kAudioHardwareNoError;
}

OSStatus LoopbackerDriver::WillDoIOOperation(AudioServerPlugInDriverRef /*inDriver*/,
                                             AudioObjectID /*inDeviceObjectID*/,
                                             UInt32 /*inClientID*/,
                                             UInt32 inOperationID,
                                             Boolean* outWillDo,
                                             Boolean* outIsInput)
{
    switch (inOperationID) {
        case kAudioServerPlugInIOOperationReadInput:
            *outWillDo = true;
            *outIsInput = true;
            break;
        case kAudioServerPlugInIOOperationWriteMix:
            *outWillDo = true;
            *outIsInput = false;
            break;
        default:
            *outWillDo = false;
            *outIsInput = false;
            break;
    }
    return kAudioHardwareNoError;
}

OSStatus LoopbackerDriver::BeginIOOperation(AudioServerPlugInDriverRef /*inDriver*/,
                                            AudioObjectID /*inDeviceObjectID*/,
                                            UInt32 /*inClientID*/,
                                            UInt32 /*inOperationID*/,
                                            UInt32 /*inIOBufferFrameSize*/,
                                            const AudioServerPlugInIOCycleInfo* /*inIOCycleInfo*/)
{
    return kAudioHardwareNoError;
}

OSStatus LoopbackerDriver::DoIOOperation(AudioServerPlugInDriverRef inDriver,
                                         AudioObjectID /*inDeviceObjectID*/,
                                         AudioObjectID /*inStreamObjectID*/,
                                         UInt32 /*inClientID*/,
                                         UInt32 inOperationID,
                                         UInt32 inIOBufferFrameSize,
                                         const AudioServerPlugInIOCycleInfo* /*inIOCycleInfo*/,
                                         void* ioMainBuffer,
                                         void* /*ioSecondaryBuffer*/)
{
    auto* driver = AsDriver(inDriver);

    switch (inOperationID) {
        case kAudioServerPlugInIOOperationWriteMix: {
            auto* samples = static_cast<const float*>(ioMainBuffer);
            driver->mRingBuffer->write(samples, inIOBufferFrameSize);
            break;
        }

        case kAudioServerPlugInIOOperationReadInput: {
            auto* samples = static_cast<float*>(ioMainBuffer);
            uint32_t framesRead = driver->mRingBuffer->read(samples, inIOBufferFrameSize);
            if (framesRead < inIOBufferFrameSize) {
                uint32_t remainingSamples = (inIOBufferFrameSize - framesRead) * kChannelCount;
                memset(&samples[framesRead * kChannelCount], 0,
                       remainingSamples * sizeof(float));
            }
            break;
        }

        default:
            break;
    }

    return kAudioHardwareNoError;
}

OSStatus LoopbackerDriver::EndIOOperation(AudioServerPlugInDriverRef /*inDriver*/,
                                          AudioObjectID /*inDeviceObjectID*/,
                                          UInt32 /*inClientID*/,
                                          UInt32 /*inOperationID*/,
                                          UInt32 /*inIOBufferFrameSize*/,
                                          const AudioServerPlugInIOCycleInfo* /*inIOCycleInfo*/)
{
    return kAudioHardwareNoError;
}
