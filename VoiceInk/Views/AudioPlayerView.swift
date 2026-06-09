import SwiftUI
import AVFoundation

extension TimeInterval {
    func formatTiming() -> String {
        if self < 1 {
            return String(format: "%.0fms", self * 1000)
        }
        if self < 60 {
            return String(format: "%.1fs", self)
        }
        let minutes = Int(self) / 60
        let seconds = self.truncatingRemainder(dividingBy: 60)
        return String(format: "%dm %.0fs", minutes, seconds)
    }
}

class WaveformGenerator {
    private static let cache = NSCache<NSString, NSArray>()

    static func generateWaveformSamples(from url: URL, sampleCount: Int = 200) async -> [Float] {
        let cacheKey = url.absoluteString as NSString

        if let cachedSamples = cache.object(forKey: cacheKey) as? [Float] {
            return cachedSamples
        }
        guard let audioFile = try? AVAudioFile(forReading: url) else { return [] }
        let format = audioFile.processingFormat
        let frameCount = UInt32(audioFile.length)
        let stride = max(1, Int(frameCount) / sampleCount)
        let bufferSize = min(UInt32(4096), frameCount)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: bufferSize) else { return [] }

        do {
            var maxValues = [Float](repeating: 0.0, count: sampleCount)
            var sampleIndex = 0
            var framePosition: AVAudioFramePosition = 0

            while sampleIndex < sampleCount && framePosition < AVAudioFramePosition(frameCount) {
                audioFile.framePosition = framePosition
                try audioFile.read(into: buffer)

                if let channelData = buffer.floatChannelData?[0], buffer.frameLength > 0 {
                    maxValues[sampleIndex] = abs(channelData[0])
                    sampleIndex += 1
                }

                framePosition += AVAudioFramePosition(stride)
            }

            let normalizedSamples: [Float]
            if let maxSample = maxValues.max(), maxSample > 0 {
                normalizedSamples = maxValues.map { $0 / maxSample }
            } else {
                normalizedSamples = maxValues
            }

            cache.setObject(normalizedSamples as NSArray, forKey: cacheKey)
            return normalizedSamples
        } catch {
            print("Error reading audio file: \(error)")
            return []
        }
    }
}

class AudioPlayerManager: ObservableObject {
    private var primaryPlayer: AVAudioPlayer?
    private var systemPlayer: AVAudioPlayer?
    private var timer: Timer?
    private var waveformLoadID = UUID()
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var waveformSamples: [Float] = []
    @Published var systemWaveformSamples: [Float] = []
    @Published var isLoadingWaveform = false
    @Published var isLoadingSystemWaveform = false
    @Published var hasSystemAudio = false
    @Published var playbackRate: Float = {
        let saved = UserDefaults.standard.float(forKey: "audioPlaybackRate")
        return saved > 0 ? saved : 1.0
    }() {
        didSet { UserDefaults.standard.set(playbackRate, forKey: "audioPlaybackRate") }
    }
    
    func loadAudio(from url: URL) {
        do {
            cleanup()
            let loadID = UUID()
            waveformLoadID = loadID
            currentTime = 0
            waveformSamples = []
            systemWaveformSamples = []
            hasSystemAudio = false

            primaryPlayer = try AVAudioPlayer(contentsOf: url)
            primaryPlayer?.enableRate = true
            primaryPlayer?.prepareToPlay()
            duration = primaryPlayer?.duration ?? 0
            isLoadingWaveform = true

            if let systemURL = MixedAudioCompanion.existingSystemAudioURL(forPrimaryAudioURL: url) {
                systemPlayer = try? AVAudioPlayer(contentsOf: systemURL)
                systemPlayer?.enableRate = true
                systemPlayer?.prepareToPlay()
                if let systemDuration = systemPlayer?.duration {
                    duration = max(duration, systemDuration)
                }
                hasSystemAudio = systemPlayer != nil
                isLoadingSystemWaveform = systemPlayer != nil
            }
            
            Task {
                let samples = await WaveformGenerator.generateWaveformSamples(from: url)
                await MainActor.run {
                    guard self.waveformLoadID == loadID else { return }
                    self.waveformSamples = samples
                    self.isLoadingWaveform = false
                }
            }

            if let systemURL = MixedAudioCompanion.existingSystemAudioURL(forPrimaryAudioURL: url), hasSystemAudio {
                Task {
                    let samples = await WaveformGenerator.generateWaveformSamples(from: systemURL)
                    await MainActor.run {
                        guard self.waveformLoadID == loadID else { return }
                        self.systemWaveformSamples = samples
                        self.isLoadingSystemWaveform = false
                    }
                }
            }
        } catch {
            print("Error loading audio: \(error.localizedDescription)")
        }
    }
    
