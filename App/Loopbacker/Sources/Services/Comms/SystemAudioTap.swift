import CoreAudio
import AudioToolbox
import Foundation
import os.log

private let tapLogger = Logger(subsystem: "com.jacobcoffee.loopbacker", category: "SystemAudioTap")

/// TCC ("System Audio Recording Only") permission state for the process tap.
///
/// The SDK exposes no dedicated "not authorized" `OSStatus` for process taps (unlike
/// `TCCAccessPreflight` for the camera/mic), so denial is inferred from any tap/aggregate
/// creation failure: `.denied` once a creation call has failed, `.granted` once one has
/// succeeded, `.unknown` before the first attempt.
enum SystemAudioTapPermission: Sendable, Equatable {
    case unknown
    case granted
    case denied
}

enum SystemAudioTapError: Error, Sendable, Equatable, LocalizedError {
    case tapCreationFailed(OSStatus)
    case aggregateCreationFailed(OSStatus)
    case ioProcCreationFailed(OSStatus)
    case ioProcStartFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .tapCreationFailed(let status): "Could not create a system audio tap (\(status)). Check System Settings > Privacy & Security > Microphone/System Audio Recording."
        case .aggregateCreationFailed(let status): "Could not create the private aggregate device for the system audio tap (\(status))."
        case .ioProcCreationFailed(let status): "Could not install the tap's IO callback (\(status))."
        case .ioProcStartFailed(let status): "Could not start the system audio tap's IO (\(status))."
        }
    }
}

enum SystemAudioTapState: Sendable, Equatable {
    case stopped
    case running
    /// The default output device is one of Loopbacker's own virtual devices, or there is no
    /// default output device at all: there's no physical speaker for echo cancellation to
    /// matter against, so the tap doesn't run (no coreaudiod round trip, no TCC prompt) until
    /// the default output becomes a real device again. `EchoCanceller` stays attached to
    /// voice routes regardless; with the ring getting nothing written to it, AEC3's reverse
    /// stream is silence, so it finds no echo to cancel and effectively passes the mic through.
    case noPhysicalOutput
    case failed(SystemAudioTapError)
}

/// Core Audio process tap capturing exactly what the *current default output device* plays, as
/// the far-end reference for `EchoCanceller`.
///
/// Uses the macOS 14.2+ process tap API (`CATapDescription` + `AudioHardwareCreateProcessTap`),
/// scoped to the default output device's UID and first stream (`initExcludingProcesses:
/// andDeviceUID:withStream:`, refined in Swift as `init(excludingProcesses:deviceUID:stream:)`)
/// rather than a global tap: a global tap mixes every process's rendered audio regardless of
/// which device it plays to, so audio apps rendering only into one of Loopbacker's own virtual
/// output devices would pollute the reference with sound that either never reaches a speaker
/// at all, or reaches one through a separate output route and would then be double-counted,
/// offset in time from the system-output copy. Scoping to the device that's actually driving
/// real speakers right now is the only way the reference matches "what the mic can physically
/// pick up". `isMixdown`/`isMono` are set explicitly (stereo) after construction since the
/// scoped initializer otherwise matches the tapped stream's native channel count, which the
/// aggregate/IOProc/ring below assume is always 2 (see `systemAudioTapIOProc`'s channel guard).
/// Wrapped in a private, tap-only aggregate device so it can be driven with a device IOProc
/// like any other HAL device.
///
/// Deliberately does *not* exclude Loopbacker's own process from the tap. The only audio
/// Loopbacker itself renders to a real output device is the monitor route (you hearing your
/// own processed voice through real speakers) plus incidental UI sounds -- genuine sources of
/// acoustic echo the mic will pick up, exactly like any other app's audio. The thing that might
/// look like it needs excluding, the virtual mic, never appears in this tap at all regardless:
/// it's an *input* device other apps capture from, not something CoreAudio mixes into any
/// process's rendered *output*, which is the only thing a process tap captures. So there's no
/// "self-echo" to guard against here, and excluding Loopbacker would instead leave the monitor
/// path's real acoustic echo uncancelled.
///
/// If the default output device *is* one of Loopbacker's own virtual devices (nothing plays to
/// real speakers right now), `rebuild` skips creating a tap entirely and reports
/// `.noPhysicalOutput` -- there's nothing for echo cancellation to do until a real device is
/// the default again, at which point the default-output-device listener rebuilds.
///
/// Thread contract: `start`/`stop`/`rebuild` run on the main actor and are not real-time safe —
/// they allocate Objective-C tap/aggregate-device objects and talk to coreaudiod. The IOProc
/// installed on the aggregate device's real-time thread (`systemAudioTapIOProc`, a top-level C
/// function, never a method) touches only the raw pointer in `IOContext` — no Swift reference
/// counting, locks, or allocation — and writes into `ring`, which `EchoCanceller` reads on its
/// own capture device's IO thread via `DriftCompensatedRing`'s single-writer/single-reader
/// contract.
@MainActor
final class SystemAudioTap: ObservableObject {
    /// Ring capacity: ~1.4 s at 48 kHz stereo, comfortably covering the 40–150 ms bulk delays
    /// this is meant to compensate for plus scheduling jitter.
    private static let ringCapacityFrames: UInt32 = 1 << 16
    /// Startup cushion / steering target. `EchoCanceller`'s adaptive filter is causal — it can
    /// only cancel echo that lags the reference it reads by more than this ring's own group
    /// delay, since that delay eats into the budget before the bulk acoustic delay even starts.
    /// Kept small (20 ms) so it stays well below the shortest acoustic bulk delay worth
    /// compensating; see `EchoCancellerTests` and the integration note in the task report for
    /// the open question of how this interacts with reverberant (room-impulse-response) echo.
    /// `AudioRouter` reads this to fold the ring's own latency into its HAL-based stream-delay
    /// estimate for AEC3.
    nonisolated static let referenceTargetFillFrames: UInt32 = 960

