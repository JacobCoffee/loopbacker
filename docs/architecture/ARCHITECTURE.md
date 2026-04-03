# Loopbacker Architecture

A minimal CoreAudio AudioServerPlugin (HAL plugin) that creates a virtual stereo
loopback device on macOS. Audio written to the device's output is immediately
readable from its input -- enabling apps like Discord to capture audio from
hardware interfaces like a MOTU M2.

## Object Model

CoreAudio's HAL plugin interface is a flat object graph where every entity has an
`AudioObjectID`. The host queries properties on these objects by ID. Loopbacker
exposes exactly five objects:

```
PlugIn (ID = kAudioObjectPlugInObject = 1)
  |
  +-- Device (ID = 2)   "Loopbacker"
        |
        +-- Input Stream  (ID = 3)   2ch, captures looped-back audio
        +-- Output Stream (ID = 4)   2ch, receives audio from apps
        +-- Volume Control (ID = 5)  master output volume (optional, nice UX)
```

The PlugIn object owns the Device. The Device owns two Streams and optionally a
Volume Control. That is the entire object hierarchy.

## Data Flow

The loopback mechanism is straightforward:

```
App A (e.g. Music.app)           App B (e.g. Discord)
       |                                ^
       | WriteMix (output)              | ReadInput (input)
       v                                |
   +---+--------------------------------+---+
   |        Ring Buffer (Float32)            |
   |    per-channel, power-of-2 frames      |
   +----------------------------------------+
```

1. The host calls `DoIOOperation` with `kAudioServerPlugInIOOperationWriteMix` on
   the output stream. The plugin writes the samples into the ring buffer.
2. The host calls `DoIOOperation` with `kAudioServerPlugInIOOperationReadInput` on
   the input stream. The plugin reads the same samples from the ring buffer.
3. `GetZeroTimeStamp` drives the virtual clock. It advances sample time based on
   `mach_absolute_time()` at the nominal sample rate.

There is no actual hardware. The plugin synthesizes timestamps from the wall clock.

## Ring Buffer Design

- **Size**: 65536 frames (power of 2, ~1.36s at 48kHz). Large enough to absorb
  jitter, small enough to stay in L2 cache.
- **Format**: Interleaved Float32, 2 channels = 8 bytes/frame.
- **Indexing**: Atomic 64-bit write position. Read position derived from
  `GetZeroTimeStamp` sample time. Masking with `(size - 1)` for wrap-around.
- **Thread safety**: Lock-free. The host guarantees that `DoIOOperation` calls
  are serialized per stream within an IO cycle. The only shared state is the
  write cursor (atomic store from output, atomic load from input).
- **Zero-copy**: `ReadInput` and `WriteMix` operate directly on the ring buffer
  memory via `memcpy` to/from the host-provided IO buffers. No intermediate
  allocations.

## Virtual Clock

Since there is no real hardware, we synthesize a clock:

```
GetZeroTimeStamp() {
    now = mach_absolute_time()
    elapsed_host_ticks = now - anchor_host_time
    elapsed_frames = elapsed_host_ticks / host_ticks_per_frame
    zero_sample_time = (elapsed_frames / period) * period   // quantize to period
    zero_host_time = anchor_host_time + (zero_sample_time * host_ticks_per_frame)
    return (zero_sample_time, zero_host_time, seed)
}
```

- `period` = `kAudioDevicePropertyZeroTimeStampPeriod` (we use the buffer size,
  minimum 10923 per Apple docs -- we will use 16384).
- `anchor_host_time` is captured at `StartIO`.
- `host_ticks_per_frame` = `mach_timebase_info` conversion at nominal sample rate.

## File Structure

```
loopbacker/
+-- CMakeLists.txt                  # Build system
+-- Info.plist.in                   # Bundle plist template (CMake configures UUIDs)
+-- src/
|   +-- LoopbackerDriver.h          # Main driver struct + vtable
|   +-- LoopbackerDriver.cpp        # All AudioServerPlugInDriverInterface methods
|   +-- LoopbackerDevice.h          # Device/Stream/Control property handling
|   +-- LoopbackerDevice.cpp        # Device property getters/setters
|   +-- RingBuffer.h                # Lock-free ring buffer (header-only)
|   +-- PluginEntry.cpp             # CFPlugIn factory function (extern "C" entry point)
+-- scripts/
|   +-- install.sh                  # Build + copy to /Library/Audio/Plug-Ins/HAL/
|   +-- uninstall.sh                # Remove + restart coreaudiod
+-- docs/
|   +-- architecture/
|       +-- ARCHITECTURE.md         # This file
+-- LICENSE
```

