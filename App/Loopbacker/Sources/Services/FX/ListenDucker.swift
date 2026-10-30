import CoreAudio
import AudioToolbox
import Foundation
import Synchronization
import os.log

private let listenDuckerLogger = Logger(subsystem: "com.jacobcoffee.loopbacker", category: "ListenDucker")

/// One-pole gain envelope for "duck what I hear": ramps toward 1 (full volume) or a ducked
/// linear gain over a fixed ~10 ms time constant, short enough to react quickly but long enough
/// to avoid a zipper/click at the transition (a per-callback step instead of a per-sample ramp
/// would itself zipper between IO blocks, same reasoning as `AppAudioProcessor`'s duck envelope).
/// Pure value type, no CoreAudio -- `ListenDucker`'s IOProc owns one instance; unit tests drive
/// it directly against a plain buffer.
struct ListenDuckGainRamp: Equatable {
    static let rampMs: Float = 10

    private(set) var gain: Float = 1

    init() {}

    /// Copies `frames` interleaved frames from `source` (`inChannels` wide) to `destination`
    /// (`outChannels` wide), ramping the gain toward `targetLinearGain` one sample at a time.
    /// The tap is a stereo mixdown but the output device can have any channel count: L/R land
    /// on the first two outputs (mono input feeds both), extra outputs get silence, and a mono
    /// output gets (L+R)/2. In-place only when `inChannels == outChannels`.
    mutating func copy(
        from source: UnsafePointer<Float>, inChannels: Int,
        to destination: UnsafeMutablePointer<Float>, outChannels: Int,
        frames: Int, targetLinearGain: Float, sampleRate: Float
    ) {
        guard frames > 0, inChannels > 0, outChannels > 0, sampleRate > 0 else { return }
        let coeff = fxTimeCoeff(ms: Self.rampMs, sampleRate: sampleRate)
        let downmix = outChannels == 1 && inChannels >= 2
        for i in 0..<frames {
            gain = targetLinearGain + coeff * (gain - targetLinearGain)
            let inBase = i * inChannels
            let outBase = i * outChannels
            for ch in 0..<outChannels {
                let sample: Float
                if downmix {
                    sample = 0.5 * (source[inBase] + source[inBase + 1])
                } else if ch < inChannels {
                    sample = source[inBase + ch]
                } else if inChannels == 1 && ch < 2 {
                    sample = source[inBase]
                } else {
                    sample = 0
                }
                destination[outBase + ch] = sample * gain
            }
        }
    }
}

/// Lifecycle state for `ListenDucker`'s replay tap, mirroring `SystemAudioTapState`.
enum ListenDuckerState: Sendable, Equatable {
    case stopped
    case running
    /// No default output device, or the default output is one of Loopbacker's own virtual
    /// devices -- same reasoning as `SystemAudioTap`: nothing to replay into right now.
    case noPhysicalOutput
    /// The configured app set is empty (after excluding Loopbacker itself and any call apps) --
    /// nothing to tap.
    case noAppsSelected
    case failed(SystemAudioTapError)
}

/// "Duck what I hear" (Part B): taps the selected apps' own audio (`muteBehavior =
/// .mutedWhenTapped`, so the instant Loopbacker reads the tap, those apps go silent on the real
/// output) and replays it to the current default output device through an aggregate device that
/// combines the tap with that device as a sub-device, applying a smoothed gain
/// (`ListenDuckGainRamp`) while the configured trigger (far-end call voices, optionally also the
/// user's own mic) is active. Stopping the tap (disabled, app removed from the set, or the
/// process exiting) hands playback back to the real device automatically -- `mutedWhenTapped`'s
/// mute is a property of the tap being *read*, enforced by coreaudiod, not something this class
/// tracks or restores itself, so it can't be left stuck muted by a crash.
///
/// **Added latency.** Replaying through an aggregate device's own IOProc round-trip adds
/// roughly one IO buffer's worth of latency versus the app rendering straight to the output
/// device -- typically on the order of the output device's configured buffer duration (a few ms
/// to ~20 ms at common buffer sizes), the same order of magnitude as the output latency
/// `AudioRouter.estimateStreamDelayMs` already accounts for elsewhere, plus the tap's own
/// capture-to-delivery delay. Not independently measured here (no physical device to benchmark
/// against in this harness); noted so a user who A/Bs "ducking on" against "ducking off" knows
/// to expect a small, fixed added delay on ducked apps' audio, not a bug.
///
/// Thread contract: `start`/`stop`/`rebuild`/`updateConfig` run on the main actor. The IOProc
/// (`listenDuckerIOProc`, top-level C function) touches only `IOContext`'s raw pointers/atomics
/// and the preallocated `ListenDuckGainRamp` -- no allocation, locks, or Swift reference
/// counting, same contract as `SystemAudioTap`'s and `CallAudioMonitor`'s IOProcs.
@MainActor
final class ListenDucker: ObservableObject {
    struct Config: Equatable {
        var isEnabled = false
        var bundleIDs: [String] = []
        var duckAmountDB: Float = -20
        var trigger: CallDuckTrigger = .callVoices
    }

