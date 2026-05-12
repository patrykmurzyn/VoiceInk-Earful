import Foundation
import os

/// Transcribes a microphone and a system-audio WAV with the same Whisper
/// context and interleaves their segments into a single text stream prefixed
/// with `[ME]` / `[THEM]` labels.
///
/// Whisper.cpp is not thread-safe per context, so the two transcriptions run
/// sequentially against the shared `WhisperContext` actor.
final class MixedTranscriber {

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MixedTranscriber")
    private let modelProvider: any WhisperModelProvider

    init(modelProvider: any WhisperModelProvider) {
        self.modelProvider = modelProvider
    }

    func transcribe(micURL: URL, systemURL: URL, model: any TranscriptionModel) async throws -> String {
        guard model.provider == .whisper else {
            throw VoiceInkEngineError.modelLoadFailed
        }
        let context = try await resolveContext(for: model)
        let prompt = UserDefaults.standard.string(forKey: "TranscriptionPrompt") ?? ""

        await context.setPrompt(prompt)
        let meSegments = try await transcribeFile(at: micURL, with: context)

        await context.setPrompt(prompt)
        let themSegments = try await transcribeFile(at: systemURL, with: context)

        if await modelProvider.whisperContext !== context {
            await context.releaseResources()
        }

        return Self.mergeLabeled(me: meSegments, them: themSegments)
    }

    // MARK: - Helpers

    private func resolveContext(for model: any TranscriptionModel) async throws -> WhisperContext {
        if await modelProvider.isModelLoaded,
           let loaded = await modelProvider.whisperContext,
           await modelProvider.loadedWhisperModel?.name == model.name {
            return loaded
        }
        guard let modelURL = await modelProvider.availableModels.first(where: { $0.name == model.name })?.url,
              FileManager.default.fileExists(atPath: modelURL.path) else {
            logger.error("Model file not found for: \(model.name, privacy: .public)")
            throw VoiceInkEngineError.modelLoadFailed
        }
        do {
            return try await WhisperContext.createContext(path: modelURL.path)
        } catch {
            logger.error("Failed to load model: \(error.localizedDescription, privacy: .public)")
            throw VoiceInkEngineError.modelLoadFailed
        }
    }

    private func transcribeFile(at url: URL, with context: WhisperContext) async throws -> [WhisperSegment] {
        let samples = try readAudioSamples(url)
        let ok = await context.fullTranscribe(samples: samples, disableVAD: true)
        guard ok else {
            logger.error("whisper_full failed for \(url.lastPathComponent, privacy: .public)")
            throw VoiceInkEngineError.whisperCoreFailed
        }
        return await context.getSegments()
    }

    private func readAudioSamples(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        return stride(from: 44, to: data.count, by: 2).map {
            data[$0..<$0 + 2].withUnsafeBytes {
                let short = Int16(littleEndian: $0.load(as: Int16.self))
                return max(-1.0, min(Float(short) / 32_767.0, 1.0))
            }
        }
    }

    /// Sort-merge two segment lists by start timestamp, dropping empty text
    /// and trimming whitespace. Ties resolve to `[ME]` first so the user's
    /// own line is preserved when both sides start the same millisecond.
    static func mergeLabeled(me: [WhisperSegment], them: [WhisperSegment]) -> String {
        struct Labeled { let order: Int; let t0: Int64; let text: String }

        let meLabeled = me.map { Labeled(order: 0, t0: $0.t0Ms, text: $0.text) }
        let themLabeled = them.map { Labeled(order: 1, t0: $0.t0Ms, text: $0.text) }

        let combined = (meLabeled + themLabeled)
            .map { Labeled(order: $0.order, t0: $0.t0, text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.text.isEmpty }
            .sorted { lhs, rhs in
                lhs.t0 != rhs.t0 ? lhs.t0 < rhs.t0 : lhs.order < rhs.order
            }

        return combined
            .map { "[\($0.order == 0 ? "ME" : "THEM")]: \($0.text)" }
            .joined(separator: "\n")
    }
}
