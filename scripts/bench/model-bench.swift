// model-bench.swift -- benchmarks DPDFNet2_48k.mlmodelc through BNNS Graph the way the app
// runs it on the audio thread: single-thread compile, pointer arguments, a preallocated
// page-aligned workspace, and a ping-ponged recurrent state. No Core ML worker thread,
// no per-hop allocation.
//
// Usage (via model-bench.sh, which handles the dylib + bridging header):
//   model-bench.sh [--coreml] [mlmodelc path]
//
// Reports:
//   - BNNS Graph compile time
//   - hot loop: ms/hop with a warm cache, back to back
//   - paced loop: one hop every 10 ms on a time-constraint (real-time) thread, matching the
//     app's IO cadence -- wall and thread-CPU median/p99/max, plus heap allocations during
//     execute (must be 0)
//   - with --coreml: parity vs. Core ML (SNR in dB) as a correctness cross-check
//
// Run standalone with `swift scripts/bench/model-bench.swift <path>`, but then the allocation
// count will be 0 only if DYLD_INSERT_LIBRARIES points at libcount.dylib built from count.c --
// model-bench.sh does this for you.
import Accelerate
import CoreML
import Foundation

var args = Array(CommandLine.arguments.dropFirst())
let wantCoreML = args.contains("--coreml")
args.removeAll { $0 == "--coreml" }

let defaultModelPath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // scripts/bench
    .deletingLastPathComponent() // scripts
    .deletingLastPathComponent() // repo root
    .appendingPathComponent("App/Loopbacker/Resources/DPDFNet2_48k.mlmodelc")
    .path

let modelPath = args.first ?? defaultModelPath
let frames = 600
let bins = 481, specCount = bins * 2

guard FileManager.default.fileExists(atPath: modelPath) else {
    FileHandle.standardError.write("model-bench: no model at \(modelPath)\n".data(using: .utf8)!)
    exit(1)
}

// Metadata (state size + initial state prefix) always comes from Core ML's model description,
// which is cheap to load even when we don't run inference through it.
let cfg = MLModelConfiguration()
cfg.computeUnits = .cpuOnly
let mlDescribe = try MLModel(contentsOf: URL(fileURLWithPath: modelPath), configuration: cfg)
let meta = mlDescribe.modelDescription.metadata[.creatorDefinedKey] as! [String: String]
let stateSize = Int(meta["state_size"]!)!
let prefix = meta["state_init"]!.split(separator: ",").map { Float($0)! }
let initial = prefix + [Float](repeating: 0, count: stateSize - prefix.count)

// Speech-like synthetic input: decaying spectrum, varying loudness, random phase. Fixed seed
// so runs are comparable.
var rng = SplitMix64(seed: 0xC0FFEE)
var inputs = [[Float]]()
for f in 0..<frames {
    let loud = Float(1 + 20 * abs(sin(Double(f) / 15)))
    inputs.append((0..<specCount).map { i in
        let k = Float(i / 2)
        return loud * Float(rng.nextUnit() * 2 - 1) / (1 + k / 40)
    })
}

struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func nextUnit() -> Double { Double(next() >> 11) * (1.0 / 9007199254740992.0) }
}

func coreML() throws -> [[Float]] {
    let spec = try MLMultiArray(shape: [1, 1, NSNumber(value: bins), 2], dataType: .float32)
    var state = try MLMultiArray(shape: [NSNumber(value: stateSize)], dataType: .float32)
    state.withUnsafeMutableBufferPointer(ofType: Float.self) { p, _ in _ = p.update(fromContentsOf: initial) }
    var out = [[Float]]()
    for f in 0..<frames {
        spec.withUnsafeMutableBufferPointer(ofType: Float.self) { p, _ in _ = p.update(fromContentsOf: inputs[f]) }
        let r = try mlDescribe.prediction(from: MLDictionaryFeatureProvider(dictionary: ["spec": spec, "state_in": state]))
        let e = r.featureValue(for: "spec_e")!.multiArrayValue!
        out.append(e.withUnsafeBufferPointer(ofType: Float.self) { Array($0) })
        state = r.featureValue(for: "state_out")!.multiArrayValue!
    }
    return out
}

func snr(_ ref: [[Float]], _ x: [[Float]]) -> Double {
    var s = 0.0, e = 0.0
    for (a, b) in zip(ref, x) { for (p, q) in zip(a, b) { s += Double(p * p); e += Double((p - q) * (p - q)) } }
    return 10 * log10(s / max(e, 1e-30))
}

