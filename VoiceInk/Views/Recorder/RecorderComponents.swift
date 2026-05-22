import SwiftUI

// MARK: - Shared Popover State

enum ActivePopoverState {
    case none
    case enhancement
    case power
}

// MARK: - Icon Toggle Button

struct RecorderToggleButton: View {
    let isEnabled: Bool
    let icon: String
    let disabled: Bool
    let action: () -> Void

    init(isEnabled: Bool, icon: String, disabled: Bool = false, action: @escaping () -> Void) {
        self.isEnabled = isEnabled
        self.icon = icon
        self.disabled = disabled
        self.action = action
    }

    private var isEmoji: Bool {
        !icon.contains(".") && !icon.contains("-") && icon.unicodeScalars.contains { !$0.isASCII }
    }

    var body: some View {
        Button(action: action) {
            Group {
                if isEmoji {
                    Text(icon).font(.system(size: 14))
                } else {
                    Image(systemName: icon).font(.system(size: 13))
                }
            }
            .foregroundColor(disabled ? .white.opacity(0.3) : (isEnabled ? .white : .white.opacity(0.6)))
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(disabled)
    }
}

// MARK: - Record Button

struct RecorderRecordButton: View {
    let isRecording: Bool
    let isProcessing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(buttonColor)
                    .frame(width: 25, height: 25)

                if isProcessing {
                    ProcessingIndicator(color: .white).frame(width: 16, height: 16)
                } else if isRecording {
                    RoundedRectangle(cornerRadius: 3).fill(Color.white).frame(width: 9, height: 9)
                } else {
                    Circle().fill(Color.white).frame(width: 9, height: 9)
                }
            }
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(isProcessing)
    }

    private var buttonColor: Color {
        if isProcessing { return Color(red: 0.4, green: 0.4, blue: 0.45) }
        if isRecording  { return .red }
        return Color(red: 0.3, green: 0.3, blue: 0.35)
    }
}

// MARK: - Processing Indicator

struct ProcessingIndicator: View {
    @State private var rotation: Double = 0
    let color: Color

    var body: some View {
        Circle()
            .trim(from: 0.1, to: 0.9)
            .stroke(color, lineWidth: 1.7)
            .frame(width: 14, height: 14)
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}

// MARK: - Progress Dot Animation

struct ProgressAnimation: View {
    let color: Color
    let animationSpeed: Double

    private let dotCount = 5
    private let dotSize: CGFloat = 3
    private let dotSpacing: CGFloat = 2

    @State private var currentDot = 0
    @State private var timer: Timer?

    init(color: Color = .white, animationSpeed: Double = 0.3) {
        self.color = color
        self.animationSpeed = animationSpeed
    }

    var body: some View {
        HStack(spacing: dotSpacing) {
            ForEach(0..<dotCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: dotSize / 2)
                    .fill(color.opacity(index <= currentDot ? 0.85 : 0.25))
                    .frame(width: dotSize, height: dotSize)
            }
        }
        .onAppear { startAnimation() }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }

    private func startAnimation() {
        timer?.invalidate()
        currentDot = 0
        timer = Timer.scheduledTimer(withTimeInterval: animationSpeed, repeats: true) { _ in
            currentDot = (currentDot + 1) % (dotCount + 2)
            if currentDot > dotCount { currentDot = -1 }
        }
    }
}

// MARK: - Enhancement Prompt Button

struct RecorderPromptButton: View {
    @EnvironmentObject private var enhancementService: AIEnhancementService
    @Binding var activePopover: ActivePopoverState
    let buttonSize: CGFloat
    let padding: EdgeInsets

    @State private var isHoveringButton: Bool = false
    @State private var isHoveringPopover: Bool = false
    @State private var dismissWorkItem: DispatchWorkItem?

    init(activePopover: Binding<ActivePopoverState>, buttonSize: CGFloat = 28, padding: EdgeInsets = EdgeInsets(top: 0, leading: 7, bottom: 0, trailing: 0)) {
        self._activePopover = activePopover
        self.buttonSize = buttonSize
        self.padding = padding
    }

