// denoise-cli.swift -- runs a 48 kHz mono WAV through one of the app's actual noise
// suppression engines (the literal kernel sources in App/Loopbacker/Sources/Services, compiled
// standalone -- see build.sh) and writes the enhanced signal back out as a 48 kHz mono WAV.
//
// This is the "SAME streaming path the app uses": the exact DenoiseKernel implementations and
// NoiseSuppressor wrapper, fed in fixed-size blocks the way RouteContext feeds a capture
// callback, not a reimplementation. Used by eval.py to build the quality table in
// docs/architecture/ARCHITECTURE.md.
//
// Usage: denoise-cli <engine: dpdfnet|fastenhancer|rnnoise> <input.wav> <output.wav>
//        [--dpdfnet-model path] [--fastenhancer-model path] [--reduction-db -60] [--block 512]
import AVFoundation
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("denoise-cli: \(message)\n".data(using: .utf8)!)
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 3 else {
    fail("usage: denoise-cli <dpdfnet|fastenhancer|rnnoise> <input.wav> <output.wav> [--dpdfnet-model path] [--fastenhancer-model path] [--reduction-db -60] [--block 512]")
}
let engineName = args.removeFirst()
let inputPath = args.removeFirst()
let outputPath = args.removeFirst()

var dpdfnetModelPath: String?
var fastEnhancerModelPath: String?
var reductionDB: Float = -60
var block = 512
var i = 0
while i < args.count {
    switch args[i] {
    case "--dpdfnet-model": i += 1; dpdfnetModelPath = args[i]
    case "--fastenhancer-model": i += 1; fastEnhancerModelPath = args[i]
    case "--reduction-db": i += 1; reductionDB = Float(args[i]) ?? reductionDB
    case "--block": i += 1; block = Int(args[i]) ?? block
    default: fail("unknown argument \(args[i])")
    }
    i += 1
}

guard let engine = NoiseSuppressionEngine(rawValue: engineName) else {
    fail("unknown engine \(engineName); expected dpdfnet, fastenhancer or rnnoise")
}

func makeKernel() -> any DenoiseKernel {
    switch engine {
    case .dpdfnet:
        guard let path = dpdfnetModelPath else { fail("--dpdfnet-model is required for engine dpdfnet") }
        guard let model = NoiseSuppressionModel.load(from: URL(fileURLWithPath: path)) else {
            fail("could not load DPDFNet model at \(path)")
        }
        guard let kernel = DPDFNetKernel(model: model) else { fail("could not create DPDFNet kernel") }
        return kernel
    case .fastenhancer:
        guard let path = fastEnhancerModelPath else { fail("--fastenhancer-model is required for engine fastenhancer") }
        guard let model = FastEnhancerModel.load(from: URL(fileURLWithPath: path)) else {
            fail("could not load FastEnhancer model at \(path)")
        }
        guard let kernel = FastEnhancerKernel(model: model) else { fail("could not create FastEnhancer kernel") }
        return kernel
    case .rnnoise:
        guard let kernel = RNNoiseKernel.make() else { fail("could not create RNNoise kernel") }
        return kernel
    }
}

let kernel = makeKernel()
guard let suppressor = NoiseSuppressor.make(sampleRate: 48_000, engine: engine, kernel: kernel) else {
    fail("NoiseSuppressor.make failed")
}
suppressor.setMaxReduction(dB: reductionDB)
suppressor.setEnabled(true)

// Read the input as mono Float32 @ 48 kHz.
let inputFile: AVAudioFile
do {
    inputFile = try AVAudioFile(forReading: URL(fileURLWithPath: inputPath))
} catch {
    fail("could not open \(inputPath): \(error)")
}
guard inputFile.processingFormat.sampleRate == 48_000 else {
    fail("\(inputPath) is \(inputFile.processingFormat.sampleRate) Hz, expected 48000 Hz")
}
let frameCount = AVAudioFrameCount(inputFile.length)
guard let buffer = AVAudioPCMBuffer(pcmFormat: inputFile.processingFormat, frameCapacity: max(frameCount, 1)) else {
    fail("could not allocate input buffer")
}
do { try inputFile.read(into: buffer) } catch { fail("could not read \(inputPath): \(error)") }
let channels = Int(inputFile.processingFormat.channelCount)
let n = Int(buffer.frameLength)
var mono = [Float](repeating: 0, count: n)
if let data = buffer.floatChannelData {
    if channels == 1 {
        mono.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: data[0], count: n) }
    } else {
        for i in 0..<n {
            var sum: Float = 0
            for c in 0..<channels { sum += data[c][i] }
            mono[i] = sum / Float(channels)
        }
    }
}

// Feed the suppressor in fixed blocks, as a capture callback would, and collect its output.
var output = [Float](repeating: 0, count: n)
var scratch = [Float](repeating: 0, count: block)
var offset = 0
var sampleTime: Float64 = 0
while offset < n {
    let count = min(block, n - offset)
    scratch.withUnsafeMutableBufferPointer { buf in
        for i in 0..<count { buf[i] = mono[offset + i] }
        if count < block { for i in count..<block { buf[i] = 0 } }
        suppressor.process(buf.baseAddress!, frames: count, stride: 1, sampleTime: sampleTime)
    }
    for i in 0..<count { output[offset + i] = scratch[i] }
    offset += count
    sampleTime += Float64(count)
}

func writeWav(_ samples: [Float], to path: String) {
    guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false) else {
        fail("could not build output format")
    }
    let outputFile: AVAudioFile
    do {
        outputFile = try AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: outFormat.settings,
                                      commonFormat: .pcmFormatFloat32, interleaved: false)
    } catch { fail("could not create \(path): \(error)") }
    guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(samples.count)) else {
        fail("could not allocate output buffer")
    }
    outBuffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { outBuffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    do { try outputFile.write(from: outBuffer) } catch { fail("could not write \(path): \(error)") }
    // AVAudioFile only patches the RIFF/data chunk sizes on dealloc; force it before the process
    // exits, or the header is left pointing at zero frames.
}
writeWav(output, to: outputPath)