    @Published private(set) var state: ListenDuckerState = .stopped
    @Published private(set) var permission: SystemAudioTapPermission = .unknown

    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var defaultOutputListenerInstalled = false
    private var defaultOutputListenerBlock: AudioObjectPropertyListenerBlock?
    private var config = Config()
    private var tappedBundleIDs: [String] = []
    private var tappedOutputUID: String?

    private let ioContext: UnsafeMutablePointer<ListenDuckerIOContext>

    init() {
        let triggerBits = UnsafeMutablePointer<Atomic<UInt8>>.allocate(capacity: 1)
        triggerBits.initialize(to: Atomic(0))
        let duckAmountDBBits = UnsafeMutablePointer<Atomic<UInt32>>.allocate(capacity: 1)
        duckAmountDBBits.initialize(to: Atomic(Float(-20).bitPattern))
        ioContext = UnsafeMutablePointer<ListenDuckerIOContext>.allocate(capacity: 1)
        ioContext.initialize(to: ListenDuckerIOContext(
            triggerBits: triggerBits, duckAmountDBBits: duckAmountDBBits,
            sampleRate: 48_000, ramp: ListenDuckGainRamp()))
    }

    isolated deinit {
        if aggregateID != 0 { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != 0 { AudioHardwareDestroyProcessTap(tapID) }
        ioContext.pointee.triggerBits.deallocate()
        ioContext.pointee.duckAmountDBBits.deallocate()
        ioContext.deallocate()
    }

    // MARK: - Config

    /// Any time, including before `start()`. `bundleIDs`/`isEnabled` changes rebuild the tap
    /// (a running `CATapDescription` doesn't support changing its process list in place);
    /// `duckAmountDB`/`trigger` push straight into the lock-free atomics the IOProc reads, no
    /// rebuild needed.
    func updateConfig(_ newValue: Config, excludingCallApps callApps: Set<String>) {
        let sanitized = Self.sanitizedBundleIDs(requested: newValue.bundleIDs, excludingCallApps: callApps)
        let needsRebuild = newValue.isEnabled != config.isEnabled || sanitized != tappedBundleIDs
        config = newValue
        ioContext.pointee.duckAmountDBBits.pointee.store(newValue.duckAmountDB.bitPattern, ordering: .relaxed)
        ioContext.pointee.triggerBits.pointee.store(newValue.trigger == .both ? 1 : 0, ordering: .relaxed)
        if newValue.isEnabled {
            installDefaultOutputListenerIfNeeded()
            if needsRebuild { rebuild(sanitizedBundleIDs: sanitized) }
        } else {
            removeDefaultOutputListener()
            teardown()
            state = .stopped
            tappedBundleIDs = []
        }
    }

    /// Apps the user asked to duck, minus Loopbacker's own process and anything currently
    /// counted as a call app (the fixed catalog plus `CallDuckSettings.extraCallAppBundleIDs`):
    /// ducking a call app on the user's own output would duck the call itself, and Loopbacker
    /// never needs to duck its own output. `ownBundleID` defaults to `Bundle.main.bundleIdentifier`
    /// (nil in a `swift test` host, where this filter is then a no-op for that clause) but is an
    /// explicit parameter so tests can inject a deterministic value instead of depending on the
    /// ambient test-runner's own identity.
    static func sanitizedBundleIDs(
        requested: [String], excludingCallApps callApps: Set<String>,
        ownBundleID: String? = Bundle.main.bundleIdentifier
    ) -> [String] {
        requested.filter { $0 != ownBundleID && !callApps.contains($0) }
    }

    // MARK: - Lifecycle

    private func rebuild(sanitizedBundleIDs: [String]) {
        teardown()
        guard !sanitizedBundleIDs.isEmpty else {
            state = .noAppsSelected
            return
        }
        guard let outputDeviceUID = SystemAudioTap.defaultOutputDeviceUID() else {
            state = .noPhysicalOutput
            return
        }
        guard !SystemAudioTap.isLoopbackerVirtualDevice(outputDeviceUID) else {
            state = .noPhysicalOutput
            return
        }

        let description = CATapDescription()
        description.name = "Loopbacker Listen Ducker"
        description.bundleIDs = sanitizedBundleIDs
        description.isPrivate = true
        description.isMixdown = true
        description.isMono = false
        // The instant Loopbacker reads this tap, the tapped apps go silent on the real device --
        // this class's whole replay path exists to put their (now gain-controlled) audio back.
        description.muteBehavior = .mutedWhenTapped
        description.isProcessRestoreEnabled = true

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

        // Combines the tap (input scope: the ducked apps' mixed-down audio) with the real
        // output device as a sub-device (output scope: where the IOProc's gain-adjusted copy
        // actually plays), so one aggregate device both captures and drives real hardware --
        // unlike `SystemAudioTap`'s tap-only aggregate, which only ever needs the input side.
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Loopbacker Listen Ducker Aggregate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputDeviceUID]
            ],
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
        if let rate = Self.nominalSampleRate(of: newAggregateID), rate > 0 {
            ioContext.pointee.sampleRate = Float(rate)
        }

