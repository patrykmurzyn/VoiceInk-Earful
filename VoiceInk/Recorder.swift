import Foundation
import AVFoundation
import CoreAudio
import os

@MainActor
class Recorder: NSObject, ObservableObject {
    private var recorder: (any AudioCaptureSource)?
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "Recorder")
    private let deviceManager = AudioDeviceManager.shared
    private var deviceSwitchObserver: NSObjectProtocol?
    private var isReconfiguring = false
    private let mediaController = MediaController.shared
    private let playbackController = PlaybackController.shared
    @Published var audioMeter = AudioMeter(averagePower: 0, peakPower: 0)
    @Published var sourceAudioMeters = SourceAudioMeters.zero
    @Published var activeAudioSourceMode: AudioSourceMode = AudioSourceMode.current
    private var audioMeterUpdateTimer: DispatchSourceTimer?
    private let audioMeterQueue = DispatchQueue(label: "com.prakashjoshipax.voiceink.audiometer", qos: .userInteractive)
    /// Dedicated serial queue for hardware setup.
    private let audioSetupQueue = DispatchQueue(label: "com.prakashjoshipax.voiceink.audioSetup", qos: .userInitiated)
    private var audioMuteTask: Task<Void, Never>?
    private var audioRestorationTask: Task<Void, Never>?
    private let smoothedValuesLock = NSLock()
    private var smoothedAverage: Float = 0
    private var smoothedPeak: Float = 0
    private var smoothedMicAverage: Float = 0
    private var smoothedMicPeak: Float = 0
    private var smoothedSystemAverage: Float = 0
    private var smoothedSystemPeak: Float = 0

    /// Audio chunk callback for streaming. Can be updated while recording;
    /// changes are forwarded to the live capture source.
    var onAudioChunk: ((_ data: Data) -> Void)? {
        didSet { recorder?.onAudioChunk = onAudioChunk }
    }

    /// Companion WAV produced alongside the primary recording (system-audio
    /// stream when in mixed mode). Captured at start and persisted across
    /// `stopRecording` so callers can consume it during transcription.
    /// `nil` for single-source modes.
    private(set) var companionAudioURL: URL?

    /// Underlying mixed-source recorder while one is active, allowing live
    /// streaming consumers to subscribe to the mic and system chunk streams
    /// separately. `nil` outside mixed mode.
    var mixedAudioRecorder: MixedAudioRecorder? {
        if #available(macOS 13.0, *) {
            return recorder as? MixedAudioRecorder
        }
        return nil
    }

    enum RecorderError: Error {
        case couldNotStartRecording(String)
    }
    
    override init() {
        super.init()
        setupDeviceSwitchObserver()
    }

    private func setupDeviceSwitchObserver() {
        deviceSwitchObserver = NotificationCenter.default.addObserver(
            forName: .audioDeviceSwitchRequired,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task {
                await self?.handleDeviceSwitchRequired(notification)
            }
        }
    }

    private func handleDeviceSwitchRequired(_ notification: Notification) async {
        guard !isReconfiguring else { return }
        guard let micRecorder = recorder as? CoreAudioRecorder else { return }
        guard let userInfo = notification.userInfo,
              let newDeviceID = userInfo["newDeviceID"] as? AudioDeviceID else {
            logger.error("Device switch notification missing newDeviceID")
            return
        }

        // Prevent concurrent device switches and handleDeviceChange() interference
        isReconfiguring = true
        defer { isReconfiguring = false }

        logger.notice("🎙️ Device switch required: switching to device \(newDeviceID, privacy: .public)")

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                audioSetupQueue.async {
                    do {
                        try micRecorder.switchDevice(to: newDeviceID)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }

            // Notify user about the switch
            if let deviceName = deviceManager.availableDevices.first(where: { $0.id == newDeviceID })?.name {
                await MainActor.run {
                    NotificationManager.shared.showNotification(
                        title: "Switched to: \(deviceName)",
                        type: .info
                    )
                }
            }

            logger.notice("🎙️ Successfully switched recording to device \(newDeviceID, privacy: .public)")
        } catch {
            logger.error("❌ Failed to switch device: \(error.localizedDescription, privacy: .public)")

            // If switch fails, stop recording and notify user
            await handleRecordingError(error)
        }
    }

    func scheduleSystemMute(afterDelayNanoseconds delay: UInt64 = 250_000_000) {
        let mode = AudioSourceMode.current
        guard mode != .systemAudio, mode != .mixed else { return }
        audioMuteTask?.cancel()
        audioMuteTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self else { return }
            _ = await self.mediaController.muteSystemAudio()
        }
    }

    func startRecording(toOutputFile url: URL) async throws {
        logger.notice("startRecording called – deviceID=\(self.deviceManager.getCurrentDevice(), privacy: .public), file=\(url.lastPathComponent, privacy: .public)")
        deviceManager.isRecordingActive = true
        companionAudioURL = nil

        let currentDeviceID = deviceManager.getCurrentDevice()
        let lastDeviceID = UserDefaults.standard.string(forKey: "lastUsedMicrophoneDeviceID")
        if String(currentDeviceID) != lastDeviceID {
            if let deviceName = deviceManager.availableDevices.first(where: { $0.id == currentDeviceID })?.name {
                NotificationManager.shared.showNotification(title: "Using: \(deviceName)", type: .info)
            }
        }
        UserDefaults.standard.set(String(currentDeviceID), forKey: "lastUsedMicrophoneDeviceID")

        let deviceID = currentDeviceID

        audioRestorationTask?.cancel()
        audioRestorationTask = nil
        audioMeterUpdateTimer?.cancel()

        let sourceMode = AudioSourceMode.current
        activeAudioSourceMode = sourceMode
        let captureSource: any AudioCaptureSource
        switch sourceMode {
        case .systemAudio:
            let sysRecorder = SystemAudioRecorder()
            sysRecorder.onAudioChunk = onAudioChunk
            captureSource = sysRecorder
        case .microphone:
            let coreAudioRecorder = CoreAudioRecorder()
            coreAudioRecorder.preferredDeviceID = deviceID
            coreAudioRecorder.onAudioChunk = onAudioChunk
            captureSource = coreAudioRecorder
        case .mixed:
            if #available(macOS 13.0, *) {
                let mixedRecorder = MixedAudioRecorder(micDeviceID: deviceID)
                mixedRecorder.onAudioChunk = onAudioChunk
                captureSource = mixedRecorder
            } else {
                let coreAudioRecorder = CoreAudioRecorder()
                coreAudioRecorder.preferredDeviceID = deviceID
                coreAudioRecorder.onAudioChunk = onAudioChunk
                captureSource = coreAudioRecorder
            }
        }
        recorder = captureSource
        logger.notice("startRecording: source=\(sourceMode.rawValue, privacy: .public) file=\(url.lastPathComponent, privacy: .public)")

        do {
            // Offload initialization to background thread to avoid hotkey lag.
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                audioSetupQueue.async {
                    do {
                        try captureSource.start(toOutputFile: url)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            logger.notice("startRecording: capture source started successfully")

            if #available(macOS 13.0, *), let mixed = captureSource as? MixedAudioRecorder {
                companionAudioURL = mixed.systemFileURL
            }

            startAudioMeterTimer()
            if sourceMode == .microphone {
                Task { [weak self] in
                    guard let self else { return }
                    await self.playbackController.pauseMedia()
                }
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            logger.error("Failed to start recording: \(message, privacy: .public)")
            await stopRecording()
            throw RecorderError.couldNotStartRecording(message)
        }
    }

    func stopRecording() async {
        logger.notice("stopRecording called")
        audioMuteTask?.cancel()
        audioMuteTask = nil
        audioMeterUpdateTimer?.cancel()
        audioMeterUpdateTimer = nil

        // Capture current recorder to stop it on the serial hardware queue
        let currentRecorder = self.recorder
        recorder = nil
        onAudioChunk = nil

        await withCheckedContinuation { continuation in
            audioSetupQueue.async {
                currentRecorder?.stop()
                continuation.resume()
            }
        }

        smoothedValuesLock.lock()
        smoothedAverage = 0
        smoothedPeak = 0
        smoothedMicAverage = 0
        smoothedMicPeak = 0
        smoothedSystemAverage = 0
        smoothedSystemPeak = 0
        smoothedValuesLock.unlock()

        audioMeter = AudioMeter(averagePower: 0, peakPower: 0)
        sourceAudioMeters = .zero

        if AudioSourceMode.current == .microphone {
            audioRestorationTask = Task {
                await mediaController.unmuteSystemAudio()
                await playbackController.resumeMedia()
            }
        }
        deviceManager.isRecordingActive = false
    }

    private func handleRecordingError(_ error: Error) async {
        logger.error("❌ Recording error occurred: \(error.localizedDescription, privacy: .public)")

        // Stop the recording
        await stopRecording()

        // Notify the user about the recording failure
        await MainActor.run {
            NotificationManager.shared.showNotification(
                title: "Recording Failed: \(error.localizedDescription)",
                type: .error
            )
        }
    }

    private func startAudioMeterTimer() {
        let timer = DispatchSource.makeTimerSource(queue: audioMeterQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(17)) 
        timer.setEventHandler { [weak self] in
            self?.updateAudioMeter()
        }
        timer.resume()
        audioMeterUpdateTimer = timer
    }

    private func updateAudioMeter() {
        guard let recorder = recorder else { return }

        let sourceMode = AudioSourceMode.current
        let combinedRaw = RawAudioMeter(averagePower: recorder.averagePower, peakPower: recorder.peakPower)
        let micRaw: RawAudioMeter
        let systemRaw: RawAudioMeter

        if #available(macOS 13.0, *), let mixed = recorder as? MixedAudioRecorder {
            micRaw = RawAudioMeter(averagePower: mixed.micAveragePower, peakPower: mixed.micPeakPower)
            systemRaw = RawAudioMeter(averagePower: mixed.systemAveragePower, peakPower: mixed.systemPeakPower)
        } else {
            switch sourceMode {
            case .microphone:
                micRaw = combinedRaw
                systemRaw = .silent
            case .systemAudio:
                micRaw = .silent
                systemRaw = combinedRaw
            case .mixed:
                micRaw = combinedRaw
                systemRaw = .silent
            }
        }

        let normalizedCombined = Self.normalizeAudioMeter(combinedRaw)
        let normalizedMic = Self.normalizeAudioMeter(micRaw)
        let normalizedSystem = Self.normalizeAudioMeter(systemRaw)

        smoothedValuesLock.lock()
        smoothedAverage = Self.smoothed(previous: smoothedAverage, next: normalizedCombined.averagePower)
        smoothedPeak = Self.smoothed(previous: smoothedPeak, next: normalizedCombined.peakPower)
        smoothedMicAverage = Self.smoothed(previous: smoothedMicAverage, next: normalizedMic.averagePower)
        smoothedMicPeak = Self.smoothed(previous: smoothedMicPeak, next: normalizedMic.peakPower)
        smoothedSystemAverage = Self.smoothed(previous: smoothedSystemAverage, next: normalizedSystem.averagePower)
        smoothedSystemPeak = Self.smoothed(previous: smoothedSystemPeak, next: normalizedSystem.peakPower)

        let newAudioMeter = AudioMeter(averagePower: Double(smoothedAverage), peakPower: Double(smoothedPeak))
        let newSourceAudioMeters = SourceAudioMeters(
            combined: newAudioMeter,
            microphone: AudioMeter(averagePower: Double(smoothedMicAverage), peakPower: Double(smoothedMicPeak)),
            system: AudioMeter(averagePower: Double(smoothedSystemAverage), peakPower: Double(smoothedSystemPeak))
        )
        smoothedValuesLock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.audioMeter = newAudioMeter
            self.sourceAudioMeters = newSourceAudioMeters
        }
    }

    private static func normalizeAudioMeter(_ meter: RawAudioMeter) -> RawAudioMeter {
        RawAudioMeter(
            averagePower: normalizeDb(meter.averagePower),
            peakPower: normalizeDb(meter.peakPower)
        )
    }

    private static func normalizeDb(_ value: Float) -> Float {
        let minVisibleDb: Float = -60.0
        let maxVisibleDb: Float = 0.0

        if value < minVisibleDb { return 0.0 }
        if value >= maxVisibleDb { return 1.0 }
        return (value - minVisibleDb) / (maxVisibleDb - minVisibleDb)
    }

    private static func smoothed(previous: Float, next: Float) -> Float {
        previous * 0.6 + next * 0.4
    }
    
    // MARK: - Cleanup

    deinit {
        audioMeterUpdateTimer?.cancel()
        audioRestorationTask?.cancel()
        if let observer = deviceSwitchObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

struct AudioMeter: Equatable {
    let averagePower: Double
    let peakPower: Double
}

struct SourceAudioMeters: Equatable {
    let combined: AudioMeter
    let microphone: AudioMeter
    let system: AudioMeter

    static let zero = SourceAudioMeters(
        combined: AudioMeter(averagePower: 0, peakPower: 0),
        microphone: AudioMeter(averagePower: 0, peakPower: 0),
        system: AudioMeter(averagePower: 0, peakPower: 0)
    )
}

private struct RawAudioMeter {
    let averagePower: Float
    let peakPower: Float

    static let silent = RawAudioMeter(averagePower: -160, peakPower: -160)
}
