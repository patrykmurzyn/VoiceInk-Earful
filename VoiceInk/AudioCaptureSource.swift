import Foundation

/// Capture source for the recording pipeline.
///
/// Implementations write a 16 kHz mono Int16 PCM WAV to the supplied URL and
/// emit identically-shaped chunks via `onAudioChunk` for streaming consumers.
/// Calls to `start` and `stop` are synchronous; implementations that wrap
/// async APIs internally must not be invoked from the main thread.
protocol AudioCaptureSource: AnyObject {
    var onAudioChunk: ((_ data: Data) -> Void)? { get set }
    var averagePower: Float { get }
    var peakPower: Float { get }
    func start(toOutputFile url: URL) throws
    func stop()
}
