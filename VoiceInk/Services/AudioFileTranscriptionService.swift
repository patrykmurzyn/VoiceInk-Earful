import Foundation
import SwiftUI
import AVFoundation
import SwiftData
import os

@MainActor
class AudioTranscriptionService: ObservableObject {
    @Published var isTranscribing = false
    @Published var currentError: TranscriptionError?

    private let modelContext: ModelContext
    private let enhancementService: AIEnhancementService?
    private let promptDetectionService = PromptDetectionService()
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "AudioTranscriptionService")
    private let serviceRegistry: TranscriptionServiceRegistry
    private let whisperModelProvider: (any WhisperModelProvider)?

    enum TranscriptionError: Error, LocalizedError {
        case noAudioFile
        case transcriptionFailed
        case modelNotLoaded
        case invalidAudioFormat
        case mixedRetranscriptionRequiresWhisper

        var errorDescription: String? {
            switch self {
            case .noAudioFile:
                return "Audio file not found"
            case .transcriptionFailed:
                return "Transcription failed"
            case .modelNotLoaded:
                return "Model not loaded"
            case .invalidAudioFormat:
                return "Invalid audio format"
            case .mixedRetranscriptionRequiresWhisper:
                return "Mixed mic + system retranscription requires a Whisper model"
            }
        }
    }

    init(modelContext: ModelContext, engine: VoiceInkEngine) {
        self.modelContext = modelContext
        self.enhancementService = engine.enhancementService
        self.serviceRegistry = TranscriptionServiceRegistry(modelProvider: engine.whisperModelManager, modelsDirectory: engine.whisperModelManager.modelsDirectory, modelContext: modelContext)
        self.whisperModelProvider = engine.whisperModelManager
    }

    init(
        modelContext: ModelContext,
        serviceRegistry: TranscriptionServiceRegistry,
        enhancementService: AIEnhancementService?,
        whisperModelProvider: (any WhisperModelProvider)? = nil
    ) {
        self.modelContext = modelContext
        self.enhancementService = enhancementService
        self.serviceRegistry = serviceRegistry
        self.whisperModelProvider = whisperModelProvider
    }
    
    func retranscribeAudio(from url: URL, using model: any TranscriptionModel) async throws -> Transcription {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TranscriptionError.noAudioFile
        }
        
        await MainActor.run {
            isTranscribing = true
        }
        
        do {
            let transcriptionStart = Date()
            let systemAudioURL = MixedAudioCompanion.existingSystemAudioURL(forPrimaryAudioURL: url)
            var text: String
            if let systemAudioURL {
                guard model.provider == .whisper,
                      let whisperModelProvider else {
                    throw TranscriptionError.mixedRetranscriptionRequiresWhisper
                }
                let mixedTranscriber = MixedTranscriber(modelProvider: whisperModelProvider)
                text = try await mixedTranscriber.transcribe(micURL: url, systemURL: systemAudioURL, model: model)
            } else {
                text = try await serviceRegistry.transcribe(audioURL: url, model: model)
            }
            let transcriptionDuration = Date().timeIntervalSince(transcriptionStart)
            text = TranscriptionOutputFilter.filter(text)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)

            let powerModeManager = PowerModeManager.shared
            let activePowerModeConfig = powerModeManager.currentActiveConfiguration
            let powerModeName = (activePowerModeConfig?.isEnabled == true) ? activePowerModeConfig?.name : nil
            let powerModeEmoji = (activePowerModeConfig?.isEnabled == true) ? activePowerModeConfig?.emoji : nil

            if UserDefaults.standard.bool(forKey: "IsTextFormattingEnabled") {
                text = WhisperTextFormatter.format(text)
            }

            text = WordReplacementService.shared.applyReplacements(to: text, using: modelContext)
            logger.notice("✅ Word replacements applied")
            let cleanedText = TranscriptionOutputFilter.applyUserCleanupPreferences(text)

            let audioAsset = AVURLAsset(url: url)
            let duration = CMTimeGetSeconds(try await audioAsset.load(.duration))
            let recordingsDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("com.prakashjoshipax.VoiceInk")
                .appendingPathComponent("Recordings")
            
            let fileName = "retranscribed_\(UUID().uuidString).wav"
            let permanentURL = recordingsDirectory.appendingPathComponent(fileName)
            
            do {
                try FileManager.default.copyItem(at: url, to: permanentURL)
                if let systemAudioURL {
                    try FileManager.default.copyItem(
                        at: systemAudioURL,
                        to: MixedAudioCompanion.systemAudioURL(forPrimaryAudioURL: permanentURL)
                    )
                }
            } catch {
                logger.error("❌ Failed to create permanent copy of audio: \(error.localizedDescription, privacy: .public)")
                isTranscribing = false
                throw error
            }
            
            let permanentURLString = permanentURL.absoluteString

            // Apply prompt detection for trigger words
            let originalText = cleanedText
            var promptDetectionResult: PromptDetectionService.PromptDetectionResult? = nil

            if let enhancementService = enhancementService, enhancementService.isConfigured {
                let detectionResult = await promptDetectionService.analyzeText(text, with: enhancementService)
                promptDetectionResult = detectionResult
                await promptDetectionService.applyDetectionResult(detectionResult, to: enhancementService)
            }

            // Apply AI enhancement if enabled
            if let enhancementService = enhancementService,
               enhancementService.isEnhancementEnabled,
               enhancementService.isConfigured {
                do {
                    let textForAI = promptDetectionResult?.processedText ?? text
                    let (enhancedText, enhancementDuration, promptName) = try await enhancementService.enhance(textForAI)
                    let newTranscription = Transcription(
                        text: originalText,
                        duration: duration,
                        enhancedText: enhancedText,
                        audioFileURL: permanentURLString,
                        transcriptionModelName: model.displayName,
                        aiEnhancementModelName: enhancementService.getAIService()?.currentModel,
                        promptName: promptName,
                        transcriptionDuration: transcriptionDuration,
                        enhancementDuration: enhancementDuration,
                        aiRequestSystemMessage: enhancementService.lastSystemMessageSent,
                        aiRequestUserMessage: enhancementService.lastUserMessageSent,
                        powerModeName: powerModeName,
                        powerModeEmoji: powerModeEmoji
                    )
                    modelContext.insert(newTranscription)
                    do {
                        try modelContext.save()
                        NotificationCenter.default.post(name: .transcriptionCreated, object: newTranscription)
                        NotificationCenter.default.post(name: .transcriptionCompleted, object: newTranscription)
                    } catch {
                        logger.error("❌ Failed to save transcription: \(error.localizedDescription, privacy: .public)")
                    }

                    // Restore original prompt settings if AI was temporarily enabled
                    if let result = promptDetectionResult,
                       result.shouldEnableAI {
                        await promptDetectionService.restoreOriginalSettings(result, to: enhancementService)
                    }

                    await MainActor.run {
                        isTranscribing = false
                    }

                    return newTranscription
                } catch {
                    let newTranscription = Transcription(
                        text: originalText,
                        duration: duration,
                        audioFileURL: permanentURLString,
                        transcriptionModelName: model.displayName,
                        promptName: nil,
                        transcriptionDuration: transcriptionDuration,
                        powerModeName: powerModeName,
                        powerModeEmoji: powerModeEmoji
                    )
                    modelContext.insert(newTranscription)
                    do {
                        try modelContext.save()
                        NotificationCenter.default.post(name: .transcriptionCreated, object: newTranscription)
                        NotificationCenter.default.post(name: .transcriptionCompleted, object: newTranscription)
                    } catch {
                        logger.error("❌ Failed to save transcription: \(error.localizedDescription, privacy: .public)")
                    }

                    await MainActor.run {
                        isTranscribing = false
                    }

                    return newTranscription
                }
            } else {
                let newTranscription = Transcription(
                    text: originalText,
                    duration: duration,
                    audioFileURL: permanentURLString,
                    transcriptionModelName: model.displayName,
                    promptName: nil,
                    transcriptionDuration: transcriptionDuration,
                    powerModeName: powerModeName,
                    powerModeEmoji: powerModeEmoji
                )
                modelContext.insert(newTranscription)
                do {
                    try modelContext.save()
                    NotificationCenter.default.post(name: .transcriptionCompleted, object: newTranscription)
                } catch {
                    logger.error("❌ Failed to save transcription: \(error.localizedDescription, privacy: .public)")
                }

                await MainActor.run {
                    isTranscribing = false
                }

                return newTranscription
            }
        } catch {
            logger.error("❌ Transcription failed: \(error.localizedDescription, privacy: .public)")
            currentError = .transcriptionFailed
            isTranscribing = false
            throw error
        }
    }
}