    var body: some View {
        RecorderToggleButton(
            isEnabled: enhancementService.isEnhancementEnabled,
            icon: enhancementService.activePrompt?.icon ?? enhancementService.allPrompts.first(where: { $0.id == PredefinedPrompts.defaultPromptId })?.icon ?? "checkmark.seal.fill",
            disabled: false
        ) {
            if enhancementService.isEnhancementEnabled {
                activePopover = activePopover == .enhancement ? .none : .enhancement
            } else {
                enhancementService.isEnhancementEnabled = true
            }
        }
        .frame(width: buttonSize)
        .padding(padding)
        .onHover {
            isHoveringButton = $0
            syncPopoverVisibility()
        }
        .popover(isPresented: .constant(activePopover == .enhancement), arrowEdge: .bottom) {
            EnhancementPromptPopover()
                .environmentObject(enhancementService)
                .onHover {
                    isHoveringPopover = $0
                    syncPopoverVisibility()
                }
        }
    }

    private func syncPopoverVisibility() {
        if isHoveringButton || isHoveringPopover {
            dismissWorkItem?.cancel()
            dismissWorkItem = nil
            activePopover = .enhancement
        } else {
            dismissWorkItem?.cancel()
            let work = DispatchWorkItem { [activePopoverBinding = $activePopover] in
                if activePopoverBinding.wrappedValue == .enhancement {
                    activePopoverBinding.wrappedValue = .none
                }
            }
            dismissWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }
}

// MARK: - Power Mode Button

struct RecorderPowerModeButton: View {
    @ObservedObject private var powerModeManager = PowerModeManager.shared
    @Binding var activePopover: ActivePopoverState
    let buttonSize: CGFloat
    let padding: EdgeInsets

    @State private var isHoveringButton: Bool = false
    @State private var isHoveringPopover: Bool = false
    @State private var dismissWorkItem: DispatchWorkItem?

    init(activePopover: Binding<ActivePopoverState>, buttonSize: CGFloat = 28, padding: EdgeInsets = EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 7)) {
        self._activePopover = activePopover
        self.buttonSize = buttonSize
        self.padding = padding
    }

    var body: some View {
        RecorderToggleButton(
            isEnabled: !powerModeManager.enabledConfigurations.isEmpty,
            icon: powerModeManager.enabledConfigurations.isEmpty ? "✨" : (powerModeManager.currentActiveConfiguration?.emoji ?? "✨"),
            disabled: powerModeManager.enabledConfigurations.isEmpty
        ) {
            activePopover = activePopover == .power ? .none : .power
        }
        .frame(width: buttonSize)
        .padding(padding)
        .onHover {
            isHoveringButton = $0
            syncPopoverVisibility()
        }
        .popover(isPresented: .constant(activePopover == .power), arrowEdge: .bottom) {
            PowerModePopover()
                .onHover {
                    isHoveringPopover = $0
                    syncPopoverVisibility()
                }
        }
    }

    private func syncPopoverVisibility() {
        if isHoveringButton || isHoveringPopover {
            dismissWorkItem?.cancel()
            dismissWorkItem = nil
            activePopover = .power
        } else {
            dismissWorkItem?.cancel()
            let work = DispatchWorkItem { [activePopoverBinding = $activePopover] in
                if activePopoverBinding.wrappedValue == .power {
                    activePopoverBinding.wrappedValue = .none
                }
            }
            dismissWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }
}

// MARK: - Live Transcript View

struct LiveTranscriptView: View {
    let text: String
    /// Optional explicit height override; falls back to a sensible default
    /// that grows when the transcript contains chat-style speaker labels.
    var height: CGFloat? = nil

    private var lines: [LiveTranscriptLine] {
        LiveTranscriptParser.parse(text)
    }

    private var hasSpeakerLabels: Bool {
        lines.contains { if case .labeled = $0 { return true } else { return false } }
    }

    private var resolvedHeight: CGFloat {
        if let height { return height }
        return hasSpeakerLabels ? 220 : 80
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        LiveTranscriptRow(line: line)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: resolvedHeight)
            .onChange(of: text) {
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }
}

enum LiveTranscriptLine {
    case labeled(LiveTranscriptSpeaker, String, isLive: Bool)
    case plain(String)
}

enum LiveTranscriptSpeaker {
    case me
    case them