    func play() {
        primaryPlayer?.rate = playbackRate
        systemPlayer?.rate = playbackRate
        let startAt = (primaryPlayer?.deviceCurrentTime ?? 0) + 0.05
        primaryPlayer?.play(atTime: startAt)
        systemPlayer?.play(atTime: startAt)
        isPlaying = true
        startTimer()
    }

    func cyclePlaybackRate() {
        switch playbackRate {
        case 1.0:  playbackRate = 1.5
        case 1.5:  playbackRate = 2.0
        default:   playbackRate = 1.0
        }
        primaryPlayer?.rate = playbackRate
        systemPlayer?.rate = playbackRate
    }
    
    func pause() {
        primaryPlayer?.pause()
        systemPlayer?.pause()
        isPlaying = false
        stopTimer()
    }
    
    func seek(to time: TimeInterval) {
        let clamped = max(0, min(time, duration))
        primaryPlayer?.currentTime = min(clamped, primaryPlayer?.duration ?? clamped)
        systemPlayer?.currentTime = min(clamped, systemPlayer?.duration ?? clamped)
        currentTime = clamped
    }
    
    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.currentTime = max(self.primaryPlayer?.currentTime ?? 0, self.systemPlayer?.currentTime ?? 0)
            if self.currentTime >= self.duration {
                self.pause()
                self.seek(to: 0)
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    func cleanup() {
        waveformLoadID = UUID()
        stopTimer()
        primaryPlayer?.stop()
        systemPlayer?.stop()
        primaryPlayer = nil
        systemPlayer = nil
        isPlaying = false
    }

    deinit {
        cleanup()
    }
}

private func formatTime(_ time: TimeInterval) -> String {
    let minutes = Int(time) / 60
    let seconds = Int(time) % 60
    return String(format: "%d:%02d", minutes, seconds)
}

struct WaveformView: View {
    let samples: [Float]
    let currentTime: TimeInterval
    let duration: TimeInterval
    let isLoading: Bool
    var tint: Color = .primary
    var onSeek: (Double) -> Void
    @State private var isHovering = false
    @State private var hoverLocation: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                if isLoading {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading...")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HStack(spacing: 0.5) {
                        ForEach(0..<samples.count, id: \.self) { index in
                            let progress = duration > 0 ? CGFloat(currentTime / duration) : 0
                            WaveformBar(
                                sample: samples[index],
                                isPlayed: samples.isEmpty ? false : CGFloat(index) / CGFloat(samples.count) <= progress,
                                totalBars: samples.count,
                                geometryWidth: geometry.size.width,
                                isHovering: isHovering,
                                hoverProgress: geometry.size.width > 0 ? hoverLocation / geometry.size.width : 0,
                                tint: tint
                            )
                        }
                    }
                    .opacity(0.6)
                    .frame(maxHeight: .infinity)
                    .padding(.horizontal, 2)

