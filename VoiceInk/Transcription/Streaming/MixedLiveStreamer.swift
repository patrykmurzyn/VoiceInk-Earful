import Foundation
import os

/// Drives two parallel `FluidAudioStreamingProvider`s — one fed by mic chunks,
/// one fed by system-audio chunks — and merges their partial / committed
/// events into a single timestamp-ordered live transcript prefixed with
/// `[ME]:` / `[THEM]:` labels.
///
/// The class is intentionally agnostic of how the UI consumes the merged
/// transcript: it just calls `onPartialUpdate` whenever the snapshot changes.
@available(macOS 13.0, *)
final class MixedLiveStreamer: @unchecked Sendable {

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MixedLiveStreamer")
    private let micProvider: FluidAudioStreamingProvider
    private let systemProvider: FluidAudioStreamingProvider
    private let onPartialUpdate: @Sendable (String) -> Void

    private struct LabeledLine {
        let label: Label
        let text: String
        let timestamp: Date
    }

    enum Label: String {
        case me = "ME"
        case them = "THEM"
    }

    private let stateLock = NSLock()
    private var committedLines: [LabeledLine] = []
    private var micPartial: String = ""
    private var systemPartial: String = ""
    private var micPartialLastUpdate: Date?
    private var systemPartialLastUpdate: Date?
    private var micLastVoiceActivity: Date?
    private var systemLastVoiceActivity: Date?
    private var micSegmentStartedAt: Date?
    private var systemSegmentStartedAt: Date?
    private var micSegmentBoundaryAt: Date?
    private var systemSegmentBoundaryAt: Date?
    private var micBoundaryInFlight = false
    private var systemBoundaryInFlight = false
    private var micCommitWaiter: AsyncStream<Void>.Continuation?
    private var systemCommitWaiter: AsyncStream<Void>.Continuation?
    /// Running concatenation of every committed bubble per speaker. The
    /// agreement engine emits hypotheses that always contain the already-
    /// confirmed prefix; we strip that prefix before flushing a partial to
    /// avoid duplicating already-committed text into a new bubble.
    private var micCommittedAccumulator: String = ""
    private var systemCommittedAccumulator: String = ""
    /// How long a partial may sit without an update before we ask the ASR
    /// provider to finalize the current audio segment.
    private let partialFlushTimeout: TimeInterval = 2.0
    private let silenceFlushTimeout: TimeInterval = 1.1
    private let maxSegmentDuration: TimeInterval = 12.0
    private let voiceActivityRMSThreshold: Float = 0.006
    private let maxBubbleWordCount = 42
    private let maxBubbleCharacterCount = 240

    private var micEventsTask: Task<Void, Never>?
    private var systemEventsTask: Task<Void, Never>?
    private var flushTickerTask: Task<Void, Never>?

    init(
        fluidAudioService: FluidAudioTranscriptionService,
        onPartialUpdate: @escaping @Sendable (String) -> Void
    ) {
        self.micProvider = FluidAudioStreamingProvider(fluidAudioService: fluidAudioService)
        self.systemProvider = FluidAudioStreamingProvider(fluidAudioService: fluidAudioService)
        self.onPartialUpdate = onPartialUpdate
    }

    func connect(model: any TranscriptionModel, language: String?) async throws {
        try await micProvider.connect(model: model, language: language)
        try await systemProvider.connect(model: model, language: language)
        startConsumingEvents()
        startFlushTicker()
        logger.notice("mixed live streamer connected")
    }

    func sendMicChunk(_ data: Data) async throws {
        noteVoiceActivityIfNeeded(data, label: .me)
        try await micProvider.sendAudioChunk(data)
    }

    func sendSystemChunk(_ data: Data) async throws {
        noteVoiceActivityIfNeeded(data, label: .them)
        try await systemProvider.sendAudioChunk(data)
    }