final class Bnns {
    let graph: bnns_graph_t
    let ctx: bnns_graph_context_t
    var args: [bnns_graph_argument_t]
    let ws: UnsafeMutableRawPointer, wsSize: Int
    let spec = UnsafeMutablePointer<Float>.allocate(capacity: specCount)
    let specE = UnsafeMutablePointer<Float>.allocate(capacity: specCount)
    let states = (0..<2).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: stateSize) }
    var pp = 0
    let pSpec, pState, pSpecE, pStateOut: Int
    let compileMs: Double

    // Single-thread compile matches how the app runs the graph inline on the audio thread
    // (no internal worker pool competing with the IO thread).
    init() {
        let opts = BNNSGraphCompileOptionsMakeDefault()
        BNNSGraphCompileOptionsSetTargetSingleThread(opts, true)
        let t0 = Date()
        graph = BNNSGraphCompileFromFile(modelPath, nil, opts)
        BNNSGraphCompileOptionsDestroy(opts)
        precondition(graph.data != nil, "BNNS Graph compile failed")
        compileMs = Date().timeIntervalSince(t0) * 1000
        ctx = BNNSGraphContextMake(graph)
        precondition(ctx.data != nil)
        BNNSGraphContextSetArgumentType(ctx, BNNSGraphArgumentTypePointer)
        let n = BNNSGraphGetInputCount(graph, nil) + BNNSGraphGetOutputCount(graph, nil)
        args = [bnns_graph_argument_t](repeating: bnns_graph_argument_t(), count: n)
        pSpec = BNNSGraphGetArgumentPosition(graph, nil, "spec")
        pState = BNNSGraphGetArgumentPosition(graph, nil, "state_in")
        pSpecE = BNNSGraphGetArgumentPosition(graph, nil, "spec_e")
        pStateOut = BNNSGraphGetArgumentPosition(graph, nil, "state_out")
        wsSize = BNNSGraphContextGetWorkspaceSize(ctx, nil)
        ws = UnsafeMutableRawPointer.allocate(byteCount: max(wsSize, 1), alignment: 16384)
        reset()
    }

    func reset() {
        states[0].update(from: initial, count: stateSize)
        states[1].update(repeating: 0, count: stateSize)
        pp = 0
    }

    @inline(__always) func step() {
        args[pSpec].data_ptr = UnsafeMutableRawPointer(spec); args[pSpec].data_ptr_size = specCount * 4
        args[pSpecE].data_ptr = UnsafeMutableRawPointer(specE); args[pSpecE].data_ptr_size = specCount * 4
        args[pState].data_ptr = UnsafeMutableRawPointer(states[pp]); args[pState].data_ptr_size = stateSize * 4
        args[pStateOut].data_ptr = UnsafeMutableRawPointer(states[1 - pp]); args[pStateOut].data_ptr_size = stateSize * 4
        let r = args.withUnsafeMutableBufferPointer {
            BNNSGraphContextExecute(ctx, nil, $0.count, $0.baseAddress!, wsSize, ws.assumingMemoryBound(to: CChar.self))
        }
        precondition(r == 0, "BNNS Graph execute failed \(r)")
        pp = 1 - pp
    }
}

let b = Bnns()
print(String(format: "compile: %.0f ms (single-thread, workspace %d bytes)", b.compileMs, b.wsSize))

if wantCoreML {
    let ref = try coreML()
    var out = [[Float]]()
    for f in 0..<frames {
        b.spec.update(from: inputs[f], count: specCount)
        b.step()
        out.append(Array(UnsafeBufferPointer(start: b.specE, count: specCount)))
    }
    print(String(format: "parity vs Core ML: %.1f dB SNR", snr(ref, out)))
}

// Hot loop: back-to-back hops with a warm cache, plus allocation count.
b.reset()
lb_count_enable(true)
let c0 = lb_count_get()
let t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
for f in 0..<frames { b.spec.update(from: inputs[f], count: specCount); b.step() }
let t1 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
lb_count_enable(false)
let hotAllocs = lb_count_get() - c0
print(String(format: "hot: %.3f ms/hop over %d hops, %ld heap allocations",
             Double(t1 - t0) / 1e6 / Double(frames), frames, hotAllocs))

// Paced loop: one hop every 10 ms on a time-constraint thread, matching the app's audio IO
// cadence (512 frames @ 48 kHz would be ~10.7 ms; 10 ms is the model's own hop size).
let pacedFrames = 300
let done = DispatchSemaphore(value: 0)
var pacedAllocs = 0
let th = Thread {
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    func ticks(_ ms: Double) -> UInt32 { UInt32(ms * 1e6 * Double(tb.denom) / Double(tb.numer)) }
    var pol = thread_time_constraint_policy_data_t(period: ticks(10), computation: ticks(3), constraint: ticks(10), preemptible: 1)
    let cnt = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size / 4)
    _ = withUnsafeMutablePointer(to: &pol) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(cnt)) {
        thread_policy_set(pthread_mach_thread_np(pthread_self()), thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, cnt)
    } }
    b.reset()
    var walls = [Double](), cpus = [Double]()
    walls.reserveCapacity(pacedFrames)
    cpus.reserveCapacity(pacedFrames)
    lb_count_enable(true)
    let a0 = lb_count_get()
    for f in 0..<pacedFrames {
        b.spec.update(from: inputs[f], count: specCount)
        let w0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW), cpu0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        b.step()
        walls.append(Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - w0) / 1e6)
        cpus.append(Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu0) / 1e6)
        usleep(10_000)
    }
    lb_count_enable(false)
    pacedAllocs = lb_count_get() - a0
    walls.sort(); cpus.sort()
    let p99 = Int(Double(pacedFrames) * 0.99)
    print(String(format: "paced (10 ms period, %d hops): wall median %.3f p99 %.3f max %.3f ms",
                 pacedFrames, walls[pacedFrames / 2], walls[p99], walls[pacedFrames - 1]))
    print(String(format: "paced cpu: median %.3f ms (%.1f%% of a core), p99 %.3f max %.3f ms, %ld heap allocations",
                 cpus[pacedFrames / 2], cpus.reduce(0, +) / Double(pacedFrames) / 10 * 100,
                 cpus[p99], cpus[pacedFrames - 1], pacedAllocs))
    done.signal()
}
th.start()
done.wait()

if pacedAllocs != 0 || hotAllocs != 0 {
    FileHandle.standardError.write("model-bench: non-zero heap allocations on the execute path\n".data(using: .utf8)!)
    exit(1)
}
