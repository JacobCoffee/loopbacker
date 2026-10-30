import Foundation
import AppKit
import CoreAudio
import AudioToolbox
import Combine
import Synchronization
import os.log

private let logger = Logger(subsystem: "com.jacobcoffee.loopbacker", category: "AudioRouter")

/// Async load state for one model-backed noise suppression engine (DPDFNet, FastEnhancer): a
/// weak hold on the compiled model while any kernel uses it, plus flags so a route doesn't
/// retrigger the load while one's in flight or retry one that failed. Touched only on
/// `AudioRouter.queue`.
private final class NoiseModelLoadState<Model: AnyObject & Sendable>: @unchecked Sendable {
    weak var model: Model?
    var isLoading = false
    var loadFailed = false
}

/// Identifies one running input/app-capture route: a source (device UID, or `"app:<bundle>"`)
/// feeding one target virtual mic (`RouteTarget.deviceUID`). A source can run two routes at
/// once — one to the virtual mic, one to Stream Mix — sharing voice processing (FX chain,
/// noise suppressor) by `captureDeviceUID` (see `attachFXChain`/`applyNoiseSuppression`), each
/// with its own `RouteContext` and mix matrix per the routing-target contract.
private struct RouteKey: Hashable {
    let source: String
    let target: String
}

/// Routes audio from real input devices to the Loopbacker virtual output device(s),
/// providing real-time meter levels back to the UI.
class AudioRouter: ObservableObject, @unchecked Sendable {
    // MARK: - Published state

    /// Live meter levels for the UI; written by the 30 Hz meter timer on the main thread.
    let meters = MeterLevels()

    /// Current effects preset — applied to new routes and propagated to existing ones
    var currentEffectsPreset = EffectsPreset()
    /// Noise suppression settings, opted-out capture devices, and devices whose monitor stays
    /// dry; read and written only on `queue`.
    private var noiseSuppression = NoiseSuppressionSettings()
    private var noiseExcludedDevices: Set<String> = []
    private var dryMonitorDevices: Set<String> = []
    /// A model-backed engine's compiled model while any kernel uses it. Kernels hold it
    /// strongly, so it's freed once the last one is gone (engine switched, suppression off,
    /// opted out, or route stopped). Queue only.
    private let dpdfnetState = NoiseModelLoadState<NoiseSuppressionModel>()
    private let fastEnhancerState = NoiseModelLoadState<FastEnhancerModel>()
    /// Echo cancellation's own global toggle lives on `noiseSuppression.echoCancellation`
    /// (shared with noise suppression's push), so only the per-source opt-out and the far-end
    /// reference need their own state here; read and written only on `queue`.
    private var echoExcludedDevices: Set<String> = []
    /// `SystemAudioTap.ring`, injected once by `RoutingSync` via `setEchoReference`. Exists as
    /// soon as the tap object does (independent of whether the tap is running), so routes can
    /// attach an `EchoCanceller` the moment echo cancellation turns on even if the tap itself
    /// hasn't started producing real reference data yet.
    private var echoReference: DriftCompensatedRing?
    /// Echo cancellers currently attached to any voice route, mirrored for cross-thread reads
    /// (`echoCancellationERLE()`, the live "echo removed" indicator), the same snapshot/lock
    /// shape as `fxChainsByDevice`/`fxChainsSnapshot`.
    private let echoCancellersLock = NSLock()
    private var echoCancellersSnapshot: [EchoCanceller] = []
    /// Queue only. Whether `installDefaultOutputChangeListenerIfNeeded` has already installed
    /// its listener, so a default-output change recomputes attached cancellers' stream delay.
    private var echoDefaultOutputListenerInstalled = false

    // MARK: - Internal state

    /// Keyed by (source, target) so one source can feed both the virtual mic and Stream Mix.
    private var activeRoutes: [RouteKey: RouteContext] = [:]
    private var activeOutputRoutes: [String: RouteContext] = [:]
    /// Voice chains keyed by capture device UID, mirrored into `fxChainsSnapshot` for
    /// cross-thread reads (`FXEngine`). Queue only.
    private var fxChainsByDevice: [String: FXChain] = [:]
    private let fxChainsLock = NSLock()
    private var fxChainsSnapshot: [String: FXChain] = [:]
    private let queue = DispatchQueue(label: "com.jacobcoffee.loopbacker.audiorouter", qos: .userInteractive)
    private var meterTimer: Timer?
    /// True once a tick finds every RT-written meter buffer silent; lets the next tick skip all
    /// publishing work (see `updatePublishedMeters`) instead of re-checking and re-pushing zeros.
    private var wasSilentMeters = false

    /// Upper bound on channels a single route captures or plays (keeps the mix matrix small
    /// for very wide interfaces).
    static let maxRouteChannels: UInt32 = 64

    /// Per-source, per-target channel mix saved from the UI. Applied when the route is
    /// (re)started, and pushed live to the running route via `mixMatrix` if it's already active.
    private var pendingMixMatrices: [RouteKey: [(srcCh: Int, dstCh: Int)]] = [:]

