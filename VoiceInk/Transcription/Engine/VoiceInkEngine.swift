import Foundation
import SwiftUI
import AVFoundation
import SwiftData
import AppKit
import os

@MainActor
class VoiceInkEngine: NSObject, ObservableObject {
    @Published var recordingState: RecordingState = .idle
    @Published var shouldCancelRecording = false
    var partialTranscript: String = ""
    var currentSession: TranscriptionSession?
    /// Coordinator for parallel mic + system streaming in mixed mode.
    /// Non-nil only while a live mixed recording is in progress.
    private var mixedLiveStreamer: MixedLiveStreamer?
    /// Final labeled transcript captured from `mixedLiveStreamer` on stop,
    /// consumed by `runPipeline` as `prebuiltText` for the saved record.
    private var pendingMixedLiveTranscript: String?
    private var activeRecordingStartID: UUID?

    let recorder = Recorder()
    var recordedFile: URL? = nil
    let recordingsDirectory: URL

    // Injected managers
    let whisperModelManager: WhisperModelManager
    let transcriptionModelManager: TranscriptionModelManager
    weak var recorderUIManager: RecorderUIManager?

    let modelContext: ModelContext
    internal let serviceRegistry: TranscriptionServiceRegistry
    let enhancementService: AIEnhancementService?
    private let pipeline: TranscriptionPipeline

