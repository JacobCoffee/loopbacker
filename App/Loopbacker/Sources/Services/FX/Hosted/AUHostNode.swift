import Accelerate
import AppKit
@preconcurrency import AudioToolbox
@preconcurrency import AVFoundation
@preconcurrency import CoreAudioKit
import Synchronization
import os.log

let auLogger = Logger(subsystem: "com.jacobcoffee.loopbacker", category: "AUHostNode")

enum AUHostError: Error {
    case componentNotFound(String)
    case unsupportedFormat(String)
    case malformedIdentifier(String)
}

/// Hosts one Audio Unit (v2 in-process, or v3 out-of-process) as a voice-chain stage.
///
/// Thread contract:
/// - `process`/`reset` run on the chain's IO thread. They only call the render block and the
///   schedule-parameter block captured at `load` time (plain Swift closures, no Objective-C
///   message sends) and touch buffers preallocated in `init`. They never message `au` itself:
///   `reset()` therefore cannot forward to `AUAudioUnit.reset()` (an Objective-C method) and
///   only clears this node's own counters — the plugin's internal history (e.g. a delay tail)
///   persists across a reset, which is what most hosts do for a transport stop/start anyway.
/// - `captureState()`/`makeEditor()` are `@MainActor` and freely message `au`.
/// - The parameter-tree observer added in `load` may fire on any thread (the plugin's own UI,
///   automation, MIDI); it only calls `FXParamStore.set`, which is safe from any thread.
final class AUHostNode: FXHostedNode, @unchecked Sendable {
    let kind: FXNodeKind = .audioUnit
    let ref: FXPluginRef
    let specs: [FXParamSpec]
    let params: FXParamStore
    let meters = FXMeters()
    let latencySamples: Int

    private let au: AUAudioUnit
    private let renderBlock: AURenderBlock
    private let scheduleParameterBlock: AUScheduleParameterBlock?
    /// 1 or 2: the channel count negotiated with the plugin's input/output busses.
    private let busChannels: Int

    /// The render destination, reused for every block; never reallocated after `init`.
    private let outputList: UnsafeMutableAudioBufferListPointer
    private let outputStorage: UnsafeMutablePointer<Float>
    /// Scratch for summing a stereo source down to the mono a mono-only plugin expects.
    private let monoScratch: UnsafeMutablePointer<Float>

    private var observerToken: AUParameterObserverToken?
    /// Bit pattern last pushed to (or observed equal from) the plugin, indexed like `specs`.
    /// Lets the parameter-tree observer, which fires for both the host's own writes and the
    /// plugin's own UI, tell its own echo from a genuine UI-made change, with no lock.
    private let lastKnown: UnsafeMutablePointer<Atomic<UInt32>>
    private var lastGeneration: UInt32 = 0
    private let errorCount = Atomic<UInt64>(0)

    // Per-call input, set at the top of `process` and read back by `pullInput` while
    // `renderBlock` runs synchronously inside it. IO thread only.
    private var currentLeft: UnsafeMutablePointer<Float>!
    private var currentRight: UnsafeMutablePointer<Float>!
    private var currentFrames = 0
    private var currentChannels = 1
    private var sampleTime: Float64 = 0

    /// One heap-allocated closure, created lazily on first touch (forced in `load`, off the IO
    /// thread) and reused for every `process` call so the IO thread never allocates one.
    private lazy var pullInput: AURenderPullInputBlock = { [unowned self] _, _, frameCount, _, data in
        self.fillInput(frameCount: Int(frameCount), into: data)
        return noErr
    }

    /// Render calls since load that returned a non-zero `OSStatus`; the block passed through
    /// untouched for each. Not part of `FXNode`; exposed for a UI badge.
    var renderErrorCount: UInt64 { errorCount.load(ordering: .relaxed) }

    static func load(ref: FXPluginRef, state: Data?, sampleRate: Double) async throws -> AUHostNode {
        let (type, subType, manufacturer) = try AUFourCC.parse(ref.identifier)
        var query = AudioComponentDescription(
            componentType: type, componentSubType: subType, componentManufacturer: manufacturer,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &query) else {
            throw AUHostError.componentNotFound(ref.identifier)
        }
        var description = AudioComponentDescription()
        AudioComponentGetDescription(component, &description)
        let isV3 = AudioComponentFlags(rawValue: description.componentFlags).contains(.isV3AudioUnit)
        // v2 components load in-process (the user accepted that risk when installing one);
        // v3 app extensions load out-of-process, the system default for them.
        let au = try await AUAudioUnit.instantiate(with: description, options: isV3 ? [] : [.loadInProcess])

        guard au.inputBusses.count > 0, au.outputBusses.count > 0 else {
            throw AUHostError.unsupportedFormat(ref.identifier)
        }
        func configure(_ channels: AVAudioChannelCount) -> Bool {
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels) else { return false }
            return (try? au.inputBusses[0].setFormat(format)) != nil && (try? au.outputBusses[0].setFormat(format)) != nil
        }
        let busChannels: Int
        if configure(2) {
            busChannels = 2
        } else if configure(1) {
            busChannels = 1
        } else {
            throw AUHostError.unsupportedFormat(ref.identifier)
        }
        // Hosts must explicitly enable input busses, or the render block pulls nothing and
        // fails with kAudioUnitErr_NoConnection.
        au.inputBusses[0].isEnabled = true