    /// Holds the CoreAudio resources for a single source -> destination route.
    ///
    /// Configuration fields are mutated only on `queue`. The real-time callbacks (and the
    /// SCStream capture queue for app routes) reach it through unretained pointers and touch
    /// only the pre-allocated buffers and the SPSC `ring`, so it is shared by hand, not by
    /// the compiler's checking.
    ///
    /// Signal path per block: capture `inputChannels` into `renderBuffer` → source meter →
    /// mix matrix into `mixBuffer` (`outputChannels` wide) → echo cancellation (voice routes,
    /// channels 1–2, against `SystemAudioTap`'s reference) → noise suppression (voice routes,
    /// channels 1–2) → voice `FXChain` (voice routes) or `AppAudioProcessor` (app-capture
    /// routes) → output meter → ring → playback.
    fileprivate final class RouteContext: @unchecked Sendable {
        var inputUnit: AudioComponentInstance?
        var outputUnit: AudioComponentInstance?
        var captureDeviceUID: String
        var captureDeviceID: AudioObjectID
        var playbackDeviceID: AudioObjectID
        var playbackDeviceUID: String
        /// Output routes only: first virtual-device channel (1-based) of the monitored pair.
        var monitorChannel = 1
        /// Channels captured from the source (interleave width of `renderBuffer`).
        let inputChannels: UInt32
        /// Channels sent to the playback device (interleave width of `mixBuffer` and `ring`).
        let outputChannels: UInt32
        var sampleRate: Float64

        // Ring passing audio from the input callback to the output callback. The two callbacks
        // run on different device clocks; the ring resamples to absorb the drift.
        // Default: 4096 frames (~85 ms) with a 1024-frame (~21 ms) target latency.
        var ring: DriftCompensatedRing

        // Pre-allocated block buffers (no malloc in the real-time callback). Both hold
        // `blockFrames` frames: captured input, then the mixed output.
        private(set) var renderBuffer: UnsafeMutablePointer<Float>
        private(set) var mixBuffer: UnsafeMutablePointer<Float>
        private(set) var blockFrames: UInt32 = 1024

        /// Voice-chain processor (mic → virtual mic / mic → Stream Mix / mic → monitor), shared
        /// with every other voice route on the same capture device via `fxSlot`, published
        /// unretained exactly like `noiseSlot`. `fxOwner` holds the strong reference.
        let fxSlot = Atomic<Unmanaged<FXChain>?>(nil)
        /// Queue only.
        private(set) var fxOwner: FXChain?
        /// App-capture routes only (game/music/browser): ducking + leveling. Never set on
        /// voice-input or output routes.
        let appAudioProcessor: AppAudioProcessor?
        /// Voice routes only: the mix just before noise suppression (after echo cancellation,
        /// which runs first), snapshotted each block for the chain's recorder.
        private(set) var preNSBuffer: UnsafeMutablePointer<Float>?

        /// Routes fed by a physical input (mic → virtual device, mic → monitor). Only these run
        /// noise suppression and the voice `FXChain`: app captures carry music/game audio, and
        /// output routes replay the already-processed virtual device.
        let isVoiceInput: Bool
        /// App-capture routes (game/music/browser → a virtual mic). Gets `appAudioProcessor`
        /// instead of the voice chain.
        let isAppCapture: Bool
        /// Mic → monitor output (you hearing yourself). Queue only.
        var isMonitor = false
        /// The suppressor the audio thread runs, published unretained so `queue` can swap it
        /// without racing a release on the audio thread. `noiseOwner` holds the strong reference.
        /// Shared with every other voice route on the same capture device (virtual mic, Stream
        /// Mix, monitor), which all run the same dry mix.
        let noiseSlot = Atomic<Unmanaged<NoiseSuppressor>?>(nil)
        /// Queue only.
        private(set) var noiseOwner: NoiseSuppressor?
        /// Queue only: fading out ahead of `detachNoiseSuppressor`.
        var noiseDetaching = false
        /// The canceller the audio thread runs, published unretained exactly like `noiseSlot`.
        /// `echoOwner` holds the strong reference. Shared with the other voice route on the
        /// same capture device, runs before noise suppression.
        let echoSlot = Atomic<Unmanaged<EchoCanceller>?>(nil)
        /// Queue only.
        private(set) var echoOwner: EchoCanceller?
        /// Queue only: fading out ahead of `detachEchoCanceller`.
        var echoDetaching = false

        // Meter levels -- C buffers written on the RT thread, read and decayed on main.
        // Source levels are per captured channel; output levels are per playback channel.
        let meterLevelsPtr: UnsafeMutablePointer<Float>
        let outMeterLevelsPtr: UnsafeMutablePointer<Float>

        /// `outputChannels × inputChannels` gains, row-major: `mixMatrix[dst * inputChannels + src]`.
        /// Written on `queue` and read on the RT thread; a race across a routing change can
        /// at worst produce one block with a half-applied matrix, which is inaudible.
        let mixMatrix: UnsafeMutablePointer<Float>

        init(captureDeviceUID: String, captureDeviceID: AudioObjectID, playbackDeviceID: AudioObjectID,
             playbackDeviceUID: String = "", inputChannels: UInt32, outputChannels: UInt32,
             sampleRate: Float64, isVoiceInput: Bool = false, isAppCapture: Bool = false) {
            self.captureDeviceUID = captureDeviceUID
            self.captureDeviceID = captureDeviceID
            self.playbackDeviceID = playbackDeviceID
            self.playbackDeviceUID = playbackDeviceUID
            self.inputChannels = inputChannels
            self.outputChannels = outputChannels
            self.sampleRate = sampleRate
            self.isVoiceInput = isVoiceInput
            self.isAppCapture = isAppCapture
            appAudioProcessor = isAppCapture ? AppAudioProcessor(sampleRate: Float(sampleRate)) : nil

            meterLevelsPtr = .allocate(capacity: Int(inputChannels))
            meterLevelsPtr.initialize(repeating: 0.0, count: Int(inputChannels))
            outMeterLevelsPtr = .allocate(capacity: Int(outputChannels))
            outMeterLevelsPtr.initialize(repeating: 0.0, count: Int(outputChannels))

            let cells = Int(outputChannels * inputChannels)
            mixMatrix = .allocate(capacity: cells)
            mixMatrix.initialize(repeating: 0.0, count: cells)

            ring = DriftCompensatedRing(capacityFrames: 4096, channels: Int(outputChannels),
                                        targetFill: 1024, sampleRate: sampleRate)

            renderBuffer = .allocate(capacity: Int(blockFrames * inputChannels))
            renderBuffer.initialize(repeating: 0.0, count: Int(blockFrames * inputChannels))
            mixBuffer = .allocate(capacity: Int(blockFrames * outputChannels))
            mixBuffer.initialize(repeating: 0.0, count: Int(blockFrames * outputChannels))
            if isVoiceInput {
                let n = Int(blockFrames * outputChannels)
                let buf = UnsafeMutablePointer<Float>.allocate(capacity: n)
                buf.initialize(repeating: 0.0, count: n)
                preNSBuffer = buf
            }

            setIdentityMix()
        }

        deinit {
            renderBuffer.deallocate()
            mixBuffer.deallocate()
            meterLevelsPtr.deallocate()
            outMeterLevelsPtr.deallocate()
            mixMatrix.deallocate()
            preNSBuffer?.deallocate()
        }

        /// Queue only.
        func attachFXChain(_ chain: FXChain) {
            fxOwner = chain
            fxSlot.store(.passUnretained(chain), ordering: .releasing)
        }

        /// Queue only. Unpublishes the chain and hands back the strong reference.
        func detachFXChain() -> FXChain? {
            fxSlot.store(nil, ordering: .releasing)
            defer { fxOwner = nil }
            return fxOwner
        }

        /// Queue only.
        func attachNoiseSuppressor(_ suppressor: NoiseSuppressor) {
            noiseOwner = suppressor
            noiseSlot.store(.passUnretained(suppressor), ordering: .releasing)
        }

        /// Queue only. Unpublishes the suppressor and hands back the strong reference: an audio
        /// callback may still be inside it, so the caller must keep it alive a while longer.
        func detachNoiseSuppressor() -> NoiseSuppressor? {
            noiseSlot.store(nil, ordering: .releasing)
            defer { noiseOwner = nil }
            return noiseOwner
        }

        /// Queue only.
        func attachEchoCanceller(_ canceller: EchoCanceller) {
            echoOwner = canceller
            echoSlot.store(.passUnretained(canceller), ordering: .releasing)
        }

        /// Queue only. Unpublishes the canceller and hands back the strong reference: an audio
        /// callback may still be inside it, so the caller must keep it alive a while longer.
        func detachEchoCanceller() -> EchoCanceller? {
            echoSlot.store(nil, ordering: .releasing)
            defer { echoOwner = nil }
            return echoOwner
        }

        /// Grow the block buffers. Only call before the route's callbacks are running.
        func reserveBlockFrames(_ frames: UInt32) {
            guard frames > blockFrames else { return }
            renderBuffer.deallocate()
            mixBuffer.deallocate()
            blockFrames = frames
            renderBuffer = .allocate(capacity: Int(frames * inputChannels))
            renderBuffer.initialize(repeating: 0.0, count: Int(frames * inputChannels))
            mixBuffer = .allocate(capacity: Int(frames * outputChannels))
            mixBuffer.initialize(repeating: 0.0, count: Int(frames * outputChannels))
            if isVoiceInput {
                preNSBuffer?.deallocate()
                let n = Int(frames * outputChannels)
                let buf = UnsafeMutablePointer<Float>.allocate(capacity: n)
                buf.initialize(repeating: 0.0, count: n)
                preNSBuffer = buf
            }
        }

        /// Passthrough: source channel N feeds output channel N for every shared index.
        func setIdentityMix() {
            let cells = Int(outputChannels * inputChannels)
            mixMatrix.update(repeating: 0.0, count: cells)
            for ch in 0..<Int(min(inputChannels, outputChannels)) {
                mixMatrix[ch * Int(inputChannels) + ch] = 1.0
            }
        }

        /// Run one captured block (already in `renderBuffer`) through the route and enqueue it.
        /// - Parameter sampleTime: the block's HAL input sample time, when the callback has one.
        func processCapturedBlock(frames: UInt32, sampleTime: Float64? = nil) {
            computePeak(from: renderBuffer, channels: inputChannels, frames: frames, into: meterLevelsPtr)
            mix(frames: frames)
            if let canceller = echoSlot.load(ordering: .acquiring) {
                canceller._withUnsafeGuaranteedRef {
                    $0.process(mixBuffer, frames: Int(frames), stride: Int(outputChannels), sampleTime: sampleTime)
                }
            }
            if let preNSBuffer {
                memcpy(preNSBuffer, mixBuffer, Int(frames * outputChannels) * MemoryLayout<Float>.size)
            }
            if let suppressor = noiseSlot.load(ordering: .acquiring) {
                suppressor._withUnsafeGuaranteedRef {
                    $0.process(mixBuffer, frames: Int(frames), stride: Int(outputChannels), sampleTime: sampleTime)
                }
            }
            if isVoiceInput, let chain = fxSlot.load(ordering: .acquiring) {
                chain._withUnsafeGuaranteedRef {
                    $0.process(mixBuffer, frames: Int(frames), stride: Int(outputChannels),
                              sampleTime: sampleTime, rawPreNS: preNSBuffer)
                }
            } else if let appAudioProcessor {
                appAudioProcessor.process(mixBuffer, frames: Int(frames), stride: Int(outputChannels))
            }
            // Mute/push-to-talk gate (Control slice): only the route that actually feeds the
            // virtual mic, right after the FX chain -- never the monitor route (you hearing
            // yourself should stay live even while the outgoing mic is muted).
            if isVoiceInput, !isMonitor {
                MicGate.shared.process(mixBuffer, frames: Int(frames), stride: Int(outputChannels))
            }
            computePeak(from: mixBuffer, channels: outputChannels, frames: frames, into: outMeterLevelsPtr)
            ring.write(mixBuffer, frames: frames)
        }

        func readFromRing(_ data: UnsafeMutablePointer<Float>, frames: UInt32) {
            ring.read(into: data, frames: frames)
        }

        private func mix(frames: UInt32) {
            let inCh = Int(inputChannels)
            let outCh = Int(outputChannels)
            for i in 0..<Int(frames) {
                let src = renderBuffer + i * inCh
                let dst = mixBuffer + i * outCh
                for o in 0..<outCh {
                    let row = mixMatrix + o * inCh
                    var acc: Float = 0
                    for s in 0..<inCh { acc += row[s] * src[s] }
                    dst[o] = acc
                }
            }
        }

        private func computePeak(from buffer: UnsafePointer<Float>, channels: UInt32,
                                 frames: UInt32, into levels: UnsafeMutablePointer<Float>) {
            let chCount = Int(channels)
            guard chCount > 0 && frames > 0 else { return }

            for ch in 0..<chCount {
                var peak: Float = 0.0
                for i in 0..<Int(frames) {
                    let s = fabsf(buffer[i * chCount + ch])
                    if s > peak { peak = s }
                }
                let db = peak > 0.00001 ? 20.0 * log10f(peak) : -100.0
                let normalized = max(0.0, min(1.0, (db + 60.0) / 60.0))
                let prev = levels[ch]
                levels[ch] = normalized > prev ? normalized : prev * 0.93 + normalized * 0.07
            }
        }
    }

    // MARK: - Lifecycle

