import Accelerate
import CoreML
import Foundation
import Synchronization
import os.log

private let nsLogger = Logger(subsystem: "com.jacobcoffee.loopbacker", category: "NoiseSuppressor")

/// Neural noise suppression for a route's voice pair, using CEVA's DPDFNet2 48 kHz model
/// (Apache-2.0), bundled as `DPDFNet2_48k.mlmodelc` and reproducible with
/// `scripts/convert-dpdfnet.py`.
///
/// Core ML allocates and takes locks, so inference runs on a dedicated worker thread. The audio
/// callback only moves samples through two lock-free SPSC rings: dry mono in, enhanced mono out.
///
/// Latency: the model looks four 10 ms hops ahead and a 20 ms analysis window has to fill before
/// a hop can be emitted, so the voice comes out ~50–60 ms later, plus about one IO buffer of
/// cushion. Until the first enhanced hop arrives (and after an underrun) the callback passes the
/// dry signal and crossfades over 10 ms, so switching on or off never clicks or drops out.
///
/// Thread contract:
/// - `process` runs on exactly one audio thread.
/// - `setEnabled`/`setMaxReduction` may be called from any thread.
/// - The worker owns the model and STFT state, plus the ring ends opposite the audio thread.
///   The audio thread starts a session (an enabled stretch) only after the worker has cleared
///   everything and published `workerReady`; it ends one by clearing `workerReady`.
final class NoiseSuppressor: @unchecked Sendable {
    static let sampleRate: Float64 = 48_000

    private static let windowLength = 960
    private static let hop = 480
    private static let bins = windowLength / 2 + 1
    /// The model's output lags its input by four hops (two conv + two deep-filter lookahead frames).
    private static let modelDelay = 4 * hop
    /// Dry history: must reach back `modelDelay` behind the newest analysis window.
    private static let historySize = 4096
    /// Largest block `process` handles in one pass; larger blocks are split.
    private static let maxChunk = 4096
    /// Wet/dry crossfade step per sample (10 ms at 48 kHz).
    private static let fadeStep: Float = 1.0 / 480.0

    // MARK: Shared state

    private let enabled = Atomic<Bool>(false)
    /// Linear gain of the dry signal blended under the enhanced one (`10^(maxReduction/20)`).
    private let dryMixBits = Atomic<UInt32>(Float(0.001).bitPattern)
    private let workerReady = Atomic<Bool>(false)
    private let stopRequested = Atomic<Bool>(false)
    private let wake = DispatchSemaphore(value: 0)
    private let input = SampleRing(capacity: 16_384)
    private let output = SampleRing(capacity: 16_384)

    // MARK: Audio-thread state

    private var inSession = false
    private var primed = false
    private var wetGain: Float = 0
    private let dryScratch: UnsafeMutablePointer<Float>
    private let wetScratch: UnsafeMutablePointer<Float>

    // MARK: Worker state

    private let model: MLModel
    private let initialState: [Float]
    private let specIn: MLMultiArray
    private let specOut: MLMultiArray
    private let states: [MLMultiArray]
    private let providers: [MLFeatureProvider]
    private let options: [MLPredictionOptions]
    private var pingPong = 0
    private let forwardDFT: vDSP_DFT_Setup
    private let inverseDFT: vDSP_DFT_Setup
    private let window: UnsafeMutablePointer<Float>
    private let analysis: UnsafeMutablePointer<Float>
    private let realIn: UnsafeMutablePointer<Float>
    private let imagIn: UnsafeMutablePointer<Float>
    private let realOut: UnsafeMutablePointer<Float>
    private let imagOut: UnsafeMutablePointer<Float>
    private let overlap: UnsafeMutablePointer<Float>
    private let history: UnsafeMutablePointer<Float>
    private let hopOut: UnsafeMutablePointer<Float>
    /// Input hops consumed this session.
    private var hopsIn = 0

    /// Loads the bundled model and starts the worker, or returns nil (and logs why) when the
    /// route can't be suppressed.
    static func make(sampleRate: Float64) -> NoiseSuppressor? {
        guard sampleRate == Self.sampleRate else {
            nsLogger.error("Noise suppression needs 48 kHz; route runs at \(sampleRate) Hz")
            return nil
        }
        guard let url = Bundle.main.url(forResource: "DPDFNet2_48k", withExtension: "mlmodelc") else {
            nsLogger.error("DPDFNet2_48k.mlmodelc missing from the app bundle")
            return nil
        }
        do {
            let config = MLModelConfiguration()
            // A batch-1 recurrent model with control flow: the CPU beats the GPU/ANE dispatch cost.
            config.computeUnits = .cpuOnly
            return try NoiseSuppressor(model: MLModel(contentsOf: url, configuration: config))
        } catch {
            nsLogger.error("Failed to load noise suppression model: \(error.localizedDescription)")
            return nil
        }
    }

