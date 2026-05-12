import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import AudioToolbox
import os

/// Captures system audio via ScreenCaptureKit and writes a 16 kHz mono Int16
/// WAV to disk while emitting chunks of the same format via `onAudioChunk`.
///
/// Exposes a synchronous `AudioCaptureSource` API (matching the existing
/// microphone path) by bridging to `SCStream`'s async lifecycle through a
/// bounded `DispatchSemaphore`. `start`/`stop` therefore must NOT be called
/// from the main thread — `Recorder` already dispatches both through its
/// dedicated `audioSetupQueue`.
@available(macOS 13.0, *)
final class SystemAudioRecorder: NSObject, @unchecked Sendable {

    // MARK: - Configuration

    /// Hard upper bound on how long we wait for `startCapture` / `stopCapture`.
    /// The bridge would otherwise block the calling queue indefinitely if
    /// ScreenCaptureKit hangs (observed under TCC edge cases).
    private static let lifecycleTimeoutSeconds: Int = 10

    private static func lifecycleDeadline() -> DispatchTime {
        .now() + .seconds(lifecycleTimeoutSeconds)
    }

    // MARK: - State

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "SystemAudioRecorder")
    private let outputQueue = DispatchQueue(label: "com.prakashjoshipax.voiceink.systemAudio", qos: .userInteractive)

    private var stream: SCStream?
    private var audioFile: ExtAudioFileRef?
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private let targetFormat: AVAudioFormat

    private let meterLock = NSLock()
    private var _averagePower: Float = -160.0
    private var _peakPower: Float = -160.0

    var averagePower: Float {
        meterLock.lock(); defer { meterLock.unlock() }
        return _averagePower
    }

    var peakPower: Float {
        meterLock.lock(); defer { meterLock.unlock() }
        return _peakPower
    }

    var onAudioChunk: ((_ data: Data) -> Void)?

    // MARK: - Lifecycle

    override init() {
        // 16 kHz mono signed-int PCM is a documented common-format combination
        // for `AVAudioFormat`. Failure here would indicate a corrupt OS install,
        // not a runtime condition we can recover from.
        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ) else {
            fatalError("AVAudioFormat init failed for 16kHz mono Int16")
        }
        self.targetFormat = fmt
        super.init()
    }

    deinit {
        if let af = audioFile {
            ExtAudioFileDispose(af)
        }
    }
}

// MARK: - AudioCaptureSource (sync bridge over async SCStream)

@available(macOS 13.0, *)
extension SystemAudioRecorder: AudioCaptureSource {
    func start(toOutputFile url: URL) throws {
        var caughtError: Error?
        let sem = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try await self?.startAsync(toOutputFile: url)
            } catch {
                caughtError = error
            }
            sem.signal()
        }
        if sem.wait(timeout: Self.lifecycleDeadline()) == .timedOut {
            throw SystemAudioRecorderError.startTimeout
        }
        if let err = caughtError {
            throw err
        }
    }

    func stop() {
        let sem = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.stopAsync()
            sem.signal()
        }
        _ = sem.wait(timeout: Self.lifecycleDeadline())
    }
}

// MARK: - Async core

@available(macOS 13.0, *)
private extension SystemAudioRecorder {

    func startAsync(toOutputFile url: URL) async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch let scError as NSError where scError.domain == SCStreamErrorDomain && scError.code == -3801 {
            throw SystemAudioRecorderError.permissionDenied
        }

        guard let display = content.displays.first else {
            throw SystemAudioRecorderError.noDisplayAvailable
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 16_000
        config.channelCount = 1
        // SCStream requires a video config even for audio-only consumers; keep
        // it as small and infrequent as possible to minimize CPU/GPU overhead.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 6

        try createOutputFile(at: url)

        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)
        try await newStream.startCapture()
        self.stream = newStream
        logger.notice("started → \(url.lastPathComponent, privacy: .public)")
    }

    func stopAsync() async {
        if let s = stream {
            do {
                try await s.stopCapture()
            } catch {
                logger.error("stopCapture: \(error.localizedDescription, privacy: .public)")
            }
            stream = nil
        }
        if let af = audioFile {
            ExtAudioFileDispose(af)
            audioFile = nil
        }
        converter = nil
        sourceFormat = nil

        meterLock.lock()
        _averagePower = -160.0
        _peakPower = -160.0
        meterLock.unlock()
    }

    func createOutputFile(at url: URL) throws {
        var fileFormat = AudioStreamBasicDescription(
            mSampleRate: 16_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )

        var file: ExtAudioFileRef?
        let createStatus = ExtAudioFileCreateWithURL(
            url as CFURL,
            kAudioFileWAVEType,
            &fileFormat,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &file
        )
        guard createStatus == noErr, let f = file else {
            throw SystemAudioRecorderError.failedToCreateFile(status: createStatus)
        }

        var clientFormat = fileFormat
        let setStatus = ExtAudioFileSetProperty(
            f,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &clientFormat
        )
        guard setStatus == noErr else {
            ExtAudioFileDispose(f)
            throw SystemAudioRecorderError.failedToSetFileFormat(status: setStatus)
        }
        self.audioFile = f
    }
}

// MARK: - SCStreamDelegate

@available(macOS 13.0, *)
extension SystemAudioRecorder: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        logger.error("stream stopped: \(error.localizedDescription, privacy: .public)")
    }
}