    init() {
        startMeterTimer()
        // Restart routing after screen unlock / wake from sleep
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            logger.info("Screen woke -- restarting audio routes")
            self?.restartAllRoutes()
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            logger.info("System woke -- restarting audio routes")
            self?.restartAllRoutes()
        }
    }

    deinit {
        meterTimer?.invalidate()
        // stopAll is synchronous here to ensure callbacks are torn down
        // before the AudioRouter is deallocated.
        let semaphore = DispatchSemaphore(value: 0)
        queue.async { [self] in
            let keys = Array(self.activeRoutes.keys)
            for key in keys {
                self.stopRoutingInternal(sourceKey: key.source, targetDeviceUID: key.target)
            }
            let outputKeys = Array(self.activeOutputRoutes.keys)
            for uid in outputKeys {
                self.stopOutputRoutingInternal(virtualDeviceUID: uid)
            }
            semaphore.signal()
        }
        semaphore.wait()
    }

    /// Tear down and re-create all active routes (after sleep/screen lock kills audio units)
    func restartAllRoutes() {
        queue.async { [weak self] in
            guard let self else { return }
            let pairs = self.activeRoutes.keys.map { (source: $0.source, target: $0.target) }
            let outputUIDs = Array(self.activeOutputRoutes.keys)
            for key in self.activeRoutes.keys {
                self.stopRoutingInternal(sourceKey: key.source, targetDeviceUID: key.target)
            }
            for uid in outputUIDs {
                self.stopOutputRoutingInternal(virtualDeviceUID: uid)
            }
            // Retry with bounded attempts instead of a fixed 0.5s delay.
            // The audio system may take a variable amount of time to settle after wake.
            self.retryRoutingAfterWake(pairs: pairs, attempt: 0, maxAttempts: 5)
        }
    }

    /// Retry starting routes after wake with bounded attempts at increasing intervals.
    private func retryRoutingAfterWake(pairs: [(source: String, target: String)], attempt: Int, maxAttempts: Int) {
        // USB devices like MOTU M2 need more time to re-enumerate after wake
        let delay = Double(attempt + 1) * 0.5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            var failedPairs: [(source: String, target: String)] = []
            for pair in pairs {
                // Check if the device is available before trying to start
                if self.findDeviceByUID(pair.source) != nil {
                    self.startRouting(sourceDeviceUID: pair.source, targetDeviceUID: pair.target)
                } else {
                    failedPairs.append(pair)
                }
            }
            // Retry remaining pairs if we haven't exhausted attempts
            if !failedPairs.isEmpty && attempt + 1 < maxAttempts {
                logger.info("Wake retry \(attempt + 1)/\(maxAttempts): \(failedPairs.count) route(s) not yet available")
                self.retryRoutingAfterWake(pairs: failedPairs, attempt: attempt + 1, maxAttempts: maxAttempts)
            } else if !failedPairs.isEmpty {
                logger.warning("Wake retry exhausted: \(failedPairs.count) route(s) still unavailable")
            }
        }
    }

    // MARK: - Public API (input routing)

    /// Start routing audio from the given source device to a Loopbacker virtual device.
    /// `targetDeviceUID` defaults to the virtual mic; pass `VirtualDeviceChannels.streamUID`
    /// for Stream Mix. The two targets run independent `RouteContext`s sharing voice
    /// processing (see `attachFXChain`/`applyNoiseSuppression`).
    func startRouting(sourceDeviceUID: String, targetDeviceUID: String = VirtualDeviceChannels.micUID) {
        queue.async { [weak self] in
            self?.startRoutingInternal(sourceDeviceUID: sourceDeviceUID, targetDeviceUID: targetDeviceUID)
        }
    }

    /// Stop routing for a specific source device → target pair.
    func stopRouting(sourceDeviceUID: String, targetDeviceUID: String = VirtualDeviceChannels.micUID) {
        queue.async { [weak self] in
            self?.stopRoutingInternal(sourceKey: sourceDeviceUID, targetDeviceUID: targetDeviceUID)
        }
    }

    /// Stop all active routes.
    func stopAll() {
        queue.async { [weak self] in
            guard let self else { return }
            let keys = Array(self.activeRoutes.keys)
            for key in keys {
                self.stopRoutingInternal(sourceKey: key.source, targetDeviceUID: key.target)
            }
            let outputKeys = Array(self.activeOutputRoutes.keys)
            for uid in outputKeys {
                self.stopOutputRoutingInternal(virtualDeviceUID: uid)
            }
        }
    }

    // MARK: - Public API (output routing)

    /// Start routing audio from a Loopbacker virtual device to a physical output device.
    /// Captures every channel from the virtual device's input side (looped-back audio) and
    /// plays the pair starting at `monitorChannel` (1-based) to the output's first two channels.
    func startOutputRouting(virtualDeviceUID: String, physicalOutputUID: String, monitorChannel: Int) {
        logger.info("startOutputRouting called: \(virtualDeviceUID) -> \(physicalOutputUID) from ch \(monitorChannel)")
        queue.async { [weak self] in
            self?.startOutputRoutingInternal(virtualDeviceUID: virtualDeviceUID, physicalOutputUID: physicalOutputUID,
                                             monitorChannel: monitorChannel)
        }
    }

    /// Start monitoring: capture from a source and play directly to physical output (hear yourself).
    func startMonitoring(sourceDeviceUID: String, outputDeviceUID: String) {
        let key = "monitor:\(sourceDeviceUID)"
        logger.info("startMonitoring: \(sourceDeviceUID) -> \(outputDeviceUID)")
        queue.async { [weak self] in
            guard let self else { return }
            self.stopOutputRoutingInternal(virtualDeviceUID: key)
            guard !outputDeviceUID.isEmpty else { return }
            guard let captureID = self.findDeviceByUID(sourceDeviceUID) else { return }
            guard let outputID = self.findDeviceByUID(outputDeviceUID) else { return }
            let rate = self.getDeviceSampleRate(captureID)
            let inputChannels = self.routableChannelCount(captureID, scope: kAudioObjectPropertyScopeInput)
            guard inputChannels > 0 else { return }
            let ctx = RouteContext(captureDeviceUID: sourceDeviceUID, captureDeviceID: captureID,
                                  playbackDeviceID: outputID, playbackDeviceUID: outputDeviceUID,
                                  inputChannels: inputChannels, outputChannels: 2, sampleRate: rate,
                                  isVoiceInput: true)
            ctx.isMonitor = true
            self.attachFXChain(to: ctx)
            self.applyNoiseSuppression(to: ctx)
            self.applyEchoCancellation(to: ctx)
            self.refreshEchoCancellersSnapshot()
            // Monitor hears the same channel mix as the virtual mic route (e.g. mono mic fanned
            // to L+R); the virtual mic is the monitor's reference target.
            if let pending = self.pendingMixMatrices[RouteKey(source: sourceDeviceUID, target: VirtualDeviceChannels.micUID)] {
                self.applyMixToContext(ctx, routes: pending)
            }
            guard self.setupInputUnit(ctx) else { return }
            guard self.setupOutputUnit(ctx) else { self.teardownUnit(&ctx.inputUnit); return }
            if let u = ctx.inputUnit { AudioOutputUnitStart(u) }
            if let u = ctx.outputUnit { AudioOutputUnitStart(u) }
            self.activeOutputRoutes[key] = ctx
        }
    }

    /// Stop output routing for a specific virtual device.
    func stopOutputRouting(virtualDeviceUID: String) {
        queue.async { [weak self] in
            self?.stopOutputRoutingInternal(virtualDeviceUID: virtualDeviceUID)
        }
    }

    // MARK: - Public API (virtual device channel count)

    /// Resize a Loopbacker virtual device (the virtual mic, Stream Mix, or an output
    /// destination) to `count` channels. Every route whose target is this device stops, the
    /// driver reconfigures it, and the same routes restart at the new width. `completion`
    /// receives the count the device reports afterwards (nil when its driver predates the
    /// channel-count property).
    func setVirtualDeviceChannels(_ count: Int, deviceUID: String, appCaptureService: AppCaptureService,
                                  completion: @escaping @MainActor @Sendable (Int?) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let current = VirtualDeviceChannels.count(deviceUID: deviceUID)
            guard let current, current != count else {
                Task { @MainActor in completion(current) }
                return
            }

            let affectedKeys = self.activeRoutes.filter { $0.value.playbackDeviceUID == deviceUID }.map(\.key)
            let outputRoute = self.activeOutputRoutes[deviceUID].map {
                (physicalUID: $0.playbackDeviceUID, monitorChannel: $0.monitorChannel)
            }
            for key in affectedKeys {
                if key.source.hasPrefix("app:") {
                    self.stopAppCaptureInternal(bundleID: String(key.source.dropFirst(4)), targetDeviceUID: key.target)
                } else {
                    self.stopRoutingInternal(sourceKey: key.source, targetDeviceUID: key.target)
                }
            }
            if outputRoute != nil {
                self.stopOutputRoutingInternal(virtualDeviceUID: deviceUID)
            }

            if VirtualDeviceChannels.setCount(count, deviceUID: deviceUID) {
                self.waitForChannelCount(count, deviceUID: deviceUID)
            } else {
                logger.error("Driver rejected \(count) channels for \(deviceUID)")
            }

            for key in affectedKeys {
                if key.source.hasPrefix("app:") {
                    // SCStream keeps running; startCapture swaps it onto the new context.
                    self.startAppCapture(bundleID: String(key.source.dropFirst(4)), targetDeviceUID: key.target,
                                        appCaptureService: appCaptureService)
                } else {
                    self.startRoutingInternal(sourceDeviceUID: key.source, targetDeviceUID: key.target)
                }
            }
            if let outputRoute {
                self.startOutputRoutingInternal(virtualDeviceUID: deviceUID, physicalOutputUID: outputRoute.physicalUID,
                                                monitorChannel: outputRoute.monitorChannel)
            }

            let applied = VirtualDeviceChannels.count(deviceUID: deviceUID)
            Task { @MainActor in completion(applied) }
        }
    }

    /// Hold the router queue until the HAL reports the new width (at most ~2 s), so restarted
    /// routes open the device at the right format.
    private func waitForChannelCount(_ count: Int, deviceUID: String) {
        for _ in 0..<40 {
            if let deviceID = findDeviceByUID(deviceUID),
               routableChannelCount(deviceID, scope: kAudioObjectPropertyScopeInput) == UInt32(count) {
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        logger.warning("Timed out waiting for \(deviceUID) to report \(count) channels")
    }

    // MARK: - Public API (app audio capture)

    /// Start routing audio from a running application (via ScreenCaptureKit) to a Loopbacker
    /// virtual device. `targetDeviceUID` defaults to the virtual mic; pass
    /// `VirtualDeviceChannels.streamUID` to also (or instead) feed Stream Mix.
    func startAppCapture(bundleID: String, targetDeviceUID: String = VirtualDeviceChannels.micUID,
                         appCaptureService: AppCaptureService) {
        let sourceKey = "app:\(bundleID)"
        let routeKey = RouteKey(source: sourceKey, target: targetDeviceUID)
        queue.async { [weak self] in
            guard let self else { return }
            guard self.activeRoutes[routeKey] == nil else { return }

            // Find the target Loopbacker virtual device for output
            guard let playbackDeviceID = self.findDeviceByUID(targetDeviceUID) else {
                logger.error("Loopbacker virtual device not found for app capture: \(targetDeviceUID)")
                return
            }

            let sampleRate = self.getDeviceSampleRate(playbackDeviceID)
            // SCStream delivers stereo; the virtual mic may be wider.
            let captureChannels: UInt32 = 2
            let micChannels = self.routableChannelCount(playbackDeviceID, scope: kAudioObjectPropertyScopeOutput)
            guard micChannels > 0 else {
                logger.error("Loopbacker virtual device reports no output channels: \(targetDeviceUID)")
                return
            }

            // Create a RouteContext with no input AUHAL — SCStream replaces it
            let ctx = RouteContext(
                captureDeviceUID: sourceKey,
                captureDeviceID: 0,
                playbackDeviceID: playbackDeviceID,
                playbackDeviceUID: targetDeviceUID,
                inputChannels: captureChannels,
                outputChannels: micChannels,
                sampleRate: sampleRate,
                isAppCapture: true
            )
            ctx.appAudioProcessor?.updateConfig(AppAudioProcessor.Config(
                duckingEnabled: self.currentEffectsPreset.appAudio.duckingEnabled,
                duckAmountDB: self.currentEffectsPreset.appAudio.duckAmountDB,
                duckAttackMs: self.currentEffectsPreset.appAudio.duckAttackMs,
                duckReleaseMs: self.currentEffectsPreset.appAudio.duckReleaseMs,
                levelerEnabled: self.currentEffectsPreset.appAudio.levelerEnabled,
                levelerTarget: self.currentEffectsPreset.appAudio.levelerTarget))

            // App capture needs a much larger ring than device routing: SCStream delivers
            // bursty chunks on its own schedule. 16384 frames (~340 ms) of capacity with a
            // 2048-frame (~42 ms) target latency absorbs the jitter.
            ctx.ring = DriftCompensatedRing(capacityFrames: 16384, channels: Int(micChannels),
                                            targetFill: 2048, sampleRate: sampleRate)

            // SCStream can deliver large chunks; larger ones are split below.
            ctx.reserveBlockFrames(8192)

            // Set up only the output AUHAL (SCStream provides the input)
            guard self.setupOutputUnit(ctx) else {
                logger.error("Failed to set up output unit for app capture")
                return
            }

            if let u = ctx.outputUnit {
                let status = AudioOutputUnitStart(u)
                if status != noErr {
                    logger.error("Failed to start output unit for app capture: \(status)")
                    self.teardownUnit(&ctx.outputUnit)
                    return
                }
            }
            self.activeRoutes[routeKey] = ctx
            if let pending = self.pendingMixMatrices[routeKey] {
                self.applyMixToContext(ctx, routes: pending)
            }

            // Start SCStream capture, writing into this context's ring buffer
            let ringWriter: AppAudioWriter = { [weak ctx] buffer, frames, chCount in
                guard let ctx, chCount == ctx.inputChannels else { return }
                var offset: UInt32 = 0
                while offset < frames {
                    let chunk = min(ctx.blockFrames, frames - offset)
                    memcpy(ctx.renderBuffer, buffer.advanced(by: Int(offset * chCount)),
                           Int(chunk * chCount) * MemoryLayout<Float>.size)
                    ctx.processCapturedBlock(frames: chunk)
                    offset += chunk
                }
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await appCaptureService.startCapture(
                        bundleID: bundleID,
                        ringBufferWriter: ringWriter,
                        sampleRate: sampleRate,
                        channelCount: captureChannels
                    )
                } catch {
                    logger.error("Failed to start app capture for \(bundleID): \(error.localizedDescription)")
                    self.queue.async {
                        self.stopAppCaptureInternal(bundleID: bundleID, targetDeviceUID: targetDeviceUID)
                    }
                }
            }

            logger.info("Started app capture routing for \(bundleID) -> \(targetDeviceUID)")
        }
    }

    /// Stop app audio capture routing for a specific bundle → target pair.
    func stopAppCapture(bundleID: String, targetDeviceUID: String = VirtualDeviceChannels.micUID,
                        appCaptureService: AppCaptureService) {
        queue.async { [weak self] in
            self?.stopAppCaptureInternal(bundleID: bundleID, targetDeviceUID: targetDeviceUID)
        }
        Task { @MainActor in
            await appCaptureService.stopCapture(bundleID: bundleID)
        }
    }

    private func stopAppCaptureInternal(bundleID: String, targetDeviceUID: String) {
        let routeKey = RouteKey(source: "app:\(bundleID)", target: targetDeviceUID)
        guard let ctx = activeRoutes.removeValue(forKey: routeKey) else { return }

        if let outputUnit = ctx.outputUnit {
            AudioOutputUnitStop(outputUnit)
        }
        // Only release for the output unit (no input unit was created)
        let hadOutput = ctx.outputUnit != nil
        teardownUnit(&ctx.outputUnit)
        if hadOutput { Unmanaged.passUnretained(ctx).release() }

        logger.info("Stopped app capture routing for \(bundleID) -> \(targetDeviceUID)")
    }

    // MARK: - Channel routing

    /// Push the per-source, per-target channel mix from the UI's route graph into the audio
    /// engine. `routes` is a list of (sourceChannel, outputChannel) 1-indexed pairs for a
    /// single source → target pair. An empty list falls back to identity passthrough
    /// (src1→out1, src2→out2). Applied immediately if the route is active, and cached so it's
    /// re-applied on restart.
    func setChannelMix(sourceDeviceUID: String, targetDeviceUID: String = VirtualDeviceChannels.micUID,
                       routes: [(srcCh: Int, dstCh: Int)]) {
        queue.async { [weak self] in
            guard let self else { return }
            let key = RouteKey(source: sourceDeviceUID, target: targetDeviceUID)
            self.pendingMixMatrices[key] = routes
            if let ctx = self.activeRoutes[key] {
                self.applyMixToContext(ctx, routes: routes)
            }
            // The monitor route always mirrors the virtual mic's mix (see `startMonitoring`).
            if targetDeviceUID == VirtualDeviceChannels.micUID,
               let monitor = self.activeOutputRoutes["monitor:\(sourceDeviceUID)"] {
                self.applyMixToContext(monitor, routes: routes)
            }
        }
    }

    /// Write the mix matrix cells for a route context from a route list.
    private func applyMixToContext(_ ctx: RouteContext, routes: [(srcCh: Int, dstCh: Int)]) {
        guard !routes.isEmpty else {
            ctx.setIdentityMix()
            return
        }
        let inCh = Int(ctx.inputChannels)
        let outCh = Int(ctx.outputChannels)
        ctx.mixMatrix.update(repeating: 0.0, count: inCh * outCh)
        for r in routes {
            let dst = r.dstCh - 1   // 1-indexed in the UI, 0-indexed here
            let src = r.srcCh - 1
            guard (0..<outCh).contains(dst), (0..<inCh).contains(src) else { continue }
            ctx.mixMatrix[dst * inCh + src] = 1.0
        }
    }

    // MARK: - Effects

    /// Push the preset's voice-chain nodes to every running voice chain (each decides for
    /// itself whether it's a param-only update or a structural rebuild) and its app-audio
    /// settings to every running app-capture route.
    func updateEffectsPreset(_ preset: EffectsPreset) {
        queue.async { [weak self] in
            guard let self else { return }
            let nodes = preset.nodes
            for chain in self.fxChainsByDevice.values {
                Task { await chain.updateConfigs(nodes) }
            }
            let appConfig = AppAudioProcessor.Config(
                duckingEnabled: preset.appAudio.duckingEnabled, duckAmountDB: preset.appAudio.duckAmountDB,
                duckAttackMs: preset.appAudio.duckAttackMs, duckReleaseMs: preset.appAudio.duckReleaseMs,
                levelerEnabled: preset.appAudio.levelerEnabled, levelerTarget: preset.appAudio.levelerTarget)
            for ctx in self.activeRoutes.values { ctx.appAudioProcessor?.updateConfig(appConfig) }
        }
    }

    // MARK: - Voice FX chain

    /// Must run on `queue`. Attaches `ctx` to the voice chain for its capture device, sharing
    /// the existing instance with any other voice route on the same device (virtual mic,
    /// Stream Mix, monitor), or creating one. No-op for non-voice routes.
    private func attachFXChain(to ctx: RouteContext) {
        guard ctx.isVoiceInput else { return }
        if let sibling = voiceContexts.first(where: { $0 !== ctx && $0.captureDeviceUID == ctx.captureDeviceUID }),
           let shared = sibling.fxOwner {
            ctx.attachFXChain(shared)
            return
        }
        let chain = FXChain(sampleRate: Float(ctx.sampleRate), captureDeviceUID: ctx.captureDeviceUID)
        ctx.attachFXChain(chain)
        fxChainsByDevice[ctx.captureDeviceUID] = chain
        fxChainsLock.lock()
        fxChainsSnapshot[ctx.captureDeviceUID] = chain
        fxChainsLock.unlock()
        let nodes = currentEffectsPreset.nodes
        Task { await chain.updateConfigs(nodes) }
    }

    /// Must run on `queue`, after removing `ctx` from `activeRoutes`/`activeOutputRoutes`, so
    /// `voiceContexts` no longer includes it. Frees the device's chain once no voice route
    /// uses it anymore.
    private func detachFXChain(from ctx: RouteContext) {
        guard ctx.isVoiceInput else { return }
        _ = ctx.detachFXChain()
        guard !voiceContexts.contains(where: { $0.captureDeviceUID == ctx.captureDeviceUID }) else { return }
        if let chain = fxChainsByDevice.removeValue(forKey: ctx.captureDeviceUID) {
            // The last voice route on this device is gone and its audio unit(s) are already
            // stopped (callers stop them before calling this): the IO proc is provably halted,
            // so it's safe to free whatever graphs this chain still owns now rather than wait.
            chain.ioStopped()
        }
        fxChainsLock.lock()
        fxChainsSnapshot.removeValue(forKey: ctx.captureDeviceUID)
        fxChainsLock.unlock()
    }

    /// Any thread. The voice chain on the first active voice device (stable key order), for
    /// `FXEngine`'s UI-facing queries.
    func firstVoiceFXChain() -> FXChain? {
        fxChainsLock.lock()
        defer { fxChainsLock.unlock() }
        return fxChainsSnapshot.keys.sorted().first.flatMap { fxChainsSnapshot[$0] }
    }

    /// Any thread. Every running voice chain (one per capture device).
    func allVoiceFXChains() -> [FXChain] {
        fxChainsLock.lock()
        defer { fxChainsLock.unlock() }
        return Array(fxChainsSnapshot.values)
    }

    // MARK: - Noise suppression

    /// Apply noise suppression settings to every voice-input route, and to routes started later.
    /// - Parameters:
    ///   - excludedDeviceUIDs: capture devices whose source opted out.
    ///   - dryMonitorDeviceUIDs: capture devices whose monitor route skips suppression (no
    ///     added delay when hearing yourself); their virtual mic and Stream Mix routes are
    ///     still suppressed.
    func updateNoiseSuppression(_ settings: NoiseSuppressionSettings, excludedDeviceUIDs: Set<String>,
                                dryMonitorDeviceUIDs: Set<String>) {
        queue.async { [weak self] in
            guard let self else { return }
            self.noiseSuppression = settings
            self.noiseExcludedDevices = excludedDeviceUIDs
            self.dryMonitorDevices = dryMonitorDeviceUIDs
            self.applyNoiseSuppressionToAllRoutes()
        }
    }

    /// Must run on `queue`.
    private var voiceContexts: [RouteContext] {
        (Array(activeRoutes.values) + Array(activeOutputRoutes.values)).filter(\.isVoiceInput)
    }

    /// Must run on `queue`.
    private func applyNoiseSuppressionToAllRoutes() {
        for ctx in voiceContexts { applyNoiseSuppression(to: ctx) }
    }

    /// Must run on `queue`. Gives `ctx` a suppressor running the selected engine, or takes it
    /// away. Voice routes on the same capture device share one suppressor. Suppressors nobody
    /// wants (off, opted out, or the other engine) fade out and are freed, and with them a
    /// model-backed engine's model once nothing uses it.
    private func applyNoiseSuppression(to ctx: RouteContext) {
        guard ctx.isVoiceInput, !ctx.noiseDetaching else { return }
        let settings = noiseSuppression
        let wanted = settings.isEnabled && !noiseExcludedDevices.contains(ctx.captureDeviceUID)
            && !(ctx.isMonitor && dryMonitorDevices.contains(ctx.captureDeviceUID))

        if let current = ctx.noiseOwner {
            if wanted && current.engine == settings.engine {
                current.setMaxReduction(dB: settings.maxReductionDB)
                current.setEnabled(true)
            } else {
                fadeOutNoiseSuppressor(of: ctx)
            }
            return
        }
        guard wanted else { return }

        let sibling = voiceContexts.first {
            $0 !== ctx && $0.captureDeviceUID == ctx.captureDeviceUID && $0.sampleRate == ctx.sampleRate
                && !$0.noiseDetaching && $0.noiseOwner?.engine == settings.engine
        }
        if let shared = sibling?.noiseOwner {
            ctx.attachNoiseSuppressor(shared)
            return
        }
        guard let kernel = makeNoiseKernel(settings.engine),
              let suppressor = NoiseSuppressor.make(sampleRate: ctx.sampleRate, engine: settings.engine, kernel: kernel)
        else { return }
        suppressor.setMaxReduction(dB: settings.maxReductionDB)
        suppressor.setEnabled(true)
        ctx.attachNoiseSuppressor(suppressor)
        logger.info("Noise suppression (\(settings.engine.rawValue, privacy: .public)) started on \(ctx.captureDeviceUID)")
    }

    /// Must run on `queue`. Crossfades `ctx`'s suppressor to dry (10 ms), then detaches it and
    /// re-applies the settings, which may attach the other engine. Waiting out the fade keeps
    /// an engine switch click-free: old wet → dry → new wet.
    private func fadeOutNoiseSuppressor(of ctx: RouteContext) {
        guard let current = ctx.noiseOwner else { return }
        ctx.noiseDetaching = true
        let sharedWithKeeper = voiceContexts.contains { $0 !== ctx && $0.noiseOwner === current && !$0.noiseDetaching }
        if !sharedWithKeeper { current.setEnabled(false) }
        queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            let old = ctx.detachNoiseSuppressor()
            ctx.noiseDetaching = false
            // An audio callback that loaded the slot just before it was cleared may still be
            // running `old`; one IO cycle is a few ms, so half a second is ample.
            self?.queue.asyncAfter(deadline: .now() + 0.5) { withExtendedLifetime(old) {} }
            guard let self, self.voiceContexts.contains(where: { $0 === ctx }) else { return }
            self.applyNoiseSuppression(to: ctx)
        }
    }

    // MARK: - Echo cancellation

    /// Any thread. Gives the audio engine the far-end reference ring for echo cancellation
    /// (`SystemAudioTap.ring`, owned by `RoutingSync`), or clears it (e.g. the tap object is
    /// being torn down). Existing routes that want echo cancellation re-apply immediately;
    /// routes with no reference yet attach once this lands.
    func setEchoReference(_ ring: DriftCompensatedRing?) {
        queue.async { [weak self] in
            guard let self else { return }
            self.echoReference = ring
            self.installDefaultOutputChangeListenerIfNeeded()
            self.applyEchoCancellationToAllRoutes()
        }
    }

    /// Queue only. The default output device changing (built-in speakers -> USB interface, or
    /// to/from one of Loopbacker's own virtual devices) can change the HAL latency AEC3's delay
    /// estimate was built from, same as it changes which device `SystemAudioTap` taps. Installed
    /// once, the first time there's a reference to echo-cancel against; never removed, since
    /// `AudioRouter` lives for the app's lifetime same as `SystemAudioTap`.
    private func installDefaultOutputChangeListenerIfNeeded() {
        guard !echoDefaultOutputListenerInstalled else { return }
        echoDefaultOutputListenerInstalled = true
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue) { [weak self] _, _ in
            self?.refreshEchoStreamDelays()
        }
    }

    /// Must run on `queue`. Recomputes and re-pushes every attached echo canceller's AEC3 delay
    /// estimate (see `estimateStreamDelayMs`); AEC3 keeps adapting through the gap, same as it
    /// does for an initial estimate that's merely in the right ballpark.
    private func refreshEchoStreamDelays() {
        for ctx in voiceContexts {
            guard let canceller = ctx.echoOwner else { continue }
            canceller.setStreamDelay(ms: estimateStreamDelayMs(for: ctx))
        }
    }

    /// Apply echo cancellation's per-source opt-outs to every voice-input route. The global
    /// on/off toggle is read from `noiseSuppression.echoCancellation`, already landed by
    /// `updateNoiseSuppression` (`RoutingSync` pushes both from the same settings object, in
    /// order, over the serial `queue`).
    func updateEchoCancellation(excludedDeviceUIDs: Set<String>) {
        queue.async { [weak self] in
            guard let self else { return }
            self.echoExcludedDevices = excludedDeviceUIDs
            self.applyEchoCancellationToAllRoutes()
        }
    }

    /// Any thread. A representative attached canceller's smoothed ERLE (dB), for
    /// `EchoCancellationSection`'s live "echo removed" indicator, or nil if none is attached.
    func echoCancellationERLE() -> Float? {
        echoCancellersLock.lock()
        defer { echoCancellersLock.unlock() }
        return echoCancellersSnapshot.first?.erleDB
    }

    /// Must run on `queue`.
    private func applyEchoCancellationToAllRoutes() {
        for ctx in voiceContexts { applyEchoCancellation(to: ctx) }
        refreshEchoCancellersSnapshot()
    }

    /// Must run on `queue`. Gives `ctx` an echo canceller reading the shared far-end reference
    /// ring, or takes it away. Voice routes on the same capture device share one canceller,
    /// the same sharing shape `applyNoiseSuppression` uses for `NoiseSuppressor`.
    private func applyEchoCancellation(to ctx: RouteContext) {
        guard ctx.isVoiceInput, !ctx.echoDetaching else { return }
        let wanted = noiseSuppression.echoCancellation && echoReference != nil
            && !echoExcludedDevices.contains(ctx.captureDeviceUID)

        if let current = ctx.echoOwner {
            if wanted {
                current.setEnabled(true)
            } else {
                fadeOutEchoCanceller(of: ctx)
            }
            return
        }
        guard wanted, let reference = echoReference else { return }

        let sibling = voiceContexts.first {
            $0 !== ctx && $0.captureDeviceUID == ctx.captureDeviceUID && $0.sampleRate == ctx.sampleRate
                && !$0.echoDetaching
        }
        if let shared = sibling?.echoOwner {
            ctx.attachEchoCanceller(shared)
            shared.setEnabled(true)
            return
        }
        guard let canceller = EchoCanceller.make(reference: reference) else { return }
        canceller.setStreamDelay(ms: estimateStreamDelayMs(for: ctx))
        canceller.setEnabled(true)
        ctx.attachEchoCanceller(canceller)
        logger.info("Echo cancellation started on \(ctx.captureDeviceUID)")
    }

    /// Must run on `queue`. Crossfades `ctx`'s canceller to dry (10 ms, inside
    /// `EchoCanceller.process`), then detaches it -- the same two-phase shape
    /// `fadeOutNoiseSuppressor` uses.
    private func fadeOutEchoCanceller(of ctx: RouteContext) {
        guard let current = ctx.echoOwner else { return }
        ctx.echoDetaching = true
        let sharedWithKeeper = voiceContexts.contains { $0 !== ctx && $0.echoOwner === current && !$0.echoDetaching }
        if !sharedWithKeeper { current.setEnabled(false) }
        queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            let old = ctx.detachEchoCanceller()
            ctx.echoDetaching = false
            // An audio callback that loaded the slot just before it was cleared may still be
            // running `old`; one IO cycle is a few ms, so half a second is ample.
            self?.queue.asyncAfter(deadline: .now() + 0.5) { withExtendedLifetime(old) {} }
            guard let self, self.voiceContexts.contains(where: { $0 === ctx }) else { return }
            self.applyEchoCancellation(to: ctx)
            self.refreshEchoCancellersSnapshot()
        }
    }

    /// Must run on `queue`. Mirrors `fxChainsSnapshot`'s publish-for-cross-thread-reads pattern.
    private func refreshEchoCancellersSnapshot() {
        let owners = voiceContexts.compactMap(\.echoOwner)
        echoCancellersLock.lock()
        echoCancellersSnapshot = owners
        echoCancellersLock.unlock()
    }

    /// Must run on `queue`. Starting point for AEC3's delay estimator (see
    /// `webrtc_aec3_shim.h`): the tap's own ring latency (system audio → reference ring) plus
    /// the default output device's rendering latency (reference → speaker) plus `ctx`'s
    /// capture device's latency (mic → this callback), from HAL `kAudioDevicePropertyLatency`/
    /// `SafetyOffset`/stream latency and buffer size, plus a margin for inter-device scheduling
    /// jitter. AEC3 only needs this in the right ballpark -- it refines the rest on its own.
    private func estimateStreamDelayMs(for ctx: RouteContext) -> Int32 {
        let outputLatencyFrames = defaultOutputDeviceID()
            .map { Self.haLatencyFrames($0, scope: kAudioObjectPropertyScopeOutput) } ?? 0
        let inputLatencyFrames = Self.haLatencyFrames(ctx.captureDeviceID, scope: kAudioObjectPropertyScopeInput)
        let tapRingMs = Double(SystemAudioTap.referenceTargetFillFrames) / 48_000 * 1000
        let outputMs = Double(outputLatencyFrames) / 48_000 * 1000
        let inputMs = Double(inputLatencyFrames) / ctx.sampleRate * 1000
        let schedulingMarginMs = 10.0
        return Int32((tapRingMs + outputMs + inputMs + schedulingMarginMs).rounded())
    }

    private func defaultOutputDeviceID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return status == noErr && deviceID != kAudioObjectUnknown ? deviceID : nil
    }

    /// Sum of HAL round-trip latency contributors for `deviceID` in `scope`: device buffering
    /// latency, safety offset, the first stream's own latency, and the current buffer size --
    /// everything CoreAudio reports between a sample leaving/entering the render callback and
    /// it actually reaching the speaker/mic.
    private static func haLatencyFrames(_ deviceID: AudioObjectID, scope: AudioObjectPropertyScope) -> UInt32 {
        func property(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector,
                      _ propScope: AudioObjectPropertyScope = scope) -> UInt32 {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: propScope,
                                                      mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectHasProperty(objectID, &address) else { return 0 }
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr ? value : 0
        }

        var total = property(deviceID, kAudioDevicePropertyLatency)
            + property(deviceID, kAudioDevicePropertySafetyOffset)
            + property(deviceID, kAudioDevicePropertyBufferFrameSize)

        var streamsAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope,
                                                         mElement: kAudioObjectPropertyElementMain)
        var streamsSize: UInt32 = 0
        if AudioObjectGetPropertyDataSize(deviceID, &streamsAddress, 0, nil, &streamsSize) == noErr,
           streamsSize >= UInt32(MemoryLayout<AudioObjectID>.size) {
            let count = Int(streamsSize) / MemoryLayout<AudioObjectID>.size
            var streamIDs = [AudioObjectID](repeating: 0, count: count)
            var fullSize = streamsSize
            if AudioObjectGetPropertyData(deviceID, &streamsAddress, 0, nil, &fullSize, &streamIDs) == noErr,
               let firstStream = streamIDs.first {
                total += property(firstStream, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal)
            }
        }
        return total
    }

    /// Must run on `queue`. Nil while a model-backed engine's model is still loading: the load
    /// runs in the background (~1.5 s compile after an app or OS update, ~30 ms from cache) and
    /// re-applies the settings when done, so routes start right away and suppression fades in
    /// later. RNNoise needs no model, so it never returns nil once the frame size matches.
    private func makeNoiseKernel(_ engine: NoiseSuppressionEngine) -> (any DenoiseKernel)? {
        switch engine {
        case .rnnoise:
            return RNNoiseKernel.make()
        case .dpdfnet:
            return modelBackedKernel(state: dpdfnetState,
                                      makeKernel: { DPDFNetKernel(model: $0) },
                                      load: { NoiseSuppressionModel.loadBundled() })
        case .fastenhancer:
            return modelBackedKernel(state: fastEnhancerState,
                                      makeKernel: { FastEnhancerKernel(model: $0) },
                                      load: { FastEnhancerModel.loadBundled() })
        }
    }

    /// Must run on `queue`. Returns a kernel from `state`'s model if it's already loaded;
    /// otherwise kicks off a background load (once) and returns nil until it lands.
    private func modelBackedKernel<Model: AnyObject & Sendable>(
        state: NoiseModelLoadState<Model>,
        makeKernel: (Model) -> (any DenoiseKernel)?,
        load: @escaping @Sendable () -> Model?
    ) -> (any DenoiseKernel)? {
        if let model = state.model { return makeKernel(model) }
        guard !state.isLoading, !state.loadFailed else { return nil }
        state.isLoading = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let model = load()
            guard let self else { return }
            self.queue.async {
                state.isLoading = false
                guard let model else {
                    state.loadFailed = true
                    return
                }
                state.model = model
                self.applyNoiseSuppressionToAllRoutes()
            }
        }
        return nil
    }

    // MARK: - Meter timer

    private func startMeterTimer() {
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.updatePublishedMeters()
        }
    }

    /// Runs on the main run loop (the meter timer is scheduled there).
    ///
    /// The decay in `drainLevels` clamps a buffer to exact `0` once it crosses the floor, so
    /// once a tick publishes an all-silent snapshot every later tick reads the same zeros until
    /// real audio returns. `isEverythingSilent` is a read-only pass over the raw buffers (no
    /// allocation); when it agrees with `wasSilentMeters` this tick skips draining, building the
    /// per-route dictionaries, and walking `NSApp.windows` entirely.
    ///
    /// Output levels are tracked per target device (virtual mic, Stream Mix): two routes
    /// feeding different targets never bleed into each other's post-mix meters even though
    /// their channel numbering overlaps (see `MeterLevels.updateOutputs(target:_:)`).
    private func updatePublishedMeters() {
        guard !(wasSilentMeters && isEverythingSilent()) else { return }

        var newSourceLevels: [String: [Int: Float]] = [:]
        var newOutputLevelsByTarget: [String: [Int: Float]] = [:]
        var sawNonZero = false

        for (key, ctx) in activeRoutes {
            newSourceLevels[key.source] = Self.drainLevels(ctx.meterLevelsPtr, count: ctx.inputChannels, sawNonZero: &sawNonZero)
            // Output meter takes post-mix levels (max across every route feeding this target).
            var targetLevels = newOutputLevelsByTarget[ctx.playbackDeviceUID] ?? [:]
            for (ch, level) in Self.drainLevels(ctx.outMeterLevelsPtr, count: ctx.outputChannels, sawNonZero: &sawNonZero) {
                targetLevels[ch] = max(targetLevels[ch] ?? 0.0, level)
            }
            newOutputLevelsByTarget[ctx.playbackDeviceUID] = targetLevels
        }

        // Output routes report the virtual device channels they capture.
        for (uid, ctx) in activeOutputRoutes {
            newSourceLevels["output:\(uid)"] = Self.drainLevels(ctx.meterLevelsPtr, count: ctx.inputChannels, sawNonZero: &sawNonZero)
        }

        // Skip later silent ticks only once these zeros are on screen; a hidden window must still
        // get them when it reappears, or it would keep showing the last levels it saw.
        wasSilentMeters = false

        let sourceLevels = newSourceLevels
        let outputLevelsByTarget = newOutputLevelsByTarget
        let activeTargets = Set(activeRoutes.values.map(\.playbackDeviceUID))
        MainActor.assumeIsolated {
            // Closing the main window only hides it: SwiftUI keeps its view graph alive, and each
            // publish re-renders the cables and meters of a window nobody sees. Publish only while
            // a window that shows meters (main window, menu bar panel) is on screen. The menu bar
            // icon's own window always reports visible, so it doesn't count.
            let showing = NSApp.windows.contains {
                $0.isVisible && $0.occlusionState.contains(.visible) && $0.className != "NSStatusBarWindow"
            }
            guard showing else { return }
            wasSilentMeters = !sawNonZero

            // Routing changes are rare (user-driven), so only pay for the `Set` and the removal
            // scan when the route count actually moved; the common tick (nothing started or
            // stopped) skips it.
            if meters.sourceCount != sourceLevels.count {
                meters.retainSources(Set(sourceLevels.keys))
            }
            for (key, channels) in sourceLevels {
                meters.updateSource(key, channels: channels)
            }
            // Every target's channel set never changes while any route still feeds it — clear
            // only on that target's empty transition so a stale post-mix peak doesn't linger.
            for target in [VirtualDeviceChannels.micUID, VirtualDeviceChannels.streamUID] {
                if activeTargets.contains(target) {
                    meters.updateOutputs(target: target, outputLevelsByTarget[target] ?? [:])
                } else {
                    meters.clearOutputs(target: target)
                }
            }
        }
    }

    /// Snapshot 1-based channel levels, decay the RT-written meter buffer in place, and note
    /// whether any channel was non-zero before decay (feeds `wasSilentMeters` for the next tick).
    private static func drainLevels(
        _ levels: UnsafeMutablePointer<Float>, count: UInt32, sawNonZero: inout Bool
    ) -> [Int: Float] {
        var snapshot: [Int: Float] = [:]
        for i in 0..<Int(count) {
            let level = levels[i]
            if level != 0 { sawNonZero = true }
            snapshot[i + 1] = level
            levels[i] = level < 0.001 / 0.85 ? 0.0 : level * 0.85
        }
        return snapshot
    }

    /// Cheap, read-only check: true only when every RT-written buffer already reads exactly `0`
    /// (the decay in `drainLevels` clamps there, so this needs no epsilon).
    private func isEverythingSilent() -> Bool {
        func allZero(_ levels: UnsafeMutablePointer<Float>, count: UInt32) -> Bool {
            for i in 0..<Int(count) where levels[i] != 0 { return false }
            return true
        }
        for ctx in activeRoutes.values {
            if !allZero(ctx.meterLevelsPtr, count: ctx.inputChannels) { return false }
            if !allZero(ctx.outMeterLevelsPtr, count: ctx.outputChannels) { return false }
        }
        for ctx in activeOutputRoutes.values {
            if !allZero(ctx.meterLevelsPtr, count: ctx.inputChannels) { return false }
        }
        return true
    }

    // MARK: - Internal routing (input -> loopbacker)

    private func startRoutingInternal(sourceDeviceUID: String, targetDeviceUID: String) {
        let routeKey = RouteKey(source: sourceDeviceUID, target: targetDeviceUID)
        // Already routing this source -> target pair
        guard activeRoutes[routeKey] == nil else { return }

        // Find the source device ID
        guard let captureDeviceID = findDeviceByUID(sourceDeviceUID) else {
            logger.error("Source device not found: \(sourceDeviceUID)")
            return
        }

        // Find the target Loopbacker virtual device
        guard let playbackDeviceID = findDeviceByUID(targetDeviceUID) else {
            logger.error("Loopbacker virtual device not found: \(targetDeviceUID)")
            return
        }

        // Capture every source channel so any of them can be patched to any mic channel.
        let inputChannels = routableChannelCount(captureDeviceID, scope: kAudioObjectPropertyScopeInput)
        guard inputChannels > 0 else {
            logger.error("Source device has no input channels")
            return
        }
        let micChannels = routableChannelCount(playbackDeviceID, scope: kAudioObjectPropertyScopeOutput)
        guard micChannels > 0 else {
            logger.error("Loopbacker virtual device reports no output channels: \(targetDeviceUID)")
            return
        }

        // Get sample rate from the target device
        let sampleRate = getDeviceSampleRate(playbackDeviceID)

        let ctx = RouteContext(
            captureDeviceUID: sourceDeviceUID,
            captureDeviceID: captureDeviceID,
            playbackDeviceID: playbackDeviceID,
            playbackDeviceUID: targetDeviceUID,
            inputChannels: inputChannels,
            outputChannels: micChannels,
            sampleRate: sampleRate,
            isVoiceInput: true
        )
        attachFXChain(to: ctx)
        applyNoiseSuppression(to: ctx)
        applyEchoCancellation(to: ctx)
        refreshEchoCancellersSnapshot()

        // Create input AUHAL (captures from source device)
        guard setupInputUnit(ctx) else {
            logger.error("Failed to set up input unit for \(sourceDeviceUID)")
            return
        }

        // Create output AUHAL (sends to the target Loopbacker device)
        guard setupOutputUnit(ctx) else {
            logger.error("Failed to set up output unit")
            teardownUnit(&ctx.inputUnit)
            return
        }

        // Start both units
        if let inputUnit = ctx.inputUnit {
            let status = AudioOutputUnitStart(inputUnit)
            if status != noErr {
                logger.info(" Failed to start input unit: \(status)")
                teardownUnit(&ctx.inputUnit)
                teardownUnit(&ctx.outputUnit)
                return
            }
        }

        if let outputUnit = ctx.outputUnit {
            let status = AudioOutputUnitStart(outputUnit)
            if status != noErr {
                logger.info(" Failed to start output unit: \(status)")
                if let inputUnit = ctx.inputUnit { AudioOutputUnitStop(inputUnit) }
                teardownUnit(&ctx.inputUnit)
                teardownUnit(&ctx.outputUnit)
                return
            }
        }

        // Restore any previously-configured channel mix for this source -> target pair so it
        // survives restarts (wake, sample rate change) without the UI having to reapply it.
        if let pending = pendingMixMatrices[routeKey] {
            applyMixToContext(ctx, routes: pending)
        }

        activeRoutes[routeKey] = ctx

        // Listen for sample rate changes on the capture device only — auto-restart every
        // route on this device when the hardware rate changes (e.g., after sleep). Idempotent:
        // a second route on the same device (e.g. Stream Mix alongside the virtual mic)
        // re-installs the same mapping rather than displacing it.
        // NOTE: Do NOT listen on the playback (Loopbacker) device. Apps like Chrome/Meet
        // can force rate changes on the virtual device, which would cause a restart loop
        // (stop → 0.3s gap → restart → rate changes again) producing crackling and
        // breaking transcription apps (Granola, Fellow) that read from the device.
        // Wake-related rate changes are already handled by restartAllRoutes().
        installSampleRateListener(deviceID: captureDeviceID, sourceDeviceUID: sourceDeviceUID)

        logger.info(" Started routing: \(sourceDeviceUID) -> \(targetDeviceUID)")
    }

    private func stopRoutingInternal(sourceKey: String, targetDeviceUID: String) {
        let routeKey = RouteKey(source: sourceKey, target: targetDeviceUID)
        guard let ctx = activeRoutes.removeValue(forKey: routeKey) else { return }

        // Remove the sample rate listener only once no other route still captures this
        // device (e.g. the virtual mic route may still be running after Stream Mix stops).
        if !activeRoutes.values.contains(where: { $0.captureDeviceID == ctx.captureDeviceID }) {
            removeSampleRateListener(deviceID: ctx.captureDeviceID)
        }

        // Stop callbacks first, then dispose, then release the retained references.
        // Each setupInputUnit/setupOutputUnit call did a passRetained on ctx.
        if let inputUnit = ctx.inputUnit {
            AudioOutputUnitStop(inputUnit)
        }
        if let outputUnit = ctx.outputUnit {
            AudioOutputUnitStop(outputUnit)
        }
        // Only now is it provably safe to detach the voice FX chain: the capture device's IO
        // callbacks that might still be inside `FXChain.process` have been stopped.
        detachFXChain(from: ctx)
        refreshEchoCancellersSnapshot()

        let hadInput = ctx.inputUnit != nil
        let hadOutput = ctx.outputUnit != nil
        teardownUnit(&ctx.inputUnit)
        teardownUnit(&ctx.outputUnit)

        // Balance the passRetained calls made during setup
        if hadInput { Unmanaged.passUnretained(ctx).release() }
        if hadOutput { Unmanaged.passUnretained(ctx).release() }

        logger.info(" Stopped routing: \(sourceKey) -> \(targetDeviceUID)")
    }

    // MARK: - Internal output routing (virtual device -> physical output)

    private func startOutputRoutingInternal(virtualDeviceUID: String, physicalOutputUID: String, monitorChannel: Int) {
        logger.info("startOutputRoutingInternal: \(virtualDeviceUID) -> \(physicalOutputUID) from ch \(monitorChannel)")
        // Stop existing output route for this virtual device first
        stopOutputRoutingInternal(virtualDeviceUID: virtualDeviceUID)

        guard !physicalOutputUID.isEmpty else { return }

        // Find the virtual device (we capture from its input side)
        guard let virtualDeviceID = findDeviceByUID(virtualDeviceUID) else {
            logger.error("Virtual device not found: \(virtualDeviceUID)")
            return
        }

        // Find the physical output device
        guard let physicalOutputID = findDeviceByUID(physicalOutputUID) else {
            logger.error("Physical output device not found: \(physicalOutputUID)")
            return
        }

        let sampleRate = getDeviceSampleRate(virtualDeviceID)
        let deviceChannels = routableChannelCount(virtualDeviceID, scope: kAudioObjectPropertyScopeInput)
        guard deviceChannels > 0 else {
            logger.error("Virtual device reports no input channels: \(virtualDeviceUID)")
            return
        }

        let ctx = RouteContext(
            captureDeviceUID: virtualDeviceUID,
            captureDeviceID: virtualDeviceID,
            playbackDeviceID: physicalOutputID,
            playbackDeviceUID: physicalOutputUID,
            inputChannels: deviceChannels,
            outputChannels: 2,
            sampleRate: sampleRate
        )
        ctx.monitorChannel = monitorChannel
        // Speakers get the selected pair; a pair past the device's width falls back to 1–2.
        if monitorChannel >= 1 && monitorChannel + 1 <= Int(deviceChannels) {
            applyMixToContext(ctx, routes: [(srcCh: monitorChannel, dstCh: 1), (srcCh: monitorChannel + 1, dstCh: 2)])
        }

        // Create input AUHAL (captures from virtual device's input side)
        guard setupInputUnit(ctx) else {
            logger.error("Failed to set up input unit for output routing: \(virtualDeviceUID)")
            return
        }

        // Create output AUHAL (sends to physical output device)
        guard setupOutputUnit(ctx) else {
            logger.error("Failed to set up output unit for output routing")
            teardownUnit(&ctx.inputUnit)
            return
        }

        // Start both units
        if let inputUnit = ctx.inputUnit {
            let status = AudioOutputUnitStart(inputUnit)
            if status != noErr {
                logger.info(" Failed to start output routing input unit: \(status)")
                teardownUnit(&ctx.inputUnit)
                teardownUnit(&ctx.outputUnit)
                return
            }
        }

        if let outputUnit = ctx.outputUnit {
            let status = AudioOutputUnitStart(outputUnit)
            if status != noErr {
                logger.info(" Failed to start output routing output unit: \(status)")
                if let inputUnit = ctx.inputUnit { AudioOutputUnitStop(inputUnit) }
                teardownUnit(&ctx.inputUnit)
                teardownUnit(&ctx.outputUnit)
                return
            }
        }

        activeOutputRoutes[virtualDeviceUID] = ctx
        logger.info(" Started output routing: \(virtualDeviceUID) -> \(physicalOutputUID)")
    }

    private func stopOutputRoutingInternal(virtualDeviceUID: String) {
        guard let ctx = activeOutputRoutes.removeValue(forKey: virtualDeviceUID) else { return }

        if let inputUnit = ctx.inputUnit {
            AudioOutputUnitStop(inputUnit)
        }
        if let outputUnit = ctx.outputUnit {
            AudioOutputUnitStop(outputUnit)
        }
        // Only now is it provably safe to detach the voice FX chain (see stopRoutingInternal).
        detachFXChain(from: ctx)
        refreshEchoCancellersSnapshot()
        let hadInput = ctx.inputUnit != nil
        let hadOutput = ctx.outputUnit != nil
        teardownUnit(&ctx.inputUnit)
        teardownUnit(&ctx.outputUnit)

        // Balance the passRetained calls made during setup
        if hadInput { Unmanaged.passUnretained(ctx).release() }
        if hadOutput { Unmanaged.passUnretained(ctx).release() }

        logger.info(" Stopped output routing: \(virtualDeviceUID)")
    }

    // MARK: - Test tone

    /// Plays a 1kHz sine wave through the Loopbacker virtual device for the given duration.
    func playTestTone(duration: Double = 2.0) {
        queue.async { [weak self] in
            guard self != nil else { return }

            // Use the default system output (speakers) so the user can actually hear it
            var desc = AudioComponentDescription(
                componentType: kAudioUnitType_Output,
                componentSubType: kAudioUnitSubType_DefaultOutput,
                componentManufacturer: kAudioUnitManufacturer_Apple,
                componentFlags: 0,
                componentFlagsMask: 0
            )

            guard let component = AudioComponentFindNext(nil, &desc) else { return }

            var audioUnit: AudioComponentInstance?
            var status = AudioComponentInstanceNew(component, &audioUnit)
            guard status == noErr, let unit = audioUnit else { return }

            let sampleRate: Float64 = 48000.0
            let channelCount: UInt32 = 2

            var streamFormat = AudioStreamBasicDescription(
                mSampleRate: sampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
                mBytesPerPacket: channelCount * 4,
                mFramesPerPacket: 1,
                mBytesPerFrame: channelCount * 4,
                mChannelsPerFrame: channelCount,
                mBitsPerChannel: 32,
                mReserved: 0
            )

            status = AudioUnitSetProperty(unit,
                                          kAudioUnitProperty_StreamFormat,
                                          kAudioUnitScope_Input,
                                          0,
                                          &streamFormat,
                                          UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
            guard status == noErr else {
                AudioComponentInstanceDispose(unit)
                return
            }

            // Allocate tone state on the heap so the C callback can access it safely.
            let toneState = UnsafeMutablePointer<TestToneState>.allocate(capacity: 1)
            toneState.initialize(to: TestToneState(
                phase: 0.0,
                phaseIncrement: Float(2.0 * Double.pi * 1000.0 / sampleRate),
                amplitude: 0.3,
                channelCount: channelCount
            ))

            var callbackStruct = AURenderCallbackStruct(
                inputProc: testToneRenderCallback,
                inputProcRefCon: UnsafeMutableRawPointer(toneState)
            )

            status = AudioUnitSetProperty(unit,
                                          kAudioUnitProperty_SetRenderCallback,
                                          kAudioUnitScope_Input,
                                          0,
                                          &callbackStruct,
                                          UInt32(MemoryLayout<AURenderCallbackStruct>.size))
            guard status == noErr else {
                toneState.deinitialize(count: 1)
                toneState.deallocate()
                AudioComponentInstanceDispose(unit)
                return
            }

            status = AudioUnitInitialize(unit)
            guard status == noErr else {
                toneState.deinitialize(count: 1)
                toneState.deallocate()
                AudioComponentInstanceDispose(unit)
                return
            }

            status = AudioOutputUnitStart(unit)
            guard status == noErr else {
                toneState.deinitialize(count: 1)
                toneState.deallocate()
                AudioUnitUninitialize(unit)
                AudioComponentInstanceDispose(unit)
                return
            }

            logger.info("Test tone started")

            // Stop after duration
            let playback = TestTonePlayback(unit: unit, state: toneState)
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                playback.stop()
                logger.info("Test tone stopped")
            }
        }
    }

    // MARK: - AUHAL setup

    private func setupInputUnit(_ ctx: RouteContext) -> Bool {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &desc) else { return false }

        var audioUnit: AudioComponentInstance?
        var status = AudioComponentInstanceNew(component, &audioUnit)
        guard status == noErr, let unit = audioUnit else { return false }

        // Enable input on the input scope (bus 1)
        var enableIO: UInt32 = 1
        status = AudioUnitSetProperty(unit,
                                      kAudioOutputUnitProperty_EnableIO,
                                      kAudioUnitScope_Input,
                                      1,
                                      &enableIO,
                                      UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else { teardownUnit(&audioUnit); return false }

        // Disable output on the output scope (bus 0) -- we only want to capture
        var disableIO: UInt32 = 0
        status = AudioUnitSetProperty(unit,
                                      kAudioOutputUnitProperty_EnableIO,
                                      kAudioUnitScope_Output,
                                      0,
                                      &disableIO,
                                      UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else { teardownUnit(&audioUnit); return false }

        // Set the input device
        var deviceID = ctx.captureDeviceID
        status = AudioUnitSetProperty(unit,
                                      kAudioOutputUnitProperty_CurrentDevice,
                                      kAudioUnitScope_Global,
                                      0,
                                      &deviceID,
                                      UInt32(MemoryLayout<AudioObjectID>.size))
        guard status == noErr else { teardownUnit(&audioUnit); return false }

        // Set small buffer size for low latency
        var bufferFrames: UInt32 = 256
        AudioUnitSetProperty(unit,
                            kAudioDevicePropertyBufferFrameSize,
                            kAudioUnitScope_Global,
                            0,
                            &bufferFrames,
                            UInt32(MemoryLayout<UInt32>.size))

        // Set format on the output scope of bus 1 (what we read from the input)
        var streamFormat = AudioStreamBasicDescription(
            mSampleRate: ctx.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
            mBytesPerPacket: ctx.inputChannels * 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: ctx.inputChannels * 4,
            mChannelsPerFrame: ctx.inputChannels,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        status = AudioUnitSetProperty(unit,
                                      kAudioUnitProperty_StreamFormat,
                                      kAudioUnitScope_Output,
                                      1,
                                      &streamFormat,
                                      UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard status == noErr else { teardownUnit(&audioUnit); return false }

        // Query actual buffer size back -- the device may not have accepted our request
        var actualBufferFrames: UInt32 = 0
        var bufSizeSize = UInt32(MemoryLayout<UInt32>.size)
        let queryStatus = AudioUnitGetProperty(unit,
                                               kAudioDevicePropertyBufferFrameSize,
                                               kAudioUnitScope_Global,
                                               0,
                                               &actualBufferFrames,
                                               &bufSizeSize)
        if queryStatus == noErr && actualBufferFrames > 0 {
            // Grow the block buffers if the device settled on a larger IO size
            ctx.reserveBlockFrames(actualBufferFrames)
        }

        // Set input callback -- called when audio data is available from the input device.
        // Use passRetained to prevent the RouteContext from being deallocated while
        // callbacks are still active. The matching release happens in teardown.
        let contextPtr = Unmanaged.passRetained(ctx).toOpaque()
        var callbackStruct = AURenderCallbackStruct(
            inputProc: inputRenderCallback,
            inputProcRefCon: contextPtr
        )

        status = AudioUnitSetProperty(unit,
                                      kAudioOutputUnitProperty_SetInputCallback,
                                      kAudioUnitScope_Global,
                                      0,
                                      &callbackStruct,
                                      UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard status == noErr else {
            Unmanaged<AudioRouter.RouteContext>.fromOpaque(contextPtr).release()
            teardownUnit(&audioUnit)
            return false
        }

        status = AudioUnitInitialize(unit)
        guard status == noErr else {
            Unmanaged<AudioRouter.RouteContext>.fromOpaque(contextPtr).release()
            teardownUnit(&audioUnit)
            return false
        }

        ctx.inputUnit = unit
        return true
    }

    private func setupOutputUnit(_ ctx: RouteContext) -> Bool {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &desc) else { return false }

        var audioUnit: AudioComponentInstance?
        var status = AudioComponentInstanceNew(component, &audioUnit)
        guard status == noErr, let unit = audioUnit else { return false }

        // Set the output device
        var deviceID = ctx.playbackDeviceID
        status = AudioUnitSetProperty(unit,
                                      kAudioOutputUnitProperty_CurrentDevice,
                                      kAudioUnitScope_Global,
                                      0,
                                      &deviceID,
                                      UInt32(MemoryLayout<AudioObjectID>.size))
        guard status == noErr else { teardownUnit(&audioUnit); return false }

        // Set small buffer size for low latency
        var bufferFrames: UInt32 = 256
        AudioUnitSetProperty(unit,
                            kAudioDevicePropertyBufferFrameSize,
                            kAudioUnitScope_Global,
                            0,
                            &bufferFrames,
                            UInt32(MemoryLayout<UInt32>.size))

        // Set stream format
        var streamFormat = AudioStreamBasicDescription(
            mSampleRate: ctx.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
            mBytesPerPacket: ctx.outputChannels * 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: ctx.outputChannels * 4,
            mChannelsPerFrame: ctx.outputChannels,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        status = AudioUnitSetProperty(unit,
                                      kAudioUnitProperty_StreamFormat,
                                      kAudioUnitScope_Input,
                                      0,
                                      &streamFormat,
                                      UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard status == noErr else { teardownUnit(&audioUnit); return false }

        // Set render callback -- called when the output device needs audio data.
        // Use passRetained for safe callback lifetime. Release happens in teardown.
        let contextPtr = Unmanaged.passRetained(ctx).toOpaque()
        var callbackStruct = AURenderCallbackStruct(
            inputProc: outputRenderCallback,
            inputProcRefCon: contextPtr
        )

        status = AudioUnitSetProperty(unit,
                                      kAudioUnitProperty_SetRenderCallback,
                                      kAudioUnitScope_Input,
                                      0,
                                      &callbackStruct,
                                      UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard status == noErr else {
            Unmanaged<AudioRouter.RouteContext>.fromOpaque(contextPtr).release()
            teardownUnit(&audioUnit)
            return false
        }

        status = AudioUnitInitialize(unit)
        guard status == noErr else {
            Unmanaged<AudioRouter.RouteContext>.fromOpaque(contextPtr).release()
            teardownUnit(&audioUnit)
            return false
        }

        ctx.outputUnit = unit
        return true
    }

    private func teardownUnit(_ unit: inout AudioComponentInstance?) {
        guard let u = unit else { return }
        AudioUnitUninitialize(u)
        AudioComponentInstanceDispose(u)
        unit = nil
    }

    // MARK: - Device lookup helpers

    func findDeviceByUID(_ uid: String) -> AudioObjectID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &dataSize
        )
        guard status == noErr, dataSize > 0 else { return nil }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &dataSize, &deviceIDs
        )
        guard status == noErr else { return nil }

        for deviceID in deviceIDs {
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var cfUID: Unmanaged<CFString>? = nil
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let s = withUnsafeMutablePointer(to: &cfUID) { ptr in
                AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, ptr)
            }
            guard s == noErr, let cf = cfUID else { continue }
            let deviceUID = cf.takeRetainedValue() as String
            if deviceUID == uid {
                return deviceID
            }
        }
        return nil
    }

    /// Find an output device by its UID
    func findOutputDeviceByUID(_ uid: String) -> AudioObjectID? {
        return findDeviceByUID(uid)
    }

    /// Channels a route captures from or plays to on `deviceID` in `scope`, capped at
    /// `maxRouteChannels` so a huge interface can't blow up the mix matrix.
    private func routableChannelCount(_ deviceID: AudioObjectID, scope: AudioObjectPropertyScope) -> UInt32 {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else { return 0 }

        let rawPtr = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPtr.deallocate() }

        let bufListPtr = rawPtr.bindMemory(to: AudioBufferList.self, capacity: 1)
        status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, bufListPtr)
        guard status == noErr else { return 0 }

        var total: UInt32 = 0
        let buffers = UnsafeMutableAudioBufferListPointer(bufListPtr)
        for buf in buffers {
            total += buf.mNumberChannels
        }
        return min(total, Self.maxRouteChannels)
    }

    // MARK: - Sample rate change listener

    /// Track which devices have a sample rate listener installed, to avoid duplicates
    /// and to remove them on teardown.
    private var sampleRateListeners: [AudioObjectID: String] = [:]  // deviceID -> sourceDeviceUID

    private func installSampleRateListener(deviceID: AudioObjectID, sourceDeviceUID: String) {
        // Already installed for this device (e.g. a second target route on the same capture
        // device, like Stream Mix alongside the virtual mic): nothing to do.
        guard sampleRateListeners[deviceID] == nil else { return }

        sampleRateListeners[deviceID] = sourceDeviceUID

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        // The listener closure captures a weak ref to self to avoid retain cycles.
        // We pass the deviceID as context so the C callback can identify which device changed.
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        AudioObjectAddPropertyListener(deviceID, &address, sampleRateChangeListener, selfPtr)
    }

    private func removeSampleRateListener(deviceID: AudioObjectID) {
        guard sampleRateListeners.removeValue(forKey: deviceID) != nil else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        AudioObjectRemovePropertyListener(deviceID, &address, sampleRateChangeListener, selfPtr)
    }

    /// Called from the C listener callback when any monitored device changes sample rate.
    fileprivate func handleSampleRateChange(deviceID: AudioObjectID) {
        // Find which source UID this device corresponds to
        guard sampleRateListeners[deviceID] != nil else { return }
        let newRate = getDeviceSampleRate(deviceID)
        logger.info("Sample rate changed on device \(deviceID) to \(newRate)Hz — restarting its routes")

        queue.async { [weak self] in
            guard let self else { return }
            // Restart every route (virtual mic, Stream Mix) that captures this device, not
            // just the one whose UID happened to install the listener.
            let pairs = self.activeRoutes.keys
                .filter { self.activeRoutes[$0]?.captureDeviceID == deviceID }
                .map { (source: $0.source, target: $0.target) }
            guard !pairs.isEmpty else { return }
            for pair in pairs {
                self.stopRoutingInternal(sourceKey: pair.source, targetDeviceUID: pair.target)
            }
            // Small delay to let the device settle at the new rate
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                for pair in pairs {
                    self.startRouting(sourceDeviceUID: pair.source, targetDeviceUID: pair.target)
                }
            }
        }
    }

    private func getDeviceSampleRate(_ deviceID: AudioObjectID) -> Float64 {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate: Float64 = 48000.0
        var dataSize = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, &sampleRate)
        if status != noErr {
            return 48000.0
        }
        return sampleRate
    }
}