    init(model: MLModel) throws {
        let meta = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
        guard let stateSize = meta["state_size"].flatMap(Int.init),
              let prefix = meta["state_init"]?.split(separator: ",").compactMap({ Float($0) }),
              prefix.count <= stateSize else {
            throw CocoaError(.coderInvalidValue, userInfo: [NSDebugDescriptionErrorKey: "model metadata lacks state_size/state_init"])
        }
        guard let forward = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(Self.windowLength), .FORWARD),
              let inverse = vDSP_DFT_zop_CreateSetup(forward, vDSP_Length(Self.windowLength), .INVERSE) else {
            throw CocoaError(.featureUnsupported)
        }
        self.model = model
        forwardDFT = forward
        inverseDFT = inverse
        initialState = prefix + [Float](repeating: 0, count: stateSize - prefix.count)

        let specShape: [NSNumber] = [1, 1, NSNumber(value: Self.bins), 2]
        let specIn = try MLMultiArray(shape: specShape, dataType: .float32)
        let specOut = try MLMultiArray(shape: specShape, dataType: .float32)
        let states = try (0..<2).map { _ in try MLMultiArray(shape: [NSNumber(value: stateSize)], dataType: .float32) }
        // Ping-pong: hop N reads states[N % 2] and writes the next state into the other one,
        // straight into preallocated outputs, so steady-state inference allocates nothing here.
        providers = try (0..<2).map {
            try MLDictionaryFeatureProvider(dictionary: [
                "spec": MLFeatureValue(multiArray: specIn),
                "state_in": MLFeatureValue(multiArray: states[$0]),
            ])
        }
        options = (0..<2).map {
            let opts = MLPredictionOptions()
            opts.outputBackings = ["spec_e": specOut, "state_out": states[1 - $0]]
            return opts
        }
        self.specIn = specIn
        self.specOut = specOut
        self.states = states

