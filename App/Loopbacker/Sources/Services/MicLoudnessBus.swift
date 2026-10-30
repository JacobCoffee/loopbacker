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
/// because every contributor for this device runs on that one shared IO thread.
///
/// That single-writer invariant extends to the mix/meter state as a whole: `contribute` (the IO
/// thread) is the *only* code path that ever mutates `mixBuffer`, `currentSampleTime`,
/// `currentFrames`, or the underlying `LoudnessMeter`. The main-thread meter timer
/// (`checkForIdleContributors`) only reads `contributionHeartbeat` and sets `discardRequested` --
/// a flag the IO thread checks and clears itself, the same pattern `LoudnessMeter.resetIntegrated`
/// already uses for its own histogram. A feed starting at the exact moment the main thread would
/// otherwise have mutated this state directly used to race it (both threads touching the same
/// filter/ring/histogram memory); routing every mutation through the IO thread removes that race
/// entirely, at the cost of the main thread's idle readouts being a one-tick-late *request*
/// rather than an immediate clear (masked at read time instead -- see `momentaryLUFS` etc. below).
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

    // MARK: - IO-thread-owned state (written only from `contribute`)

    private var mixBuffer: UnsafeMutablePointer<Float>
    private var currentSampleTime: Float64 = -1
    private var currentFrames: Int = 0

    /// Bumped on every `contribute()` call -- not cycle-keyed like `currentSampleTime`, just a
    /// heartbeat the idle-detection state machine below watches for "has anything contributed
    /// recently." Read/written across threads (IO thread writes, main thread reads via
    /// `checkForIdleContributors`) without synchronization: a benign race on a monotonically
    /// increasing counter the main thread only ever compares for (in)equality.
    private var contributionHeartbeat: Int = 0
    /// Set by the main thread (`checkForIdleContributors`), cleared and acted on only by the IO
    /// thread (`contribute`, alongside a sample-time discontinuity -- see there). The one piece
    /// of state the main thread is allowed to write, and even that is a request, never a mutation
    /// of `mixBuffer`/the meter itself.
    private var discardRequested = false

    // MARK: - Main-thread-only state (idle detection + read-time masking)

    private static let idleTicksThreshold = 3 // ~100 ms at the 30 Hz meter-timer cadence
    private var lastSeenHeartbeat = -1
    private var idleTicks = 0
    private var isIdle = false
    /// Bumped whenever `isIdle` flips to `true`. Folded into `changeGeneration` below: going
    /// idle changes what every reader should see (momentary/short-term/true-peak now read as
    /// absent) without the IO thread necessarily running `process` again any time soon to bump
    /// its own `meter.changeGeneration`, so callers that cache on that generation (`AudioRouter`)
    /// still notice and republish.
    private var idleGeneration = 0

    private init() {
        meter = LoudnessMeter(sampleRate: 48000, channelCount: maxChannels)
        mixBuffer = .allocate(capacity: maxFrames * maxChannels)
        mixBuffer.initialize(repeating: 0, count: maxFrames * maxChannels)
    }

    /// Adds one feed's contribution to the virtual mic's current IO cycle. Real-time safe: no
    /// allocation, no locks, preallocated buffer only. The sole writer of every piece of mutable
    /// state this class and its `LoudnessMeter` hold -- see the type doc comment.
    func contribute(buffer: UnsafePointer<Float>, frames: Int, channels: Int, sampleTime: Float64) {
        guard frames > 0, frames <= maxFrames, channels > 0 else { return }
        let clampedChannels = min(channels, maxChannels)
        contributionHeartbeat &+= 1

        // Either the main thread noticed every feed had gone quiet for a while and requested a
        // discard, or this cycle's sample time doesn't follow on from the last one this thread
        // itself finalized (a route/soundboard unit restarting, a device change, or simply
        // resuming after a gap long enough that real device time moved on without anyone
        // contributing). Either way, whatever's pending has no real continuity with what's about
        // to arrive: discard it (don't finalize it through the meter -- it's stale, not worth
        // measuring) and clear momentary/short-term/true-peak before this cycle's audio joins
        // them, so a feed resuming doesn't wrongly blend unrelated audio across the gap.
        // Integrated loudness, which intentionally spans the whole session, is unaffected.
        let isDiscontinuous = currentSampleTime >= 0 && abs(sampleTime - currentSampleTime) > Double(maxFrames) * 4
        if discardRequested || isDiscontinuous {
            discardRequested = false
            currentFrames = 0
            mixBuffer.update(repeating: 0, count: maxFrames * maxChannels)
            meter.clearLiveWindows()
        }

        if sampleTime != currentSampleTime {
            finalizeCycle()
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

    // MARK: - Contributor lifecycle (main thread: reads only, never mutates meter/bus state)

    /// Called once per meter tick (the main thread's 30 Hz timer) to notice when every feed has
    /// stopped. No route/soundboard teardown talks to this class directly -- a vanished feed
    /// just stops calling `contribute()` -- so this polls `contributionHeartbeat` for a few
    /// consecutive idle ticks (long enough to not misfire between two IO cycles of the same
    /// ongoing feed) before deciding nothing is playing.
    ///
    /// Only ever sets `isIdle` (this type's own state, read only by `momentaryLUFS` etc. below)
    /// and requests a discard (`discardRequested`) for the IO thread to act on next time it runs
    /// -- never touches `mixBuffer`, `currentSampleTime`/`currentFrames`, or the meter itself, so
    /// a feed starting back up at the exact moment this runs can't race a main-thread mutation of
    /// the same state (see the type doc comment).
    func checkForIdleContributors() {
        let heartbeat = contributionHeartbeat
        if heartbeat != lastSeenHeartbeat {
            lastSeenHeartbeat = heartbeat
            idleTicks = 0
            isIdle = false
            return
        }

        idleTicks += 1
        guard idleTicks >= Self.idleTicksThreshold, !isIdle else { return }
        isIdle = true
        discardRequested = true
        idleGeneration &+= 1
    }

    // MARK: - Reads (main thread)

    /// `-infinity` (reported as "no signal" by `LoudnessStatus`) while idle, regardless of
    /// whatever the meter's actually still holding -- the IO thread only clears that on its next
    /// `contribute()` call, which may be arbitrarily far in the future (or never). Masking the
    /// read here, rather than mutating the meter from the main thread to force it, is what keeps
    /// the main thread a read-only observer of this state.
    var momentaryLUFS: Float { isIdle ? -.infinity : meter.momentaryLUFS }
    var shortTermLUFS: Float { isIdle ? -.infinity : meter.shortTermLUFS }
    var truePeakDBTP: Float { isIdle ? -.infinity : meter.truePeakDBTP }
    /// Bumped whenever a published reading could have changed -- a new 100 ms step, an applied
    /// reset, a live-window clear, or (since those don't necessarily involve the meter itself)
    /// going idle. `AudioRouter`'s meter timer compares this against the value it last published
    /// instead of re-reading and republishing every tick.
    var changeGeneration: Int { meter.changeGeneration &+ idleGeneration }
    /// Integrated loudness is never masked by `isIdle`: it intentionally spans the whole session,
    /// not just the current feed, and `LoudnessMeter.integratedLUFS()` already reports a pending
    /// `resetIntegrated()` immediately regardless of whether anything is currently playing.
    func integratedLUFS() -> Float { meter.integratedLUFS() }
    func resetIntegrated() { meter.resetIntegrated() }
}
