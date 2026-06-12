#pragma once

#include <CoreAudio/AudioServerPlugIn.h>
#include <cstdint>

// Number of virtual devices this plugin exposes
static const uint32_t kMaxDevices = 2;

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
    AudioObjectID volumeControlID;       // output scope
    AudioObjectID inputVolumeControlID;  // input scope (shows "Input volume" in System Settings)

    // Per-device stream terminal types. Device 0 reports Microphone/Speaker so
    // strict pickers (Slack, some CallKit clients) list it. Device 1 reports
    // generic USB Audio Class undefined terminals so macOS Voice Processing IO
    // (FaceTime, Phone, iPhone-relay) doesn't model it as a real mic and gate
    // the user's actual mic to near-silence.
    UInt32 inputTerminalType;
    UInt32 outputTerminalType;
};

// USB Audio Class terminal types (CoreAudio doesn't expose constants for these).
static const UInt32 kTerminalTypeInputUndefined  = 0x0200;
static const UInt32 kTerminalTypeOutputUndefined = 0x0300;

static const VirtualDeviceInfo kDeviceInfos[kMaxDevices] = {
    // Device 0: app-compatible (Microphone-class). Visible in apps that filter
    // input devices by terminal type, but VPIO will treat it as a candidate mic.
    { "Loopbacker",   "LoopbackerDevice_UID",   10, 11, 12, 13, 14,
      kAudioStreamTerminalTypeMicrophone, kAudioStreamTerminalTypeSpeaker },
    // Device 1: VPIO-safe (generic terminals). Hidden from strict pickers but
    // FaceTime/Phone won't gate the user's real mic when this device exists.
    { "Loopbacker 2", "LoopbackerDevice_UID_2", 20, 21, 22, 23, 24,
      kTerminalTypeInputUndefined, kTerminalTypeOutputUndefined },
};

// Device metadata
static const char* kDeviceManufacturer = "JacobCoffee";
static const char* kDeviceModelUID     = "LoopbackerDevice_ModelUID";

// Audio format constants
static const uint32_t kChannelCount    = 2;
static const uint32_t kBitsPerChannel  = 32;
static const uint32_t kBytesPerFrame   = kChannelCount * (kBitsPerChannel / 8); // 8

// Supported sample rates — locked to 48kHz to prevent browsers (Firefox/Chrome)
// from changing the rate and breaking active routes. Browsers resample on their end.
static const Float64 kSampleRates[] = { 48000.0 };
static const uint32_t kNumSampleRates = 1;
static const Float64 kDefaultSampleRate = 48000.0;

// Ring buffer
static const uint32_t kRingBufferFrames = 2048; // must be power of 2 (~42ms at 48kHz)

// IO
static const uint32_t kDefaultIOBufferFrames = 256;

// Compile-time guards: ring buffer must be power-of-two and large enough
// to hold at least 4x the IO buffer to prevent underruns.
static_assert((kRingBufferFrames & (kRingBufferFrames - 1)) == 0,
              "kRingBufferFrames must be a power of two");
static_assert(kRingBufferFrames >= kDefaultIOBufferFrames * 4,
              "kRingBufferFrames must be at least 4x kDefaultIOBufferFrames");
