#pragma once

#include <CoreAudio/AudioServerPlugIn.h>
#include <cstdint>

// Number of virtual devices this plugin exposes
static const uint32_t kMaxDevices = 3;

// Object IDs
// Plugin itself is always kAudioObjectPlugInObject (1).
// Device N gets base ID (N+1)*10:
//   Device 0: deviceID=10, inputStreamID=11, outputStreamID=12, volumeControlID=13
//   Device 1: deviceID=20, inputStreamID=21, outputStreamID=22, volumeControlID=23
//   Device 2: deviceID=30, inputStreamID=31, outputStreamID=32, volumeControlID=33

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
static const uint32_t kRingBufferFrames = 16384; // must be power of 2

// IO
static const uint32_t kDefaultIOBufferFrames = 512;
