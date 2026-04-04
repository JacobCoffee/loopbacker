import Foundation
import AppKit
import CoreAudio
import AudioToolbox
import Accelerate
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
        var ringBufferFrames: UInt32 = 512  // ~10.7ms at 48kHz - low latency
        var writePos: UnsafeMutablePointer<UInt32>  // atomic-friendly aligned pointer
        var readPos: UnsafeMutablePointer<UInt32>   // atomic-friendly aligned pointer

        // Fill-target mechanism to bound latency
        var targetFillFrames: UInt32 = 128  // ~2.7ms at 48kHz
        var hysteresisFrames: UInt32 = 32   // skip threshold above target

        // Pre-allocated render buffer (avoid malloc in real-time callback)
        var renderBuffer: UnsafeMutablePointer<Float>?
        var renderBufferFrames: UInt32 = 512

        // Actual IO buffer size after negotiation with the audio system
        var actualIOBufferFrames: UInt32 = 256

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

            // Allocate atomic-friendly aligned positions
            writePos = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)
            writePos.initialize(to: 0)
            readPos = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)
            readPos.initialize(to: 0)

            meterLevelsPtr = UnsafeMutablePointer<Float>.allocate(capacity: meterChannelCount)
            meterLevelsPtr?.initialize(repeating: 0.0, count: meterChannelCount)

            let totalSamples = Int(ringBufferFrames * channelCount)
            ringBuffer = UnsafeMutablePointer<Float>.allocate(capacity: totalSamples)
            ringBuffer?.initialize(repeating: 0.0, count: totalSamples)

            // Pre-allocate render buffer for max expected IO size
            let renderSamples = Int(renderBufferFrames * channelCount)
            renderBuffer = UnsafeMutablePointer<Float>.allocate(capacity: renderSamples)
            renderBuffer?.initialize(repeating: 0.0, count: renderSamples)
        }

        deinit {
            if let buf = ringBuffer { buf.deallocate() }
            if let buf = renderBuffer { buf.deallocate() }
            if let buf = meterLevelsPtr { buf.deallocate() }
            writePos.deallocate()
            readPos.deallocate()
        }

        func writeToRing(_ data: UnsafePointer<Float>, frames: UInt32) {
            guard let ring = ringBuffer else { return }
            let mask = ringBufferFrames - 1
            let chCount = channelCount
            let samplesPerFrame = Int(chCount)
            let wr = writePos.pointee
            let rd = readPos.pointee

            // If buffer is full, advance readPos to drop oldest frames
            let used = wr &- rd
            if used >= ringBufferFrames {
                // Drop oldest: advance read to make room
                let newRead = wr &- (ringBufferFrames / 2)
                readPos.pointee = newRead
            }

            // Bulk copy using memcpy with wrap-around handling
            let startIdx = Int(wr & mask)
            let firstChunk = min(Int(frames), Int(ringBufferFrames) - startIdx)
            let secondChunk = Int(frames) - firstChunk

            ring.advanced(by: startIdx * samplesPerFrame)
                .update(from: data, count: firstChunk * samplesPerFrame)
            if secondChunk > 0 {
                ring.update(from: data.advanced(by: firstChunk * samplesPerFrame),
                           count: secondChunk * samplesPerFrame)
            }

            writePos.pointee = wr &+ frames
        }

        func readFromRing(_ data: UnsafeMutablePointer<Float>, frames: UInt32) -> UInt32 {
            guard let ring = ringBuffer else { return 0 }
            let mask = ringBufferFrames - 1
            let chCount = channelCount
            let samplesPerFrame = Int(chCount)
            let wr = writePos.pointee
            var rd = readPos.pointee
            let available = wr &- rd

            // Fill-target: if we have too much data buffered, skip ahead
            if available > targetFillFrames + hysteresisFrames {
                let skip = available - targetFillFrames
                rd = rd &+ skip
                readPos.pointee = rd
            }

            let actualAvailable = wr &- rd
            let toRead = min(frames, actualAvailable)

            if toRead > 0 {
                // Bulk copy with wrap-around handling
                let startIdx = Int(rd & mask)
                let firstChunk = min(Int(toRead), Int(ringBufferFrames) - startIdx)
                let secondChunk = Int(toRead) - firstChunk

                data.update(from: ring.advanced(by: startIdx * samplesPerFrame),
                           count: firstChunk * samplesPerFrame)
                if secondChunk > 0 {
                    data.advanced(by: firstChunk * samplesPerFrame)
                        .update(from: ring, count: secondChunk * samplesPerFrame)
                }
            }

            readPos.pointee = rd &+ toRead

            // Zero-fill remainder using memset
            if toRead < frames {
                let offset = Int(toRead) * samplesPerFrame
                let remaining = Int(frames - toRead) * samplesPerFrame
                data.advanced(by: offset).update(repeating: 0.0, count: remaining)
            }
            return toRead
        }

        func computeRMS(from buffer: UnsafePointer<Float>, frames: UInt32) {
            let chCount = Int(channelCount)
            guard chCount > 0 && frames > 0, let levels = meterLevelsPtr else { return }
            let frameCount = Int(frames)

            for ch in 0..<chCount {
                // Use vDSP for efficient mean-square calculation on strided data
                var meanSquare: Float = 0.0
                vDSP_measqv(buffer.advanced(by: ch),
                           vDSP_Stride(chCount),
                           &meanSquare,
                           vDSP_Length(frameCount))
                let rms = sqrtf(meanSquare)
                let smoothing: Float = 0.3
                let prev = levels[ch]
                levels[ch] = min(max(rms, prev * (1.0 - smoothing)), 1.0)
            }
        }

        /// Resize render buffer to match actual IO buffer size
        func resizeRenderBuffer(frames: UInt32) {
            guard frames != renderBufferFrames else { return }
            if let buf = renderBuffer { buf.deallocate() }
            renderBufferFrames = frames
            let renderSamples = Int(frames * channelCount)
            renderBuffer = UnsafeMutablePointer<Float>.allocate(capacity: renderSamples)
            renderBuffer?.initialize(repeating: 0.0, count: renderSamples)
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
        stopAll()
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
            // Brief pause for audio system to settle
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                for uid in uids {
                    self.startRouting(sourceDeviceUID: uid)
                }
                // Output routes need to be restarted by the caller (RoutingState)
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

    /// Stop output routing for a specific virtual device.
    func stopOutputRouting(virtualDeviceUID: String) {
        queue.async { [weak self] in
            self?.stopOutputRoutingInternal(virtualDeviceUID: virtualDeviceUID)
        }
    }

    // MARK: - Meter timer

    private func startMeterTimer() {
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.updatePublishedMeters()
        }
    }

    private func updatePublishedMeters() {
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

        // Get sample rate from BOTH devices and match them (Fix 6)
        let captureRate = getDeviceSampleRate(captureDeviceID)
        let playbackRate = getDeviceSampleRate(playbackDeviceID)

        let sampleRate: Float64
        if captureRate != playbackRate {
            logger.warning("Sample rate mismatch: capture=\(captureRate) playback=\(playbackRate), setting virtual device to match source")
            // Set the virtual device to match the source device's rate
            if setDeviceSampleRate(playbackDeviceID, sampleRate: captureRate) {
                sampleRate = captureRate
            } else {
                logger.warning("Failed to set virtual device sample rate to \(captureRate), using playback rate \(playbackRate)")
                sampleRate = playbackRate
            }
        } else {
            sampleRate = captureRate
        }

        let ctx = RouteContext(
            captureDeviceUID: sourceDeviceUID,
            captureDeviceID: captureDeviceID,
            playbackDeviceID: playbackDeviceID,
            playbackDeviceUID: "LoopbackerDevice_UID",
            channelCount: UInt32(min(channelCount, 2)), // Clamp to stereo
            sampleRate: sampleRate
        )

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

        if let inputUnit = ctx.inputUnit {
            AudioOutputUnitStop(inputUnit)
        }
        if let outputUnit = ctx.outputUnit {
            AudioOutputUnitStop(outputUnit)
        }
        teardownUnit(&ctx.inputUnit)
        teardownUnit(&ctx.outputUnit)

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

        // Get sample rate from BOTH devices and match them (Fix 6)
        let virtualRate = getDeviceSampleRate(virtualDeviceID)
        let physicalRate = getDeviceSampleRate(physicalOutputID)

        let sampleRate: Float64
        if virtualRate != physicalRate {
            logger.warning("Output routing sample rate mismatch: virtual=\(virtualRate) physical=\(physicalRate), using virtual device rate")
            sampleRate = virtualRate
        } else {
            sampleRate = virtualRate
        }
        let channelCount: UInt32 = 2 // Stereo

        let ctx = RouteContext(
            captureDeviceUID: virtualDeviceUID,
            captureDeviceID: virtualDeviceID,
            playbackDeviceID: physicalOutputID,
            playbackDeviceUID: physicalOutputUID,
            channelCount: channelCount,
            sampleRate: sampleRate
        )

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
        teardownUnit(&ctx.inputUnit)
        teardownUnit(&ctx.outputUnit)

        logger.info(" Stopped output routing: \(virtualDeviceUID)")
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

        // Query the actual buffer size that took effect (Fix 3)
        var actualBufferFrames: UInt32 = 256
        var bufSize = UInt32(MemoryLayout<UInt32>.size)
        let queryStatus = AudioUnitGetProperty(unit,
                                               kAudioDevicePropertyBufferFrameSize,
                                               kAudioUnitScope_Global,
                                               0,
                                               &actualBufferFrames,
                                               &bufSize)
        if queryStatus == noErr {
            logger.info("Input unit actual buffer size: \(actualBufferFrames) frames")
            ctx.actualIOBufferFrames = actualBufferFrames
            ctx.resizeRenderBuffer(frames: actualBufferFrames)
        } else {
            logger.warning("Could not query actual input buffer size, using default 256")
        }

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

        // Set input callback -- called when audio data is available from the input device
        let contextPtr = Unmanaged.passUnretained(ctx).toOpaque()
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
        guard status == noErr else { teardownUnit(&audioUnit); return false }

        status = AudioUnitInitialize(unit)
        guard status == noErr else { teardownUnit(&audioUnit); return false }

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

        // Query the actual buffer size that took effect (Fix 3)
        var actualBufferFrames: UInt32 = 256
        var bufSize = UInt32(MemoryLayout<UInt32>.size)
        let queryStatus = AudioUnitGetProperty(unit,
                                               kAudioDevicePropertyBufferFrameSize,
                                               kAudioUnitScope_Global,
                                               0,
                                               &actualBufferFrames,
                                               &bufSize)
        if queryStatus == noErr {
            logger.info("Output unit actual buffer size: \(actualBufferFrames) frames")
            // Use the larger of input/output actual sizes for render buffer
            if actualBufferFrames > ctx.actualIOBufferFrames {
                ctx.actualIOBufferFrames = actualBufferFrames
                ctx.resizeRenderBuffer(frames: actualBufferFrames)
            }
        } else {
            logger.warning("Could not query actual output buffer size, using default 256")
        }

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

        // Set render callback -- called when the output device needs audio data
        let contextPtr = Unmanaged.passUnretained(ctx).toOpaque()
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
        guard status == noErr else { teardownUnit(&audioUnit); return false }

        status = AudioUnitInitialize(unit)
        guard status == noErr else { teardownUnit(&audioUnit); return false }

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

    /// Set a device's nominal sample rate (Fix 6)
    private func setDeviceSampleRate(_ deviceID: AudioObjectID, sampleRate: Float64) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate = sampleRate
        let status = AudioObjectSetPropertyData(deviceID, &propertyAddress, 0, nil,
                                                UInt32(MemoryLayout<Float64>.size), &rate)
        if status != noErr {
            logger.error("Failed to set sample rate \(sampleRate) on device \(deviceID): \(status)")
            return false
        }
        return true
    }
}