        // Restore before reading the parameter tree, so specs' `defaultValue` (used to seed
        // `FXParamStore`) reflects the restored values rather than the plugin's own defaults.
        if let state, let plist = try? PropertyListSerialization.propertyList(from: state, options: [], format: nil) as? [String: Any] {
            au.fullState = plist
        }

        au.maximumFramesToRender = AUAudioFrameCount(FXBlock.maxFrames)
        try au.allocateRenderResources()

        let (specs, addressIndex) = buildSpecs(from: au.parameterTree)
        let params = FXParamStore(specs: specs)
        let latencySamples = Int((au.latency * sampleRate).rounded())

        let node = AUHostNode(
            ref: ref, au: au, renderBlock: au.renderBlock, scheduleParameterBlock: au.scheduleParameterBlock,
            busChannels: busChannels, specs: specs, params: params, latencySamples: latencySamples)
        _ = node.pullInput // force the lazy closure to materialize before `process` can run
        node.attachObserver(tree: au.parameterTree, addressIndex: addressIndex)
        return node
    }

    private init(ref: FXPluginRef, au: AUAudioUnit, renderBlock: @escaping AURenderBlock,
                 scheduleParameterBlock: AUScheduleParameterBlock?, busChannels: Int,
                 specs: [FXParamSpec], params: FXParamStore, latencySamples: Int) {
        self.ref = ref
        self.au = au
        self.renderBlock = renderBlock
        self.scheduleParameterBlock = scheduleParameterBlock
        self.busChannels = busChannels
        self.specs = specs
        self.params = params
        self.latencySamples = latencySamples

        outputList = AudioBufferList.allocate(maximumBuffers: busChannels)
        outputStorage = .allocate(capacity: busChannels * FXBlock.maxFrames)
        outputStorage.initialize(repeating: 0, count: busChannels * FXBlock.maxFrames)
        for i in 0..<busChannels {
            outputList[i] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(FXBlock.maxFrames * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(outputStorage + i * FXBlock.maxFrames))
        }
        monoScratch = .allocate(capacity: FXBlock.maxFrames)
        monoScratch.initialize(repeating: 0, count: FXBlock.maxFrames)

        lastKnown = .allocate(capacity: max(specs.count, 1))
        for (i, spec) in specs.enumerated() {
            (lastKnown + i).initialize(to: Atomic(spec.defaultValue.bitPattern))
        }

    }

    deinit {
        if let observerToken { au.parameterTree?.removeParameterObserver(observerToken) }
        au.deallocateRenderResources()
        outputList.unsafeMutablePointer.deallocate()
        outputStorage.deallocate()
        monoScratch.deallocate()
        lastKnown.deinitialize(count: max(specs.count, 1))
        lastKnown.deallocate()
    }

    // MARK: - FXNode

    func process(_ block: FXBlock) {
        syncParameters()

        currentLeft = block.left
        currentRight = block.right
        currentFrames = block.frames
        currentChannels = block.channels

        var flags = AudioUnitRenderActionFlags()
        var timestamp = AudioTimeStamp()
        timestamp.mSampleTime = sampleTime
        timestamp.mFlags = .sampleTimeValid

        let status = renderBlock(&flags, &timestamp, AUAudioFrameCount(block.frames), 0, outputList.unsafeMutablePointer, pullInput)
        sampleTime += Float64(block.frames)

        if status == noErr {
            copyOutput(frames: block.frames, into: block)
        } else {
            errorCount.add(1, ordering: .relaxed)
            // Pass-through: `block` still holds the untouched input; we never wrote to it.
        }
    }

    func reset() {
        sampleTime = 0
    }

    // MARK: - Hosted

    @MainActor func captureState() -> Data? {
        guard let state = au.fullState else { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
    }

    @MainActor func makeEditor() async -> NSViewController? {
        await withCheckedContinuation { continuation in
            au.requestViewController { viewController in
                continuation.resume(returning: viewController)
            }
        }
    }

    // MARK: - IO thread helpers

    /// Runs inside `renderBlock`'s call on the IO thread: fills the input `AudioBufferList`
    /// the Audio Unit asked for from the current block, adapting channel count if needed.
    private func fillInput(frameCount: Int, into data: UnsafeMutablePointer<AudioBufferList>) {
        let n = min(frameCount, currentFrames)
        let list = UnsafeMutableAudioBufferListPointer(data)
        switch (busChannels, currentChannels) {
        case (2, 2):
            write(list, 0, currentLeft, n)
            write(list, 1, currentRight, n)
        case (2, 1):
            write(list, 0, currentLeft, n)
            write(list, 1, currentLeft, n)
        case (1, 2):
            vDSP_vadd(currentLeft, 1, currentRight, 1, monoScratch, 1, vDSP_Length(n))
            var half: Float = 0.5
            vDSP_vsmul(monoScratch, 1, &half, monoScratch, 1, vDSP_Length(n))
            write(list, 0, monoScratch, n)
        default: // (1, 1)
            write(list, 0, currentLeft, n)
        }
    }

    private func write(_ list: UnsafeMutableAudioBufferListPointer, _ index: Int, _ source: UnsafeMutablePointer<Float>, _ count: Int) {
        guard index < list.count else { return }
        if let destination = list[index].mData {
            destination.assumingMemoryBound(to: Float.self).update(from: source, count: count)
        } else {
            // The AU asked us to supply the buffer: zero-copy, point it at our own data.
            list[index].mData = UnsafeMutableRawPointer(source)
        }
        list[index].mDataByteSize = UInt32(count * MemoryLayout<Float>.size)
    }

    /// Copies a successful render's output (in `outputList`) into `block`, adapting channel
    /// count. Only called after `renderBlock` returns `noErr`.
    private func copyOutput(frames: Int, into block: FXBlock) {
        func channel(_ i: Int) -> UnsafeMutablePointer<Float>? {
            outputList[i].mData?.assumingMemoryBound(to: Float.self)
        }
        switch (busChannels, block.channels) {
        case (2, 2):
            if let l = channel(0) { block.left.update(from: l, count: frames) }
            if let r = channel(1) { block.right.update(from: r, count: frames) }
        case (2, 1):
            if let l = channel(0), let r = channel(1) {
                vDSP_vadd(l, 1, r, 1, block.left, 1, vDSP_Length(frames))
                var half: Float = 0.5
                vDSP_vsmul(block.left, 1, &half, block.left, 1, vDSP_Length(frames))
            }
        case (1, 2):
            if let m = channel(0) {
                block.left.update(from: m, count: frames)
                block.right.update(from: m, count: frames)
            }
        default: // (1, 1)
            if let m = channel(0) { block.left.update(from: m, count: frames) }
        }
    }

    /// Pushes any parameter the host changed since the last block to the plugin. IO thread.
    private func syncParameters() {
        let generation = params.generation
        guard generation != lastGeneration else { return }
        lastGeneration = generation
        guard let schedule = scheduleParameterBlock else { return }
        for i in 0..<specs.count {
            guard let address = specs[i].hostAddress else { continue }
            let value = params.get(i)
            let bits = value.bitPattern
            if lastKnown[i].load(ordering: .relaxed) != bits {
                lastKnown[i].store(bits, ordering: .relaxed)
                schedule(AUEventSampleTimeImmediate, 0, AUParameterAddress(address), AUValue(value))
            }
        }
    }

    // MARK: - Setup helpers (off IO thread)

    private func attachObserver(tree: AUParameterTree?, addressIndex: [AUParameterAddress: Int]) {
        guard let tree else { return }
        observerToken = tree.token(byAddingParameterObserver: { [weak self] address, value in
            guard let self, let index = addressIndex[address] else { return }
            let bits = value.bitPattern
            // Our own `syncParameters` write echoing back through the tree: ignore it, or we'd
            // bounce the value between `params` and the plugin forever.
            if self.lastKnown[index].load(ordering: .relaxed) == bits { return }
            self.lastKnown[index].store(bits, ordering: .relaxed)
            self.params.set(index, value)
        })
    }

    private static func buildSpecs(from tree: AUParameterTree?) -> ([FXParamSpec], [AUParameterAddress: Int]) {
        guard let tree else { return ([], [:]) }
        var specs: [FXParamSpec] = []
        var addressIndex: [AUParameterAddress: Int] = [:]
        for parameter in tree.allParameters {
            let choices = (parameter.valueStrings?.isEmpty == false) ? parameter.valueStrings : nil
            let spec = FXParamSpec(
                id: "au.\(parameter.identifier)",
                name: parameter.displayName,
                detail: parameter.displayName,
                unit: fxUnit(for: parameter.unit),
                min: parameter.minValue,
                max: parameter.maxValue,
                defaultValue: parameter.value,
                scale: .linear,
                choices: choices,
                hostAddress: parameter.address)
            addressIndex[parameter.address] = specs.count
            specs.append(spec)
        }
        return (specs, addressIndex)
    }

    private static func fxUnit(for unit: AudioUnitParameterUnit) -> FXUnit {
        switch unit {
        case .decibels: .dB
        case .hertz: .hz
        case .percent: .percent
        case .seconds: .seconds
        case .milliseconds: .ms
        case .relativeSemiTones: .semitones
        case .ratio: .ratio
        default: .none
        }
    }
}
