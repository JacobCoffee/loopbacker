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
    case osStatus(String, OSStatus)
}

private func checkStatus(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else { throw AUHostError.osStatus(what, status) }
}

/// The Cocoa view-factory protocol every v2 Audio Unit with a custom view implements. Apple
/// only declares it in an Objective-C-only header (`AudioToolbox/AUCocoaUIView.h`, gated behind
/// `#if defined(__OBJC__)`), invisible to a pure-Swift target. Redeclared here with the
/// identical selectors: ObjC dispatch only cares about selector names matching at the call
/// site, not which header declared them. Most factories don't formally declare conformance to
/// it either, so `AUHostNode.loadCocoaView` uses `responds(to:)` plus a raw `IMP` call instead
/// of an `as?` cast.
@objc private protocol AUCocoaUIBase {
    func interfaceVersion() -> UInt32
    @objc(uiViewForAudioUnit:withSize:) func uiView(for audioUnit: AudioUnit, withSize inPreferredSize: NSSize) -> NSView?
}

/// Wraps a v2 Audio Unit's Cocoa factory view so `makeEditor()` can return an `NSViewController`.
private final class CocoaUIViewController: NSViewController {
    private let hostedView: NSView
    init(hostedView: NSView) {
        self.hostedView = hostedView
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = hostedView.frame.size
    }
    required init?(coder: NSCoder) { fatalError("not supported") }
    override func loadView() { view = hostedView }
}

/// Hosts one Audio Unit (v2 in-process, or v3 out-of-process) as a voice-chain stage.
///
/// Thread contract:
/// - `process`/`reset` run on the chain's IO thread. v2 calls only the classic C API
///   (`AudioUnitRender`, `AudioUnitSetParameter`, `AudioUnitReset`) — plain C calls, allowed on
///   the IO thread, and (measured) allocation-free. v3 calls the render block and
///   schedule-parameter block captured at `load` time — Swift closures wrapping an
///   Objective-C/Swift bridge; `reset()` therefore cannot forward to `AUAudioUnit.reset()` (an
///   Objective-C method) for v3 and only clears this node's own counters — the plugin's internal
///   history (e.g. a delay tail) persists across a v3 reset, which is what most hosts do for a
///   transport stop/start anyway.
/// - Both paths only touch buffers preallocated in `init`.
/// - `captureState()`/`makeEditor()` are `@MainActor` and freely message the AU.
/// - The parameter-feedback callback added in `load` (v3: a parameter-tree observer; v2: an
///   `AUEventListener`) may fire on any thread (v3) or the main run loop (v2); both only call
///   `FXParamStore.set`, safe from any thread.
///
/// v2 is hosted through the classic C API, not `AUAudioUnit`, because `AUAudioUnit`'s
/// `renderBlock`/`scheduleParameterBlock` (the Swift/ObjC bridge to the same in-process v2
/// component) heap-allocates twice per render call — measured with every built-in AU tried,
/// constant regardless of which plugin, the block size, or whether the size varies call to
/// call — which the IO thread may not do. The raw C entry points measure zero allocations under
/// the same conditions. v3 app extensions have no C-API equivalent (they only exist as
/// out-of-process `AUAudioUnit`s reached over XPC), so they still go through the bridge.
final class AUHostNode: FXHostedNode, @unchecked Sendable {
    let kind: FXNodeKind = .audioUnit
    let ref: FXPluginRef
    let specs: [FXParamSpec]
    let params: FXParamStore
    let meters = FXMeters()
    let latencySamples: Int

    // Exactly one of the two backends below is populated, chosen once in `load` by the
    // component's v2/v3 flag. `process`, `syncParameters` and `reset` branch on which.
    private let v2Instance: AudioComponentInstance?
    private let v3Unit: AUAudioUnit?
    private let v3RenderBlock: AURenderBlock?
    private let v3ScheduleParameterBlock: AUScheduleParameterBlock?