                    if isHovering {
                        Text(formatTime(duration * Double(geometry.size.width > 0 ? hoverLocation / geometry.size.width : 0)))
                            .font(.system(size: 10, weight: .medium))
                            .monospacedDigit()
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(tint))
                            .offset(x: max(0, min(hoverLocation - 25, geometry.size.width - 50)))
                            .offset(y: -26)

                        Rectangle()
                            .fill(tint)
                            .frame(width: 2)
                            .frame(maxHeight: .infinity)
                            .offset(x: hoverLocation)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isLoading {
                            hoverLocation = value.location.x
                            let progress = geometry.size.width > 0 ? Double(value.location.x / geometry.size.width) : 0
                            onSeek(progress * duration)
                        }
                    }
            )
            .onHover { hovering in
                if !isLoading {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isHovering = hovering
                    }
                }
            }
            .onContinuousHover { phase in
                if !isLoading {
                    if case .active(let location) = phase {
                        hoverLocation = location.x
                    }
                }
            }
        }
        .frame(height: 32)
    }
}

struct WaveformBar: View {
    let sample: Float
    let isPlayed: Bool
    let totalBars: Int
    let geometryWidth: CGFloat
    let isHovering: Bool
    let hoverProgress: CGFloat
    let tint: Color
    
    private var isNearHover: Bool {
        let barPosition = geometryWidth / CGFloat(totalBars)
        let hoverPosition = hoverProgress * geometryWidth
        return abs(barPosition - hoverPosition) < 20
    }
    
    var body: some View {
        Capsule()
            .fill(
                LinearGradient(
                    colors: [
                        isPlayed ? tint : tint.opacity(0.3),
                        isPlayed ? tint.opacity(0.8) : tint.opacity(0.2)
                    ],
                    startPoint: .bottom,
                    endPoint: .top
                )
            )
            .frame(
                width: max((geometryWidth / CGFloat(totalBars)) - 0.5, 1),
                height: max(CGFloat(sample) * 24, 2)
            )
            .scaleEffect(y: isHovering && isNearHover ? 1.15 : 1.0)
            .animation(.interpolatingSpring(stiffness: 300, damping: 15), value: isHovering && isNearHover)
    }
}

private struct WaveformTrackView: View {
    let label: String
    let samples: [Float]
    let currentTime: TimeInterval
    let duration: TimeInterval
    let isLoading: Bool
    let tint: Color
    var onSeek: (Double) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .monospaced()
                .foregroundStyle(tint)
                .frame(width: 34, alignment: .trailing)

            WaveformView(
                samples: samples,
                currentTime: currentTime,
                duration: duration,
                isLoading: isLoading,
                tint: tint,
                onSeek: onSeek
            )
        }
    }
}

// MARK: - Reusable Components

private struct CircleIconButton: View {
    let icon: String
    let action: () -> Void
    var fillOpacity: Double = 0.06
    var iconFont: Font = .system(size: 14, weight: .semibold)

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color.primary.opacity(fillOpacity))
                .frame(width: 32, height: 32)
                .overlay(
                    Image(systemName: icon)
                        .font(iconFont)
                        .foregroundStyle(.primary)
                )
        }
        .buttonStyle(.plain)
    }
}

private struct AsyncCircleButton: View {
    let defaultIcon: String
    let isLoading: Bool
    let showSuccess: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color.primary.opacity(0.06))
                .frame(width: 32, height: 32)
                .overlay(
                    Group {
                        if isLoading {
                            ProgressView()
                                .controlSize(.small)
                        } else if showSuccess {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.green)
                        } else {
                            Image(systemName: defaultIcon)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.primary)
                        }
                    }
                )
        }
        .buttonStyle(.plain)
    }
}

private struct StatusBanner: View {
    let message: String
    let isError: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundColor(isError ? .red : .green)
            Text(message)
                .font(.system(size: 14, weight: .medium))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isError ? Color.red.opacity(0.1) : Color.green.opacity(0.1))
                .stroke(isError ? Color.red.opacity(0.2) : Color.green.opacity(0.2), lineWidth: 1)
        )
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - Banner State

