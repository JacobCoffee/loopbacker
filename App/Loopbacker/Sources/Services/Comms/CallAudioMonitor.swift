import CoreAudio
import AudioToolbox
import Foundation
import Synchronization
import AppKit
import os.log

private let callMonitorLogger = Logger(subsystem: "com.jacobcoffee.loopbacker", category: "CallAudioMonitor")

/// Far-end "someone in the call is talking" signal, published lock-free for `AppAudioProcessor`
/// (Part A: duck app audio feeding the virtual mic) and `ListenDucker` (Part B: duck what the
/// user hears) to read from their own IO threads. Mirrors `VoiceBus`'s pattern but for the
/// *other* side of the conversation -- tapped straight from the call apps' own processes
/// (`CallAudioMonitor`) rather than the mic.
///
/// Unlike `VoiceBus` (a raw decayed probability, thresholded by each reader), this publishes a
/// post-hysteresis `Bool` computed once by `CallAudioMonitor`'s own IOProc
/// (`CallVoiceHysteresis`): every reader would otherwise need its own attack/hold/release logic
/// to avoid flutter between words, and `CallAudioMonitor` already has to run that logic to
/// decide when to keep the tap worth running. `level()` is still exposed (the smoothed
/// pre-threshold probability) for a future meter, but ducking consumers read `isTalking()`.
enum CallVoiceBus {
    private static let staleNanos: UInt64 = 300_000_000
    private static let levelBits = Atomic<UInt32>(Float(0).bitPattern)
    private static let talkingBits = Atomic<Bool>(false)
    private static let lastUpdateNanos = Atomic<UInt64>(0)

    /// `CallAudioMonitor`'s IOProc, once per processed callback. No allocation, no locks.
    static func update(level: Float, talking: Bool) {
        lastUpdateNanos.store(DispatchTime.now().uptimeNanoseconds, ordering: .relaxed)
        levelBits.store(level.bitPattern, ordering: .relaxed)
        talkingBits.store(talking, ordering: .relaxed)
    }

    /// Any thread. The smoothed far-end speech probability (0...1), or 0 if the monitor isn't
    /// running or hasn't published recently.
    static func level() -> Float {
        guard isFresh() else { return 0 }
        return Float(bitPattern: levelBits.load(ordering: .relaxed))
    }

    /// Any thread. Whether someone in the call is talking right now, after attack/hold/release
    /// hysteresis -- false if the monitor isn't running or hasn't published recently.
    static func isTalking() -> Bool {
        guard isFresh() else { return false }
        return talkingBits.load(ordering: .relaxed)
    }

    private static func isFresh() -> Bool {
        let last = lastUpdateNanos.load(ordering: .relaxed)
        return last != 0 && DispatchTime.now().uptimeNanoseconds &- last < staleNanos
    }
}

/// Attack/hold/release hysteresis over a raw per-block speech probability, so "someone's
/// talking" doesn't flutter true/false between words or on a single noisy frame. Pure value
/// type (no CoreAudio, no allocation) so it's unit-testable without a real tap: `CallAudioMonitor`'s
/// IOProc owns one instance and feeds it the VAD's raw probability each callback.
///
/// - Smoothing: a one-pole low-pass over the raw probability (`levelSmoothingMs`) absorbs
///   RNNoise's own per-10ms-hop jitter.
/// - Attack: crossing `onThreshold` flips `talking` true immediately (no delay) and arms the
///   hold timer.
/// - Hold + release: once `talking`, the hold timer keeps resetting to `holdMs` as long as the
///   smoothed level stays above `offThreshold` (lower than `onThreshold`, standard Schmitt-
///   trigger gap so noise near the threshold can't chatter it); `talking` only flips back to
///   false once the level has been below `offThreshold` for the full hold duration -- long
///   enough to ride out a mid-sentence pause.
struct CallVoiceHysteresis: Equatable {
    static let onThreshold: Float = 0.6
    static let offThreshold: Float = 0.3
    static let levelSmoothingMs: Float = 120
    static let holdMs: Float = 500

    private(set) var level: Float = 0
    private(set) var talking = false
    private var holdRemainingFrames: Int = 0

    init() {}

    /// Feeds one block's raw VAD probability. `frames`/`sampleRate` convert the hold duration to
    /// a frame count; `sampleRate` may change between calls (e.g. the tap aggregate's rate
    /// changed) without resetting hysteresis state.
    mutating func update(rawProbability: Float, frames: Int, sampleRate: Float) {
        guard frames > 0, sampleRate > 0 else { return }
        let smoothCoeff = fxTimeCoeff(ms: Self.levelSmoothingMs, sampleRate: sampleRate)
        // One block's worth of smoothing applied as a single step (not per-sample): `frames`
        // here is a whole IOProc callback, typically a handful of ms, so the per-call
        // granularity doesn't matter for a ~120 ms time constant.
        level = Self.onePoleStep(current: level, target: min(max(rawProbability, 0), 1),
                                 coeff: smoothCoeff, steps: frames)
        let holdFrames = Int(Self.holdMs / 1000 * sampleRate)

        if !talking {
            if level > Self.onThreshold {
                talking = true
                holdRemainingFrames = holdFrames
            }
        } else if level > Self.offThreshold {
            holdRemainingFrames = holdFrames
        } else {
            holdRemainingFrames -= frames
            if holdRemainingFrames <= 0 {
                talking = false
                holdRemainingFrames = 0
            }
        }
    }