        var newIOProcID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcID(aggregateID, listenDuckerIOProc, ioContext, &newIOProcID)
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

        tappedBundleIDs = sanitizedBundleIDs
        tappedOutputUID = outputDeviceUID
        state = .running
        listenDuckerLogger.info("Listen ducker running for \(sanitizedBundleIDs.count) app(s) -> \(outputDeviceUID) (tap \(newTapID), aggregate \(newAggregateID))")
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
        tappedOutputUID = nil
        ioContext.pointee.ramp = ListenDuckGainRamp()
    }

    private func fail(_ error: SystemAudioTapError) {
        listenDuckerLogger.error("\(error.localizedDescription, privacy: .public)")
        teardown()
        state = .failed(error)
    }

    private static func nominalSampleRate(of deviceID: AudioObjectID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
        return status == noErr ? rate : nil
    }

    // MARK: - Default output device changes

    /// Rebuilds against the new default output when it changes (headphones plugged in, output
    /// switched in menu bar, etc.), same reasoning and pattern as `SystemAudioTap`: a
    /// device-scoped aggregate's sub-device doesn't follow the system default automatically.
    private func installDefaultOutputListenerIfNeeded() {
        guard !defaultOutputListenerInstalled else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, self.config.isEnabled else { return }
                listenDuckerLogger.info("Default output device changed; rebuilding listen ducker")
                self.rebuild(sanitizedBundleIDs: self.tappedBundleIDs)
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        guard status == noErr else {
            listenDuckerLogger.error("Could not install default-output listener: \(status)")
            return
        }
        defaultOutputListenerBlock = block
        defaultOutputListenerInstalled = true
    }

    private func removeDefaultOutputListener() {
        guard defaultOutputListenerInstalled, let block = defaultOutputListenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        defaultOutputListenerBlock = nil
        defaultOutputListenerInstalled = false
    }
}

/// Raw state the real-time IOProc may touch. Plain struct, no ARC aside from the atomics (which
/// own no heap storage of their own) -- passed as `inClientData` to `AudioDeviceCreateIOProcID`.
private struct ListenDuckerIOContext {
    /// 0 = trigger on call voices only, 1 = also the user's own mic (`CallDuckTrigger.both`).
    let triggerBits: UnsafeMutablePointer<Atomic<UInt8>>
    let duckAmountDBBits: UnsafeMutablePointer<Atomic<UInt32>>
    /// IO-thread-owned; written off the IO thread only in `rebuild()`, before the IOProc starts.
    var sampleRate: Float
    var ramp: ListenDuckGainRamp
}

/// Top-level `AudioDeviceIOProc`: copies the tap's input (the ducked apps' mixed-down audio)
/// into the aggregate's output (the real sub-device), applying `ListenDuckGainRamp` while the
/// configured trigger is active. No allocation, locks, or Swift reference counting.
private func listenDuckerIOProc(
    _ device: AudioObjectID,
    _ now: UnsafePointer<AudioTimeStamp>,
    _ inputData: UnsafePointer<AudioBufferList>,
    _ inputTime: UnsafePointer<AudioTimeStamp>,
    _ outputData: UnsafeMutablePointer<AudioBufferList>,
    _ outputTime: UnsafePointer<AudioTimeStamp>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData else { return noErr }
    let context = clientData.assumingMemoryBound(to: ListenDuckerIOContext.self)

    let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
    let outList = UnsafeMutableAudioBufferListPointer(outputData)
    guard let inBuffer = inList.first, let inPtr = inBuffer.mData,
          let outBuffer = outList.first, let outPtr = outBuffer.mData else { return noErr }
    let inChannels = Int(inBuffer.mNumberChannels)
    let outChannels = Int(outBuffer.mNumberChannels)
    guard inChannels > 0, outChannels > 0 else { return noErr }
    let frames = Int(inBuffer.mDataByteSize) / (inChannels * MemoryLayout<Float>.size)
    let outFrames = Int(outBuffer.mDataByteSize) / (outChannels * MemoryLayout<Float>.size)
    let n = min(frames, outFrames)
    guard n > 0 else { return noErr }

    let triggerBoth = context.pointee.triggerBits.pointee.load(ordering: .relaxed) == 1
    let callTalking = CallVoiceBus.isTalking()
    let myTalking = triggerBoth && VoiceBus.probability() > 0.5
    let triggered = callTalking || myTalking
    let duckAmountDB = Float(bitPattern: context.pointee.duckAmountDBBits.pointee.load(ordering: .relaxed))
    let targetLinear: Float = triggered ? fxDBToLinear(duckAmountDB) : 1

    let inFloats = inPtr.assumingMemoryBound(to: Float.self)
    let outFloats = outPtr.assumingMemoryBound(to: Float.self)
    context.pointee.ramp.copy(from: inFloats, inChannels: inChannels, to: outFloats, outChannels: outChannels,
                              frames: n, targetLinearGain: targetLinear, sampleRate: context.pointee.sampleRate)
    return noErr
}
