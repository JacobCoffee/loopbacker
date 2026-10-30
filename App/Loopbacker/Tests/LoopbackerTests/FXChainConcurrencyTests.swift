import Foundation
import Synchronization
import Testing
@testable import Loopbacker

/// Regression tests for the graph-lifecycle bugs fixed after review: a graph freed on the IO
/// thread, a timeout-based release racing a stalled device, non-IO readers racing a concurrent
/// release, and out-of-order publishes from concurrent `updateConfigs` calls.
@Suite("FXChain concurrency and lifecycle")
struct FXChainConcurrencyTests {
    private static let sampleRate: Float = 48_000

    @Test("Concurrent process() and 200 random structural/param edits: no crash, finite output, latest config wins")
    func stressConcurrentEditsAndProcessing() async {
        let chain = FXChain(sampleRate: Self.sampleRate, captureDeviceUID: "stress")
        let kinds: [FXNodeKind] = [.gate, .eq, .compressor, .deEsser, .limiter]

        var currentConfig = [FXNodeConfig(id: UUID(), kind: .limiter)]
        await chain.updateConfigs(currentConfig)

        let stopFlag = Atomic<Bool>(false)
        let nonFiniteSeen = Atomic<Bool>(false)

        // Simulated IO thread: calls `process` back to back with varying block sizes, the way
        // real callbacks with jittery host-requested frame counts would.
        let ioThread = Thread {
            var rng = SystemRandomNumberGenerator()
            while !stopFlag.load(ordering: .relaxed) {
                let frames = Int.random(in: 16...512, using: &rng)
                var buffer = [Float](repeating: 0.3, count: frames * 2)
                buffer.withUnsafeMutableBufferPointer { ptr in
                    chain.process(ptr.baseAddress!, frames: frames, stride: 2, sampleTime: nil, rawPreNS: nil)
                }
                for v in buffer where !v.isFinite { nonFiniteSeen.store(true, ordering: .relaxed) }
            }
        }
        ioThread.start()

        for i in 0..<200 {
            if i % 3 == 0 {
                let count = Int.random(in: 1...4)
                currentConfig = (0..<count).map { _ in FXNodeConfig(id: UUID(), kind: kinds.randomElement()!) }
            } else if !currentConfig.isEmpty {
                currentConfig = currentConfig.map { cfg in
                    var c = cfg
                    c.enabled.toggle()
                    return c
                }
            }
            await chain.updateConfigs(currentConfig)
        }

        stopFlag.store(true, ordering: .relaxed)
        // Give the IO thread a moment to notice and exit before asserting on final state.
        try? await Task.sleep(nanoseconds: 100_000_000)

        let sawNonFinite = nonFiniteSeen.load(ordering: .relaxed)
        #expect(!sawNonFinite)
        // The final published graph must be exactly the last requested configuration, not a
        // stale or partially-applied one.
        for cfg in currentConfig {
            #expect(chain.liveNode(id: cfg.id) != nil)
        }
        let expectedLatency = currentConfig.reduce(0) { $0 + (chain.liveNode(id: $1.id)?.latencySamples ?? 0) }
        #expect(chain.totalLatencySamples == expectedLatency)
    }

    @Test("Concurrent updateConfigs calls never publish a corrupted mix of two requests")
    func concurrentUpdateConfigsDoNotCorrupt() async {
        let chain = FXChain(sampleRate: Self.sampleRate, captureDeviceUID: "coalesce")
        let requests: [[FXNodeConfig]] = (0..<20).map { i in
            [FXNodeConfig(id: UUID(), kind: i.isMultiple(of: 2) ? .limiter : .gate)]
        }

        await withTaskGroup(of: Void.self) { group in
            for request in requests {
                group.addTask { await chain.updateConfigs(request) }
            }
        }

        // Exactly one request's node must be live -- never zero (lost update) and never more
        // than one (a corrupted publish mixing two requests).
        let winners = requests.filter { chain.liveNode(id: $0[0].id) != nil }
        #expect(winners.count == 1)
    }

    @Test("A structural edit published while the IO proc is paused outlives the old 3s timeout and resumes cleanly",
          .timeLimit(.minutes(1)))
    func ioPauseThenResumeOutlivesOldTimeout() async throws {
        let chain = FXChain(sampleRate: Self.sampleRate, captureDeviceUID: "pause")
        let configA = [FXNodeConfig(id: UUID(), kind: .limiter)]
        await chain.updateConfigs(configA)

        var buffer = [Float](repeating: 0.1, count: 128 * 2)
        buffer.withUnsafeMutableBufferPointer { ptr in
            chain.process(ptr.baseAddress!, frames: 128, stride: 2, sampleTime: nil, rawPreNS: nil)
        }

        // Publish a structural change while nothing calls `process` -- simulating a stalled or
        // sleeping device. Nothing can mark the old graph `retired` during this window, so a
        // timeout-based release (the old 3 s deadline) would free it before IO ever resumes.
        let configB = [FXNodeConfig(id: UUID(), kind: .gate)]
        await chain.updateConfigs(configB)

        try await Task.sleep(nanoseconds: 3_500_000_000) // longer than the removed 3 s timeout

        // Resume: must not crash (use-after-free) and must declick into the new graph correctly.
        var buffer2 = [Float](repeating: 0.1, count: 480 * 2)
        buffer2.withUnsafeMutableBufferPointer { ptr in
            chain.process(ptr.baseAddress!, frames: 480, stride: 2, sampleTime: nil, rawPreNS: nil)
        }
        for v in buffer2 { #expect(v.isFinite) }
        #expect(chain.liveNode(id: configB[0].id) != nil)

        // A second block settles fully onto the new graph.
        var buffer3 = [Float](repeating: 0.1, count: 480 * 2)
        buffer3.withUnsafeMutableBufferPointer { ptr in
            chain.process(ptr.baseAddress!, frames: 480, stride: 2, sampleTime: nil, rawPreNS: nil)
        }
        for v in buffer3 { #expect(v.isFinite) }
    }

    @Test("ioStopped() frees outstanding graphs and further process() calls are safely inert")
    func ioStoppedFreesAndIsIdempotent() async {
        let chain = FXChain(sampleRate: Self.sampleRate, captureDeviceUID: "teardown")
        await chain.updateConfigs([FXNodeConfig(id: UUID(), kind: .limiter)])

        var buffer = [Float](repeating: 0.2, count: 128 * 2)
        buffer.withUnsafeMutableBufferPointer { ptr in
            chain.process(ptr.baseAddress!, frames: 128, stride: 2, sampleTime: nil, rawPreNS: nil)
        }

        chain.ioStopped()
        chain.ioStopped() // idempotent: must not double-free or crash

        // A `process` call after teardown must not crash; the chain simply has nothing to run.
        var buffer2 = [Float](repeating: 0.2, count: 128 * 2)
        buffer2.withUnsafeMutableBufferPointer { ptr in
            chain.process(ptr.baseAddress!, frames: 128, stride: 2, sampleTime: nil, rawPreNS: nil)
        }
        for v in buffer2 { #expect(v.isFinite) }
    }
}