// MARK: - Render callbacks (C functions)

/// Called when audio data is captured from the input device.
/// We render from the input unit bus 1 and write to the ring buffer.
/// NOTE: This is a real-time audio callback. Avoid allocations, locks, ObjC dispatch.
private func inputRenderCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    // The RouteContext is kept alive by activeRoutes dictionary on the AudioRouter.
    let ctx = Unmanaged<AudioRouter.RouteContext>.fromOpaque(inRefCon).takeUnretainedValue()

    let inputUnit = ctx.inputUnit
    let renderBuf = ctx.renderBuffer
    guard let unit = inputUnit, let buf = renderBuf else { return noErr }

    // Cache channel count for this callback invocation
    let channelCount = ctx.channelCount
    let bytesPerFrame = channelCount * 4
    let bufferSize = inNumberFrames * bytesPerFrame

    var bufferList = AudioBufferList(
        mNumberBuffers: 1,
        mBuffers: AudioBuffer(
            mNumberChannels: channelCount,
            mDataByteSize: bufferSize,
            mData: buf
        )
    )

    // Pull audio from the input device
    let status = AudioUnitRender(unit, ioActionFlags, inTimeStamp, 1, inNumberFrames, &bufferList)
    guard status == noErr else { return status }

    // Compute meter levels (uses vDSP)
    ctx.computeRMS(from: buf, frames: inNumberFrames)

    // Write captured audio into the ring buffer (uses bulk memcpy)
    ctx.writeToRing(buf, frames: inNumberFrames)

    return noErr
}

/// Called when the output device (Loopbacker) needs audio data.
/// We read from the ring buffer and provide it.
/// NOTE: This is a real-time audio callback. Avoid allocations, locks, ObjC dispatch.
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

    // Read from the ring buffer into the output (uses bulk memcpy + fill-target)
    _ = ctx.readFromRing(outputBuffer, frames: inNumberFrames)

    return noErr
}