    @Published private(set) var state: SystemAudioTapState = .stopped
    @Published private(set) var permission: SystemAudioTapPermission = .unknown

    /// Far-end reference ring, stereo at 48 kHz. `EchoCanceller` reads from this.
    let ring: DriftCompensatedRing

    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var defaultOutputListenerInstalled = false
    private let ioContext: UnsafeMutablePointer<IOContext>

    init() {
        ring = DriftCompensatedRing(capacityFrames: Self.ringCapacityFrames, channels: 2,
                                     targetFill: Self.referenceTargetFillFrames, sampleRate: 48_000)
        ioContext = UnsafeMutablePointer<IOContext>.allocate(capacity: 1)
        ioContext.initialize(to: IOContext(ring: Unmanaged.passUnretained(ring).toOpaque()))
    }

    isolated deinit {
        // Views only ever release this after `stop()`; this is a backstop so a forgotten
        // `stop()` doesn't leak the HAL-side tap/aggregate past the object's lifetime.
        if aggregateID != 0 { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != 0 { AudioHardwareDestroyProcessTap(tapID) }
        ioContext.deallocate()
    }

    // MARK: - Lifecycle

    func start() {
        guard state != .running else { return }
        installDefaultOutputListenerIfNeeded()
        rebuild()
    }

    func stop() {
        removeDefaultOutputListener()
        teardown()
        state = .stopped
    }

    /// Tears down and recreates the tap/aggregate/IOProc in place. Used for both the initial
    /// start and recovery from a default-output device change: a device-scoped tap's format
    /// tracks whatever device it names, so switching outputs (e.g. built-in speakers to a USB
    /// interface, or to/from one of Loopbacker's own virtual devices) means re-pointing it at
    /// the new default, or dropping it entirely if there's no physical device to tap.
    private func rebuild() {
        teardown()

        guard let outputDeviceUID = Self.defaultOutputDeviceUID() else {
            tapLogger.info("No default output device; system audio tap stays stopped")
            state = .noPhysicalOutput
            return
        }
        guard !Self.isLoopbackerVirtualDevice(outputDeviceUID) else {
            tapLogger.info("Default output (\(outputDeviceUID)) is a Loopbacker virtual device; nothing to echo-cancel")
            state = .noPhysicalOutput
            return
        }

        // No process exclusion list: see the class doc for why Loopbacker's own process stays
        // in (it's the only way to capture the monitor route's real acoustic echo source).
        // Scoped to the default output device's first stream: see the class doc for why a
        // global tap is wrong here. `isMixdown`/`isMono` force the stereo shape the aggregate/
        // IOProc/ring below assume, overriding the tapped stream's native channel count.
        let description = CATapDescription(excludingProcesses: [], deviceUID: outputDeviceUID, stream: 0)
        description.name = "Loopbacker System Audio Tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        description.isMixdown = true
        description.isMono = false

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &newTapID)
        guard tapStatus == noErr else {
            permission = .denied
            fail(.tapCreationFailed(tapStatus))
            return
        }
        permission = .granted
        tapID = newTapID

        let tapUID = description.uuid.uuidString

        // A tap-only private aggregate device: no physical sub-devices, just the tap. Its
        // input scope delivers the tap's mixed-down stereo system audio to the IOProc below.
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Loopbacker System Audio Tap Aggregate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]
            ]
        ]

        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID)
        guard aggregateStatus == noErr else {
            fail(.aggregateCreationFailed(aggregateStatus))
            return
        }
        aggregateID = newAggregateID

        var newIOProcID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcID(aggregateID, systemAudioTapIOProc, ioContext, &newIOProcID)
        guard createStatus == noErr, let newIOProcID else {
            fail(.ioProcCreationFailed(createStatus))
            return
        }
        ioProcID = newIOProcID

        let startStatus = AudioDeviceStart(aggregateID, newIOProcID)
        guard startStatus == noErr else {
            fail(.ioProcStartFailed(startStatus))
            return
        }

        state = .running
        tapLogger.info("System audio tap running (tap \(newTapID), aggregate \(newAggregateID))")
    }

    private func teardown() {
        if let ioProcID {
            if aggregateID != 0 { AudioDeviceStop(aggregateID, ioProcID) }
            if aggregateID != 0 { AudioDeviceDestroyIOProcID(aggregateID, ioProcID) }
            self.ioProcID = nil
        }
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
    }

    private func fail(_ error: SystemAudioTapError) {
        tapLogger.error("\(error.localizedDescription, privacy: .public)")
        teardown()
        state = .failed(error)
    }

    // MARK: - Default output device lookup

    /// The current default output device's UID, or nil if none can be found.
    private static func defaultOutputDeviceUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var deviceIDSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                                &deviceIDSize, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cfUID: Unmanaged<CFString>? = nil
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let uidStatus = withUnsafeMutablePointer(to: &cfUID) { ptr in
            AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, ptr)
        }
        guard uidStatus == noErr, let cf = cfUID else { return nil }
        return cf.takeRetainedValue() as String
    }

    /// `VirtualDeviceChannels.micUID` ("LoopbackerDevice_UID") and the extra output devices
    /// (`"LoopbackerDevice_UID_2"`, ...) all share this prefix; matches `DefaultDeviceRestorer`'s
    /// own `isLoopbackerDevice` check.
    private static func isLoopbackerVirtualDevice(_ uid: String) -> Bool {
        uid.contains("Loopbacker")
    }

    // MARK: - Default output device changes

    private func installDefaultOutputListenerIfNeeded() {
        guard !defaultOutputListenerInstalled else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            MainActor.assumeIsolated {
                // Rebuilds whenever the listener is installed (i.e. demand is active, from
                // `start()` through `stop()`), not only while currently `.running`: this is
                // exactly how `.noPhysicalOutput` -> real-device transitions get picked up.
                guard let self else { return }
                tapLogger.info("Default output device changed; rebuilding system audio tap")
                self.rebuild()
            }
        }
        defaultOutputListenerInstalled = true
    }

    private func removeDefaultOutputListener() {
        guard defaultOutputListenerInstalled else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { _, _ in }
        defaultOutputListenerInstalled = false
    }
}