private enum BannerState: Equatable {
    case retranscribeSuccess
    case reEnhanceSuccess
    case retranscribeError(String)
    case reEnhanceError(String)
}

// MARK: - AudioPlayerView

struct AudioPlayerView: View {
    let url: URL
    let transcription: Transcription?
    var onInfoTap: (() -> Void)?
    @StateObject private var playerManager = AudioPlayerManager()
    @State private var isHovering = false
    @State private var isRetranscribing = false
    @State private var isReEnhancing = false
    @State private var bannerState: BannerState?
    @State private var showPromptPopover = false
    @EnvironmentObject private var engine: VoiceInkEngine
    @EnvironmentObject private var enhancementService: AIEnhancementService
    @Environment(\.modelContext) private var modelContext

    private var isOperationInProgress: Bool {
        isRetranscribing || isReEnhancing
    }

    private var transcriptionService: AudioTranscriptionService {
        AudioTranscriptionService(modelContext: modelContext, engine: engine)
    }

    var body: some View {
        VStack(spacing: 8) {
            if playerManager.hasSystemAudio {
                VStack(spacing: 4) {
                    WaveformTrackView(
                        label: "ME",
                        samples: playerManager.waveformSamples,
                        currentTime: playerManager.currentTime,
                        duration: playerManager.duration,
                        isLoading: playerManager.isLoadingWaveform,
                        tint: .accentColor,
                        onSeek: { playerManager.seek(to: $0) }
                    )

                    WaveformTrackView(
                        label: "THEM",
                        samples: playerManager.systemWaveformSamples,
                        currentTime: playerManager.currentTime,
                        duration: playerManager.duration,
                        isLoading: playerManager.isLoadingSystemWaveform,
                        tint: .secondary,
                        onSeek: { playerManager.seek(to: $0) }
                    )
                }
                .padding(.horizontal, 10)
            } else {
                WaveformView(
                    samples: playerManager.waveformSamples,
                    currentTime: playerManager.currentTime,
                    duration: playerManager.duration,
                    isLoading: playerManager.isLoadingWaveform,
                    onSeek: { playerManager.seek(to: $0) }
                )
                .padding(.horizontal, 10)
            }

            HStack(spacing: 8) {
                Text(formatTime(playerManager.currentTime))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundColor(.secondary)

                Spacer()

                HStack(spacing: 8) {
                    CircleIconButton(icon: "folder", action: showInFinder)
                        .help("Show in Finder")

                    Button(action: { playerManager.cyclePlaybackRate() }) {
                        Circle()
                            .fill(Color.primary.opacity(playerManager.playbackRate == 1.0 ? 0.06 : 0.14))
                            .frame(width: 32, height: 32)
                            .overlay(
                                Text(playerManager.playbackRate == 1.0 ? "1×" : playerManager.playbackRate == 1.5 ? "1.5×" : "2×")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.primary)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Playback speed")

                    CircleIconButton(
                        icon: enhancementService.activePrompt?.icon ?? "sparkles",
                        action: { showPromptPopover.toggle() }
                    )
                    .opacity(enhancementService.isEnhancementEnabled ? 1.0 : 0.4)
                    .help("Select enhancement prompt")
                    .popover(isPresented: $showPromptPopover, arrowEdge: .bottom) {
                        EnhancementPromptPopover()
                            .environmentObject(enhancementService)
                    }

                    CircleIconButton(
                        icon: playerManager.isPlaying ? "pause.fill" : "play.fill",
                        action: { playerManager.isPlaying ? playerManager.pause() : playerManager.play() }
                    )
                    .scaleEffect(isHovering ? 1.05 : 1.0)
                    .onHover { hovering in
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            isHovering = hovering
                        }
                    }

                    AsyncCircleButton(
                        defaultIcon: "arrow.clockwise",
                        isLoading: isRetranscribing,
                        showSuccess: bannerState == .retranscribeSuccess,
                        action: retranscribeAudio
                    )
                    .disabled(isOperationInProgress)
                    .help("Retranscribe this audio")

                    if transcription != nil {
                        AsyncCircleButton(
                            defaultIcon: "wand.and.stars",
                            isLoading: isReEnhancing,
                            showSuccess: bannerState == .reEnhanceSuccess,
                            action: reEnhanceOnly
                        )
                        .disabled(isOperationInProgress || !enhancementService.isEnhancementEnabled || !enhancementService.isConfigured)
                        .opacity(enhancementService.isEnhancementEnabled && enhancementService.isConfigured ? 1.0 : 0.4)
                        .help("Re-enhance with selected prompt")
                    }

                    if let onInfoTap {
                        CircleIconButton(icon: "info.circle", action: onInfoTap)
                            .help("View details")
                    }
                }

                Spacer()

                Text(formatTime(playerManager.duration))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
        }
        .padding(.top, 8)
        .padding(.bottom, 6)
        .onAppear {
            playerManager.loadAudio(from: url)
        }
        .onDisappear {
            playerManager.cleanup()
        }
        .overlay(
            VStack {
                if let state = bannerState {
                    switch state {
                    case .retranscribeSuccess:
                        StatusBanner(message: "Retranscription successful", isError: false)
                    case .reEnhanceSuccess:
                        StatusBanner(message: "Re-enhancement successful", isError: false)
                    case .retranscribeError(let message):
                        StatusBanner(message: message.isEmpty ? "Retranscription failed" : message, isError: true)
                    case .reEnhanceError(let message):
                        StatusBanner(message: message.isEmpty ? "Re-enhancement failed" : message, isError: true)
                    }
                }
                Spacer()
            }
            .padding(.top, 16)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: bannerState)
        )
    }

