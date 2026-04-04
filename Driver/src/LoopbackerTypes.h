#pragma once

#include <CoreAudio/AudioServerPlugIn.h>
#include <cstdint>

// Number of virtual devices this plugin exposes
static const uint32_t kMaxDevices = 8;

// Object IDs
// Plugin itself is always kAudioObjectPlugInObject (1).
// Device N gets base ID (N+1)*10:
//   Device 0: deviceID=10, inputStreamID=11, outputStreamID=12, volumeControlID=13
//   Device N: deviceID=(N+1)*10, ...

struct VirtualDeviceInfo {
    const char* name;
    const char* uid;
    AudioObjectID deviceID;
    AudioObjectID inputStreamID;
    AudioObjectID outputStreamID;
    AudioObjectID volumeControlID;
};

static const VirtualDeviceInfo kDeviceInfos[kMaxDevices] = {
    { "Loopbacker",   "LoopbackerDevice_UID",   10, 11, 12, 13 },
    { "Loopbacker 2", "LoopbackerDevice_UID_2", 20, 21, 22, 23 },
    { "Loopbacker 3", "LoopbackerDevice_UID_3", 30, 31, 32, 33 },
    { "Loopbacker 4", "LoopbackerDevice_UID_4", 40, 41, 42, 43 },
    { "Loopbacker 5", "LoopbackerDevice_UID_5", 50, 51, 52, 53 },
    { "Loopbacker 6", "LoopbackerDevice_UID_6", 60, 61, 62, 63 },
    { "Loopbacker 7", "LoopbackerDevice_UID_7", 70, 71, 72, 73 },
    { "Loopbacker 8", "LoopbackerDevice_UID_8", 80, 81, 82, 83 },
};

// Device metadata
static const char* kDeviceManufacturer = "JacobCoffee";
static const char* kDeviceModelUID     = "LoopbackerDevice_ModelUID";

// Audio format constants
static const uint32_t kChannelCount    = 2;
static const uint32_t kBitsPerChannel  = 32;
static const uint32_t kBytesPerFrame   = kChannelCount * (kBitsPerChannel / 8); // 8

// Supported sample rates
static const Float64 kSampleRates[] = { 44100.0, 48000.0, 96000.0 };
static const uint32_t kNumSampleRates = 3;
static const Float64 kDefaultSampleRate = 48000.0;

// Ring buffer
static const uint32_t kRingBufferFrames = 512; // must be power of 2 (~10.7ms at 48kHz)

// IO
static const uint32_t kDefaultIOBufferFrames = 256;