### Why These Files

| File | Responsibility |
|---|---|
| `PluginEntry.cpp` | Exports `Loopbacker_Create` (the CFPlugIn factory). Allocates the driver struct, returns `IUnknown`. ~50 lines. |
| `LoopbackerDriver.h/cpp` | The `AudioServerPlugInDriverInterface` vtable and IUnknown methods (`QueryInterface`, `AddRef`, `Release`), plus `Initialize`, `CreateDevice`, `DestroyDevice`, client management, and IO dispatch. This is the "router" -- it looks at the ObjectID and delegates to the device. |
| `LoopbackerDevice.h/cpp` | All property handling for the Device, its two Streams, and the Volume Control. This is where `HasProperty`, `GetPropertyData`, `SetPropertyData`, `StartIO`, `StopIO`, `GetZeroTimeStamp`, and `DoIOOperation` live for object IDs 2-5. |
| `RingBuffer.h` | ~60 lines. A trivial lock-free SPSC ring buffer. `write(const float*, frameCount)` and `read(float*, frameCount, atFrame)`. Header-only, no allocations after construction. |

### Why Not More Files

A HAL plugin is inherently a single flat interface with ~20 function pointers.
Splitting further (separate Stream class, separate Control class) adds
indirection without benefit at this scale. BlackHole uses a single .cpp file for
the same reason. We use two files (Driver + Device) purely to separate routing
from property logic.

## AudioObjectID Assignment

All IDs are compile-time constants:

```cpp
enum : AudioObjectID {
    kPlugInObjectID     = kAudioObjectPlugInObject,  // 1 (Apple-defined)
    kDeviceObjectID     = 2,
    kInputStreamID      = 3,
    kOutputStreamID     = 4,
    kVolumeControlID    = 5,
};
```

No dynamic allocation of IDs. The host queries `kAudioObjectPropertyOwnedObjects`
on each parent, and we return the children by their fixed IDs.

## Properties We Must Implement

### PlugIn (ID 1)
- `kAudioObjectPropertyClass` -> `kAudioPlugInClassID`
- `kAudioObjectPropertyOwnedObjects` -> `[kDeviceObjectID]`
- `kAudioPlugInPropertyDeviceList` -> `[kDeviceObjectID]`
- `kAudioPlugInPropertyResourceBundle` -> `""`
- `kAudioObjectPropertyManufacturer` -> `"Loopbacker"`

### Device (ID 2)
- `kAudioObjectPropertyClass` -> `kAudioDeviceClassID`
- `kAudioObjectPropertyName` -> `"Loopbacker"`
- `kAudioDevicePropertyDeviceUID` -> `"Loopbacker_UID"`
- `kAudioDevicePropertyModelUID` -> `"Loopbacker_ModelUID"`
- `kAudioObjectPropertyManufacturer` -> `"Loopbacker"`
- `kAudioObjectPropertyOwnedObjects` -> `[kInputStreamID, kOutputStreamID, kVolumeControlID]`
- `kAudioDevicePropertyStreams` (input scope) -> `[kInputStreamID]`
- `kAudioDevicePropertyStreams` (output scope) -> `[kOutputStreamID]`
- `kAudioDevicePropertyNominalSampleRate` -> `48000.0` (settable: 44100, 48000, 96000)
- `kAudioDevicePropertyAvailableNominalSampleRates` -> `[44100, 48000, 96000]`
- `kAudioDevicePropertyBufferFrameSize` -> `512` (settable, range 64-8192)
- `kAudioDevicePropertyBufferFrameSizeRange` -> `{64, 8192}`
- `kAudioDevicePropertyLatency` -> `0`
- `kAudioDevicePropertySafetyOffset` -> `0`
- `kAudioDevicePropertyZeroTimeStampPeriod` -> `16384`
- `kAudioDevicePropertyClockIsStable` -> `1`
- `kAudioDevicePropertyClockAlgorithm` -> `kAudioDeviceClockAlgorithmRaw`
- `kAudioDevicePropertyIsRunning` -> `(0 or 1)`
- `kAudioDevicePropertyIsAlive` -> `1`
- `kAudioDevicePropertyDeviceCanBeDefaultDevice` -> `1`
- `kAudioDevicePropertyDeviceCanBeDefaultSystemDevice` -> `1`
- `kAudioObjectPropertyControlList` -> `[kVolumeControlID]`
- `kAudioDevicePropertyTransportType` -> `kAudioDeviceTransportTypeVirtual`
- `kAudioDevicePropertyRelatedDevices` -> `[kDeviceObjectID]`