        func buffer(_ count: Int) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: count)
            p.initialize(repeating: 0, count: count)
            return p
        }
        let n = Self.windowLength
        window = buffer(n)
        analysis = buffer(n)
        realIn = buffer(n)
        imagIn = buffer(n)
        realOut = buffer(n)
        imagOut = buffer(n)
        overlap = buffer(n)
        history = buffer(Self.historySize)
        hopOut = buffer(Self.hop)
        dryScratch = buffer(Self.maxChunk)
        wetScratch = buffer(Self.maxChunk)

        // Vorbis window: power-complementary at 50% overlap, as DPDFNet was trained with.
        for i in 0..<n {
            let s = sin(0.5 * Double.pi * (Double(i) + 0.5) / Double(n / 2))
            window[i] = Float(sin(0.5 * Double.pi * s * s))
        }

        let worker = Thread { [self] in runWorker() }
        worker.name = "Loopbacker noise suppression"
        worker.qualityOfService = .userInteractive
        worker.start()
        // First wake: the worker resets and publishes `workerReady`, opening the first session.
        wake.signal()
    }

    deinit {
        vDSP_DFT_DestroySetup(forwardDFT)
        vDSP_DFT_DestroySetup(inverseDFT)
        for p in [window, analysis, realIn, imagIn, realOut, imagOut, overlap, history, hopOut,
                  dryScratch, wetScratch] {
            p.deallocate()
        }
    }

    /// Ends the worker thread, which releases the last reference. Call once no audio thread can
    /// reach this instance anymore.
    func stop() {
        stopRequested.store(true, ordering: .releasing)
        wake.signal()
    }

    func setEnabled(_ on: Bool) {
        enabled.store(on, ordering: .relaxed)
    }

    /// - Parameter dB: how far noise may be pulled down, as a negative level (e.g. -60).
    func setMaxReduction(dB: Float) {
        dryMixBits.store(powf(10, min(0, dB) / 20).bitPattern, ordering: .relaxed)
    }

    // MARK: - Audio thread

    /// Replaces the first `min(stride, 2)` channels of interleaved `buffer` with the enhanced
    /// voice. Leaves the buffer untouched while disabled.
    func process(_ buffer: UnsafeMutablePointer<Float>, frames: Int, stride: Int) {
        let channels = min(stride, 2)
        guard channels > 0 else { return }
        var offset = 0
        while offset < frames {
            let n = min(frames - offset, Self.maxChunk)
            processChunk(buffer.advanced(by: offset * stride), frames: n, stride: stride, channels: channels)
            offset += n
        }
    }

    private func processChunk(_ buf: UnsafeMutablePointer<Float>, frames n: Int, stride: Int, channels: Int) {
        let want = enabled.load(ordering: .relaxed)
        if !inSession {
            guard want, workerReady.load(ordering: .acquiring) else { return }
            inSession = true
            primed = false
            wetGain = 0
        }

        let dry = dryScratch
        for i in 0..<n {
            let base = i * stride
            dry[i] = channels == 1 ? buf[base] : 0.5 * (buf[base] + buf[base + 1])
        }
        // A full ring means the worker is stalled; the output then underruns and we stay dry.
        _ = input.write(dry, count: n)
        wake.signal()

        // Start (or restart after an underrun) only with a hop of margin, so the worker's
        // hop-sized output doesn't leave us one sample short on the very next block.
        let available = output.availableToRead()
        let haveWet = available >= (primed ? n : n + Self.hop)
        if haveWet {
            output.read(into: wetScratch, count: n)
            primed = true
            // After a stall the backlog (= latency) can grow; pull it back to one block + hop.
            let backlog = available - n
            if backlog > 2 * (n + Self.hop) {
                output.discard(count: backlog - (n + Self.hop))
            }
        } else {
            primed = false
        }

        let target: Float = want && haveWet ? 1 : 0
        var g = wetGain
        if g == 0 && target == 0 {
            // Fully dry: leave the original channels (and any stereo image) alone.
        } else {
            for i in 0..<n {
                g = target > g ? min(target, g + Self.fadeStep) : max(target, g - Self.fadeStep)
                let wet = haveWet ? wetScratch[i] : 0
                let y = g * wet + (1 - g) * dry[i]
                let base = i * stride
                buf[base] = y
                if channels == 2 { buf[base + 1] = y }
            }
        }
        wetGain = g

        if !want && g == 0 {
            inSession = false
            workerReady.store(false, ordering: .releasing)
            wake.signal()
        }
    }

    // MARK: - Worker thread

    private func runWorker() {
        while true {
            wake.wait()
            if stopRequested.load(ordering: .acquiring) { return }
            if !workerReady.load(ordering: .acquiring) {
                resetSession()
                workerReady.store(true, ordering: .releasing)
                continue
            }
            while input.availableToRead() >= Self.hop {
                if !processHop() { break }
            }
        }
    }

    /// Clears every bit of per-session state. Runs only while the audio thread is outside a
    /// session, so it may also rewind the output ring's consumer side.
    private func resetSession() {
        input.discardAll()
        output.discardAll()
        hopsIn = 0
        pingPong = 0
        let n = Self.windowLength
        analysis.update(repeating: 0, count: n)
        overlap.update(repeating: 0, count: n)
        history.update(repeating: 0, count: Self.historySize)
        states[0].withUnsafeMutableBufferPointer(ofType: Float.self) { ptr, _ in
            _ = ptr.update(fromContentsOf: initialState)
        }
    }

    /// Consumes one hop of input and, once the window is full, emits one enhanced hop.
    /// Returns false if inference failed (the audio thread then falls back to dry).
    private func processHop() -> Bool {
        let n = Self.windowLength, h = Self.hop
        // Slide the analysis window by one hop and append the new samples, also logging them in
        // the dry history used for the attenuation-limit blend.
        analysis.update(from: analysis.advanced(by: h), count: n - h)
        input.read(into: analysis.advanced(by: n - h), count: h)
        let base = hopsIn * h
        for i in 0..<h {
            history[(base + i) & (Self.historySize - 1)] = analysis[n - h + i]
        }
        hopsIn += 1
        guard hopsIn >= 2 else { return true }

        // Analysis STFT frame (unnormalised, like numpy.fft.rfft).
        vDSP_vmul(analysis, 1, window, 1, realIn, 1, vDSP_Length(n))
        imagIn.update(repeating: 0, count: n)
        vDSP_DFT_Execute(forwardDFT, realIn, imagIn, realOut, imagOut)

        specIn.withUnsafeMutableBufferPointer(ofType: Float.self) { spec, _ in
            for k in 0..<Self.bins {
                spec[2 * k] = realOut[k]
                spec[2 * k + 1] = imagOut[k]
            }
        }
        let current = pingPong
        do {
            _ = try model.prediction(from: providers[current], options: options[current])
        } catch {
            nsLogger.error("Noise suppression inference failed: \(error.localizedDescription)")
            return false
        }
        pingPong = 1 - current

        // Rebuild the Hermitian spectrum and inverse-transform.
        specOut.withUnsafeBufferPointer(ofType: Float.self) { spec in
            for k in 0..<Self.bins {
                realIn[k] = spec[2 * k]
                imagIn[k] = spec[2 * k + 1]
            }
        }
        for k in Self.bins..<n {
            realIn[k] = realIn[n - k]
            imagIn[k] = -imagIn[n - k]
        }
        vDSP_DFT_Execute(inverseDFT, realIn, imagIn, realOut, imagOut)

        // Synthesis window + overlap-add; the first hop is complete.
        var scale = 1 / Float(n)
        vDSP_vsmul(realOut, 1, &scale, realOut, 1, vDSP_Length(n))
        vDSP_vma(realOut, 1, window, 1, overlap, 1, overlap, 1, vDSP_Length(n))

        // Output sample j holds input sample j - modelDelay; blend that dry sample back in to
        // cap the reduction. Frame k = hopsIn - 2 starts at input sample k * hop.
        let dryMix = Float(bitPattern: dryMixBits.load(ordering: .relaxed))
        let wetMix = 1 - dryMix
        let outStart = (hopsIn - 2) * h - Self.modelDelay
        for i in 0..<h {
            let j = outStart + i
            let dry = j >= 0 ? history[j & (Self.historySize - 1)] : 0
            hopOut[i] = wetMix * overlap[i] + dryMix * dry
        }
        overlap.update(from: overlap.advanced(by: h), count: n - h)
        overlap.advanced(by: n - h).update(repeating: 0, count: h)

        // Full only if the audio thread stopped reading mid-session; drop the hop then.
        _ = output.write(hopOut, count: h)
        return true
    }
}

