import FluidAudio
import Foundation
import os

/// Agreement-based on-device streaming transcription using FluidAudio ASR.
final class FluidAudioStreamingProvider: StreamingTranscriptionProvider {

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "FluidAudioStreaming")
    private let fluidAudioService: FluidAudioTranscriptionService
    private var eventsContinuation: AsyncStream<StreamingTranscriptionEvent>.Continuation?

    private(set) var transcriptionEvents: AsyncStream<StreamingTranscriptionEvent>

    private var audioBuffer: [Float] = []
    private let bufferLock = NSLock()
    private let sampleRate: Double = 16000.0
    // Samples trimmed from buffer front; subtract from absolute indices for buffer-relative access.
    private var trimmedSampleCount: Int = 0

    private var asrManager: AsrManager?
    private var decoderLayerCount: Int = 0
    private let agreementEngine: WordAgreementEngine
    private let config: AgreementConfig

    private var transcriptionTask: Task<Void, Never>?
    private var isTranscribing = false
    private let transcriptionStateLock = NSLock()
    private var lastTranscribedSampleCount = 0
    private let minNewSamples = 8000 // ~0.5s

    private enum RemainingAudioTranscription {
        case unavailable
        case transcribed(String)
    }

    init(fluidAudioService: FluidAudioTranscriptionService, config: AgreementConfig = AgreementConfig()) {
        self.fluidAudioService = fluidAudioService
        self.config = config
        self.agreementEngine = WordAgreementEngine(config: config)

        var continuation: AsyncStream<StreamingTranscriptionEvent>.Continuation!
        transcriptionEvents = AsyncStream { continuation = $0 }
        eventsContinuation = continuation
    }

    deinit {
        transcriptionTask?.cancel()
        eventsContinuation?.finish()
    }

    func connect(model: any TranscriptionModel, language: String?) async throws {
        let version: AsrModelVersion = FluidAudioModelManager.asrVersion(for: model.name)
        let models = try await fluidAudioService.getOrLoadModels(for: version)

        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.asrManager = manager
        self.decoderLayerCount = await manager.decoderLayerCount

        agreementEngine.reset()
        audioBuffer = []
        trimmedSampleCount = 0
        lastTranscribedSampleCount = 0

        startTranscriptionLoop()

        eventsContinuation?.yield(.sessionStarted)
        logger.notice("FluidAudio agreement streaming started for \(model.displayName, privacy: .public)")
    }

    func sendAudioChunk(_ data: Data) async throws {
        let samples = Self.convertToFloat32(data)
        bufferLock.lock()
        audioBuffer.append(contentsOf: samples)
        bufferLock.unlock()
    }

    func commit() async throws {
        transcriptionTask?.cancel()
        await transcriptionTask?.value
        transcriptionTask = nil

        // Run a clean final ASR pass on the unconfirmed audio portion.
        switch await transcribeRemainingAudio() {
        case .transcribed(let remainingText):
            eventsContinuation?.yield(.committed(text: remainingText))
        case .unavailable:
            eventsContinuation?.yield(.committed(text: ""))
        }
    }

    /// Finalizes the currently active audio segment and starts the agreement
    /// engine from a clean boundary. Mixed mic+system live transcription uses
    /// this when voice activity detects a pause or an oversized chat bubble.
    func forceSegmentBoundary() async throws {
        guard await waitForTranscriptionSlot() else { return }
        defer { endExclusiveTranscription() }

        let boundarySample: Int
        bufferLock.lock()
        boundarySample = trimmedSampleCount + audioBuffer.count
        bufferLock.unlock()

        let transcription = await transcribeRemainingAudio(upToAbsoluteSample: boundarySample)
        guard case .transcribed(let remainingText) = transcription else {
            return
        }

        eventsContinuation?.yield(.committed(text: remainingText))

        bufferLock.lock()
        let samplesToTrim = min(max(0, boundarySample - trimmedSampleCount), audioBuffer.count)
        if samplesToTrim > 0 {
            audioBuffer.removeFirst(samplesToTrim)
            trimmedSampleCount += samplesToTrim
        }
        lastTranscribedSampleCount = trimmedSampleCount
        bufferLock.unlock()

        agreementEngine.reset()
    }

    func disconnect() async {
        transcriptionTask?.cancel()
        await transcriptionTask?.value
        transcriptionTask = nil

        await asrManager?.cleanup()
        asrManager = nil
        decoderLayerCount = 0

        bufferLock.lock()
        audioBuffer = []
        trimmedSampleCount = 0
        bufferLock.unlock()
        agreementEngine.reset()

        eventsContinuation?.finish()
        logger.notice("FluidAudio agreement streaming disconnected")
    }

    // MARK: - Private

    private func startTranscriptionLoop() {
        transcriptionTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(
                        (self?.config.transcribeIntervalSeconds ?? 1.0) * 1_000_000_000
                    ))
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                await self?.runTranscriptionPass()
            }
        }
    }

    private func runTranscriptionPass() async {
        guard beginExclusiveTranscription() else { return }
        defer { endExclusiveTranscription() }

        guard let asrManager else { return }

        bufferLock.lock()
        let absoluteSampleCount = trimmedSampleCount + audioBuffer.count
        bufferLock.unlock()

        guard absoluteSampleCount - lastTranscribedSampleCount >= minNewSamples else { return }
        guard absoluteSampleCount >= Int(sampleRate) else { return }

        // Seek to the start of the first unconfirmed word so it isn't clipped.
        let seekTime = agreementEngine.hypothesisStartTime > 0
            ? agreementEngine.hypothesisStartTime
            : agreementEngine.confirmedEndTime
        let seekSample = max(0, Int(seekTime * sampleRate))

        bufferLock.lock()
        let bufferRelativeSeek = max(0, seekSample - trimmedSampleCount)
        let sliceEnd = audioBuffer.count
        guard bufferRelativeSeek < sliceEnd else {
            bufferLock.unlock()
            return
        }
        var audioSlice = Array(audioBuffer[bufferRelativeSeek..<sliceEnd])
        bufferLock.unlock()

        // Pad with 1s trailing silence for punctuation capture
        let maxSingleChunkSamples = 240_000
        let trailingSilenceSamples = 16_000
        if audioSlice.count + trailingSilenceSamples <= maxSingleChunkSamples {
            audioSlice += [Float](repeating: 0, count: trailingSilenceSamples)
        }

        guard audioSlice.count >= Int(sampleRate) else { return }

        do {
            var state = TdtDecoderState.make(decoderLayers: decoderLayerCount)
            let result = try await asrManager.transcribe(audioSlice, decoderState: &state)
            lastTranscribedSampleCount = absoluteSampleCount

            guard let tokenTimings = result.tokenTimings, !tokenTimings.isEmpty else {
                if !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    eventsContinuation?.yield(.partial(text: result.text))
                }
                return
            }

            let timeOffset = Double(seekSample) / sampleRate
            let words = WordAgreementEngine.mergeTokensToWords(tokenTimings, timeOffset: timeOffset)
            guard !words.isEmpty else { return }

            let agreementResult = agreementEngine.processTranscriptionResult(words: words, resultConfidence: result.confidence)

            if !agreementResult.newlyConfirmedText.isEmpty {
                let normalizedConfirmed = TextNormalizer.shared.normalizeSentence(agreementResult.newlyConfirmedText)
                eventsContinuation?.yield(.committed(text: normalizedConfirmed))
            }
            if !agreementResult.fullText.isEmpty {
                eventsContinuation?.yield(.partial(text: agreementResult.fullText))
            }

            // Trim audio up to the hypothesis start point, keeping unconfirmed audio intact.
            let newHypothesisStartTime = agreementEngine.hypothesisStartTime
            if newHypothesisStartTime > 0 {
                let safeTrimPoint = max(0, Int(newHypothesisStartTime * sampleRate))
                let samplesToTrim = safeTrimPoint - trimmedSampleCount
                if samplesToTrim > 0 {
                    bufferLock.lock()
                    let actualTrim = min(samplesToTrim, audioBuffer.count)
                    audioBuffer.removeFirst(actualTrim)
                    trimmedSampleCount += actualTrim
                    bufferLock.unlock()
                }
            }

        } catch {
            logger.error("Transcription pass failed: \(error.localizedDescription, privacy: .public)")
            eventsContinuation?.yield(.error(error))
        }
    }

    // Final transcription of audio after the last confirmed word.
    private func transcribeRemainingAudio(upToAbsoluteSample boundarySample: Int? = nil) async -> RemainingAudioTranscription {
        guard let asrManager else { return .unavailable }

        let seekTime = agreementEngine.hypothesisStartTime > 0
            ? agreementEngine.hypothesisStartTime
            : agreementEngine.confirmedEndTime
        let seekSample = max(0, Int(seekTime * sampleRate))

        bufferLock.lock()
        let bufferRelativeSeek = max(0, seekSample - trimmedSampleCount)
        let bufferRelativeEnd = min(
            audioBuffer.count,
            max(0, (boundarySample ?? (trimmedSampleCount + audioBuffer.count)) - trimmedSampleCount)
        )
        guard bufferRelativeSeek < bufferRelativeEnd else {
            bufferLock.unlock()
            return .unavailable
        }
        var samples = Array(audioBuffer[bufferRelativeSeek..<bufferRelativeEnd])
        bufferLock.unlock()

        guard samples.count >= Int(sampleRate) else { return .unavailable }

        let trailingSilenceSamples = 16_000
        let maxSingleChunkSamples = 240_000
        if samples.count + trailingSilenceSamples <= maxSingleChunkSamples {
            samples += [Float](repeating: 0, count: trailingSilenceSamples)
        }

        do {
            var state = TdtDecoderState.make(decoderLayers: decoderLayerCount)
            let result = try await asrManager.transcribe(samples, decoderState: &state)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return .transcribed("") }
            return .transcribed(TextNormalizer.shared.normalizeSentence(text))
        } catch {
            logger.error("Final transcription failed: \(error.localizedDescription, privacy: .public)")
            return .unavailable
        }
    }

    // MARK: - Audio Conversion

    private static func convertToFloat32(_ data: Data) -> [Float] {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        var samples = [Float](repeating: 0, count: sampleCount)
        data.withUnsafeBytes { rawPtr in
            let int16Ptr = rawPtr.bindMemory(to: Int16.self)
            for i in 0..<sampleCount {
                samples[i] = Float(int16Ptr[i]) / 32767.0
            }
        }
        return samples
    }

    private func beginExclusiveTranscription() -> Bool {
        transcriptionStateLock.lock()
        defer { transcriptionStateLock.unlock() }
        guard !isTranscribing else { return false }
        isTranscribing = true
        return true
    }

    private func endExclusiveTranscription() {
        transcriptionStateLock.lock()
        isTranscribing = false
        transcriptionStateLock.unlock()
    }

    private func waitForTranscriptionSlot() async -> Bool {
        for _ in 0..<40 {
            if beginExclusiveTranscription() {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }
}