### Input Stream (ID 3)
- `kAudioObjectPropertyClass` -> `kAudioStreamClassID`
- `kAudioStreamPropertyDirection` -> `1` (input)
- `kAudioStreamPropertyTerminalType` -> `kAudioStreamTerminalTypeMicrophone`
- `kAudioStreamPropertyStartingChannel` -> `1`
- `kAudioStreamPropertyPhysicalFormat` -> `{48000, 'lpcm', kFloat32, 2ch, interleaved}`
- `kAudioStreamPropertyVirtualFormat` -> same
- `kAudioStreamPropertyAvailablePhysicalFormats` -> all rate/format combos
- `kAudioStreamPropertyLatency` -> `0`
- `kAudioObjectPropertyOwnedObjects` -> `[]`

### Output Stream (ID 4)
- Same as Input Stream but `kAudioStreamPropertyDirection` -> `0` (output)
- `kAudioStreamPropertyTerminalType` -> `kAudioStreamTerminalTypeSpeaker`

### Volume Control (ID 5)
- `kAudioObjectPropertyClass` -> `kAudioVolumeControlClassID`
- `kAudioObjectPropertyScope` -> `kAudioObjectPropertyScopeOutput`
- `kAudioLevelControlPropertyScalarValue` -> `1.0` (settable)
- `kAudioLevelControlPropertyDecibelValue` -> `0.0` (settable)
- `kAudioLevelControlPropertyDecibelRange` -> `{-96.0, 0.0}`

## Driver Struct (C layout for CFPlugIn COM compatibility)

```cpp
struct LoopbackerDriver {
    // COM vtable pointer -- MUST be first field
    AudioServerPlugInDriverInterface** mInterface;

    // Reference count (atomic)
    std::atomic<UInt32> mRefCount;

    // Host interface (set during Initialize)
    AudioServerPlugInHostRef mHost;

    // Device state
    std::atomic<bool>    mIORunning;
    std::atomic<UInt32>  mIOClientCount;
    Float64              mSampleRate;      // current nominal
    UInt32               mBufferFrameSize; // current buffer size
    Float32              mVolume;          // 0.0 - 1.0

    // Clock state
    UInt64  mAnchorHostTime;  // mach_absolute_time at StartIO
    UInt64  mAnchorSampleTime;
    UInt64  mClockSeed;

    // Ring buffer
    RingBuffer mRingBuffer;

    // Mutex for non-realtime property changes (sample rate, etc.)
    pthread_mutex_t mMutex;
};
```

The static vtable is defined once and the `mInterface` field points to its
address. This is standard COM/CFPlugIn layout.

## Build System (CMake)

```cmake
cmake_minimum_required(VERSION 3.20)
project(Loopbacker LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_OSX_DEPLOYMENT_TARGET "11.0")

add_library(Loopbacker MODULE
    src/PluginEntry.cpp
    src/LoopbackerDriver.cpp
    src/LoopbackerDevice.cpp
)

set_target_properties(Loopbacker PROPERTIES
    BUNDLE TRUE
    BUNDLE_EXTENSION "driver"
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_SOURCE_DIR}/Info.plist.in"
    PREFIX ""
    SUFFIX ""
)

target_link_libraries(Loopbacker PRIVATE
    "-framework CoreAudio"
    "-framework CoreFoundation"
)

# Export only the factory symbol
set_target_properties(Loopbacker PROPERTIES
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN ON
)
```

This produces `Loopbacker.driver/` as a proper macOS bundle.

## Info.plist

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>English</string>
    <key>CFBundleExecutable</key>
    <string>Loopbacker</string>
    <key>CFBundleIdentifier</key>
    <string>dev.jacobcoffee.loopbacker</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Loopbacker</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleSignature</key>
    <string>????</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFPlugInFactories</key>
    <dict>
        <!-- Factory UUID: unique to Loopbacker -->
        <key>A8E4B1C0-7D3F-4E5A-9B2C-1F6E8D9A0B3C</key>
        <string>Loopbacker_Create</string>
    </dict>
    <key>CFPlugInTypes</key>
    <dict>
        <!-- kAudioServerPlugInTypeUUID = 443ABAB8-E7B3-491A-B985-BEB9187030DB -->
        <key>443ABAB8-E7B3-491A-B985-BEB9187030DB</key>
        <array>
            <string>A8E4B1C0-7D3F-4E5A-9B2C-1F6E8D9A0B3C</string>
        </array>
    </dict>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