/// Lock-free single-producer/single-consumer ring of mono samples. `head` and `tail` are
/// monotonically increasing sample counts; each is stored only by its owning side, with
/// release ordering after the copy it publishes.
private final class SampleRing {
    private let storage: UnsafeMutablePointer<Float>
    private let capacity: Int
    private let head = Atomic<Int>(0)
    private let tail = Atomic<Int>(0)

    init(capacity: Int) {
        precondition(capacity.nonzeroBitCount == 1, "capacity must be a power of two")
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
    }

    deinit {
        storage.deallocate()
    }

    /// Consumer side.
    func availableToRead() -> Int {
        head.load(ordering: .acquiring) - tail.load(ordering: .relaxed)
    }

    /// Producer side. Writes all of `src` or nothing.
    @discardableResult
    func write(_ src: UnsafePointer<Float>, count: Int) -> Bool {
        let h = head.load(ordering: .relaxed)
        guard capacity - (h - tail.load(ordering: .acquiring)) >= count else { return false }
        let start = h & (capacity - 1)
        let first = min(count, capacity - start)
        storage.advanced(by: start).update(from: src, count: first)
        if first < count {
            storage.update(from: src.advanced(by: first), count: count - first)
        }
        head.store(h + count, ordering: .releasing)
        return true
    }

    /// Consumer side. `count` must not exceed `availableToRead()`.
    func read(into dst: UnsafeMutablePointer<Float>, count: Int) {
        let t = tail.load(ordering: .relaxed)
        let start = t & (capacity - 1)
        let first = min(count, capacity - start)
        dst.update(from: storage.advanced(by: start), count: first)
        if first < count {
            dst.advanced(by: first).update(from: storage, count: count - first)
        }
        tail.store(t + count, ordering: .releasing)
    }

    /// Consumer side.
    func discard(count: Int) {
        tail.store(tail.load(ordering: .relaxed) + count, ordering: .releasing)
    }

    /// Consumer side, or either side while the other is quiescent.
    func discardAll() {
        tail.store(head.load(ordering: .acquiring), ordering: .releasing)
    }
}
