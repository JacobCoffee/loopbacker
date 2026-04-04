import Foundation
import AppKit
import CoreAudio
import AudioToolbox
import Combine
import os.log

private let logger = Logger(subsystem: "com.jacobcoffee.loopbacker", category: "AudioRouter")

/// Routes audio from real input devices to the Loopbacker virtual output device,
/// providing real-time meter levels back to the UI.
class AudioRouter: ObservableObject {
    // MARK: - Published state

    /// Per-source meter levels: [sourceDeviceUID: [channelIndex: level]]
    @Published var sourceMeterLevels: [String: [Int: Float]] = [:]

    /// Output channel meter levels: [channelId: level]
    @Published var outputMeterLevels: [Int: Float] = [:]

    /// Current effects preset — applied to new routes and propagated to existing ones
    var currentEffectsPreset = EffectsPreset()

    // MARK: - Internal state

    private var activeRoutes: [String: RouteContext] = [:]
    private var activeOutputRoutes: [String: RouteContext] = [:]
    private let queue = DispatchQueue(label: "com.jacobcoffee.loopbacker.audiorouter", qos: .userInteractive)
    private var meterTimer: Timer?

    /// Holds the CoreAudio resources for a single source -> destination route
    fileprivate class RouteContext {
        var inputUnit: AudioComponentInstance?
        var outputUnit: AudioComponentInstance?
        var captureDeviceUID: String
        var captureDeviceID: AudioObjectID
        var playbackDeviceID: AudioObjectID
        var playbackDeviceUID: String
        var channelCount: UInt32
        var sampleRate: Float64

        // Ring buffer for passing audio from input callback to output callback
        var ringBuffer: UnsafeMutablePointer<Float>?
        var ringBufferFrames: UInt32 = 2048  // ~42ms at 48kHz - low latency
        var writePos: UInt32 = 0
        var readPos: UInt32 = 0

        // Pre-allocated render buffer (avoid malloc in real-time callback)
        var renderBuffer: UnsafeMutablePointer<Float>?
        var renderBufferFrames: UInt32 = 1024

        // Audio effects chain (broadcast voice processing)
        var effectsChain: AudioEffectsChain?

        // Meter levels -- C buffer for thread safety (written from RT thread, read from main)
        var meterLevelsPtr: UnsafeMutablePointer<Float>?
        var meterChannelCount: Int = 0

        init(captureDeviceUID: String, captureDeviceID: AudioObjectID, playbackDeviceID: AudioObjectID,
             playbackDeviceUID: String = "", channelCount: UInt32, sampleRate: Float64) {
            self.captureDeviceUID = captureDeviceUID
            self.captureDeviceID = captureDeviceID
            self.playbackDeviceID = playbackDeviceID
            self.playbackDeviceUID = playbackDeviceUID
            self.channelCount = channelCount
            self.sampleRate = sampleRate
            self.meterChannelCount = Int(channelCount)

            meterLevelsPtr = UnsafeMutablePointer<Float>.allocate(capacity: meterChannelCount)
            meterLevelsPtr?.initialize(repeating: 0.0, count: meterChannelCount)

            let totalSamples = Int(ringBufferFrames * channelCount)
            ringBuffer = UnsafeMutablePointer<Float>.allocate(capacity: totalSamples)
            ringBuffer?.initialize(repeating: 0.0, count: totalSamples)

            // Pre-allocate render buffer for max expected IO size
            let renderSamples = Int(renderBufferFrames * channelCount)
            renderBuffer = UnsafeMutablePointer<Float>.allocate(capacity: renderSamples)
            renderBuffer?.initialize(repeating: 0.0, count: renderSamples)

            // Initialize effects chain for this route
            effectsChain = AudioEffectsChain(sampleRate: Float(sampleRate))
        }

        deinit {
            if let buf = ringBuffer { buf.deallocate() }
            if let buf = renderBuffer { buf.deallocate() }
            if let buf = meterLevelsPtr { buf.deallocate() }
        }

        func writeToRing(_ data: UnsafePointer<Float>, frames: UInt32) {
            guard let ring = ringBuffer else { return }
            let mask = ringBufferFrames - 1
            let chCount = channelCount
            for i in 0..<frames {
                let ringIdx = Int((writePos + i) & mask) * Int(chCount)
                let srcIdx = Int(i) * Int(chCount)
                for ch in 0..<Int(chCount) {
                    ring[ringIdx + ch] = data[srcIdx + ch]
                }
            }
            writePos = writePos &+ frames
        }

        func readFromRing(_ data: UnsafeMutablePointer<Float>, frames: UInt32) -> UInt32 {
            guard let ring = ringBuffer else {
                // No ring buffer -- fill with silence
                let totalSamples = Int(frames * channelCount)
                for j in 0..<totalSamples { data[j] = 0.0 }
                return 0
            }
            let mask = ringBufferFrames - 1
            let chCount = channelCount
            let available = writePos &- readPos
            let toRead = min(frames, available)

            for i in 0..<toRead {
                let ringIdx = Int((readPos + i) & mask) * Int(chCount)
                let dstIdx = Int(i) * Int(chCount)
                for ch in 0..<Int(chCount) {
                    data[dstIdx + ch] = ring[ringIdx + ch]
                }
            }
            readPos = readPos &+ toRead

            // Zero-fill remainder
            if toRead < frames {
                let remaining = Int((frames - toRead) * chCount)
                let offset = Int(toRead * chCount)
                for j in 0..<remaining {
                    data[offset + j] = 0.0
                }
            }
            return toRead
        }

        func computeRMS(from buffer: UnsafePointer<Float>, frames: UInt32) {
            let chCount = Int(channelCount)
            guard chCount > 0 && frames > 0, let levels = meterLevelsPtr else { return }

            for ch in 0..<chCount {
                // Peak detection (more responsive than RMS for meters)
                var peak: Float = 0.0
                for i in 0..<Int(frames) {
                    let s = fabsf(buffer[i * chCount + ch])
                    if s > peak { peak = s }
                }
                // Map dB to 0..1: -60dB=0, 0dB=1
                let db = peak > 0.00001 ? 20.0 * log10f(peak) : -100.0
                let normalized = max(0.0, min(1.0, (db + 60.0) / 60.0))
                // Fast attack, slow release
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
            for uid in keys {
                self.stopRoutingInternal(sourceDeviceUID: uid)
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
            let uids = Array(self.activeRoutes.keys)
            let outputUIDs = Array(self.activeOutputRoutes.keys)
            for uid in uids {
                self.stopRoutingInternal(sourceDeviceUID: uid)
            }
            for uid in outputUIDs {
                self.stopOutputRoutingInternal(virtualDeviceUID: uid)
            }
            // Retry with bounded attempts instead of a fixed 0.5s delay.
            // The audio system may take a variable amount of time to settle after wake.
            self.retryRoutingAfterWake(sourceUIDs: uids, attempt: 0, maxAttempts: 3)
        }
    }

    /// Retry starting routes after wake with bounded attempts at 0.2s intervals.
    private func retryRoutingAfterWake(sourceUIDs: [String], attempt: Int, maxAttempts: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            var failedUIDs: [String] = []
            for uid in sourceUIDs {
                // Check if the device is available before trying to start
                if self.findDeviceByUID(uid) != nil {
                    self.startRouting(sourceDeviceUID: uid)
                } else {
                    failedUIDs.append(uid)
                }
            }
            // Retry remaining UIDs if we haven't exhausted attempts
            if !failedUIDs.isEmpty && attempt + 1 < maxAttempts {
                logger.info("Wake retry \(attempt + 1)/\(maxAttempts): \(failedUIDs.count) device(s) not yet available")
                self.retryRoutingAfterWake(sourceUIDs: failedUIDs, attempt: attempt + 1, maxAttempts: maxAttempts)
            } else if !failedUIDs.isEmpty {
                logger.warning("Wake retry exhausted: \(failedUIDs.count) device(s) still unavailable")
            }
        }
    }

    // MARK: - Public API (input routing)

    /// Start routing audio from the given source device to the Loopbacker virtual device.
    func startRouting(sourceDeviceUID: String) {
        queue.async { [weak self] in
            self?.startRoutingInternal(sourceDeviceUID: sourceDeviceUID)
        }
    }

    /// Stop routing for a specific source device.
    func stopRouting(sourceDeviceUID: String) {
        queue.async { [weak self] in
            self?.stopRoutingInternal(sourceDeviceUID: sourceDeviceUID)
        }
    }

    /// Stop all active routes.
    func stopAll() {
        queue.async { [weak self] in
            guard let self else { return }
            let keys = Array(self.activeRoutes.keys)
            for uid in keys {
                self.stopRoutingInternal(sourceDeviceUID: uid)
            }
            let outputKeys = Array(self.activeOutputRoutes.keys)
            for uid in outputKeys {
                self.stopOutputRoutingInternal(virtualDeviceUID: uid)
            }
        }
    }

    // MARK: - Public API (output routing)

    /// Start routing audio from a Loopbacker virtual device to a physical output device.
    /// Captures from the virtual device's input side (looped-back audio) and plays to a physical output.
    func startOutputRouting(virtualDeviceUID: String, physicalOutputUID: String) {
        logger.info("startOutputRouting called: \(virtualDeviceUID) -> \(physicalOutputUID)")
        queue.async { [weak self] in
            self?.startOutputRoutingInternal(virtualDeviceUID: virtualDeviceUID, physicalOutputUID: physicalOutputUID)
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
            let chCount = UInt32(min(self.getInputChannelCount(captureID), 2))
            guard chCount > 0 else { return }
            let ctx = RouteContext(captureDeviceUID: sourceDeviceUID, captureDeviceID: captureID,
                                  playbackDeviceID: outputID, playbackDeviceUID: outputDeviceUID,
                                  channelCount: chCount, sampleRate: rate)
            ctx.effectsChain?.updatePreset(self.currentEffectsPreset)
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

    // MARK: - Effects

    /// Update the effects preset on all active route contexts.
    func updateEffectsPreset(_ preset: EffectsPreset) {
        queue.async { [weak self] in
            guard let self else { return }
            for (_, ctx) in self.activeRoutes {
                ctx.effectsChain?.updatePreset(preset)
            }
            for (_, ctx) in self.activeOutputRoutes {
                ctx.effectsChain?.updatePreset(preset)
            }
        }
    }

    // MARK: - Meter timer

    private func startMeterTimer() {
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.updatePublishedMeters()
        }
    }

    private func updatePublishedMeters() {
        // Skip publishing when there are no active routes -- avoids allocating
        // fresh dictionaries at 30 Hz for nothing.
        if activeRoutes.isEmpty && activeOutputRoutes.isEmpty {
            // Only clear if we previously had levels (avoid redundant publishes)
            if !sourceMeterLevels.isEmpty || !outputMeterLevels.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    self?.sourceMeterLevels = [:]
                    self?.outputMeterLevels = [:]
                }
            }
            return
        }

        var newSourceLevels: [String: [Int: Float]] = [:]
        var newOutputLevels: [Int: Float] = [:]

        for (uid, ctx) in activeRoutes {
            guard let levels = ctx.meterLevelsPtr else { continue }
            var channelLevels: [Int: Float] = [:]
            for i in 0..<ctx.meterChannelCount {
                let level = levels[i]
                channelLevels[i + 1] = level
                let existingOutput = newOutputLevels[i + 1] ?? 0.0
                newOutputLevels[i + 1] = max(existingOutput, level)
                // Decay
                levels[i] = level * 0.85
                if levels[i] < 0.001 { levels[i] = 0.0 }
            }
            newSourceLevels[uid] = channelLevels
        }

        // Include output route meters
        for (uid, ctx) in activeOutputRoutes {
            guard let levels = ctx.meterLevelsPtr else { continue }
            var channelLevels: [Int: Float] = [:]
            for i in 0..<ctx.meterChannelCount {
                let level = levels[i]
                channelLevels[i + 1] = level
                // Decay
                levels[i] = level * 0.85
                if levels[i] < 0.001 { levels[i] = 0.0 }
            }
            newSourceLevels["output:\(uid)"] = channelLevels
        }

        DispatchQueue.main.async { [weak self] in
            self?.sourceMeterLevels = newSourceLevels
            self?.outputMeterLevels = newOutputLevels
        }
    }