    var color: Color {
        switch self {
        case .me:   return .accentColor
        case .them: return Color.white.opacity(0.18)
        }
    }

    var foreground: Color {
        switch self {
        case .me:   return .white
        case .them: return .white
        }
    }
}

enum LiveTranscriptParser {
    static func parse(_ text: String) -> [LiveTranscriptLine] {
        guard !text.isEmpty else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { raw in
            let line = String(raw)
            // Order matters — "[ME~]:" must be checked before "[ME]:" because
            // the latter is a prefix of the former otherwise.
            if let body = stripPrefix(line, prefix: "[ME~]:") {
                return .labeled(.me, body, isLive: true)
            }
            if let body = stripPrefix(line, prefix: "[THEM~]:") {
                return .labeled(.them, body, isLive: true)
            }
            if let body = stripPrefix(line, prefix: "[ME]:") {
                return .labeled(.me, body, isLive: false)
            }
            if let body = stripPrefix(line, prefix: "[THEM]:") {
                return .labeled(.them, body, isLive: false)
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : .plain(trimmed)
        }
    }

    private static func stripPrefix(_ line: String, prefix: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        let body = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return body
    }
}

struct LiveTranscriptRow: View {
    let line: LiveTranscriptLine

    var body: some View {
        switch line {
        case .plain(let text):
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
        case .labeled(let speaker, let text, let isLive):
            HStack(spacing: 0) {
                if speaker == .me { Spacer(minLength: 40) }
                Text(text)
                    .font(.system(size: 12))
                    .italic(isLive)
                    .foregroundColor(speaker.foreground)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(speaker.color.opacity(isLive ? 0.55 : 1.0))
                    )
                    .fixedSize(horizontal: false, vertical: true)
                if speaker == .them { Spacer(minLength: 40) }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Recorder Status Display

struct RecorderStatusDisplay: View {
    let currentState: RecordingState
    let audioMeter: AudioMeter
    let sourceAudioMeters: SourceAudioMeters
    let audioSourceMode: AudioSourceMode
    let menuBarHeight: CGFloat?

    init(
        currentState: RecordingState,
        audioMeter: AudioMeter,
        sourceAudioMeters: SourceAudioMeters = .zero,
        audioSourceMode: AudioSourceMode = .microphone,
        menuBarHeight: CGFloat? = nil
    ) {
        self.currentState = currentState
        self.audioMeter = audioMeter
        self.sourceAudioMeters = sourceAudioMeters
        self.audioSourceMode = audioSourceMode
        self.menuBarHeight = menuBarHeight
    }

    private var statusScale: CGFloat {
        menuBarHeight != nil ? min(1.0, (menuBarHeight! - 8) / 25) : 1.0
    }

    var body: some View {
        Group {
            if currentState == .enhancing {
                ProcessingStatusDisplay(mode: .enhancing, color: .white).transition(.opacity)
            } else if currentState == .transcribing {
                ProcessingStatusDisplay(mode: .transcribing, color: .white).transition(.opacity)
            } else if currentState == .recording {
                recordingVisualizer.transition(.opacity)
            } else {
                StaticVisualizer(color: .white)
                    .scaleEffect(y: statusScale, anchor: .center)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: currentState)
    }

    @ViewBuilder
    private var recordingVisualizer: some View {
        switch audioSourceMode {
        case .microphone:
            AudioVisualizer(audioMeter: sourceAudioMeters.microphone, color: .accentColor, isActive: true)
                .scaleEffect(y: statusScale, anchor: .center)
        case .systemAudio:
            AudioVisualizer(audioMeter: sourceAudioMeters.system, color: .white, isActive: true)
                .scaleEffect(y: statusScale, anchor: .center)
        case .mixed:
            HStack(spacing: 5) {
                AudioVisualizer(audioMeter: sourceAudioMeters.system, color: .white, isActive: true, barCount: 9)
                AudioVisualizer(audioMeter: sourceAudioMeters.microphone, color: .accentColor, isActive: true, barCount: 9)
            }
            .scaleEffect(y: statusScale, anchor: .center)
        }
    }
}