// MARK: - SCStreamOutput

@available(macOS 13.0, *)
extension SystemAudioRecorder: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio,
              sampleBuffer.isValid,
              let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return
        }

        let asbd = asbdPtr.pointee
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return }

        guard let srcFormat = sourceFormat(for: asbd),
              let inputBuffer = extractPCM(from: sampleBuffer, format: srcFormat, frameCount: frameCount),
              let outputBuffer = convert(inputBuffer, sourceFormat: srcFormat, frameCount: frameCount)
        else { return }

        writeAndEmit(outputBuffer)
    }

    /// Returns the cached `AVAudioFormat` if it still matches `asbd`, otherwise
    /// builds a new one and resets the converter. SCStream is allowed to switch
    /// formats mid-stream (e.g., when the user changes default output device).
    private func sourceFormat(for asbd: AudioStreamBasicDescription) -> AVAudioFormat? {
        if let cached = sourceFormat,
           cached.streamDescription.pointee.mSampleRate == asbd.mSampleRate,
           cached.streamDescription.pointee.mChannelsPerFrame == asbd.mChannelsPerFrame,
           cached.streamDescription.pointee.mFormatFlags == asbd.mFormatFlags,
           cached.streamDescription.pointee.mBitsPerChannel == asbd.mBitsPerChannel {
            return cached
        }
        var asbdCopy = asbd
        guard let fmt = AVAudioFormat(streamDescription: &asbdCopy) else {
            logger.error("could not build AVAudioFormat from incoming ASBD")
            return nil
        }
        sourceFormat = fmt
        converter = AVAudioConverter(from: fmt, to: targetFormat)
        return fmt
    }

    private func extractPCM(from sampleBuffer: CMSampleBuffer, format: AVAudioFormat, frameCount: Int) -> AVAudioPCMBuffer? {
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: pcmBuffer.mutableAudioBufferList
        )
        guard status == noErr else {
            logger.error("CMSampleBufferCopyPCMDataIntoAudioBufferList: OSStatus \(status)")
            return nil
        }
        return pcmBuffer
    }

    private func convert(_ input: AVAudioPCMBuffer, sourceFormat: AVAudioFormat, frameCount: Int) -> AVAudioPCMBuffer? {
        guard let conv = converter else { return nil }

        // Conservative headroom: avoids round-off underestimation when target
        // and source sample rates differ. For 16k→16k it degenerates to +64.
        let capacity = AVAudioFrameCount(
            Double(frameCount) * targetFormat.sampleRate / sourceFormat.sampleRate + 64
        )
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }

        var providedOnce = false
        var convError: NSError?
        // `.noDataNow` (not `.endOfStream`) is essential: signalling end-of-stream
        // here permanently puts the converter into a terminal state and every
        // subsequent buffer would return 0 frames.
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if providedOnce {
                outStatus.pointee = .noDataNow
                return nil
            }
            providedOnce = true
            outStatus.pointee = .haveData
            return input
        }
        let status = conv.convert(to: output, error: &convError, withInputFrom: inputBlock)
        if status == .error {
            if let e = convError {
                logger.error("AVAudioConverter: \(e.localizedDescription, privacy: .public)")
            }
            return nil
        }
        return output.frameLength > 0 ? output : nil
    }

    private func writeAndEmit(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let int16Ptr = buffer.int16ChannelData?[0] else { return }

        if let af = audioFile {
            let writeStatus = ExtAudioFileWrite(af, UInt32(frames), buffer.audioBufferList)
            if writeStatus != noErr {
                logger.error("ExtAudioFileWrite: OSStatus \(writeStatus)")
            }
        }

        updateMeters(samples: int16Ptr, count: frames)

        if let cb = onAudioChunk {
            let byteCount = frames * MemoryLayout<Int16>.size
            cb(Data(bytes: int16Ptr, count: byteCount))
        }
    }

    private func updateMeters(samples: UnsafeMutablePointer<Int16>, count: Int) {
        var sumSquares: Float = 0
        var peak: Float = 0
        for i in 0..<count {
            let s = Float(samples[i]) / 32_768.0
            sumSquares += s * s
            let absS = abs(s)
            if absS > peak { peak = absS }
        }
        let rms = sqrt(sumSquares / Float(count))
        let avgDb = rms > 0 ? 20 * log10f(rms) : -160.0
        let peakDb = peak > 0 ? 20 * log10f(peak) : -160.0

        meterLock.lock()
        _averagePower = avgDb
        _peakPower = peakDb
        meterLock.unlock()
    }
}

// MARK: - Errors

enum SystemAudioRecorderError: Error, LocalizedError {
    case permissionDenied
    case noDisplayAvailable
    case failedToCreateFile(status: OSStatus)
    case failedToSetFileFormat(status: OSStatus)
    case startTimeout

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Screen & System Audio Recording permission is required. Enable VoiceInk in System Settings → Privacy & Security."
        case .noDisplayAvailable:
            return "No display available for system audio capture."
        case .failedToCreateFile(let status):
            return "Failed to create output audio file (OSStatus \(status))."
        case .failedToSetFileFormat(let status):
            return "Failed to configure output audio file format (OSStatus \(status))."
        case .startTimeout:
            return "Timed out waiting for system audio capture to start."
        }
    }
}