</dict>
</plist>
```

Critical: `CFPlugInTypes` maps Apple's well-known `kAudioServerPlugInTypeUUID` to
our factory UUID. `CFPlugInFactories` maps our factory UUID to the C symbol name
`Loopbacker_Create`. The host uses this to find and call our entry point.

## Installation

```bash
#!/bin/bash
# scripts/install.sh
set -euo pipefail

BUILD_DIR="build"
INSTALL_DIR="/Library/Audio/Plug-Ins/HAL"
DRIVER_NAME="Loopbacker.driver"

cmake -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=Release
cmake --build "$BUILD_DIR"

sudo rm -rf "$INSTALL_DIR/$DRIVER_NAME"
sudo cp -R "$BUILD_DIR/$DRIVER_NAME" "$INSTALL_DIR/"
sudo launchctl kickstart -kp system/com.apple.audio.coreaudiod
```

The `launchctl kickstart -kp` restarts `coreaudiod`, which rescans the HAL
directory and loads the new plugin. No reboot required.

Uninstall is the reverse: delete the bundle, restart coreaudiod.

## Key Design Decisions

### 1. Pure C interface, C++ internals

The AudioServerPlugIn interface is C (COM-style vtable). We implement it with
free functions that cast `inDriver` to our `LoopbackerDriver*` struct. Internals
use C++ for `std::atomic`, but nothing heavier -- no STL containers, no
exceptions, no RTTI.

**Rationale**: The IO path runs on a realtime thread. No allocations, no locks,
no exceptions. C++ atomics are the only concession.

### 2. Single device, no dynamic creation

`CreateDevice` / `DestroyDevice` return `kAudioHardwareUnsupportedOperationError`.
The device exists from plugin load to unload.

**Rationale**: Simplicity. BlackHole does the same. Multiple devices would be a
separate binary (like BlackHole16ch vs BlackHole2ch).

### 3. Interleaved Float32

The native format is 32-bit float, interleaved, at the nominal sample rate. The
host handles format conversion for clients that request something different.

**Rationale**: Float32 interleaved is the simplest format that avoids any
conversion in the common case (most macOS audio is Float32).

### 4. No volume scaling in the IO path

The volume control exists for UX (shows a slider in Sound preferences). But we
do not apply gain in `DoIOOperation` -- the data passes through unmodified.

**Rationale**: Keep the IO path as thin as possible. If volume scaling is
desired later, it is a single multiply in the ReadInput path.

### 5. Zero latency / zero safety offset

Both `kAudioDevicePropertyLatency` and `kAudioDevicePropertySafetyOffset` return
0. Since there is no real hardware, there is no pipeline delay.

**Rationale**: Minimizes the total roundtrip latency reported to apps.

## Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Clock drift vs. real hardware | Glitches when aggregating with MOTU M2 | Use `kAudioDeviceClockAlgorithmRaw` and keep timestamps precise. For aggregate device use, the host handles drift compensation. |
| Ring buffer overrun/underrun | Silence or stale audio | 65536-frame buffer provides >1s headroom. Log (to stderr/syslog) on wrap. |
| coreaudiod crash on bad property response | System-wide audio failure | Extensive testing of every property the host queries. Return `kAudioHardwareUnknownPropertyError` for anything unexpected. |
| Code signing on macOS 13+ | Plugin may not load | Ad-hoc signing (`codesign -s -`) is sufficient for local use. Distribution requires a Developer ID. |
| Apple Silicon / Intel | Must run on both | CMake `CMAKE_OSX_ARCHITECTURES "arm64;x86_64"` for universal binary. |

## Testing Strategy

1. **Build and load**: Install, restart coreaudiod, verify device appears in
   Audio MIDI Setup.
2. **Property audit**: Use `coreaudiod` log output and/or a test harness that
   calls `AudioObjectGetPropertyData` for every property we claim to support.
3. **Loopback test**: Play audio to Loopbacker output, record from Loopbacker
   input, compare waveforms (should be bit-identical with no volume scaling).
4. **Multi-rate**: Switch between 44.1/48/96kHz and verify no crashes.
5. **Aggregate device**: Create an aggregate with MOTU M2 + Loopbacker, verify
   Discord can capture the aggregate input.

## Future Considerations (Out of Scope for v0.1)

- Multiple channel counts (separate binaries like BlackHole)
- A preferences app / menu bar utility for configuration
- Volume scaling in the IO path
- Per-client isolation (separate ring buffers per client)
- Notarization and pkg installer for distribution