    func commit() async {
        let micSignal = prepareCommitSignal(label: .me)
        let systemSignal = prepareCommitSignal(label: .them)

        async let micCommit: Void = commitProvider(micProvider, label: .me)
        async let systemCommit: Void = commitProvider(systemProvider, label: .them)
        _ = await (micCommit, systemCommit)

        async let micAck = waitForCommitSignal(micSignal)
        async let systemAck = waitForCommitSignal(systemSignal)
        _ = await (micAck, systemAck)
    }

    func disconnect() async {
        micEventsTask?.cancel()
        systemEventsTask?.cancel()
        flushTickerTask?.cancel()
        await micProvider.disconnect()
        await systemProvider.disconnect()
        micEventsTask = nil
        systemEventsTask = nil
        flushTickerTask = nil
    }

    /// Final merged transcript suitable for saving to the Transcription record.
    func finalTranscript() -> String {
        stateLock.lock(); defer { stateLock.unlock() }
        return buildSnapshotLocked(includePartials: false)
    }

    // MARK: - Private

    private func startConsumingEvents() {
        micEventsTask = Task { [weak self, micProvider] in
            for await event in micProvider.transcriptionEvents {
                self?.handle(event, label: .me)
            }
        }
        systemEventsTask = Task { [weak self, systemProvider] in
            for await event in systemProvider.transcriptionEvents {
                self?.handle(event, label: .them)
            }
        }
    }

    private func handle(_ event: StreamingTranscriptionEvent, label: Label) {
        stateLock.lock()
        switch event {
        case .partial(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch label {
            case .me:
                micPartial = trimmed
                micPartialLastUpdate = trimmed.isEmpty ? nil : Date()
                if !trimmed.isEmpty, micSegmentStartedAt == nil {
                    micSegmentStartedAt = Date()
                }
            case .them:
                systemPartial = trimmed
                systemPartialLastUpdate = trimmed.isEmpty ? nil : Date()
                if !trimmed.isEmpty, systemSegmentStartedAt == nil {
                    systemSegmentStartedAt = Date()
                }
            }
        case .committed(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let committed: String
            let timestamp: Date
            switch label {
            case .me:
                committed = micCommittedAccumulator
                timestamp = micSegmentBoundaryAt ?? micLastVoiceActivity ?? micPartialLastUpdate ?? Date()
            case .them:
                committed = systemCommittedAccumulator
                timestamp = systemSegmentBoundaryAt ?? systemLastVoiceActivity ?? systemPartialLastUpdate ?? Date()
            }
            if let newText = Self.displayablePartial(trimmed, after: committed) {
                committedLines.append(LabeledLine(label: label, text: newText, timestamp: timestamp))
                switch label {
                case .me:   appendCommittedAccumulator(&micCommittedAccumulator, with: newText)
                case .them: appendCommittedAccumulator(&systemCommittedAccumulator, with: newText)
                }
            }
            switch label {
            case .me:
                micPartial = ""
                micPartialLastUpdate = nil
                micLastVoiceActivity = nil
                micSegmentStartedAt = nil
                micSegmentBoundaryAt = nil
                micBoundaryInFlight = false
            case .them:
                systemPartial = ""
                systemPartialLastUpdate = nil
                systemLastVoiceActivity = nil
                systemSegmentStartedAt = nil
                systemSegmentBoundaryAt = nil
                systemBoundaryInFlight = false
            }
            signalCommitLocked(label: label)
        case .sessionStarted, .error:
            break
        }
        let snapshot = buildSnapshotLocked(includePartials: true)
        stateLock.unlock()
        onPartialUpdate(snapshot)
    }

    /// Periodically asks the ASR providers to close stale active segments.
    /// The provider emits the final committed text after it has transcribed
    /// and trimmed the corresponding audio range.
    private func startFlushTicker() {
        flushTickerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { break }
                self?.requestBoundariesForStalePartialsIfNeeded()
            }
        }
    }