    /// Applies the one-pole step `steps` times in closed form (`coeff^steps`) instead of a
    /// `steps`-iteration loop -- same result, no per-sample cost for a whole-block update.
    private static func onePoleStep(current: Float, target: Float, coeff: Float, steps: Int) -> Float {
        guard steps > 0 else { return current }
        let decay = powf(coeff, Float(steps))
        return target + decay * (current - target)
    }
}

/// TCC/lifecycle state of `CallAudioMonitor`'s tap, mirroring `SystemAudioTapState` but with
/// "no call app running" in place of "no physical output" as the demand-but-nothing-to-do case.
enum CallAudioMonitorState: Sendable, Equatable {
    case stopped
    case running
    /// Monitoring is wanted (some feature needs the far-end signal) but no known call app
    /// (`CallAppAdviceCatalog` plus any bundle IDs the user added in settings) is currently
    /// running, so there's nothing to tap. Re-checked on every app launch/quit.
    case noCallAppRunning
    case failed(SystemAudioTapError)
}

/// Taps only the running call apps' own audio (never a global/device tap -- see class doc) and
/// runs voice-activity detection on the mixdown, publishing a hysteresis-smoothed "far-end
/// talking" flag to `CallVoiceBus` for `AppAudioProcessor` (Part A) and `ListenDucker` (Part B)
/// to duck against.
///
/// Scoped to specific processes by bundle ID (`CATapDescription.bundleIDs`, macOS 26+) rather
/// than PID-translated `AudioObjectID`s: simpler, and `processRestoreEnabled` makes the tap
/// itself survive a listed app quitting and relaunching without a rebuild. A *new* call app
/// starting (not previously in the bundle-ID list) still needs a rebuild, which
/// `NSWorkspace.didLaunchApplicationNotification`/`didTerminateApplicationNotification`
/// trigger here. Browsers are deliberately excluded from the fixed catalog (a tab running a
/// web call can't be told apart from any other tab), so they only ever enter the tapped set via
/// `CallDuckSettings.extraCallAppBundleIDs`, the user opting a specific app in.
///
/// Mono mixdown (not stereo): only a VAD decision is needed here, not the waveform itself, so
/// there's no reason to carry two channels through the tap/aggregate/IOProc. No sample-rate
/// conversion to a fixed reference rate either (unlike `SystemAudioTap`, which feeds AEC3 a
/// precisely-timed reference): `VoiceActivityDetector`'s 480-sample hop is treated as "the next
/// ~10 ms" regardless of the tap aggregate's actual nominal rate, a deliberate simplification --
/// a non-48kHz call app would feed RNNoise slightly mistimed audio, which may read speech as
/// marginally less confident but doesn't break the hysteresis gate's correctness.
///
/// Thread contract: `start`/`stop`/`rebuild` run on the main actor, same as `SystemAudioTap`.
/// The IOProc (`callAudioMonitorIOProc`, top-level C function) touches only `IOContext`'s raw
/// pointers/atomics and the `VoiceActivityDetector` instance via `Unmanaged.fromOpaque` (no
/// retain/release) -- no allocation, locks, or other Swift reference counting.
@MainActor
final class CallAudioMonitor: ObservableObject {
    @Published private(set) var state: CallAudioMonitorState = .stopped
    @Published private(set) var permission: SystemAudioTapPermission = .unknown

    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var wantsMonitor = false
    private var workspaceObservers: [NSObjectProtocol] = []
    private var tappedBundleIDs: Set<String> = []

    private let vad: VoiceActivityDetector?
    private let ioContext: UnsafeMutablePointer<CallMonitorIOContext>

    /// Extra call-app bundle IDs the user added (e.g. a browser running a web call), beyond
    /// `CallAppAdviceCatalog`. Read fresh on every `rebuild()`/relaunch check, not cached, so a
    /// settings change takes effect the next time the running-app set is re-evaluated.
    var extraCallAppBundleIDs: () -> Set<String> = { [] }

    init() {
        vad = VoiceActivityDetector()
        ioContext = UnsafeMutablePointer<CallMonitorIOContext>.allocate(capacity: 1)
        ioContext.initialize(to: CallMonitorIOContext(
            vad: vad.map { Unmanaged.passUnretained($0).toOpaque() },
            sampleRate: 48_000,
            hysteresis: CallVoiceHysteresis()))
    }

