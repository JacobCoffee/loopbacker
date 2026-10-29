/// One noise suppression engine, streaming mono 48 kHz audio in fixed hops. `NoiseSuppressor`
/// wraps a kernel with everything engine-independent: hop buffering, the delayed dry blend
/// that caps the reduction, crossfades, and sharing between routes.
///
/// `reset` and `process` run on a capture device's IO thread, one call at a time: no
/// allocation, locks, Objective-C, or blocking.
protocol DenoiseKernel: AnyObject {
    /// Samples consumed and produced per `process` call.
    var hop: Int { get }
    /// Output sample `i` of the `k`-th call since `reset` is the enhanced version of input
    /// sample `k * hop + i - delay` (zeros where that's negative).
    var delay: Int { get }
    /// Returns to the state right after creation: the start of a new stream.
    func reset()
    /// Consumes `hop` samples from `input` (full scale ±1) and writes `hop` samples to
    /// `output`. Returns false if the engine failed; the stream then stays dry.
    func process(_ input: UnsafePointer<Float>, _ output: UnsafeMutablePointer<Float>) -> Bool
}