    private func requestBoundariesForStalePartialsIfNeeded() {
        stateLock.lock()
        let now = Date()
        var labelsToFinalize: [Label] = []
        if !micPartial.isEmpty,
           !micBoundaryInFlight,
           Self.shouldFinalizeSegment(
               text: micPartial,
               segmentStartedAt: micSegmentStartedAt,
               lastPartialUpdate: micPartialLastUpdate,
               lastVoiceActivity: micLastVoiceActivity,
               now: now,
               silenceTimeout: silenceFlushTimeout,
               partialTimeout: partialFlushTimeout,
               maxSegmentDuration: maxSegmentDuration,
               maxWords: maxBubbleWordCount,
               maxCharacters: maxBubbleCharacterCount
           ) {
            micBoundaryInFlight = true
            micSegmentBoundaryAt = micLastVoiceActivity ?? micPartialLastUpdate ?? now
            labelsToFinalize.append(.me)
        }
        if !systemPartial.isEmpty,
           !systemBoundaryInFlight,
           Self.shouldFinalizeSegment(
               text: systemPartial,
               segmentStartedAt: systemSegmentStartedAt,
               lastPartialUpdate: systemPartialLastUpdate,
               lastVoiceActivity: systemLastVoiceActivity,
               now: now,
               silenceTimeout: silenceFlushTimeout,
               partialTimeout: partialFlushTimeout,
               maxSegmentDuration: maxSegmentDuration,
               maxWords: maxBubbleWordCount,
               maxCharacters: maxBubbleCharacterCount
           ) {
            systemBoundaryInFlight = true
            systemSegmentBoundaryAt = systemLastVoiceActivity ?? systemPartialLastUpdate ?? now
            labelsToFinalize.append(.them)
        }
        stateLock.unlock()

        for label in labelsToFinalize {
            Task { [weak self] in
                await self?.finalizeActiveSegment(label: label)
            }
        }
    }

    private func noteVoiceActivityIfNeeded(_ data: Data, label: Label) {
        guard Self.rmsLevel(forPCM16Data: data) >= voiceActivityRMSThreshold else { return }
        stateLock.lock()
        switch label {
        case .me:
            micLastVoiceActivity = Date()
        case .them:
            systemLastVoiceActivity = Date()
        }
        stateLock.unlock()
    }

    static func shouldFinalizeSegment(
        text: String,
        segmentStartedAt: Date?,
        lastPartialUpdate: Date?,
        lastVoiceActivity: Date?,
        now: Date,
        silenceTimeout: TimeInterval,
        partialTimeout: TimeInterval,
        maxSegmentDuration: TimeInterval,
        maxWords: Int,
        maxCharacters: Int
    ) -> Bool {
        if let lastVoiceActivity,
           now.timeIntervalSince(lastVoiceActivity) >= silenceTimeout {
            return true
        }
        if let lastPartialUpdate,
           now.timeIntervalSince(lastPartialUpdate) >= partialTimeout {
            return true
        }
        if let segmentStartedAt,
           now.timeIntervalSince(segmentStartedAt) >= maxSegmentDuration {
            return true
        }
        if Self.isOversizedBubble(text, maxWords: maxWords, maxCharacters: maxCharacters) {
            return true
        }
        return false
    }