/// Raw state the real-time IOProc may touch: a pointer to the `DriftCompensatedRing` it writes
/// into. Plain struct, no ARC — passed as `inClientData` to `AudioDeviceCreateIOProcID`.
private struct IOContext {
    let ring: UnsafeRawPointer
}

/// Top-level `AudioDeviceIOProc`: writes the tap's input audio into the far-end reference ring.
/// Runs on the aggregate device's real-time thread. No allocation, locks, or Swift reference
/// counting — `Unmanaged.fromOpaque` does not retain, and `DriftCompensatedRing.write` is a
/// bounded copy loop.
private func systemAudioTapIOProc(
    _ device: AudioObjectID,
    _ now: UnsafePointer<AudioTimeStamp>,
    _ inputData: UnsafePointer<AudioBufferList>,
    _ inputTime: UnsafePointer<AudioTimeStamp>,
    _ outputData: UnsafeMutablePointer<AudioBufferList>,
    _ outputTime: UnsafePointer<AudioTimeStamp>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData else { return noErr }
    let context = clientData.assumingMemoryBound(to: IOContext.self).pointee
    let ring = Unmanaged<DriftCompensatedRing>.fromOpaque(context.ring).takeUnretainedValue()

    let bufferList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
    guard let buffer = bufferList.first, let data = buffer.mData else { return noErr }
    let channels = Int(buffer.mNumberChannels)
    guard channels > 0 else { return noErr }
    let frames = Int(buffer.mDataByteSize) / (channels * MemoryLayout<Float>.size)
    guard frames > 0 else { return noErr }

    let floats = data.assumingMemoryBound(to: Float.self)
    // `description.isMixdown = true` (set in `rebuild`) forces a stereo mix regardless of the
    // tapped device's native channel count, so this is the only shape the ring (always
    // stereo) ever needs to handle. Drop anything else rather than reshaping on the IO
    // thread, which would need an allocation.
    guard channels == ring.channels else { return noErr }
    ring.write(floats, frames: UInt32(frames))
    return noErr
}