/// A running test-tone unit and its callback state. Created on the router queue, then handed
/// to the main queue exactly once to stop and free it.
private struct TestTonePlayback: @unchecked Sendable {
    let unit: AudioComponentInstance
    let state: UnsafeMutablePointer<TestToneState>

    func stop() {
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        state.deinitialize(count: 1)
        state.deallocate()
    }
}

// MARK: - Sample rate change listener (C function)

private func sampleRateChangeListener(
    objectID: AudioObjectID,
    numberAddresses: UInt32,
    addresses: UnsafePointer<AudioObjectPropertyAddress>,
    clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData else { return noErr }
    let router = Unmanaged<AudioRouter>.fromOpaque(clientData).takeUnretainedValue()
    router.handleSampleRateChange(deviceID: objectID)
    return noErr
}

// MARK: - Render callbacks (C functions)

/// Called when audio data is captured from the input device.
/// We render from the input unit bus 1 and write to the ring buffer.
private func inputRenderCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let ctx = Unmanaged<AudioRouter.RouteContext>.fromOpaque(inRefCon).takeUnretainedValue()
    guard let inputUnit = ctx.inputUnit else { return noErr }

    // Guard: if inNumberFrames exceeds our pre-allocated block buffers,
    // return silence rather than overflowing.
    if inNumberFrames > ctx.blockFrames {
        return noErr
    }

    // Use pre-allocated buffer (no malloc in real-time thread!)
    let channelCount = ctx.inputChannels
    var bufferList = AudioBufferList(
        mNumberBuffers: 1,
        mBuffers: AudioBuffer(
            mNumberChannels: channelCount,
            mDataByteSize: inNumberFrames * channelCount * 4,
            mData: ctx.renderBuffer
        )
    )

    // Pull audio from the input device
    let status = AudioUnitRender(inputUnit, ioActionFlags, inTimeStamp, 1, inNumberFrames, &bufferList)
    guard status == noErr else { return status }

    // Meter, mix to the playback width, denoise, run effects, meter again, and enqueue.
    let hasSampleTime = inTimeStamp.pointee.mFlags.contains(.sampleTimeValid)
    ctx.processCapturedBlock(frames: inNumberFrames, sampleTime: hasSampleTime ? inTimeStamp.pointee.mSampleTime : nil)

    return noErr
}