    let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "VoiceInkEngine")

    init(
        modelContext: ModelContext,
        whisperModelManager: WhisperModelManager,
        transcriptionModelManager: TranscriptionModelManager,
        enhancementService: AIEnhancementService? = nil
    ) {
        self.modelContext = modelContext
        self.whisperModelManager = whisperModelManager
        self.transcriptionModelManager = transcriptionModelManager
        self.enhancementService = enhancementService

        let appSupportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.prakashjoshipax.VoiceInk")
        self.recordingsDirectory = appSupportDirectory.appendingPathComponent("Recordings")

        self.serviceRegistry = TranscriptionServiceRegistry(
            modelProvider: whisperModelManager,
            modelsDirectory: whisperModelManager.modelsDirectory,
            modelContext: modelContext
        )
        self.pipeline = TranscriptionPipeline(
            modelContext: modelContext,
            serviceRegistry: serviceRegistry,
            enhancementService: enhancementService
        )

        super.init()

        if let enhancementService {
            PowerModeSessionManager.shared.configure(engine: self, enhancementService: enhancementService)
        }

        setupNotifications()
        createRecordingsDirectoryIfNeeded()
    }

    private func createRecordingsDirectoryIfNeeded() {
        do {
            try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true, attributes: nil)
        } catch {
            logger.error("❌ Error creating recordings directory: \(error.localizedDescription, privacy: .public)")
        }
    }

    func getEnhancementService() -> AIEnhancementService? {
        return enhancementService
    }

    // MARK: - Toggle Record

    func toggleRecord(powerModeId: UUID? = nil) async {
        logger.notice("toggleRecord called – state=\(String(describing: self.recordingState), privacy: .public)")

        if recordingState == .starting {
            logger.notice("toggleRecord: cancelling in-flight recording start")
            shouldCancelRecording = true
            activeRecordingStartID = nil
            await recorder.stopRecording()
            recordedFile = nil
            recordingState = .idle
            return
        }

        if recordingState == .recording {
            activeRecordingStartID = nil
            partialTranscript = ""
            recordingState = .transcribing
            await recorder.stopRecording()
            pendingMixedLiveTranscript = await finalizeMixedLiveStreamingIfNeeded()

            if let recordedFile {
                if !shouldCancelRecording {
                    let transcription = Transcription(
                        text: "",
                        duration: 0,
                        audioFileURL: recordedFile.absoluteString,
                        transcriptionStatus: .pending
                    )
                    modelContext.insert(transcription)
                    try? modelContext.save()
                    NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)

                    await runPipeline(on: transcription, audioURL: recordedFile)
                } else {
                    currentSession?.cancel()
                    currentSession = nil
                    MixedAudioCompanion.removePrimaryAndCompanion(forPrimaryAudioURL: recordedFile)
                    recordingState = .idle
                    await cleanupResources()
                }
            } else {
                logger.error("❌ No recorded file found after stopping recording")
                currentSession?.cancel()
                currentSession = nil
                recordingState = .idle
                await cleanupResources()
            }
        } else {
            logger.notice("toggleRecord: entering start-recording branch")
            guard transcriptionModelManager.currentTranscriptionModel != nil else {
                NotificationManager.shared.showNotification(title: "No AI Model Selected", type: .error)
                return
            }
            shouldCancelRecording = false
            partialTranscript = ""

            requestRecordPermission { [self] granted in
                if granted {
                    Task { @MainActor [self] in
                        let startID = UUID()
                        self.activeRecordingStartID = startID

                        do {
                            let fileName = "\(UUID().uuidString).wav"
                            let permanentURL = self.recordingsDirectory.appendingPathComponent(fileName)
                            self.recordedFile = permanentURL

                            let pendingChunks = OSAllocatedUnfairLock(initialState: [Data]())
                            self.recorder.onAudioChunk = { data in
                                pendingChunks.withLock { $0.append(data) }
                            }

                            self.recordingState = .starting
                            self.logger.notice("toggleRecord: state=starting, starting audio hardware")
                            self.recorder.scheduleSystemMute()

                            try await self.recorder.startRecording(toOutputFile: permanentURL)

                            guard self.activeRecordingStartID == startID,
                                  self.recorderUIManager?.isMiniRecorderVisible ?? false,
                                  !self.shouldCancelRecording else {
                                if self.activeRecordingStartID == startID {
                                    await self.recorder.stopRecording()
                                    self.recordedFile = nil
                                    self.recordingState = .idle
                                    self.activeRecordingStartID = nil
                                }
                                return
                            }

                            self.recordingState = .recording
                            self.logger.notice("toggleRecord: recording started successfully, state=recording")

                            await ActiveWindowService.shared.applyConfiguration(powerModeId: powerModeId)

                            if self.recordingState == .recording,
                               let model = self.transcriptionModelManager.currentTranscriptionModel {
                                if AudioSourceMode.current == .mixed,
                                   model.supportsStreaming,
                                   model.provider == .fluidAudio,
                                   self.isStreamingEnabled(for: model),
                                   let mixedRec = self.recorder.mixedAudioRecorder {
                                    try await self.startMixedLiveStreaming(
                                        model: model,
                                        mixedRecorder: mixedRec,
                                        bufferedChunks: pendingChunks
                                    )
                                } else {
                                    let session = self.serviceRegistry.createSession(
                                        for: model,
                                        onPartialTranscript: { [weak self] partial in
                                            Task { @MainActor in
                                                self?.partialTranscript = partial
                                            }
                                        }
                                    )
                                    self.currentSession = session
                                    let realCallback = try await session.prepare(model: model)

                                    if let realCallback {
                                        self.recorder.onAudioChunk = realCallback
                                        let buffered = pendingChunks.withLock { chunks -> [Data] in
                                            let result = chunks
                                            chunks.removeAll()
                                            return result
                                        }
                                        for chunk in buffered { realCallback(chunk) }
                                    } else {
                                        self.recorder.onAudioChunk = nil
                                        pendingChunks.withLock { $0.removeAll() }
                                    }
                                }
                            }

                            Task.detached { [weak self] in
                                guard let self else { return }

                                if let model = await self.transcriptionModelManager.currentTranscriptionModel,
                                   model.provider == .whisper {
                                    if let localWhisperModel = await self.whisperModelManager.availableModels.first(where: { $0.name == model.name }),
                                       await self.whisperModelManager.whisperContext == nil {
                                        do {
                                            try await self.whisperModelManager.loadModel(localWhisperModel)
                                        } catch {
                                            await self.logger.error("❌ Model loading failed: \(error.localizedDescription, privacy: .public)")
                                        }
                                    }
                                } else if let fluidAudioModel = await self.transcriptionModelManager.currentTranscriptionModel as? FluidAudioModel {
                                    try? await self.serviceRegistry.fluidAudioTranscriptionService.loadModel(for: fluidAudioModel)
                                }

                                if let enhancementService = await self.enhancementService {
                                    await MainActor.run {
                                        enhancementService.captureClipboardContext()
                                    }
                                    await enhancementService.captureScreenContext()
                                }
                            }

                        } catch {
                            let message = Self.recordingStartErrorMessage(error)
                            self.logger.error("❌ Failed to start recording: \(message, privacy: .public)")
                            self.recordingState = .idle
                            self.recordedFile = nil
                            self.activeRecordingStartID = nil
                            await NotificationManager.shared.showNotification(title: message, type: .error)
                            self.logger.notice("toggleRecord: calling dismissMiniRecorder from error handler")
                            await self.recorderUIManager?.dismissMiniRecorder()
                        }
                    }
                } else {
                    logger.error("❌ Recording permission denied.")
                }
            }
        }
    }

    private func requestRecordPermission(response: @escaping (Bool) -> Void) {
        response(true)
    }

    private static func recordingStartErrorMessage(_ error: Error) -> String {
        if case Recorder.RecorderError.couldNotStartRecording(let message) = error {
            return message
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: - Mixed-Mode Live Streaming

    /// Matches `TranscriptionServiceRegistry.supportsStreaming(model:)` for the
    /// model-level toggle ("streaming-enabled-<name>") which defaults to true.
    private func isStreamingEnabled(for model: any TranscriptionModel) -> Bool {
        UserDefaults.standard.object(forKey: "streaming-enabled-\(model.name)") as? Bool ?? true
    }

    /// Spins up two parallel FluidAudio streaming providers and wires the
    /// recorder's mic and system chunks to them. Merged `[ME]:`/`[THEM]:`
    /// partials feed `partialTranscript` while recording is active.
    private func startMixedLiveStreaming(
        model: any TranscriptionModel,
        mixedRecorder: MixedAudioRecorder,
        bufferedChunks: OSAllocatedUnfairLock<[Data]>
    ) async throws {
        let streamer = MixedLiveStreamer(
            fluidAudioService: serviceRegistry.fluidAudioTranscriptionService,
            onPartialUpdate: { [weak self] partial in
                Task { @MainActor in self?.partialTranscript = partial }
            }
        )
        try await streamer.connect(model: model, language: nil)
        mixedLiveStreamer = streamer

        // Buffered chunks captured before this point arrived on the mic source
        // (legacy `onAudioChunk` setter); replay them into the mic provider.
        let buffered = bufferedChunks.withLock { chunks -> [Data] in
            let result = chunks
            chunks.removeAll()
            return result
        }
        for chunk in buffered {
            try? await streamer.sendMicChunk(chunk)
        }

        recorder.onAudioChunk = nil
        mixedRecorder.onMicAudioChunk = { data in
            Task { try? await streamer.sendMicChunk(data) }
        }
        mixedRecorder.onSystemAudioChunk = { data in
            Task { try? await streamer.sendSystemChunk(data) }
        }
    }

    /// Commits, drains, and tears down the mixed live streamer if it was
    /// active, returning its final labeled transcript for `pipeline.run` to
    /// consume as `prebuiltText`.
    private func finalizeMixedLiveStreamingIfNeeded() async -> String? {
        guard let streamer = mixedLiveStreamer else { return nil }
        mixedLiveStreamer = nil
        await streamer.commit()
        let final = streamer.finalTranscript()
        await streamer.disconnect()
        return final.isEmpty ? nil : final
    }

    // MARK: - Pipeline Dispatch

    private func runPipeline(on transcription: Transcription, audioURL: URL) async {
        guard let model = transcriptionModelManager.currentTranscriptionModel else {
            transcription.text = "Transcription Failed: No model selected"
            transcription.transcriptionStatus = TranscriptionStatus.failed.rawValue
            try? modelContext.save()
            recordingState = .idle
            return
        }

        let session = currentSession
        currentSession = nil

        var prebuiltText: String? = nil
        if let mixedLive = pendingMixedLiveTranscript {
            pendingMixedLiveTranscript = nil
            prebuiltText = mixedLive
        } else if let companionURL = recorder.companionAudioURL,
                  model.provider == .whisper {
            do {
                let mixedTranscriber = MixedTranscriber(modelProvider: whisperModelManager)
                prebuiltText = try await mixedTranscriber.transcribe(
                    micURL: audioURL,
                    systemURL: companionURL,
                    model: model
                )
            } catch {
                logger.error("Mixed-mode transcription failed: \(error.localizedDescription, privacy: .public)")
                transcription.text = "Transcription Failed: \(error.localizedDescription)"
                transcription.transcriptionStatus = TranscriptionStatus.failed.rawValue
                try? modelContext.save()
                await recorderUIManager?.dismissMiniRecorder()
                recordingState = .idle
                return
            }
        }
        // Companion WAV (system audio for mixed mode) is retained on disk so
        // it can be re-processed later from the history view.

        await pipeline.run(
            transcription: transcription,
            audioURL: audioURL,
            model: model,
            session: session,
            prebuiltText: prebuiltText,
            onStateChange: { [weak self] state in self?.recordingState = state },
            shouldCancel: { [weak self] in self?.shouldCancelRecording ?? false },
            onCleanup: { [weak self] in await self?.cleanupResources() },
            onDismiss: { [weak self] in await self?.recorderUIManager?.dismissMiniRecorder() }
        )

        shouldCancelRecording = false
        if recordingState != .idle {
            recordingState = .idle
        }
    }

    // MARK: - Resource Cleanup

    func cleanupResources() async {
        logger.notice("cleanupResources: releasing model resources")
        activeRecordingStartID = nil
        await whisperModelManager.cleanupResources()
        await serviceRegistry.cleanup()
        logger.notice("cleanupResources: completed")
    }

    // MARK: - Notification Handling

    func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLicenseStatusChanged),
            name: .licenseStatusChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePromptChange),
            name: .promptDidChange,
            object: nil
        )
    }

    @objc func handleLicenseStatusChanged() {
        pipeline.licenseViewModel = LicenseViewModel()
    }

    @objc func handlePromptChange() {
        Task {
            let currentPrompt = UserDefaults.standard.string(forKey: "TranscriptionPrompt")
                ?? whisperModelManager.whisperPrompt.transcriptionPrompt
            if let context = whisperModelManager.whisperContext {
                await context.setPrompt(currentPrompt)
            }
        }
    }
}