    /// 1 or 2: the channel count negotiated with the plugin's input/output busses.
    private let busChannels: Int

    /// The render destination, reused for every block; never reallocated after `init`. Reset
    /// (byte size and `mData` pointer) before every render call: the AU may rewrite either
    /// field — some point `mData` into their own memory — so a stale buffer list silently
    /// desyncs the declared size from a later, larger block and renders start failing.
    private let outputList: UnsafeMutableAudioBufferListPointer
    private let outputStorage: UnsafeMutablePointer<Float>
    /// Scratch for summing a stereo source down to the mono a mono-only plugin expects.
    private let monoScratch: UnsafeMutablePointer<Float>

    private var v3ObserverToken: AUParameterObserverToken?
    private var v2Listener: AUEventListenerRef?
    /// Bit pattern last pushed to (or observed equal from) the plugin, indexed like `specs`.
    /// Lets the parameter-feedback callback, which fires for both the host's own writes (v3
    /// only — v2's `AudioUnitSetParameter` never notifies `AUEventListener`, only `AUParameterSet`
    /// does, so v2 needs no echo guard at all) and the plugin's own UI, tell its own echo from a
    /// genuine UI-made change, with no lock.
    private let lastKnown: UnsafeMutablePointer<Atomic<UInt32>>
    private var lastGeneration: UInt32 = 0
    private let errorCount = Atomic<UInt64>(0)

    // Per-call input, set at the top of `process` and read back by the pull-input
    // block/callback while the AU renders synchronously inside it. IO thread only.
    private var currentLeft: UnsafeMutablePointer<Float>!
    private var currentRight: UnsafeMutablePointer<Float>!
    private var currentFrames = 0
    private var currentChannels = 1
    private var sampleTime: Float64 = 0

    /// v3 only: one heap-allocated closure, created lazily on first touch (forced in `load`,
    /// off the IO thread) and reused for every `process` call so the IO thread never allocates
    /// one. v2's equivalent (`v2PullInputProc` below) is a non-capturing C function pointer,
    /// registered once via `kAudioUnitProperty_SetRenderCallback`, not passed per call.
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

