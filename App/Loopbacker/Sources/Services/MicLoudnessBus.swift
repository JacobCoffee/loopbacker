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

    // MARK: - Reads (main thread)

    var momentaryLUFS: Float { meter.momentaryLUFS }
    var shortTermLUFS: Float { meter.shortTermLUFS }
    var truePeakDBTP: Float { meter.truePeakDBTP }
    func integratedLUFS() -> Float { meter.integratedLUFS() }
    func resetIntegrated() { meter.resetIntegrated() }
}
