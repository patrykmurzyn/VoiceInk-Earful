import Foundation
import SwiftData

/// A utility class that manages automatic cleanup of audio files while preserving transcript data
class AudioCleanupManager {
    static let shared = AudioCleanupManager()

    private var cleanupTimer: Timer?
    
    // Default cleanup settings
    private let defaultRetentionDays = 7
    private let cleanupCheckInterval: TimeInterval = 86400 // Check once per day (in seconds)
    
    private init() {}
    
    /// Start the automatic cleanup process
    func startAutomaticCleanup(modelContext: ModelContext) {
        // Cancel any existing timer
        cleanupTimer?.invalidate()

        // Perform initial cleanup
        Task {
            await performCleanup(modelContext: modelContext)
        }

        // Schedule regular cleanup
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: cleanupCheckInterval, repeats: true) { [weak self] _ in
            Task { [weak self] in
                await self?.performCleanup(modelContext: modelContext)
            }
        }
    }
    
    /// Stop the automatic cleanup process
    func stopAutomaticCleanup() {
        cleanupTimer?.invalidate()
        cleanupTimer = nil
    }
    
    /// Get information about the files that would be cleaned up
    func getCleanupInfo(modelContext: ModelContext) async -> (fileCount: Int, totalSize: Int64, transcriptions: [Transcription]) {
        // Get retention period from UserDefaults
        let effectiveRetentionDays = UserDefaults.standard.integer(forKey: "AudioRetentionPeriod")

        // Calculate the cutoff date
        let calendar = Calendar.current
        guard let cutoffDate = calendar.date(byAdding: .day, value: -effectiveRetentionDays, to: Date()) else {
            return (0, 0, [])
        }

        do {
            // Execute SwiftData operations on the main thread
            return try await MainActor.run {
                // Create a predicate to find transcriptions with audio files older than the cutoff date
                let descriptor = FetchDescriptor<Transcription>(
                    predicate: #Predicate<Transcription> { transcription in
                        transcription.timestamp < cutoffDate &&
                        transcription.audioFileURL != nil
                    }
                )

                let transcriptions = try modelContext.fetch(descriptor)

                // Calculate stats (can be done on any thread)
                var fileCount = 0
                var totalSize: Int64 = 0
                var eligibleTranscriptions: [Transcription] = []

                for transcription in transcriptions {
                    if let urlString = transcription.audioFileURL,
                       let url = URL(string: urlString) {
                        var transcriptionSize: Int64 = 0
                        var transcriptionFileCount = 0
                        for candidate in [url, MixedAudioCompanion.systemAudioURL(forPrimaryAudioURL: url)] where FileManager.default.fileExists(atPath: candidate.path) {
                            if let attributes = try? FileManager.default.attributesOfItem(atPath: candidate.path),
                               let fileSize = attributes[.size] as? Int64 {
                                transcriptionSize += fileSize
                                transcriptionFileCount += 1
                            }
                        }
                        if transcriptionFileCount > 0 {
                            totalSize += transcriptionSize
                            fileCount += transcriptionFileCount
                            eligibleTranscriptions.append(transcription)
                        }
                    }
                }

                return (fileCount, totalSize, eligibleTranscriptions)
            }
        } catch {
            return (0, 0, [])
        }
    }
    
    /// Perform the cleanup operation
    private func performCleanup(modelContext: ModelContext) async {
        // Get retention period from UserDefaults
        let effectiveRetentionDays = UserDefaults.standard.integer(forKey: "AudioRetentionPeriod")

        // Check if automatic cleanup is enabled
        let isCleanupEnabled = UserDefaults.standard.bool(forKey: "IsAudioCleanupEnabled")
        guard isCleanupEnabled else { return }

        // Calculate the cutoff date
        let calendar = Calendar.current
        guard let cutoffDate = calendar.date(byAdding: .day, value: -effectiveRetentionDays, to: Date()) else {
            return
        }

        do {
            // Execute SwiftData operations on the main thread
            try await MainActor.run {
                // Create a predicate to find transcriptions with audio files older than the cutoff date
                let descriptor = FetchDescriptor<Transcription>(
                    predicate: #Predicate<Transcription> { transcription in
                        transcription.timestamp < cutoffDate &&
                        transcription.audioFileURL != nil
                    }
                )

                let transcriptions = try modelContext.fetch(descriptor)
                var deletedCount = 0
                var didUpdateTranscription = false

                for transcription in transcriptions {
                    if let urlString = transcription.audioFileURL,
                       let url = URL(string: urlString) {
                        let removal = MixedAudioCompanion.removePrimaryAndCompanion(forPrimaryAudioURL: url)
                        if removal.didFail {
                            continue
                        }
                        if removal.deletedCount > 0 {
                            deletedCount += removal.deletedCount
                        }
                        transcription.audioFileURL = nil
                        didUpdateTranscription = true
                    }
                }

                if didUpdateTranscription {
                    try modelContext.save()
                }
            }
        } catch {
            // Silently fail - cleanup is non-critical
        }
    }
    
    /// Run cleanup manually - can be called from settings
    func runManualCleanup(modelContext: ModelContext) async {
        await performCleanup(modelContext: modelContext)
    }
    
    /// Run cleanup on the specified transcriptions
    func runCleanupForTranscriptions(modelContext: ModelContext, transcriptions: [Transcription]) async -> (deletedCount: Int, errorCount: Int) {
        do {
            // Execute SwiftData operations on the main thread
            return try await MainActor.run {
                var deletedCount = 0
                var errorCount = 0
                var didUpdateTranscription = false

                for transcription in transcriptions {
                    if let urlString = transcription.audioFileURL,
                       let url = URL(string: urlString) {
                        let removal = MixedAudioCompanion.removePrimaryAndCompanion(forPrimaryAudioURL: url)
                        if removal.didFail {
                            errorCount += removal.failedCount
                            continue
                        }
                        deletedCount += removal.deletedCount
                        transcription.audioFileURL = nil
                        didUpdateTranscription = true
                    }
                }

                if didUpdateTranscription {
                    try? modelContext.save()
                }

                return (deletedCount, errorCount)
            }
        } catch {
            return (0, 0)
        }
    }
    
    /// Format file size in human-readable form
    func formatFileSize(_ size: Int64) -> String {
        let byteCountFormatter = ByteCountFormatter()
        byteCountFormatter.allowedUnits = [.useKB, .useMB, .useGB]
        byteCountFormatter.countStyle = .file
        return byteCountFormatter.string(fromByteCount: size)
    }
} 