    isolated deinit {
        if aggregateID != 0 { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != 0 { AudioHardwareDestroyProcessTap(tapID) }
        ioContext.deallocate()
    }

    // MARK: - Lifecycle

    func start() {
        guard state != .running else { return }
        wantsMonitor = true
        installWorkspaceObserversIfNeeded()
        rebuild()
    }

    func stop() {
        wantsMonitor = false
        removeWorkspaceObservers()
        teardown()
        state = .stopped
    }

    /// Re-evaluates which call apps are running and rebuilds the tap if that set changed (or if
    /// nothing is tapped yet). Cheap to call speculatively -- e.g. from a workspace notification
    /// for an app that turned out not to be a call app -- since it no-ops when the set matches.
    private func rebuild() {
        guard wantsMonitor else { return }
        let bundleIDs = Self.runningCallAppBundleIDs(extra: extraCallAppBundleIDs())
        guard bundleIDs != tappedBundleIDs || state != .running else { return }
        teardown()

        guard !bundleIDs.isEmpty else {
            callMonitorLogger.info("No call app running; call audio monitor stays stopped")
            state = .noCallAppRunning
            return
        }

        let description = CATapDescription()
        description.name = "Loopbacker Call Audio Monitor"
        description.bundleIDs = Array(bundleIDs)
        description.isPrivate = true
        description.isMixdown = true
        description.isMono = true
        // Never mute the call apps themselves -- the user must keep hearing the call.
        description.muteBehavior = .unmuted
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

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Loopbacker Call Audio Monitor Aggregate",
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
        if let rate = Self.nominalSampleRate(of: newAggregateID), rate > 0 {
            ioContext.pointee.sampleRate = Float(rate)
        }

        var newIOProcID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcID(aggregateID, callAudioMonitorIOProc, ioContext, &newIOProcID)
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

        tappedBundleIDs = bundleIDs
        state = .running
        callMonitorLogger.info("Call audio monitor running for \(bundleIDs.count) app(s) (tap \(newTapID), aggregate \(newAggregateID))")
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
        tappedBundleIDs = []
        ioContext.pointee.hysteresis = CallVoiceHysteresis()
        CallVoiceBus.update(level: 0, talking: false)
    }

    private func fail(_ error: SystemAudioTapError) {
        callMonitorLogger.error("\(error.localizedDescription, privacy: .public)")
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

    /// The fixed catalog (`CallAppAdviceCatalog`) plus any user-added bundle IDs, filtered to
    /// apps actually running right now.
    private static func runningCallAppBundleIDs(extra: Set<String>) -> Set<String> {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let candidates = Set(CallAppAdviceCatalog.all.map(\.id)).union(extra)
        return candidates.intersection(running)
    }

    // MARK: - App launch/quit

    private func installWorkspaceObserversIfNeeded() {
        guard workspaceObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.wantsMonitor else { return }
                    self.rebuild()
                }
            })
        }
    }

    private func removeWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers { center.removeObserver(observer) }
        workspaceObservers = []
    }
}

/// Raw state the real-time IOProc may touch. Plain struct (aside from the opaque `vad` pointer,
/// which owns no storage of its own here) passed as `inClientData` to `AudioDeviceCreateIOProcID`.
private struct CallMonitorIOContext {
    /// `Unmanaged<VoiceActivityDetector>.toOpaque()`, or nil if RNNoise init failed
    /// (`VoiceActivityDetector.init?`) -- the monitor still runs the tap in that case, just
    /// never reports talking, rather than failing the whole feature over a missing VAD.
    let vad: UnsafeRawPointer?
    /// Updated off the IO thread in `rebuild()` before the IOProc is created/started, and on
    /// the IO thread nowhere else, so no atomic is needed (no concurrent writer once running).
    var sampleRate: Float
    var hysteresis: CallVoiceHysteresis
}

/// Top-level `AudioDeviceIOProc`: runs VAD on the tap's mono mixdown and publishes
/// hysteresis-smoothed "far-end talking" to `CallVoiceBus`. No allocation, locks, or Swift
/// reference counting -- `Unmanaged.fromOpaque` does not retain.
private func callAudioMonitorIOProc(
    _ device: AudioObjectID,
    _ now: UnsafePointer<AudioTimeStamp>,
    _ inputData: UnsafePointer<AudioBufferList>,
    _ inputTime: UnsafePointer<AudioTimeStamp>,
    _ outputData: UnsafeMutablePointer<AudioBufferList>,
    _ outputTime: UnsafePointer<AudioTimeStamp>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData else { return noErr }
    let context = clientData.assumingMemoryBound(to: CallMonitorIOContext.self)

    let bufferList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
    guard let buffer = bufferList.first, let data = buffer.mData else { return noErr }
    let channels = Int(buffer.mNumberChannels)
    // `description.isMono = true` forces a single-channel mixdown.
    guard channels == 1 else { return noErr }
    let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
    guard frames > 0 else { return noErr }

    let floats = data.assumingMemoryBound(to: Float.self)
    let rawProbability: Float
    if let vadPointer = context.pointee.vad {
        let vad = Unmanaged<VoiceActivityDetector>.fromOpaque(vadPointer).takeUnretainedValue()
        rawProbability = vad.process(floats, frames: frames)
    } else {
        rawProbability = 0
    }

    context.pointee.hysteresis.update(rawProbability: rawProbability, frames: frames, sampleRate: context.pointee.sampleRate)
    CallVoiceBus.update(level: context.pointee.hysteresis.level, talking: context.pointee.hysteresis.talking)
    return noErr
}