    private func showInFinder() {
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
    }

    private func showTemporaryBanner(_ state: BannerState) {
        bannerState = state
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation { bannerState = nil }
        }
    }

    private func reEnhanceOnly() {
        guard let transcription = transcription else { return }

        guard enhancementService.isEnhancementEnabled, enhancementService.isConfigured else {
            showTemporaryBanner(.reEnhanceError("AI Enhancement is not enabled or configured"))
            return
        }

        isReEnhancing = true
        bannerState = nil

        Task {
            do {
                let (enhancedText, enhancementDuration, promptName) = try await enhancementService.enhance(transcription.text)
                await MainActor.run {
                    transcription.enhancedText = enhancedText
                    transcription.aiEnhancementModelName = enhancementService.getAIService()?.currentModel
                    transcription.promptName = promptName
                    transcription.enhancementDuration = enhancementDuration
                    transcription.aiRequestSystemMessage = enhancementService.lastSystemMessageSent
                    transcription.aiRequestUserMessage = enhancementService.lastUserMessageSent
                    try? modelContext.save()

                    isReEnhancing = false
                    showTemporaryBanner(.reEnhanceSuccess)
                }
            } catch {
                await MainActor.run {
                    isReEnhancing = false
                    showTemporaryBanner(.reEnhanceError(error.localizedDescription))
                }
            }
        }
    }

    private func retranscribeAudio() {
        guard let currentTranscriptionModel = engine.transcriptionModelManager.currentTranscriptionModel else {
            showTemporaryBanner(.retranscribeError("No transcription model selected"))
            return
        }

        isRetranscribing = true
        bannerState = nil

        Task {
            do {
                let _ = try await transcriptionService.retranscribeAudio(from: url, using: currentTranscriptionModel)
                await MainActor.run {
                    isRetranscribing = false
                    showTemporaryBanner(.retranscribeSuccess)
                }
            } catch {
                await MainActor.run {
                    isRetranscribing = false
                    showTemporaryBanner(.retranscribeError(error.localizedDescription))
                }
            }
        }
    }
}