    // MARK: - Internal routing (input -> loopbacker)

    private func startRoutingInternal(sourceDeviceUID: String) {
        // Already routing this source
        guard activeRoutes[sourceDeviceUID] == nil else { return }

        // Find the source device ID
        guard let captureDeviceID = findDeviceByUID(sourceDeviceUID) else {
            logger.error("Source device not found: \(sourceDeviceUID)")
            return
        }

        // Find the Loopbacker virtual device
        guard let playbackDeviceID = findDeviceByUID("LoopbackerDevice_UID") else {
            logger.error("Loopbacker virtual device not found")
            return
        }

        // Get channel count from source device
        let channelCount = getInputChannelCount(captureDeviceID)
        guard channelCount > 0 else {
            logger.error("Source device has no input channels")
            return
        }

        // Get sample rate from the Loopbacker device
        let sampleRate = getDeviceSampleRate(playbackDeviceID)

        let ctx = RouteContext(
            captureDeviceUID: sourceDeviceUID,
            captureDeviceID: captureDeviceID,
            playbackDeviceID: playbackDeviceID,
            playbackDeviceUID: "LoopbackerDevice_UID",
            channelCount: UInt32(min(channelCount, 2)), // Clamp to stereo
            sampleRate: sampleRate
        )
        ctx.effectsChain?.updatePreset(currentEffectsPreset)

        // Create input AUHAL (captures from source device)
        guard setupInputUnit(ctx) else {
            logger.error("Failed to set up input unit for \(sourceDeviceUID)")
            return
        }

        // Create output AUHAL (sends to Loopbacker device)
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

        activeRoutes[sourceDeviceUID] = ctx
        logger.info(" Started routing: \(sourceDeviceUID)")
    }