/// Called when the output device (Loopbacker) needs audio data.
/// We read from the ring buffer and provide it.
private func outputRenderCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let ctx = Unmanaged<AudioRouter.RouteContext>.fromOpaque(inRefCon).takeUnretainedValue()
    guard let bufferList = ioData else { return noErr }

    let abl = UnsafeMutableAudioBufferListPointer(bufferList)
    guard abl.count > 0, let outputBuffer = abl[0].mData?.assumingMemoryBound(to: Float.self) else {
        return noErr
    }

    // Read from the ring buffer into the output
    ctx.readFromRing(outputBuffer, frames: inNumberFrames)

    return noErr
}

// MARK: - Test tone support

struct TestToneState {
    var phase: Float
    var phaseIncrement: Float
    var amplitude: Float
    var channelCount: UInt32
}

private func testToneRenderCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let state = inRefCon.assumingMemoryBound(to: TestToneState.self)
    guard let bufferList = ioData else { return noErr }

    let abl = UnsafeMutableAudioBufferListPointer(bufferList)
    guard abl.count > 0, let buffer = abl[0].mData?.assumingMemoryBound(to: Float.self) else {
        return noErr
    }

    let chCount = Int(state.pointee.channelCount)
    var phase = state.pointee.phase

    for frame in 0..<Int(inNumberFrames) {
        let sample = sinf(phase) * state.pointee.amplitude
        for ch in 0..<chCount {
            buffer[frame * chCount + ch] = sample
        }
        phase += state.pointee.phaseIncrement
        if phase > Float.pi * 2.0 {
            phase -= Float.pi * 2.0
        }
    }

    state.pointee.phase = phase
    return noErr
}
