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

    // MARK: - Internal state

    private var activeRoutes: [String: RouteContext] = [:]
    private let queue = DispatchQueue(label: "com.jacobcoffee.loopbacker.audiorouter", qos: .userInteractive)
    private var meterTimer: Timer?

    /// Holds the CoreAudio resources for a single source -> Loopbacker route
    fileprivate class RouteContext {
        var inputUnit: AudioComponentInstance?
        var outputUnit: AudioComponentInstance?
        var sourceDeviceUID: String
        var sourceDeviceID: AudioObjectID
        var loopbackerDeviceID: AudioObjectID
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

        // Meter levels -- C buffer for thread safety (written from RT thread, read from main)
        var meterLevelsPtr: UnsafeMutablePointer<Float>?
        var meterChannelCount: Int = 0

        init(sourceDeviceUID: String, sourceDeviceID: AudioObjectID, loopbackerDeviceID: AudioObjectID,
             channelCount: UInt32, sampleRate: Float64) {
            self.sourceDeviceUID = sourceDeviceUID
            self.sourceDeviceID = sourceDeviceID
            self.loopbackerDeviceID = loopbackerDeviceID
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
        }

        deinit {
            if let buf = ringBuffer { buf.deallocate() }
            if let buf = renderBuffer { buf.deallocate() }
            if let buf = meterLevelsPtr { buf.deallocate() }
        }

        func writeToRing(_ data: UnsafePointer<Float>, frames: UInt32) {
            let mask = ringBufferFrames - 1
            let chCount = channelCount
            for i in 0..<frames {
                let ringIdx = Int((writePos + i) & mask) * Int(chCount)
                let srcIdx = Int(i) * Int(chCount)
                for ch in 0..<Int(chCount) {
                    ringBuffer?[ringIdx + ch] = data[srcIdx + ch]
                }
            }
            writePos = writePos &+ frames
        }

        func readFromRing(_ data: UnsafeMutablePointer<Float>, frames: UInt32) -> UInt32 {
            let mask = ringBufferFrames - 1
            let chCount = channelCount
            let available = writePos &- readPos
            let toRead = min(frames, available)

            for i in 0..<toRead {
                let ringIdx = Int((readPos + i) & mask) * Int(chCount)
                let dstIdx = Int(i) * Int(chCount)
                for ch in 0..<Int(chCount) {
                    data[dstIdx + ch] = ringBuffer?[ringIdx + ch] ?? 0.0
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
                var sumSquares: Float = 0.0
                for i in 0..<Int(frames) {
                    let sample = buffer[i * chCount + ch]
                    sumSquares += sample * sample
                }
                let rms = sqrtf(sumSquares / Float(frames))
                let smoothing: Float = 0.3
                let prev = levels[ch]
                levels[ch] = min(max(rms, prev * (1.0 - smoothing)), 1.0)
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
        stopAll()
    }

    /// Tear down and re-create all active routes (after sleep/screen lock kills audio units)
    func restartAllRoutes() {
        queue.async { [weak self] in
            guard let self else { return }
            let uids = Array(self.activeRoutes.keys)
            for uid in uids {
                self.stopRoutingInternal(sourceDeviceUID: uid)
            }
            // Brief pause for audio system to settle
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                for uid in uids {
                    self.startRouting(sourceDeviceUID: uid)
                }
            }
        }
    }

    // MARK: - Public API

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

        DispatchQueue.main.async { [weak self] in
            self?.sourceMeterLevels = newSourceLevels
            self?.outputMeterLevels = newOutputLevels
        }
    }

    // MARK: - Internal routing

    private func startRoutingInternal(sourceDeviceUID: String) {
        // Already routing this source
        guard activeRoutes[sourceDeviceUID] == nil else { return }

        // Find the source device ID
        guard let sourceDeviceID = findDeviceByUID(sourceDeviceUID) else {
            logger.error("Source device not found: \(sourceDeviceUID)")
            return
        }

        // Find the Loopbacker virtual device
        guard let loopbackerDeviceID = findDeviceByUID("LoopbackerDevice_UID") else {
            logger.error("Loopbacker virtual device not found")
            return
        }

        // Get channel count from source device
        let channelCount = getInputChannelCount(sourceDeviceID)
        guard channelCount > 0 else {
            logger.error("Source device has no input channels")
            return
        }

        // Get sample rate from the Loopbacker device
        let sampleRate = getDeviceSampleRate(loopbackerDeviceID)

        let ctx = RouteContext(
            sourceDeviceUID: sourceDeviceUID,
            sourceDeviceID: sourceDeviceID,
            loopbackerDeviceID: loopbackerDeviceID,
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
        var deviceID = ctx.sourceDeviceID
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

        // Set the output device to Loopbacker
        var deviceID = ctx.loopbackerDeviceID
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

    private func findDeviceByUID(_ uid: String) -> AudioObjectID? {
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

    // Compute meter levels
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
