# Loopbacker Architecture

A minimal CoreAudio AudioServerPlugin (HAL plugin) that creates virtual stereo
loopback devices on macOS. Audio written to a device's output is immediately
readable from its input -- enabling apps like Discord to capture audio from
hardware interfaces like a MOTU M2.

## Object Model

CoreAudio's HAL plugin interface is a flat object graph where every entity has an
`AudioObjectID`. The host queries properties on these objects by ID. Loopbacker
exposes `kMaxDevices` (currently 3) virtual devices, each with the same shape:

```
PlugIn (ID = kAudioObjectPlugInObject = 1)
  |
  +-- Device 0 (ID = 10)    "Loopbacker"        (LoopbackerDevice_UID)
  |     +-- Input Stream  (ID = 11)   Nch, captures looped-back audio
  |     +-- Output Stream (ID = 12)   Nch, receives audio from apps
  |     +-- Volume Control       (ID = 13)  output-scope volume
  |     +-- Input Volume Control (ID = 14)  input-scope volume
  |
  +-- Device 1 (ID = 20)    "Loopbacker 2"      (LoopbackerDevice_UID_2)
  |     +-- Input Stream  (ID = 21), Output Stream (ID = 22),
  |         Volume Control (ID = 23), Input Volume Control (ID = 24)
  |
  +-- Device 2 (ID = 30)    "Loopbacker Stream"  (LoopbackerDevice_UID_Stream)
        +-- Input Stream  (ID = 31), Output Stream (ID = 32),
            Volume Control (ID = 33), Input Volume Control (ID = 34)
```

The PlugIn object owns every Device. Each Device owns two Streams and two Volume
Controls (`Driver/src/LoopbackerTypes.h`: `VirtualDeviceInfo`, `kDeviceInfos`).
`N` is the device's current `lbch` channel count (see "Per-Device Channel Count"
below), independently configurable per device.