    private func finalizeActiveSegment(label: Label) async {
        do {
            switch label {
            case .me:
                try await micProvider.forceSegmentBoundary()
            case .them:
                try await systemProvider.forceSegmentBoundary()
            }
        } catch {
            logger.error("segment boundary failed for \(label.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        stateLock.lock()
        switch label {
        case .me:
            micBoundaryInFlight = false
        case .them:
            systemBoundaryInFlight = false
        }
        stateLock.unlock()
    }

    private func prepareCommitSignal(label: Label) -> AsyncStream<Void> {
        var continuation: AsyncStream<Void>.Continuation!
        let stream = AsyncStream<Void> { continuation = $0 }
        stateLock.lock()
        switch label {
        case .me:
            micCommitWaiter?.finish()
            micCommitWaiter = continuation
        case .them:
            systemCommitWaiter?.finish()
            systemCommitWaiter = continuation
        }
        stateLock.unlock()
        return stream
    }

    private func commitProvider(_ provider: FluidAudioStreamingProvider, label: Label) async {
        do {
            try await provider.commit()
        } catch {
            logger.error("\(label.rawValue, privacy: .public) commit: \(error.localizedDescription, privacy: .public)")
            stateLock.lock()
            signalCommitLocked(label: label)
            stateLock.unlock()
        }
    }

    private func waitForCommitSignal(_ signal: AsyncStream<Void>) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in signal {
                    return
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
            await group.next()
            group.cancelAll()
        }
    }

    private func signalCommitLocked(label: Label) {
        switch label {
        case .me:
            micCommitWaiter?.yield()
            micCommitWaiter?.finish()
            micCommitWaiter = nil
        case .them:
            systemCommitWaiter?.yield()
            systemCommitWaiter?.finish()
            systemCommitWaiter = nil
        }
    }

    private func appendCommittedAccumulator(_ acc: inout String, with text: String) {
        if acc.isEmpty {
            acc = text
        } else {
            acc += " " + text
        }
    }

    /// Returns the part of `partial` that does not overlap with the
    /// already-committed prefix, comparing whitespace- and punctuation-
    /// normalized tokens. Returns `nil` when the partial is fully covered.
    static func subtractCommittedPrefix(partial: String, committed: String) -> String? {
        guard !committed.isEmpty else { return partial }
        let partialTokens = partial.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let committedTokens = committed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !partialTokens.isEmpty, !committedTokens.isEmpty else { return partial }

        func normalize(_ token: String) -> String {
            token.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters)
        }

        var i = 0
        let limit = min(partialTokens.count, committedTokens.count)
        while i < limit, normalize(partialTokens[i]) == normalize(committedTokens[i]) {
            i += 1
        }
        guard i < partialTokens.count else { return nil }
        return partialTokens[i...].joined(separator: " ")
    }

    static func displayablePartial(_ partial: String, after committed: String) -> String? {
        let trimmed = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let tail = subtractCommittedPrefix(partial: trimmed, committed: committed)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !tail.isEmpty else {
            return nil
        }
        return tail
    }

    static func isOversizedBubble(_ text: String, maxWords: Int, maxCharacters: Int) -> Bool {
        if text.count >= maxCharacters { return true }
        return text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count >= maxWords
    }

    static func rmsLevel(forPCM16Data data: Data) -> Float {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return 0 }

        var sumSquares: Double = 0
        data.withUnsafeBytes { rawPtr in
            let int16Ptr = rawPtr.bindMemory(to: Int16.self)
            for i in 0..<sampleCount {
                let sample = Double(int16Ptr[i]) / 32767.0
                sumSquares += sample * sample
            }
        }
        return Float((sumSquares / Double(sampleCount)).squareRoot())
    }

    /// Caller must hold `stateLock`.
    private func buildSnapshotLocked(includePartials: Bool) -> String {
        var lines: [String] = committedLines
            .sorted { $0.timestamp < $1.timestamp }
            .map { "[\($0.label.rawValue)]: \($0.text)" }
        if includePartials {
            // The `~` suffix distinguishes a live (still-changing) partial
            // from a committed bubble — the UI renders these with reduced
            // opacity so the user knows that text may still be revised.
            if let micTail = Self.displayablePartial(micPartial, after: micCommittedAccumulator) {
                lines.append("[\(Label.me.rawValue)~]: \(micTail)")
            }
            if let systemTail = Self.displayablePartial(systemPartial, after: systemCommittedAccumulator) {
                lines.append("[\(Label.them.rawValue)~]: \(systemTail)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
