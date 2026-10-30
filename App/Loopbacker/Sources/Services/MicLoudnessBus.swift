import Foundation

/// Combines every feed writing to the virtual mic device into one shared loudness measurement,
/// instead of measuring each feed (a mic route, an app-capture route, the soundboard's loopback
/// unit) separately and picking the loudest.
///
/// Within one process, CoreAudio services every AUHAL output unit registered against the same
/// device on that device's single IO thread, once per IO cycle, handing each render callback an
/// identical `inTimeStamp.mSampleTime`. Confirmed empirically with a throwaway CLI (two
/// independent `kAudioUnitSubType_HALOutput` units targeting one device, silence only): both
/// units' render callbacks reported the same `pthread_threadid_np` and, cycle for cycle, the
/// same `mSampleTime`/`mHostTime`. `contribute` uses that shared sample time as the cycle key:
/// each call for a cycle sums its buffer into a shared accumulator; the first call for a *new*
/// cycle finalizes the previous cycle through `LoudnessMeter.process` first. No locks are needed
/// because every contributor for this device runs on that one shared IO thread -- there is no
/// cross-thread access to the accumulator (reads from the main-thread meter timer are the same
/// benign race `LoudnessMeter`'s own published readouts already accept).
final class MicLoudnessBus: @unchecked Sendable {
    static let shared = MicLoudnessBus()

    /// Always sized to the device's maximum possible channel count so this never needs to
    /// reallocate when the user changes the virtual mic's channel count mid-session: unused
    /// trailing channels are always-zero and contribute nothing to the weighted loudness sum.
    private let meter: LoudnessMeter
    private let maxChannels = VirtualDeviceChannels.maxCount
    /// Generous bound on a single IO cycle's frame count (`DriftCompensatedRing` elsewhere in
    /// this app sizes its ring the same way). A block larger than this -- very rare, e.g. a brief
    /// underrun-recovery block -- is dropped from this cycle's measurement rather than risking an
    /// out-of-bounds write.
    private let maxFrames = 4096

    private var mixBuffer: UnsafeMutablePointer<Float>
    private var currentSampleTime: Float64 = -1
    private var currentFrames: Int = 0

    /// Bumped on every `contribute()` call -- not cycle-keyed like `currentSampleTime`, just a
    /// heartbeat the idle-detection state machine below watches for "has anything contributed
    /// recently." Read/written across threads (IO thread writes, main thread reads via
    /// `checkForIdleContributors`) without synchronization, same benign-race pattern as
    /// `LoudnessMeter`'s own published readouts.
    private var contributionHeartbeat: Int = 0

    // MARK: - Idle detection (main-thread only state; see `checkForIdleContributors`)

    private static let idleTicksThreshold = 3 // ~100 ms at the 30 Hz meter-timer cadence
    private var lastSeenHeartbeat = -1
    private var idleTicks = 0
    private var isIdle = false

    private init() {
        meter = LoudnessMeter(sampleRate: 48000, channelCount: maxChannels)
        mixBuffer = .allocate(capacity: maxFrames * maxChannels)
        mixBuffer.initialize(repeating: 0, count: maxFrames * maxChannels)
    }

    /// Adds one feed's contribution to the virtual mic's current IO cycle. Real-time safe: no
    /// allocation, no locks, preallocated buffer only.
    func contribute(buffer: UnsafePointer<Float>, frames: Int, channels: Int, sampleTime: Float64) {
        guard frames > 0, frames <= maxFrames, channels > 0 else { return }
        let clampedChannels = min(channels, maxChannels)
        contributionHeartbeat &+= 1

        if sampleTime != currentSampleTime {
            let previousSampleTime = currentSampleTime
            finalizeCycle()
            // A gap far larger than one IO cycle -- a route/soundboard unit restarting, a device
            // change, or resuming right after `checkForIdleContributors` already went idle --
            // means whatever's about to be measured has no real continuity with what came
            // before. Averaging it into the momentary/short-term windows anyway would wrongly
            // blend unrelated audio across the gap, so treat it like the idle path: clear the
            // live windows before this cycle's audio joins them. Integrated loudness, which
            // intentionally spans the whole session, is unaffected.
            if previousSampleTime >= 0, abs(sampleTime - previousSampleTime) > Double(maxFrames) * 4 {
                meter.clearLiveWindows()
            }
            currentSampleTime = sampleTime
            currentFrames = frames
            // Clears the whole buffer (not just this cycle's frame count) so a later block this
            // cycle that's larger than `frames` never reads stale data from an older cycle.
            mixBuffer.update(repeating: 0, count: maxFrames * maxChannels)
        } else {
            currentFrames = max(currentFrames, frames)
        }

        // Fixed `maxChannels` stride in the destination regardless of this feed's own channel
        // count, so a feed that arrives after a wider one (or vice versa) never misreads the
        // buffer's layout -- only the leading `clampedChannels` lanes of each frame are touched.
        for f in 0..<frames {
            for ch in 0..<clampedChannels {
                mixBuffer[f * maxChannels + ch] += buffer[f * channels + ch]
            }
        }
    }

    private func finalizeCycle() {
        guard currentFrames > 0 else { return }
        meter.process(mixBuffer, frames: currentFrames, channels: maxChannels)
        currentFrames = 0
    }

    // MARK: - Contributor lifecycle (main thread)

    /// Called once per meter tick (the main thread's 30 Hz timer) to notice when every feed has
    /// stopped. No route/soundboard teardown talks to this class directly -- a vanished feed
    /// just stops calling `contribute()` -- so this polls `contributionHeartbeat` for a few
    /// consecutive idle ticks (long enough to not misfire between two IO cycles of the same
    /// ongoing feed) before deciding nothing is playing.
    ///
    /// Once idle, discards whatever partial cycle never got finalized (it's stale by now, not
    /// worth measuring) and clears the momentary/short-term/true-peak windows so the UI doesn't
    /// keep showing a stale "on target" reading after nothing is playing; integrated loudness is
    /// left untouched. Also the only place a `resetIntegrated()` request made while already idle
    /// gets consumed -- nothing else will ever reach a step boundary to do it, since idle by
    /// definition means the audio thread isn't running `process` anymore.
    func checkForIdleContributors() {
        let heartbeat = contributionHeartbeat
        if heartbeat != lastSeenHeartbeat {
            lastSeenHeartbeat = heartbeat
            idleTicks = 0
            isIdle = false
            return
        }

        idleTicks += 1
        guard idleTicks >= Self.idleTicksThreshold else { return }

        if !isIdle {
            isIdle = true
            currentFrames = 0
            currentSampleTime = -1
            meter.clearLiveWindows()
        } else {
            meter.consumePendingReset()
        }
    }

    // MARK: - Reads (main thread)

    var momentaryLUFS: Float { meter.momentaryLUFS }
    var shortTermLUFS: Float { meter.shortTermLUFS }
    var truePeakDBTP: Float { meter.truePeakDBTP }
    /// Bumped whenever a published reading could have changed -- a new 100 ms step, an applied
    /// reset, or a live-window clear. `AudioRouter`'s meter timer compares this against the
    /// value it last published instead of re-reading and republishing every tick.
    var changeGeneration: Int { meter.changeGeneration }
    func integratedLUFS() -> Float { meter.integratedLUFS() }
    func resetIntegrated() { meter.resetIntegrated() }
}