Device 0 and Device 2 report `kAudioStreamTerminalTypeMicrophone`/`...Speaker`
stream terminal types, so strict pickers (Slack, some CallKit clients, OBS) list
them as real microphones. Device 1 reports generic USB Audio Class "undefined"
terminal types so macOS Voice Processing IO (FaceTime, Phone, iPhone-relay)
doesn't model it as a candidate mic and gate the user's actual mic. Device 2
("Loopbacker Stream", the app's "Stream Mix" routing target) exists so a source
can feed a second, independently-mixed virtual mic -- e.g. a stream mix with
music/alerts folded in for OBS -- without disturbing Device 0's route.

## Data Flow

The loopback mechanism is straightforward, repeated per device:

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
   a device's output stream. The plugin writes the samples into that device's
   ring buffer.
2. The host calls `DoIOOperation` with `kAudioServerPlugInIOOperationReadInput` on
   the same device's input stream. The plugin reads the same samples back.
3. `GetZeroTimeStamp` drives each device's virtual clock. It advances sample time
   based on `mach_absolute_time()` at the nominal sample rate.

There is no actual hardware. The plugin synthesizes timestamps from the wall clock.
Each device's `DeviceState` (ring buffer, clock anchors, channel count) is
independent, so one device's IO never blocks or interferes with another's.

## Ring Buffer Design

- **Size**: `kRingBufferFrames` = 2048 frames (power of 2, ~42ms at 48kHz) per
  device, sized at least 4x the default IO buffer to prevent underruns.
- **Format**: Interleaved Float32, `BytesPerFrameForChannelCount(channelCount)`
  bytes/frame -- the device's current `lbch` channel count, not a fixed 2.
- **Indexing**: Atomic 64-bit write position. Read position derived from
  `GetZeroTimeStamp` sample time. Masking with `(size - 1)` for wrap-around.
- **Thread safety**: Lock-free. The host guarantees that `DoIOOperation` calls
  are serialized per stream within an IO cycle. The only shared state is the
  write cursor (atomic store from output, atomic load from input).
- **Zero-copy**: `ReadInput` and `WriteMix` operate directly on the ring buffer
  memory via `memcpy` to/from the host-provided IO buffers. No intermediate
  allocations.

## Virtual Clock

Since there is no real hardware, we synthesize a clock per device:

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
- `anchor_host_time` is captured at `StartIO`, per device.
- `host_ticks_per_frame` = `mach_timebase_info` conversion at nominal sample rate.

## File Structure

```
Driver/
+-- CMakeLists.txt                  # Build system
+-- Info.plist.in                   # Bundle plist template (CMake configures UUIDs)
+-- src/
|   +-- LoopbackerTypes.h           # kMaxDevices, kDeviceInfos, shared constants
|   +-- LoopbackerDriver.h          # Driver struct (DeviceState[kMaxDevices]) + vtable
|   +-- LoopbackerDriver.cpp        # All AudioServerPlugInDriverInterface methods,
|   |                                # generic over device index (no per-device branches)
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
| `LoopbackerTypes.h` | `kMaxDevices`, `kDeviceInfos` (name/UID/object-ID base/terminal types per device), channel-count/sample-rate/ring-buffer constants, and `'lbch'` custom property selector. Adding a device means adding one `VirtualDeviceInfo` entry and bumping `kMaxDevices`; nothing else in the driver assumes a device count. |
| `LoopbackerDriver.h/cpp` | The `AudioServerPlugInDriverInterface` vtable and IUnknown methods (`QueryInterface`, `AddRef`, `Release`), `Initialize`, `CreateDevice`/`DestroyDevice` (both unsupported), client management, property handling (`HasProperty`/`GetPropertyData`/`SetPropertyData`/...), and IO dispatch (`StartIO`/`StopIO`/`GetZeroTimeStamp`/`DoIOOperation`) for every device, stream, and control, keyed generically by `FindDeviceByObjectID`. |
| `RingBuffer.h` | ~60 lines. A trivial lock-free SPSC ring buffer. `write(const float*, frameCount)` and `read(float*, frameCount, atFrame)`. Header-only, no allocations after construction. |

### Why Not More Files

A HAL plugin is inherently a single flat interface with ~20 function pointers.
Splitting further (a class per device, a class per stream) adds indirection
without benefit at this scale: every device shares identical property/IO logic,
dispatched by object ID through `FindDeviceByObjectID`, so there is nothing
device-specific to factor out into its own file. BlackHole uses a single .cpp
file for the same reason.

## AudioObjectID Assignment

IDs are derived at compile time from `kMaxDevices` and each device's index,
not individually hardcoded:

```cpp
// Plugin itself is always kAudioObjectPlugInObject (1).
// Device N gets base ID (N+1)*10:
//   deviceID = (N+1)*10, inputStreamID = +1, outputStreamID = +2,
//   volumeControlID = +3, inputVolumeControlID = +4.
// Today: Device 0 -> 10-14, Device 1 -> 20-24, Device 2 -> 30-34.
```

`FindDeviceByObjectID` inverts this (`group = objectID / 10`, `offset = objectID
% 10`) to find the owning `DeviceState` for any object ID in O(1), generic over
`kMaxDevices` -- adding a device needs no change here. No dynamic allocation of
IDs; the host queries `kAudioObjectPropertyOwnedObjects`/`kAudioPlugInPropertyDeviceList`
on the PlugIn, and we return every device's fixed ID.

## Properties We Must Implement

Every device implements the same property set (values below are per-device,
substituting that device's own IDs/UID/name/channel count):

### PlugIn (ID 1)
- `kAudioObjectPropertyClass` -> `kAudioPlugInClassID`
- `kAudioObjectPropertyOwnedObjects` -> every device's ID
- `kAudioPlugInPropertyDeviceList` -> every device's ID
- `kAudioPlugInPropertyResourceBundle` -> `""`
- `kAudioObjectPropertyManufacturer` -> `"JacobCoffee"`

### Device (e.g. ID 10, 20, 30)
- `kAudioObjectPropertyClass` -> `kAudioDeviceClassID`
- `kAudioObjectPropertyName` -> the device's name (`"Loopbacker"`, `"Loopbacker 2"`, `"Loopbacker Stream"`)
- `kAudioDevicePropertyDeviceUID` -> the device's UID (e.g. `"LoopbackerDevice_UID_Stream"`)
- `kAudioDevicePropertyModelUID` -> `"LoopbackerDevice_ModelUID"` (shared)
- `kAudioObjectPropertyManufacturer` -> `"JacobCoffee"`
- `kAudioObjectPropertyOwnedObjects` -> `[inputStreamID, outputStreamID, volumeControlID, inputVolumeControlID]`
- `kAudioDevicePropertyStreams` (input scope) -> `[inputStreamID]`
- `kAudioDevicePropertyStreams` (output scope) -> `[outputStreamID]`
- `kAudioDevicePropertyNominalSampleRate` -> `48000.0` (locked; see `kSampleRates`)
- `kAudioDevicePropertyBufferFrameSize` -> `kDefaultIOBufferFrames` (settable)
- `kLoopbackerDevicePropertyChannelCount` (`'lbch'`) -> this device's current channel count (settable, even 2-16; see "Per-Device Channel Count")
- `kAudioDevicePropertyLatency` -> `0`
- `kAudioDevicePropertySafetyOffset` -> `0`
- `kAudioDevicePropertyZeroTimeStampPeriod` -> `kRingBufferFrames`
- `kAudioDevicePropertyClockIsStable` -> `1`
- `kAudioDevicePropertyClockAlgorithm` -> `kAudioDeviceClockAlgorithmRaw`
- `kAudioDevicePropertyIsRunning` -> `(0 or 1)`, per device
- `kAudioDevicePropertyIsAlive` -> `1`
- `kAudioDevicePropertyDeviceCanBeDefaultDevice` -> `1`
- `kAudioDevicePropertyDeviceCanBeDefaultSystemDevice` -> `1`
- `kAudioObjectPropertyControlList` -> `[volumeControlID, inputVolumeControlID]`
- `kAudioDevicePropertyTransportType` -> `kAudioDeviceTransportTypeVirtual`
- `kAudioDevicePropertyRelatedDevices` -> this device's own ID only (devices are not related to each other)

### Input Stream
- `kAudioObjectPropertyClass` -> `kAudioStreamClassID`
- `kAudioStreamPropertyDirection` -> `1` (input)
- `kAudioStreamPropertyTerminalType` -> the device's `inputTerminalType` (microphone, or undefined for Device 1)
- `kAudioStreamPropertyStartingChannel` -> `1`
- `kAudioStreamPropertyPhysicalFormat`/`VirtualFormat` -> `{48000, 'lpcm', kFloat32, <channelCount>ch, interleaved}`
- `kAudioStreamPropertyAvailablePhysicalFormats` -> every supported channel count at 48 kHz
- `kAudioStreamPropertyLatency` -> `0`
- `kAudioObjectPropertyOwnedObjects` -> `[]`

### Output Stream
- Same as Input Stream but `kAudioStreamPropertyDirection` -> `0` (output)
- `kAudioStreamPropertyTerminalType` -> the device's `outputTerminalType`

### Volume Control / Input Volume Control
- `kAudioObjectPropertyClass` -> `kAudioVolumeControlClassID`
- `kAudioObjectPropertyScope` -> `kAudioObjectPropertyScopeOutput` / `kAudioObjectPropertyScopeInput`
- `kAudioLevelControlPropertyScalarValue` -> `1.0` (settable)
- `kAudioLevelControlPropertyDecibelValue` -> `0.0` (settable)
- `kAudioLevelControlPropertyDecibelRange` -> `{-96.0, 0.0}`

## Driver Struct

```cpp
struct DeviceState {
    const char* name; const char* uid;
    AudioObjectID deviceID, inputStreamID, outputStreamID, volumeControlID, inputVolumeControlID;
    Float64 sampleRate;
    std::atomic<UInt32> ioIsRunning;
    UInt64  ioCycleCount;
    Float32 volume; bool mute;
    UInt32  inputTerminalType, outputTerminalType;
    std::unique_ptr<RingBuffer> ringBuffer;
    std::vector<float> snapshotBuffer;        // broadcast-read snapshot for this IO cycle
    std::atomic<bool>  needsSnapshot;
    UInt64  anchorHostTime; Float64 hostTicksPerFrame;
    std::atomic<UInt32> channelCount;          // current 'lbch' value, IO-thread safe
    UInt32  pendingChannelCount;               // guarded by LoopbackerDriver::mMutex
};

struct LoopbackerDriver {
    AudioServerPlugInDriverInterface* mInterface;  // COM vtable pointer -- MUST be first field
    std::atomic<UInt32> mRefCount;
    AudioServerPlugInHostRef mHost;
    DeviceState mDevices[kMaxDevices];
    std::mutex mMutex;                              // shared across all devices
    static AudioServerPlugInDriverInterface sInterface;
};
```

The static vtable is defined once and `mInterface` points to its address --
standard COM/CFPlugIn layout. `mDevices` is a fixed-size array sized by
`kMaxDevices`; every device shares the same mutex for non-realtime property
changes (channel count, etc.) since those are rare and never on the IO path.

## Build System (CMake)

```cmake
cmake_minimum_required(VERSION 3.20)
project(Loopbacker LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_OSX_DEPLOYMENT_TARGET "11.0")

add_library(Loopbacker MODULE
    src/PluginEntry.cpp
    src/LoopbackerDriver.cpp
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

This produces `Loopbacker.driver/` as a proper macOS bundle. Build with
`cd Driver && cmake -B build && cmake --build build`.

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
directory and loads the new plugin -- all `kMaxDevices` devices appear together.
No reboot required.

Uninstall is the reverse: delete the bundle, restart coreaudiod.

## Key Design Decisions

### 1. Pure C interface, C++ internals

The AudioServerPlugIn interface is C (COM-style vtable). We implement it with
free functions that cast `inDriver` to our `LoopbackerDriver*` struct. Internals
use C++ for `std::atomic`, but nothing heavier -- no STL containers on the IO
path, no exceptions, no RTTI.

**Rationale**: The IO path runs on a realtime thread. No allocations, no locks,
no exceptions. C++ atomics are the only concession.

### 2. Fixed device set, no dynamic creation

`CreateDevice` / `DestroyDevice` return `kAudioHardwareUnsupportedOperationError`.
The driver's `kMaxDevices` devices exist from plugin load to unload; adding one
means adding a `VirtualDeviceInfo` entry and rebuilding/reinstalling the driver,
not calling a runtime API.

**Rationale**: Simplicity and predictability -- every object ID is a compile-time
constant, so no part of the driver (or the app's `AudioRouter`) has to handle a
device appearing or disappearing mid-session. BlackHole ships separate binaries
per channel count for the same reason; we instead parameterize the device count
at compile time via `kMaxDevices`/`kDeviceInfos`.

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
0 on every device. Since there is no real hardware, there is no pipeline delay.

**Rationale**: Minimizes the total roundtrip latency reported to apps.

## Per-Device Channel Count (`lbch`)

Each virtual device's channel count is independently configurable (even
integers 2-16, default 2) via a custom property, not a compile-time constant.
Input and output streams on a device always share the same count.

- **Property**: selector `kLoopbackerDevicePropertyChannelCount` (FourCC
  `'lbch'`), scope `kAudioObjectPropertyScopeGlobal`, element
  `kAudioObjectPropertyElementMain`. Listed in the device's
  `kAudioObjectPropertyCustomPropertyInfoList` with data type
  `kAudioServerPlugInCustomPropertyDataTypeCFPropertyList` (a `CFNumber`
  holding the channel count as `kCFNumberSInt32Type`).
- **Validation**: `SetPropertyData` rejects anything outside even integers in
  `[2, kMaxChannelCount]` with `kAudioHardwareIllegalOperationError`. Setting
  the current value is a no-op that returns `noErr`.
- **Apply flow (e.g. 2 -> 4 channels)**:
  1. `SetPropertyData` validates the new count, stores it in
     `DeviceState::pendingChannelCount` (guarded by `mMutex`), and calls
     `RequestDeviceConfigurationChange`.
  2. The HAL stops IO on the device and calls back into
     `PerformDeviceConfigurationChange`.
  3. `PerformDeviceConfigurationChange` is the only place (besides
     `Initialize`) allowed to reallocate: it rebuilds the device's
     `RingBuffer` and `snapshotBuffer` sized for the new channel count,
     stores the count atomically on `DeviceState::channelCount`, and writes
     it to host storage.
  4. The HAL re-reads `kAudioStreamPropertyVirtualFormat` /
     `PhysicalFormat` on both streams, which now report the new
     `mChannelsPerFrame` / `mBytesPerFrame`; no manual format-change
     notification is sent.
- **Persistence**: `PerformDeviceConfigurationChange` calls
  `host->WriteToStorage` with key `"channelCount.<deviceUID>"` and a
  `CFNumber` value. `Initialize` restores it per device via
  `host->CopyFromStorage`, falling back to the default (2) if the key is
  absent or the stored value is invalid. Keys are per-device-UID, so each of
  the three devices persists its own width independently.
- **IO path**: `DoIOOperation` reads `DeviceState::channelCount` with an
  atomic load (real-time safe — no allocation/lock/logging) to size its
  `memcpy`/volume-scaling loops; the value only changes while IO is stopped.
- **Channel layout**: channel 1 -> Left, channel 2 -> Right, channel 3+ ->
  `kAudioChannelLabel_Discrete_<index>`. `kAudioDevicePropertyPreferredChannelsForStereo`
  always reports `[1, 2]` regardless of channel count.

### App side

The app sets `lbch` through `VirtualDeviceChannels` and owns the desired counts:

- **Virtual mic** (`VirtualDeviceChannels.micUID` = `LoopbackerDevice_UID`): the
  Routing canvas's output channels rounded up to a pair (`RoutingState.micChannelCount`).
  The ⊕/⊖ buttons add or remove a pair.
- **Stream Mix** (`VirtualDeviceChannels.streamUID` = `LoopbackerDevice_UID_Stream`):
  a second, independent set of channels (`RoutingState.streamOutputChannels`,
  `streamMicChannelCount`), hidden behind `RoutingState.streamMixEnabled` (a
  toggle in the routing canvas header) so existing users see no change until
  they opt in. Sized and routed exactly like the virtual mic, just into a
  different device and a disjoint set of `AudioRoute`s (`AudioRoute.targetId`).
- **Output devices** (e.g. `LoopbackerDevice_UID_2`): `OutputDestination.channelCount`,
  plus `monitorChannel`, the first channel of the pair played to the physical output.

`AudioRouter.setVirtualDeviceChannels` stops every route whose target is the
resized device (identified by `RouteContext.playbackDeviceUID == deviceUID`,
regardless of source), sets the property, waits (≤2 s) for the HAL to report the
new stream configuration, and restarts those same routes. Saved counts for every
device (virtual mic, Stream Mix, output destinations) are pushed before any
route starts at launch.

**Routing targets.** `AudioRoute` carries a `targetId: RouteTarget` (`.virtualMic`
or `.streamMix`; routes saved before Stream Mix existed decode as `.virtualMic`).
The router runs one `RouteContext` per (source device, target device) pair, each
with its own mix matrix (`AudioRoute.sourceChannelId` -> `.outputChannelId` for
that target only) and its own input/output AUHAL pair, keyed internally by both
source and target so a source can feed the virtual mic, Stream Mix, both, or
neither independently. This mirrors the existing mic-route/monitor-route split
(two separate `RouteContext`s on the same capture device) rather than
introducing a new sharing mechanism.

Each `RouteContext` has independent widths: `inputChannels` (every channel of the
source, capped at 64) and `outputChannels` (the target device's current width,
which can differ between the virtual mic and Stream Mix). One block flows:

```
capture (inputChannels) → source meter → mix matrix (outputChannels × inputChannels)
  → noise suppression on channels 1–2 (voice routes only)
  → voice FXChain on channels 1–2 (voice routes) or AppAudioProcessor (app-capture routes;
    output routes get neither)
  → output meter → drift-compensated ring → playback
```

Noise suppression and the voice `FXChain` run **once per capture device**, not
once per route: every voice route on the same capture device (virtual mic,
Stream Mix, monitor) shares one `NoiseSuppressor` and one `FXChain` instance,
published through an unretained atomic pointer the IO thread reads
(`RouteContext.noiseSlot`/`fxSlot`). Both caches key a processed block by HAL
sample time and are width-agnostic: the cached data is always a canonical
stereo/mono pair, and both the cache-hit and cache-miss paths write/read it
through the *calling* route's own `stride`/`outputChannels`, never anything
cached from whichever route happened to compute the block first -- so the
virtual mic (e.g. 2 channels) and Stream Mix (e.g. 4 channels) routes on the
same mic correctly share one computation despite their different output widths.

Output routing captures every channel of the virtual device and mixes the monitor pair
to the physical output's first two channels, so other channels (a timecode track, for
example) stay on the device for other apps to record without reaching the speakers.

Meter levels go to an `@Observable` `MeterLevels` store rather than the routing model, split
per route and per channel (`SourceLevelStore`, `ChannelLevelBox`) and quantized to 1/256, so a
30 Hz meter tick re-renders only the meters and cables whose own level visibly moved. Post-mix
output levels are tracked per target device (`MeterLevels.updateOutputs(target:_:)`), so the
virtual mic's and Stream Mix's meters never bleed into each other even though both number
their channels from 1.

## Noise Suppression

`NoiseSuppressor` runs one of three engines (`DenoiseKernel`s) on the CPU, inline in the capture
callback. Only routes fed by a physical input use it (mic → virtual mic, mic → Stream Mix,
mic → monitor); app captures and output routes don't.

- **DPDFNet** (`DPDFNetKernel`): CEVA's DPDFNet2 48 kHz model (Apache-2.0) through BNNS Graph,
  which executes a compiled graph with caller-provided workspace and buffers, with no
  allocation, locks or thread hops: ~0.6 ms per 10 ms hop on an M4 Max (p99 ~1.3 ms per
  512-frame callback). A 20 ms Vorbis-window STFT (10 ms hop), one model execution per hop with
  a ping-pong recurrent state, then ISTFT/overlap-add. The workspace and buffers live in one
  `mlock`ed mapping; the compiled graph is read into wired memory too, since a file mapping
  could page-fault from disk mid-callback. Kernel delay: 2400 samples (4 hops of model
  lookahead plus a hop for the second half of the analysis window).
- **FastEnhancer** (`FastEnhancerKernel`): aask1357's FastEnhancer-S 48 kHz model (MIT) through
  the same BNNS Graph setup as DPDFNet (they share `CompiledGraph`, generalised over the
  model's bundle name and its four argument names). 212K parameters -- tiny next to DPDFNet --
  so it measures ~0.2 ms per 10.67 ms hop (~2% of a core). A 1024-sample/512-hop Hann-window
  STFT, one model execution per hop with a ping-pong recurrent state (the per-frequency-bin
  GRUs' hidden states, flattened), then ISTFT with FastEnhancer's own COLA synthesis window
  (not a symmetric analysis/synthesis window like DPDFNet's). FastEnhancer is zero-lookahead:
  every layer but the GRUs is purely per-frame (strided convs and self-attention across
  frequency bins, never across time), so unlike DPDFNet it has no model-inherent lookahead.
  Kernel delay: 512 samples (one hop), measured by passing an impulse through the exact
  analysis/synthesis framing with an identity mask -- matching FastEnhancer's reported
  zero-lookahead, ~10.7 ms algorithmic latency. Zero heap allocations on the execute path,
  checked the same way as DPDFNet (an interposed `malloc`, 500 hops).
- **RNNoise** (`RNNoiseKernel`): Xiph's RNNoise v0.2 (BSD-3-Clause), vendored as the `CRNNoise`
  C target with its default model compiled in. ~0.2 ms per hop. `rnnoise_init(_, NULL)` resets
  state without allocating. Kernel delay: 960 samples (analysis over two frames, plus
  overlap-add). Its state and scratch buffers are `mlock`ed; the weights stay in the binary's
  read-only data (mlock refuses those pages) and are read every hop.

The engine-independent part is `NoiseSuppressor`: it downmixes channels 1–2 to mono, feeds
the kernel hop-sized blocks (480 samples for DPDFNet/RNNoise, 512 for FastEnhancer -- any hop
size works, `NoiseSuppressor` doesn't assume one), and blends the dry signal (delayed by the
kernel's delay) back in at the user's max-reduction level. Its buffers are `mlock`ed as well.
`process(_:frames:stride:sampleTime:)` caches the processed mono/stereo pair keyed by
`sampleTime`; a later caller with the same `sampleTime` and frame count gets the cached result
written through its *own* `stride`, so routes of different output widths sharing one
suppressor (e.g. the virtual mic at 2 channels and Stream Mix at 4) are handled correctly
without any width-specific logic.

Compiling DPDFNet or FastEnhancer takes roughly a second, so the compiled graph
(`CompiledGraph`, shared by `NoiseSuppressionModel` and `FastEnhancerModel`) is cached in
`~/Library/Caches/<bundle id>/`, keyed by a hash of the model and the OS build; loading from
the cache takes ~30 ms. Either way it loads on a background queue: routes start immediately,
and the router attaches suppressors when the model is ready, which then fade in as usual.

The audio thread reaches the suppressor through an unretained atomic pointer
(`RouteContext.noiseSlot`), so the router queue can swap it at any time. The router attaches a
suppressor when suppression is on, the engine matches, and the source hasn't opted out
(`AudioSource.noiseSuppression`). Otherwise it fades the suppressor to dry (10 ms), clears the
slot after 100 ms, and drops its reference 0.5 s later, once no callback can still be inside
it. Switching engines goes old wet → dry → new wet with no click. The router holds each
model-backed engine's compiled model weakly, behind a small generic `NoiseModelLoadState`, so
the model (DPDFNet ~13 MB, FastEnhancer <1 MB) is freed with the last kernel that uses it.

`NoiseEngineBenchmark` times 200 hops of each engine once per launch, when the Effects section
first shows the picker. It recommends FastEnhancer while it takes at most 20% of a core (one
512-frame callback can run roughly two hops alongside the mix and effects), and RNNoise
otherwise. FastEnhancer is also the default engine for new setups. DPDFNet is never the
recommendation: it cleans up slightly more, but its 60 ms of delay matters more on a live mic.

Every voice route on the same capture device shares one suppressor: the virtual mic route,
the Stream Mix route, and the monitor route, when more than one exists. They mix identically
(the mix matrix only differs in output *width*, not which source channels feed channels 1-2),
and the HAL calls their input callbacks back to back on the device's IO thread with the same
sample time, so the first one to run computes the block and the others copy it (a busy flag
leaves a block dry if two threads ever collided).

Latency is constant regardless of buffer size: the kernel's delay plus up to a hop waiting for
the current hop to fill. That's 60 ms (2879 samples) for DPDFNet, 21 ms (1023) for
FastEnhancer, and 30 ms (1439) for RNNoise. Switching on passes the dry signal until real
output arrives, then crossfades over 10 ms; switching off crossfades back. Suppression only
runs at 48 kHz; a monitor route on a device at another rate logs and stays dry.

`scripts/convert-dpdfnet.py` rebuilds `App/Loopbacker/Resources/DPDFNet2_48k.mlmodelc` from
pinned upstream code and weights. It replaces the DPRNN blocks' bidirectional `nn.GRU`s with
an unrolled equivalent: Core ML's `gru` op applies the reset gate differently from PyTorch, so
coremltools lowers `nn.GRU` to `WhileLoop`s that Core ML interprets step by step, which was
three quarters of inference time. Unrolled, a hop takes ~0.7 ms of CPU instead of ~1.3 ms on an
M4 Max (hot cache). Weights are stored as fp16 (`constexpr_cast` back to fp32), halving the
model to 7 MB; compute stays fp32, and BNNS expands the weights once at compile time, so speed
is unchanged. The script checks the result against the unmodified upstream PyTorch model over
~500 stateful frames (~61 dB SNR, set by the fp16 weights; ~127 dB with fp32 weights). fp16
compute and the Neural Engine were tried: fp16 compute breaks the output (~9 dB SNR), and the
Neural Engine gives nothing for an fp32 model.

`scripts/convert-fastenhancer.py` rebuilds `App/Loopbacker/Resources/FastEnhancer_S_48k.mlmodelc`
from pinned upstream code (commit `85d98a6`) and the `fastenhancer_s` checkpoint (release
`ckpt-v1.0.0-48khz`, epoch 500). FastEnhancer-S's `ONNXModel.forward` already takes one STFT
frame plus the per-block GRU caches and returns the enhanced frame plus the next caches -- the
same shape as DPDFNet's traced graph -- so the conversion is a plain `torch.jit.trace` plus
`coremltools.convert` with no custom op lowering: a single-layer unidirectional `nn.GRU` and
`scaled_dot_product_attention` both convert natively (unlike DPDFNet's bidirectional,
chunked GRU). Weights stay fp32 (212K parameters is under 1 MB either way, so there's no size
reason to compress). Parity against the unmodified upstream PyTorch model over 484 frames
(STFT frames of a real signal plus random spectra): 127.2 dB SNR, worst frame 1.26e-5 relative
error. Three checkpoints share this hop size (10.67 ms) at increasing size/quality -- t (29K
params), b (104K), s (212K) -- with authors' own VoiceBank+DEMAND-48k validation PESQ/STOI of
2.73/0.937, 2.92/0.944 and 2.98/0.947 respectively; s is shipped since BNNS Graph runs it in a
small fraction of the ~1 ms/hop budget regardless of size, so quality decided it.

### Quality

`scripts/eval-denoisers/` measures noisy input and all three engines on the VoiceBank+DEMAND
48 kHz test set (824 real noisy/clean speech pairs, Edinburgh DataShare), through the literal
app kernels: `denoise-cli` is `swiftc`-compiled directly from the committed
`DenoiseKernel`/`NoiseSuppressor` sources (not a reimplementation), fed in 512-sample blocks the
way a capture callback would. `eval.py` delay-compensates each engine's output by its kernel
delay, then reports PESQ (wide-band, 16 kHz), ESTOI, SI-SDR and DNSMOS P.835 (official ONNX
model) at -60 dB max reduction:

| Engine | PESQ (wb) | ESTOI | SI-SDR (dB) | DNSMOS SIG | DNSMOS BAK | DNSMOS OVRL |
|---|---|---|---|---|---|---|
| Noisy input | 1.97 | 0.79 | 8.4 | 3.34 | 3.13 | 2.70 |
| DPDFNet | 3.04 | 0.86 | 18.8 | 3.40 | 4.02 | 3.13 |
| FastEnhancer | 2.99 | 0.86 | 18.2 | 3.35 | 4.02 | 3.07 |
| RNNoise | 2.47 | 0.84 | 13.2 | 3.38 | 4.02 | 3.09 |

DPDFNet and FastEnhancer both clean up far more than RNNoise (SI-SDR and PESQ), with DPDFNet
slightly ahead of FastEnhancer on every metric -- consistent with the authors' own
VoiceBank+DEMAND numbers for FastEnhancer-S against stronger non-causal baselines. FastEnhancer
gets close to DPDFNet's cleanup at roughly a third of its latency and CPU, which is why it's the
recommended engine and the default. Re-run with
`scripts/eval-denoisers/build.sh && scripts/eval-denoisers/eval.py`.

## Effects Chain

The voice chain is an ordered list of `FXNode` stages (`EffectsPreset.nodes`, each an
`FXNodeConfig`): built-ins (gate, EQ, compressor, leveler, de-esser, chorus, pitch shift, reverb,
delay, limiter) plus hosted third-party effects (Audio Unit, JSFX, Airwindows). `FXChain` runs
that list for one capture device, shared by every voice route on the device (virtual mic,
Stream Mix, and monitor) exactly like `NoiseSuppressor`: the routes' input callbacks run back to
back on the device's IO thread with the same HAL sample time, so the first route to see a block
computes it and the others copy the cached result -- the cache (`FXChain.cachedInterleaved`) is
a fixed-width stereo pair written and read through each caller's own `stride`, so it stays
correct across routes of different output widths. Each block is deinterleaved into planar
scratch buffers (processed mono when the voice pair is bitwise identical, e.g. a mono mic
fanned to L+R), run through the nodes, then reinterleaved; blocks larger than `FXBlock.maxFrames`
(4096) are split.

`FXChain` also runs a `VoiceActivityDetector` on the block's mono mix and publishes the latest
speech probability to `VoiceBus`, an app-wide atomic (max over every active chain, decaying when
chains stop). `AppAudioProcessor`, run on app-capture routes instead of the voice chain, reads
`VoiceBus` to duck game/music/browser audio while you're talking, and optionally runs a
`LevelerNode` to hold it at a target loudness. Output routes (virtual device → speakers) run
neither.

**Edits.** Structural changes (add/remove/reorder a node, change its kind, or swap its hosted
plugin) build a new immutable `ChainGraph` off the IO thread -- reusing existing node instances
by `FXNodeConfig.id` where the kind and plugin didn't change, loading hosted nodes
asynchronously before publishing -- then swap it in with one atomic pointer exchange. The swap is
declicked: the outgoing graph's last block fades to silence, the incoming graph's first block
fades in from silence. The outgoing graph is freed only after the IO thread has marked it
retired (a busy/epoch flag), never from the IO thread itself. Param-only edits (values, `enabled`,
EQ bands) skip the rebuild and push straight into the live instances' `FXParamStore` (and
`EQNode.setBands`).

**Bypass.** Each node's own `enabled` flag crossfades over 10 ms against a dry signal delayed by
that node's own `latencySamples`, so toggling a node with nonzero latency doesn't jump: the dry
tap and the node's wet output are time-aligned. Chain latency is the sum of every node's
`latencySamples`, independent of which nodes are enabled, so toggling a node never moves the
chain's overall delay. `FXChain.setABBypass` additionally bypasses every stage at once with
loudness matching: it measures input vs. output RMS while voice probability is above 0.5 over a
~3 s window and applies that ratio (smoothed) to the bypassed signal, so A/B comparison is about
tone, not volume.

**Recording.** Each `FXChain` has a lock-free SPSC `FXRecorder` that, once armed from the main
thread, captures up to 30 s of the mono raw mic mix (before noise suppression) alongside the
mono chain output, for an A/B listen.

`FXEngine` (`@MainActor`, owned by the app alongside `RoutingSync`/`AudioRouter`) is the UI-facing
facade: it surfaces the first active voice device's chain for meters/latency/plugin-load-error
display, fans `setABBypass` out to every running chain, scans the three hosted-effect catalogs
for the effect browser, and persists hosted-plugin state into the preset via
`captureHostedStates`.

**Persistence.** `EffectsPreset` is versioned (`version = 2`); `init(from:)` migrates the v1
shape (fixed flat `gateEnabled`/`gateThresholdDB`/... fields with no `nodes` key) into an
equivalent `nodes` array in the original fixed order, decoding v2 JSON (which carries `nodes`)
unchanged. `EffectsPreset.appAudio` holds the app-capture ducking/leveling settings separately
from `nodes`, since app-capture routes never run the voice chain.


## UI Cost

SwiftUI work on the main thread is kept off the per-display-frame path:

- **Meters** (`LiveSignalMeter`, used by channel strips and source peaks) are Core Animation
  layers (a gradient masked to the filled length) that observe their `MeterLevels` value
  themselves with `withObservationTracking`. A 30 Hz tick resizes a mask layer: no SwiftUI body
  evaluation, layout pass or re-rasterization. Driving meters through SwiftUI cost ~16% of a core
  on the Routing page with every meter moving. `SignalMeter(level:)` uses the same layers for
  value-driven meters (Soundboard). There is no animation between levels; the router's 30 Hz
  decay is the ballistics.
- **Cables** (`CableView`) are Core Animation layers, same as the meters: SwiftUI supplies
  structure (routes, which sources are enabled/muted, connector positions) and only reshapes
  layers when it changes, while each live source's glow is driven separately by observing
  `MeterLevels` inside the `NSView`, quantized to 16 steps. The glow is a wide low-opacity stroke
  layer plus a native `shadowRadius`/`shadowOpacity` for softness, not a Gaussian blur filter,
  which previously forced the whole routing canvas to be re-rasterized on the main thread on
  every step change (~6% of a core with all meters moving). `ConnectorEnd.output` carries the
  target device, so the virtual mic and Stream Mix columns' channel 1 connectors (and their
  cables) never collide despite sharing channel numbers.
- **Looping animations** (`LiveDot`'s halo, `SignalLineConnector`'s travelling dot) are
  `CAAnimation`s on a `LoopingDot` layer. A repeating SwiftUI animation re-runs the view graph
  and window layout every display frame; Core Animation runs it in the render server.
- **Hidden windows**: closing the main window only hides it, and SwiftUI keeps its view graph
  alive. The meter timer publishes only while a window that shows meters is on screen (the menu
  bar icon's own window always reports visible and is ignored).

## Benchmarks

`scripts/bench/` holds the tooling used to measure noise-suppression and audio-thread cost
on a given machine, independent of the app's own UI.

- **`model-bench.sh`** (wraps `model-bench.swift` + `count.c`) runs the shipped
  `DPDFNet2_48k.mlmodelc` through BNNS Graph the way the audio thread runs it: single-thread
  compile, pointer arguments into a preallocated page-aligned workspace, and a ping-ponged
  recurrent state -- no Core ML worker thread, no per-hop allocation. It reports compile time,
  hot ms/hop, and paced per-hop wall/CPU time (one hop every 10 ms on a time-constraint
  thread, matching the audio IO cadence), with a malloc/free interposer (`count.c`, loaded via
  `DYLD_INSERT_LIBRARIES`) confirming the execute path allocates nothing on the heap. `--coreml`
  additionally reports parity (SNR) against running the same frames through Core ML. On an M4
  Max: ~1.4 s single-thread compile, 0.55 ms/hop hot, paced median/p99/max ~0.7/1.9/2.3 ms, 0
  allocations. `FastEnhancer_S_48k.mlmodelc` isn't wired into `model-bench.sh` (it's
  DPDFNet-shaped only), but the same technique applied ad hoc gives ~0.2 ms/hop hot (BNNS
  execute alone ~0.2 ms; full kernel including the STFT/ISTFT vDSP work ~0.2 ms, run-to-run
  noise dominates the difference) and 0 allocations over 500 hops, both with and without the
  STFT/ISTFT around it.
- **`tone.swift`** plays a quiet 440 Hz tone with level swinging -40..-20 dBFS at 1.5 Hz to a
  named output device via `AudioQueue`, so meters and any level-dependent processing keep
  moving during a measurement without needing real program audio.
- **`perthread.py`** parses a `sample` report and prints each thread's active (non-idle) % of
  a core plus its top leaf (innermost sampled) frames, filtering out known idle leaf frames
  (kernel waits, `start_wqthread`, etc.) so blocked threads don't look busy.
- **`app-bench.sh`** relaunches a given `Loopbacker.app` build and records process-level CPU
  (`ps` cumulative cputime delta over wall time) and per-thread CPU with the app in the
  background (window open but not activated, so usually covered: meters don't publish), and
  optionally (`--visible`, which steals focus and sends ⌘1/⌘2) Routing- and Effects-page-visible
  states. It picks out the main thread, any thread named "noise", and the summed CPU of threads
  named `HALB`/`IOThread`/`com.apple.audio`, where noise suppression now runs. Results append
  to a TSV for comparing runs.

## Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Clock drift vs. real hardware | Glitches when aggregating with MOTU M2 | Use `kAudioDeviceClockAlgorithmRaw` and keep timestamps precise. For aggregate device use, the host handles drift compensation. The app's own routes (input AUHAL on one device, output AUHAL on another) bridge clocks through `DriftCompensatedRing`, which resamples by up to ±0.1% to hold the ring at its target fill; a measured M2 runs ~45 ppm slow vs. the host clock, which drained the old plain ring into continuous crackle within minutes. |
| Ring buffer overrun/underrun | Silence or stale audio | 2048-frame-per-device buffer provides >4x the default IO buffer size of headroom. Log (to stderr/syslog) on wrap. |
| coreaudiod crash on bad property response | System-wide audio failure | Extensive testing of every property the host queries, on every device. Return `kAudioHardwareUnknownPropertyError` for anything unexpected. |
| Code signing on macOS 13+ | Plugin may not load | Ad-hoc signing (`codesign -s -`) is sufficient for local use. Distribution requires a Developer ID. |
| Apple Silicon / Intel | Must run on both | CMake `CMAKE_OSX_ARCHITECTURES "arm64;x86_64"` for universal binary. |
| A new virtual device isn't VPIO-safe or mic-class by mistake | FaceTime/Phone gates the real mic, or OBS/Discord can't see it | Each `VirtualDeviceInfo` entry picks its own `inputTerminalType`/`outputTerminalType` explicitly (mic-class for Device 0 and 2, generic for Device 1); adding a device means choosing this deliberately, not inheriting a default. |

## Testing Strategy

1. **Build and load**: Install, restart coreaudiod, verify all `kMaxDevices`
   devices appear in Audio MIDI Setup (Loopbacker, Loopbacker 2, Loopbacker
   Stream).
2. **Property audit**: Use `coreaudiod` log output and/or a test harness that
   calls `AudioObjectGetPropertyData` for every property we claim to support,
   on every device.
3. **Loopback test**: Play audio to a device's output, record from that same
   device's input, compare waveforms (should be bit-identical with no volume
   scaling). Repeat per device.
4. **Channel count**: Switch each device's `lbch` through its supported range
   and verify no crashes and the new width is reported and persisted.
5. **Aggregate device**: Create an aggregate with MOTU M2 + Loopbacker, verify
   Discord can capture the aggregate input.
6. **App-side manual test plan** (after installing the new driver, see the
   PR/issue report for the exact steps): devices appear with the right names
   and terminal types, OBS/streaming apps see "Loopbacker Stream" as a
   selectable microphone, a source routes independently to Virtual Mic and
   Stream Mix, and each target's channel count can be changed without
   affecting the other.

## Future Considerations (Out of Scope for v0.1)

- A preferences app / menu bar utility for configuration
- Volume scaling in the IO path
- Per-client isolation (separate ring buffers per client)
- Notarization and pkg installer for distribution
