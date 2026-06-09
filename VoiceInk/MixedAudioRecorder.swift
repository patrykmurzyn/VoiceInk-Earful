import Foundation
import CoreAudio
import os

/// Captures microphone and system audio in parallel as separate WAV files so
/// the transcription pipeline can label each segment with the speaker source.
///
/// Layout: the primary `url` passed to `start` receives the microphone stream;
/// a companion file at `url.system.wav` receives system audio. Both are
/// 16 kHz mono Int16, matching the format consumed downstream.
///
/// For live streaming consumers, only microphone chunks are forwarded via
/// `onAudioChunk` — mixing chunks in real time would require sample-aligned
/// buffering across two independent capture pipelines and is out of scope.
@available(macOS 13.0, *)
final class MixedAudioRecorder: NSObject, AudioCaptureSource, @unchecked Sendable {

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MixedAudioRecorder")
    private let mic: CoreAudioRecorder
    private let system: SystemAudioRecorder
    private let micNoiseGate = PCM16NoiseGate(
        thresholdDb: -42,
        holdDurationMs: 250,
        sampleRate: 16_000
    )

    private(set) var micFileURL: URL?
    private(set) var systemFileURL: URL?

    var onAudioChunk: ((_ data: Data) -> Void)? {
        didSet { onMicAudioChunk = onAudioChunk }
    }

    /// Chunks emitted by the microphone sub-recorder (16 kHz mono Int16).
    /// Setting this overrides the `onAudioChunk` legacy single-stream sink.
    var onMicAudioChunk: ((_ data: Data) -> Void)? {
        didSet { mic.onAudioChunk = onMicAudioChunk }
    }

    /// Chunks emitted by the system-audio sub-recorder (16 kHz mono Int16).
    /// Only consumers that explicitly need a separated system stream should
    /// set this — e.g. the parallel-streaming coordinator for mixed mode.
    var onSystemAudioChunk: ((_ data: Data) -> Void)? {
        didSet { system.onAudioChunk = onSystemAudioChunk }
    }

    var averagePower: Float {
        max(mic.averagePower, system.averagePower)
    }

    var peakPower: Float {
        max(mic.peakPower, system.peakPower)
    }

    var micAveragePower: Float {
        mic.averagePower
    }

    var micPeakPower: Float {
        mic.peakPower
    }

    var systemAveragePower: Float {
        system.averagePower
    }

    var systemPeakPower: Float {
        system.peakPower
    }

    init(micDeviceID: AudioDeviceID) {
        self.mic = CoreAudioRecorder()
        self.mic.preferredDeviceID = micDeviceID
        self.system = SystemAudioRecorder()
        super.init()
        mic.pcm16OutputProcessor = { [micNoiseGate] samples, count in
            micNoiseGate.process(samples: samples, count: count)
        }
    }

    func start(toOutputFile url: URL) throws {
        let companion = url.deletingPathExtension().appendingPathExtension("system.wav")

        micNoiseGate.reset()
        try mic.start(toOutputFile: url)
        do {
            try system.start(toOutputFile: companion)
        } catch {
            mic.stop()
            throw error
        }
        self.micFileURL = url
        self.systemFileURL = companion
        logger.notice("started mic=\(url.lastPathComponent, privacy: .public) system=\(companion.lastPathComponent, privacy: .public)")
    }

    func stop() {
        mic.stop()
        system.stop()
    }
}

private final class PCM16NoiseGate: @unchecked Sendable {
    private let thresholdRMS: Float
    private let holdSampleCount: Int
    private var remainingHoldSamples: Int = 0

    init(thresholdDb: Float, holdDurationMs: Int, sampleRate: Int) {
        self.thresholdRMS = pow(10, thresholdDb / 20)
        self.holdSampleCount = max(0, sampleRate * holdDurationMs / 1_000)
    }

    func reset() {
        remainingHoldSamples = 0
    }

    func process(samples: UnsafeMutablePointer<Int16>, count: Int) {
        guard count > 0 else { return }

        let rms = Self.rms(samples: samples, count: count)
        if rms >= thresholdRMS {
            remainingHoldSamples = holdSampleCount
            return
        }

        if remainingHoldSamples > 0 {
            remainingHoldSamples = max(0, remainingHoldSamples - count)
            return
        }

        for i in 0..<count {
            samples[i] = 0
        }
    }

    private static func rms(samples: UnsafeMutablePointer<Int16>, count: Int) -> Float {
        var sumSquares: Double = 0
        for i in 0..<count {
            let sample = Double(samples[i]) / 32_768.0
            sumSquares += sample * sample
        }
        return Float((sumSquares / Double(count)).squareRoot())
    }
}
