#pragma once

#include <CoreAudio/AudioServerPlugIn.h>
#include <cstdint>

// Object IDs
static const AudioObjectID kPlugInObjectID       = kAudioObjectPlugInObject; // 1
static const AudioObjectID kDeviceObjectID       = 2;
static const AudioObjectID kInputStreamObjectID  = 3;
static const AudioObjectID kOutputStreamObjectID = 4;
static const AudioObjectID kVolumeControlObjectID = 5;

// Device metadata
static const char* kDeviceName         = "Loopbacker";
static const char* kDeviceManufacturer = "JacobCoffee";
static const char* kDeviceUID          = "LoopbackerDevice_UID";
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
