import CAirwindows
import Foundation
import Testing
@testable import Loopbacker

private let frames = 512
private let rate: Double = 48_000

/// A short, non-trivial test signal: a couple of sine partials, never silent so effects that
/// gate/duck on level still have something to react to.
private func signal() -> [Float] {
    (0..<frames).map { i in
        let t = Float(i) / Float(rate)
        return 0.3 * sinf(2 * .pi * 220 * t) + 0.1 * sinf(2 * .pi * 1_800 * t)
    }
}

private func makeNode(_ name: String) async throws -> AirwindowsNode {
    let ref = FXPluginRef(format: .airwindows, identifier: name, name: name, vendor: "Airwindows")
    return try await AirwindowsNode.load(ref: ref, state: nil, sampleRate: rate)
}

/// Runs `node` over a fresh copy of `signal()` once and returns the processed left channel.
private func run(_ node: AirwindowsNode) -> [Float] {
    var left = signal()
    var right = left
    left.withUnsafeMutableBufferPointer { l in
        right.withUnsafeMutableBufferPointer { r in
            let block = FXBlock(left: l.baseAddress!, right: r.baseAddress!, frames: frames, channels: 2,
                                 sidechain: FXSidechain(voiceProbability: 1))
            node.process(block)
        }
    }
    return left
}

@Suite("Airwindows", .serialized)
struct AirwindowsNodeTests {
    @Test("Catalog count matches the vendored registry")
    func catalogCount() async {
        let saved = AirwindowsLibrary.isEnabled
        defer { AirwindowsLibrary.isEnabled = saved }
        AirwindowsLibrary.isEnabled = true
        let infos = await AirwindowsCatalog.scan()
        #expect(infos.count == Int(aw_effect_count()))
        #expect(infos.count > 500) // the vendored suite is ~528 effects
    }

    @Test("Disabling the library empties the catalog")
    func disabledCatalog() async {
        let saved = AirwindowsLibrary.isEnabled
        defer { AirwindowsLibrary.isEnabled = saved }
        AirwindowsLibrary.isEnabled = false
        let infos = await AirwindowsCatalog.scan()
        #expect(infos.isEmpty)
    }

    @Test("Named effects load, process a signal without NaN, and respond to a parameter change",
          arguments: ["Pressure5", "Air", "PurestGain", "Galactic"])
    func loadsAndProcesses(name: String) async throws {
        let node = try await makeNode(name)
        let output = run(node)
        #expect(output.allSatisfy { $0.isFinite })

        guard !node.specs.isEmpty else { return }

        let low = try await makeNode(name)
        low.params.set(0, low.specs[0].min)
        let outputLow = run(low)

        let high = try await makeNode(name)
        high.params.set(0, high.specs[0].max)
        let outputHigh = run(high)

        #expect(outputLow != outputHigh, "\(name): param 0 swing produced identical output")
    }

    @Test("State round-trips exactly")
    func stateRoundTrip() async throws {
        let node = try await makeNode("Pressure5")
        for (i, spec) in node.specs.enumerated() {
            node.params.set(i, spec.min + Float(i) * 0.1)
        }
        let before = (0..<node.specs.count).map { node.params.get($0) }
        let state = await node.captureState()
        #expect(state != nil)

        let restored = try await AirwindowsNode.load(
            ref: FXPluginRef(format: .airwindows, identifier: "Pressure5", name: "Pressure5", vendor: "Airwindows"),
            state: state, sampleRate: rate
        )
        let after = (0..<restored.specs.count).map { restored.params.get($0) }
        #expect(after == before)
    }

    @Test("An unknown effect name throws instead of loading")
    func unknownEffect() async {
        let ref = FXPluginRef(format: .airwindows, identifier: "NotARealAirwindowsEffect", name: "x", vendor: nil)
        await #expect(throws: AirwindowsError.self) {
            _ = try await AirwindowsNode.load(ref: ref, state: nil, sampleRate: rate)
        }
    }

    @Test("Documentation text is available for a well-known effect")
    func documentation() {
        let ref = FXPluginRef(format: .airwindows, identifier: "Pressure5", name: "Pressure5", vendor: "Airwindows")
        let doc = AirwindowsNode.documentation(for: ref)
        #expect(doc?.contains("Pressure5") == true)
    }

    @Test("Documentation is nil for an unregistered name")
    func documentationMissing() {
        let ref = FXPluginRef(format: .airwindows, identifier: "NotARealAirwindowsEffect", name: "x", vendor: nil)
        #expect(AirwindowsNode.documentation(for: ref) == nil)
    }
}