    private func stopRoutingInternal(sourceDeviceUID: String) {
        guard let ctx = activeRoutes.removeValue(forKey: sourceDeviceUID) else { return }

        // Stop callbacks first, then dispose, then release the retained references.
        // Each setupInputUnit/setupOutputUnit call did a passRetained on ctx.
        if let inputUnit = ctx.inputUnit {
            AudioOutputUnitStop(inputUnit)
        }
        if let outputUnit = ctx.outputUnit {
            AudioOutputUnitStop(outputUnit)
        }
        let hadInput = ctx.inputUnit != nil
        let hadOutput = ctx.outputUnit != nil
        teardownUnit(&ctx.inputUnit)
        teardownUnit(&ctx.outputUnit)

        // Balance the passRetained calls made during setup
        if hadInput { Unmanaged.passUnretained(ctx).release() }
        if hadOutput { Unmanaged.passUnretained(ctx).release() }

        logger.info(" Stopped routing: \(sourceDeviceUID)")
    }

    // MARK: - Internal output routing (virtual device -> physical output)

    private func startOutputRoutingInternal(virtualDeviceUID: String, physicalOutputUID: String) {
        logger.info("startOutputRoutingInternal: \(virtualDeviceUID) -> \(physicalOutputUID)")
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
        let channelCount: UInt32 = 2 // Stereo

        let ctx = RouteContext(
            captureDeviceUID: virtualDeviceUID,
            captureDeviceID: virtualDeviceID,
            playbackDeviceID: physicalOutputID,
            playbackDeviceUID: physicalOutputUID,
            channelCount: channelCount,
            sampleRate: sampleRate
        )
        ctx.effectsChain?.updatePreset(currentEffectsPreset)

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
            guard let self else { return }

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
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                AudioOutputUnitStop(unit)
                AudioUnitUninitialize(unit)
                AudioComponentInstanceDispose(unit)
                toneState.deinitialize(count: 1)
                toneState.deallocate()
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
            mBytesPerPacket: ctx.channelCount * 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: ctx.channelCount * 4,
            mChannelsPerFrame: ctx.channelCount,
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
            // Resize render buffer to match actual IO size if needed
            let needed = actualBufferFrames * ctx.channelCount
            if actualBufferFrames > ctx.renderBufferFrames {
                ctx.renderBuffer?.deallocate()
                ctx.renderBufferFrames = actualBufferFrames
                ctx.renderBuffer = UnsafeMutablePointer<Float>.allocate(capacity: Int(needed))
                ctx.renderBuffer?.initialize(repeating: 0.0, count: Int(needed))
            }
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
            mBytesPerPacket: ctx.channelCount * 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: ctx.channelCount * 4,
            mChannelsPerFrame: ctx.channelCount,
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

    private func getInputChannelCount(_ deviceID: AudioObjectID) -> Int {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
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
        return Int(total)
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
    guard let inputUnit = ctx.inputUnit, let renderBuf = ctx.renderBuffer else { return noErr }

    // Guard: if inNumberFrames exceeds our pre-allocated render buffer,
    // return silence rather than overflowing.
    if inNumberFrames > ctx.renderBufferFrames {
        return noErr
    }

    // Use pre-allocated buffer (no malloc in real-time thread!)
    let channelCount = ctx.channelCount
    let bytesPerFrame = channelCount * 4
    let bufferSize = inNumberFrames * bytesPerFrame

    var bufferList = AudioBufferList(
        mNumberBuffers: 1,
        mBuffers: AudioBuffer(
            mNumberChannels: channelCount,
            mDataByteSize: bufferSize,
            mData: renderBuf
        )
    )

    // Pull audio from the input device
    let status = AudioUnitRender(inputUnit, ioActionFlags, inTimeStamp, 1, inNumberFrames, &bufferList)
    guard status == noErr else { return status }

    // Apply effects chain (Gate → EQ → Compressor → De-Esser → Limiter)
    ctx.effectsChain?.process(renderBuf, frames: inNumberFrames, channels: channelCount)

    // Compute meter levels (post-effects)
    ctx.computeRMS(from: renderBuf, frames: inNumberFrames)

    // Write captured audio into the ring buffer
    ctx.writeToRing(renderBuf, frames: inNumberFrames)

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
    _ = ctx.readFromRing(outputBuffer, frames: inNumberFrames)

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