        if isV3 {
            return try await loadV3(ref: ref, description: description, state: state, sampleRate: sampleRate)
        } else {
            return try loadV2(ref: ref, component: component, state: state, sampleRate: sampleRate)
        }
    }

    private init(ref: FXPluginRef, v2Instance: AudioComponentInstance?, v3Unit: AUAudioUnit?,
                 v3RenderBlock: AURenderBlock?, v3ScheduleParameterBlock: AUScheduleParameterBlock?,
                 busChannels: Int, specs: [FXParamSpec], params: FXParamStore, latencySamples: Int) {
        self.ref = ref
        self.v2Instance = v2Instance
        self.v3Unit = v3Unit
        self.v3RenderBlock = v3RenderBlock
        self.v3ScheduleParameterBlock = v3ScheduleParameterBlock
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
        if let v3ObserverToken { v3Unit?.parameterTree?.removeParameterObserver(v3ObserverToken) }
        v3Unit?.deallocateRenderResources()
        if let v2Listener { AUListenerDispose(v2Listener) }
        if let v2Instance {
            AudioUnitUninitialize(v2Instance)
            AudioComponentInstanceDispose(v2Instance)
        }
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

        // The AU may rewrite a buffer's `mDataByteSize` to the frame count it just rendered,
        // and/or replace `mData` with a pointer into its own memory (common when it supplies
        // its own output storage). Left as-is, a later call with more frames than the smallest
        // one seen so far fails: the buffer list must describe exactly this call's capacity and
        // point back at our own storage every time.
        for i in 0..<busChannels {
            outputList[i] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(block.frames * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(outputStorage + i * FXBlock.maxFrames))
        }

        var flags = AudioUnitRenderActionFlags()
        var timestamp = AudioTimeStamp()
        timestamp.mSampleTime = sampleTime
        timestamp.mFlags = .sampleTimeValid

        let status: OSStatus
        if let v2Instance {
            status = AudioUnitRender(v2Instance, &flags, &timestamp, 0, AudioUnitRenderActionFlags.RawValue(block.frames), outputList.unsafeMutablePointer)
        } else if let v3RenderBlock {
            status = v3RenderBlock(&flags, &timestamp, AUAudioFrameCount(block.frames), 0, outputList.unsafeMutablePointer, pullInput)
        } else {
            status = kAudio_ParamError
        }
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
        // `AudioUnitReset` is a plain C call, allowed on the IO thread; `AUAudioUnit.reset()`
        // is Objective-C and is not. v3's plugin history therefore persists across a reset.
        if let v2Instance { AudioUnitReset(v2Instance, kAudioUnitScope_Global, 0) }
    }

    // MARK: - Hosted

    @MainActor func captureState() -> Data? {
        if let v2Instance {
            var classInfo: Unmanaged<CFPropertyList>?
            var size = UInt32(MemoryLayout<Unmanaged<CFPropertyList>?>.size)
            guard AudioUnitGetProperty(v2Instance, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &classInfo, &size) == noErr,
                  let classInfo else { return nil }
            return try? PropertyListSerialization.data(fromPropertyList: classInfo.takeRetainedValue(), format: .binary, options: 0)
        }
        guard let state = v3Unit?.fullState else { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
    }

    @MainActor func makeEditor() async -> NSViewController? {
        if let v2Instance {
            return loadCocoaView(instance: v2Instance)
        }
        guard let v3Unit else { return nil }
        return await withCheckedContinuation { continuation in
            v3Unit.requestViewController { viewController in
                continuation.resume(returning: viewController)
            }
        }
    }

    // MARK: - IO thread helpers

    /// Runs inside the AU's pull-input call on the IO thread: fills the input `AudioBufferList`
    /// it asked for from the current block, adapting channel count if needed.
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
    /// count. Only called after the render call returns `noErr`.
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
        for i in 0..<specs.count {
            guard let address = specs[i].hostAddress else { continue }
            let value = params.get(i)
            let bits = value.bitPattern
            guard lastKnown[i].load(ordering: .relaxed) != bits else { continue }
            lastKnown[i].store(bits, ordering: .relaxed)
            if let v2Instance {
                // Plain C call: real-time safe, and (unlike `AUParameterSet`) never triggers
                // our own `AUEventListener`, so v2 needs no echo guard beyond deduplicating
                // identical consecutive values above.
                AudioUnitSetParameter(v2Instance, AudioUnitParameterID(address), kAudioUnitScope_Global, 0, value, 0)
            } else if let v3ScheduleParameterBlock {
                v3ScheduleParameterBlock(AUEventSampleTimeImmediate, 0, AUParameterAddress(address), AUValue(value))
            }
        }
    }

    // MARK: - v3

    private static func loadV3(ref: FXPluginRef, description: AudioComponentDescription, state: Data?, sampleRate: Double) async throws -> AUHostNode {
        // v3 app extensions load out-of-process, the system default for them (no C-API
        // in-process option exists unless the extension ships a separate in-process bundle,
        // which we don't assume).
        let au = try await AUAudioUnit.instantiate(with: description, options: [])

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

        let (specs, addressIndex) = buildV3Specs(from: au.parameterTree)
        let params = FXParamStore(specs: specs)
        let latencySamples = Int((au.latency * sampleRate).rounded())

        let node = AUHostNode(
            ref: ref, v2Instance: nil, v3Unit: au, v3RenderBlock: au.renderBlock,
            v3ScheduleParameterBlock: au.scheduleParameterBlock, busChannels: busChannels,
            specs: specs, params: params, latencySamples: latencySamples)
        _ = node.pullInput // force the lazy closure to materialize before `process` can run
        node.attachV3Observer(tree: au.parameterTree, addressIndex: addressIndex)
        return node
    }

    private func attachV3Observer(tree: AUParameterTree?, addressIndex: [AUParameterAddress: Int]) {
        guard let tree else { return }
        v3ObserverToken = tree.token(byAddingParameterObserver: { [weak self] address, value in
            guard let self, let index = addressIndex[address] else { return }
            let bits = value.bitPattern
            // Our own `syncParameters` write echoing back through the tree: ignore it, or we'd
            // bounce the value between `params` and the plugin forever.
            if self.lastKnown[index].load(ordering: .relaxed) == bits { return }
            self.lastKnown[index].store(bits, ordering: .relaxed)
            self.params.set(index, value)
        })
    }

    private static func buildV3Specs(from tree: AUParameterTree?) -> ([FXParamSpec], [AUParameterAddress: Int]) {
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

    // MARK: - v2

    /// A non-capturing C function pointer registered once via
    /// `kAudioUnitProperty_SetRenderCallback`; the per-call `refCon` (the node's own address,
    /// stable for its lifetime) routes back into `fillInput` without a heap allocation.
    private static let v2PullInputProc: AURenderCallback = { refCon, _, _, _, frameCount, data in
        guard let data else { return noErr }
        let node = Unmanaged<AUHostNode>.fromOpaque(refCon).takeUnretainedValue()
        node.fillInput(frameCount: Int(frameCount), into: data)
        return noErr
    }

    private static let v2EventListenerProc: AUEventListenerProc = { userData, _, event, _, value in
        guard let userData else { return }
        guard event.pointee.mEventType == .parameterValueChange else { return }
        let node = Unmanaged<AUHostNode>.fromOpaque(userData).takeUnretainedValue()
        node.handleV2ParameterFeedback(paramID: event.pointee.mArgument.mParameter.mParameterID, value: value)
    }

    private func handleV2ParameterFeedback(paramID: AudioUnitParameterID, value: AudioUnitParameterValue) {
        guard let index = specs.firstIndex(where: { $0.hostAddress == UInt64(paramID) }) else { return }
        let bits = value.bitPattern
        if lastKnown[index].load(ordering: .relaxed) == bits { return }
        lastKnown[index].store(bits, ordering: .relaxed)
        params.set(index, value)
    }

    private static func loadV2(ref: FXPluginRef, component: AudioComponent, state: Data?, sampleRate: Double) throws -> AUHostNode {
        var instanceOpt: AudioComponentInstance?
        try checkStatus(AudioComponentInstanceNew(component, &instanceOpt), "AudioComponentInstanceNew")
        guard let instance = instanceOpt else { throw AUHostError.unsupportedFormat(ref.identifier) }

        func configure(_ channels: UInt32) -> Bool {
            var asbd = AudioStreamBasicDescription(
                mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
            let inStatus = AudioUnitSetProperty(instance, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
            let outStatus = AudioUnitSetProperty(instance, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
            return inStatus == noErr && outStatus == noErr
        }
        let busChannels: Int
        if configure(2) {
            busChannels = 2
        } else if configure(1) {
            busChannels = 1
        } else {
            AudioComponentInstanceDispose(instance)
            throw AUHostError.unsupportedFormat(ref.identifier)
        }

        var maxFrames = UInt32(FXBlock.maxFrames)
        try checkStatus(AudioUnitSetProperty(instance, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, UInt32(MemoryLayout<UInt32>.size)), "set max frames")

        // Restore before reading the parameter list, so specs' `defaultValue` (used to seed
        // `FXParamStore`) reflects the restored values rather than the plugin's own defaults.
        if let state, let plist = try? PropertyListSerialization.propertyList(from: state, options: [], format: nil) {
            let cfPlist = plist as CFPropertyList
            withUnsafePointer(to: cfPlist) { ptr in
                _ = AudioUnitSetProperty(instance, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, ptr, UInt32(MemoryLayout<CFPropertyList>.size))
            }
        }

        let (specs, addressIndex) = try buildV2Specs(instance: instance)
        let params = FXParamStore(specs: specs)

        var latency: Float64 = 0
        var latSize = UInt32(MemoryLayout<Float64>.size)
        _ = AudioUnitGetProperty(instance, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &latency, &latSize)
        let latencySamples = Int((latency * sampleRate).rounded())

        let node = AUHostNode(
            ref: ref, v2Instance: instance, v3Unit: nil, v3RenderBlock: nil, v3ScheduleParameterBlock: nil,
            busChannels: busChannels, specs: specs, params: params, latencySamples: latencySamples)

        // `node` is fully initialized and (as a class instance) never moves, so its address is
        // stable for the registered callback's lifetime.
        let nodeRef = Unmanaged.passUnretained(node).toOpaque()
        var callback = AURenderCallbackStruct(inputProc: v2PullInputProc, inputProcRefCon: nodeRef)
        try checkStatus(AudioUnitSetProperty(instance, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "set render callback")
        try checkStatus(AudioUnitInitialize(instance), "AudioUnitInitialize")

        node.attachV2Listener(instance: instance, addressIndex: addressIndex)
        return node
    }

    /// Delivers `kAudioUnitEvent_ParameterValueChange` notifications posted by the plugin's own
    /// Cocoa UI (via `AUParameterSet`) back into `params`. The host's own writes, made via plain
    /// `AudioUnitSetParameter`, never generate one — Apple's documented behavior — so no echo
    /// guard beyond `lastKnown`'s value dedup is needed on this path.
    private func attachV2Listener(instance: AudioComponentInstance, addressIndex: [UInt64: Int]) {
        guard !addressIndex.isEmpty else { return }
        var listener: AUEventListenerRef?
        guard AUEventListenerCreate(Self.v2EventListenerProc, Unmanaged.passUnretained(self).toOpaque(),
                                     CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue, 0, 0, &listener) == noErr,
              let listener else { return }
        v2Listener = listener
        for address in addressIndex.keys {
            var event = AudioUnitEvent()
            event.mEventType = .parameterValueChange
            event.mArgument.mParameter = AudioUnitParameter(
                mAudioUnit: instance, mParameterID: AudioUnitParameterID(address),
                mScope: AudioUnitScope(kAudioUnitScope_Global), mElement: 0)
            AUEventListenerAddEventType(listener, nil, &event)
        }
    }

    private static func buildV2Specs(instance: AudioComponentInstance) throws -> ([FXParamSpec], [UInt64: Int]) {
        var listSize: UInt32 = 0
        guard AudioUnitGetPropertyInfo(instance, kAudioUnitProperty_ParameterList, kAudioUnitScope_Global, 0, &listSize, nil) == noErr,
              listSize > 0 else { return ([], [:]) }
        let count = Int(listSize) / MemoryLayout<AudioUnitParameterID>.size
        var ids = [AudioUnitParameterID](repeating: 0, count: count)
        guard AudioUnitGetProperty(instance, kAudioUnitProperty_ParameterList, kAudioUnitScope_Global, 0, &ids, &listSize) == noErr else {
            return ([], [:])
        }

        // AudioUnitParameterOptions bit positions (AudioUnitProperties.h); not exposed as
        // Swift OptionSet members, so tested against `flags.rawValue` directly.
        let flagHasCFNameString: UInt32 = 1 << 27
        let flagCFNameRelease: UInt32 = 1 << 4
        let flagValuesHaveStrings: UInt32 = 1 << 21

        var specs: [FXParamSpec] = []
        var addressIndex: [UInt64: Int] = [:]
        for id in ids {
            var info = AudioUnitParameterInfo()
            var infoSize = UInt32(MemoryLayout<AudioUnitParameterInfo>.size)
            guard AudioUnitGetProperty(instance, kAudioUnitProperty_ParameterInfo, kAudioUnitScope_Global, id, &info, &infoSize) == noErr else { continue }

            let name: String
            if info.flags.rawValue & flagHasCFNameString != 0, let cfNameRef = info.cfNameString {
                let cfName = cfNameRef.takeUnretainedValue()
                name = cfName as String
                if info.flags.rawValue & flagCFNameRelease != 0 { cfNameRef.release() }
            } else {
                name = withUnsafeBytes(of: info.name) { raw in
                    String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
                }
            }

            var choices: [String]?
            if info.flags.rawValue & flagValuesHaveStrings != 0 {
                var arrayRef: Unmanaged<CFArray>?
                var size = UInt32(MemoryLayout<Unmanaged<CFArray>?>.size)
                if AudioUnitGetProperty(instance, kAudioUnitProperty_ParameterValueStrings, kAudioUnitScope_Global, id, &arrayRef, &size) == noErr,
                   let array = arrayRef?.takeRetainedValue() as? [CFString] {
                    choices = array.map { $0 as String }
                }
            }

            // `info.defaultValue` is the plugin's static declared default, unaffected by a
            // ClassInfo restore; the *live* value (what `AudioUnitGetParameter` reads right
            // now) is what a restored state actually set, and what `FXParamStore` must seed.
            var liveValue = info.defaultValue
            AudioUnitGetParameter(instance, id, kAudioUnitScope_Global, 0, &liveValue)

            let spec = FXParamSpec(
                id: "au.\(id)",
                name: name,
                detail: name,
                unit: fxUnit(for: info.unit),
                min: info.minValue,
                max: info.maxValue,
                defaultValue: liveValue,
                scale: .linear,
                choices: choices,
                hostAddress: UInt64(id))
            addressIndex[UInt64(id)] = specs.count
            specs.append(spec)
        }
        return (specs, addressIndex)
    }

    /// Dynamically loads a v2 Audio Unit's custom Cocoa view, if it has one, and wraps it in an
    /// `NSViewController`. `kAudioUnitProperty_CocoaUI` is read-only and only present when the
    /// plugin provides a view; most don't declare formal conformance to the (Objective-C-only,
    /// so Swift-invisible) `AUCocoaUIBase` protocol, so the factory method is called through a
    /// raw `IMP` lookup rather than an `as?` cast.
    @MainActor private func loadCocoaView(instance: AudioComponentInstance) -> NSViewController? {
        var size: UInt32 = 0
        var writable: DarwinBoolean = false
        guard AudioUnitGetPropertyInfo(instance, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, &size, &writable) == noErr,
              size >= UInt32(MemoryLayout<AudioUnitCocoaViewInfo>.size) else { return nil }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioUnitCocoaViewInfo>.alignment)
        defer { raw.deallocate() }
        var readSize = size
        guard AudioUnitGetProperty(instance, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, raw, &readSize) == noErr else { return nil }
        let info = raw.assumingMemoryBound(to: AudioUnitCocoaViewInfo.self)
        let bundleURL = info.pointee.mCocoaAUViewBundleLocation.takeRetainedValue() as URL
        let className = info.pointee.mCocoaAUViewClass.takeRetainedValue() as String

        guard let bundle = Bundle(url: bundleURL), bundle.load(),
              let factoryClass = bundle.classNamed(className) as? NSObject.Type else { return nil }
        let factory = factoryClass.init()

        let selector = NSSelectorFromString("uiViewForAudioUnit:withSize:")
        guard factory.responds(to: selector), let method = class_getInstanceMethod(factoryClass, selector) else { return nil }
        typealias ViewFactoryFn = @convention(c) (AnyObject, Selector, AudioUnit, NSSize) -> Unmanaged<NSView>?
        let fn = unsafeBitCast(method_getImplementation(method), to: ViewFactoryFn.self)
        guard let view = fn(factory, selector, instance, NSSize(width: 480, height: 300))?.takeUnretainedValue() else { return nil }
        return CocoaUIViewController(hostedView: view)
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
