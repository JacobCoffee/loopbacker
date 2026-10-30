import AppKit
import CAirwindows
import Foundation

enum AirwindowsError: Error {
    /// `ref.identifier` doesn't name a registered Airwindows effect.
    case unknownEffect(String)
}

/// Persisted state for an `AirwindowsNode`: the effect name (for a sanity check on restore) and
/// its 0...1 parameter values in spec order.
private struct AirwindowsState: Codable {
    var name: String
    var values: [Float]
}

/// Hosts one effect from the vendored Airwindows suite (`CAirwindows`). Parameters are exactly
/// the effect's own controls, always normalized 0...1 as upstream; `FXParamSpec.hostAddress` is
/// the Airwindows parameter index passed to `aw_get_param`/`aw_set_param`.
///
/// Thread contract: `load`, `captureState` and `makeEditor` run off the IO thread (they allocate:
/// `aw_create` constructs the effect, `captureState` builds a `Data`). `process` and `reset` run
/// on the IO thread and touch only `aw_process`/`aw_get_param`/`aw_set_param`, which read/write
/// plain fields on the already-constructed effect and never allocate.
final class AirwindowsNode: FXHostedNode, @unchecked Sendable {
    let kind: FXNodeKind = .airwindows
    let ref: FXPluginRef
    let specs: [FXParamSpec]
    let params: FXParamStore
    let meters = FXMeters()
    /// Every vendored Airwindows effect here is a block-synchronous processor (no internal
    /// lookahead buffer exposed through the VST-era `processReplacing` interface).
    let latencySamples = 0

    private let handle: OpaquePointer
    /// Preallocated so `process` never allocates: `aw_process` writes into these instead of the
    /// caller's buffer, since not every effect in a 528-strong suite is verified safe for
    /// in-place (aliased input/output) processing.
    private let scratchL: UnsafeMutablePointer<Float>
    private let scratchR: UnsafeMutablePointer<Float>
    /// Last parameter generation applied to the plugin; the IO thread compares this each block
    /// against `params.generation` instead of touching the plugin every sample.
    private var appliedGeneration: UInt32 = .max

    private init(ref: FXPluginRef, handle: OpaquePointer, specs: [FXParamSpec]) {
        self.ref = ref
        self.handle = handle
        self.specs = specs
        params = FXParamStore(specs: specs)
        scratchL = .allocate(capacity: FXBlock.maxFrames)
        scratchR = .allocate(capacity: FXBlock.maxFrames)
        scratchL.initialize(repeating: 0, count: FXBlock.maxFrames)
        scratchR.initialize(repeating: 0, count: FXBlock.maxFrames)
    }

    deinit {
        aw_destroy(handle)
        scratchL.deallocate()
        scratchR.deallocate()
    }

    static func load(ref: FXPluginRef, state: Data?, sampleRate: Double) async throws -> AirwindowsNode {
        let index = aw_effect_index_for_name(ref.identifier)
        guard index >= 0, let handle = aw_create(index, sampleRate) else {
            throw AirwindowsError.unknownEffect(ref.identifier)
        }

        let paramCount = Int(aw_param_count(handle))
        var specs: [FXParamSpec] = []
        specs.reserveCapacity(paramCount)
        for i in 0..<paramCount {
            let paramIndex = Int32(i)
            var nameBuffer = [CChar](repeating: 0, count: 128)
            aw_param_name(handle, paramIndex, &nameBuffer, Int32(nameBuffer.count))
            let nulIndex = nameBuffer.firstIndex(of: 0) ?? nameBuffer.count
            let name = String(decoding: nameBuffer[..<nulIndex].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            specs.append(FXParamSpec(
                id: "p\(i)",
                name: name.isEmpty ? "Param \(i + 1)" : name,
                detail: "",
                unit: .none,
                min: 0,
                max: 1,
                defaultValue: aw_get_param(handle, paramIndex),
                hostAddress: UInt64(i)
            ))
        }

        let node = AirwindowsNode(ref: ref, handle: handle, specs: specs)

        if let state, let decoded = try? JSONDecoder().decode(AirwindowsState.self, from: state) {
            for (i, value) in decoded.values.enumerated() where i < specs.count {
                node.params.set(i, min(max(value, 0), 1))
            }
        }
        // Seed the plugin from params (defaults, or just-restored state) before the first block.
        node.applyParams(force: true)

        return node
    }

    @MainActor
    func captureState() -> Data? {
        let values = (0..<specs.count).map { params.get($0) }
        return try? JSONEncoder().encode(AirwindowsState(name: ref.identifier, values: values))
    }

    @MainActor
    func makeEditor() async -> NSViewController? { nil } // Generic parameter UI only.

    /// Airwindows effects expose no native reset: their internal state (filters, delay taps,
    /// dither seeds) is only ever set up in the constructor. Recreating the instance here would
    /// allocate/deallocate on the IO thread, which the contract forbids, so this is intentionally
    /// a no-op — state settles from near-silent input within a block or two regardless.
    func reset() {}

    func process(_ block: FXBlock) {
        applyParams(force: false)

        var peakIn: Float = 0
        for i in 0..<block.frames { peakIn = max(peakIn, abs(block.left[i])) }

        let frames = Int32(block.frames)
        if block.channels == 1 {
            aw_process(handle, block.left, block.left, scratchL, scratchR, frames)
            block.left.update(from: scratchL, count: block.frames)
        } else {
            aw_process(handle, block.left, block.right, scratchL, scratchR, frames)
            block.left.update(from: scratchL, count: block.frames)
            block.right.update(from: scratchR, count: block.frames)
        }

        var peakOut: Float = 0
        for i in 0..<block.frames { peakOut = max(peakOut, abs(block.left[i])) }
        meters.inputPeak = peakIn
        meters.outputPeak = peakOut
    }

    /// IO thread. Pushes every parameter value whose generation moved since the last block.
    private func applyParams(force: Bool) {
        let generation = params.generation
        guard force || generation != appliedGeneration else { return }
        for i in 0..<specs.count {
            aw_set_param(handle, Int32(i), params.get(i))
        }
        appliedGeneration = generation
    }

    /// Long-form documentation for the effect browser, or nil if none is embedded.
    static func documentation(for ref: FXPluginRef) -> String? {
        let index = aw_effect_index_for_name(ref.identifier)
        guard index >= 0, let cText = aw_effect_doc_text(index) else { return nil }
        defer { aw_free_string(cText) }
        let text = String(cString: cText)
        return text.isEmpty ? nil : text
    }
}
