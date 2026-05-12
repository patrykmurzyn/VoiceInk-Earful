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
    private var audioMeterUpdateTimer: DispatchSourceTimer?
    private let audioMeterQueue = DispatchQueue(label: "com.prakashjoshipax.voiceink.audiometer", qos: .userInteractive)
    /// Dedicated serial queue for hardware setup.
    private let audioSetupQueue = DispatchQueue(label: "com.prakashjoshipax.voiceink.audioSetup", qos: .userInitiated)
    private var audioMuteTask: Task<Void, Never>?
    private var audioRestorationTask: Task<Void, Never>?
    private let smoothedValuesLock = NSLock()
    private var smoothedAverage: Float = 0
    private var smoothedPeak: Float = 0

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

    enum RecorderError: Error {
        case couldNotStartRecording
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
            logger.error("Failed to start recording: \(error.localizedDescription, privacy: .public)")
            await stopRecording()
            throw RecorderError.couldNotStartRecording
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
        smoothedValuesLock.unlock()

        audioMeter = AudioMeter(averagePower: 0, peakPower: 0)

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

        // Sample audio levels (thread-safe read)
        let averagePower = recorder.averagePower
        let peakPower = recorder.peakPower

        // Normalize values
        let minVisibleDb: Float = -60.0
        let maxVisibleDb: Float = 0.0

        let normalizedAverage: Float
        if averagePower < minVisibleDb {
            normalizedAverage = 0.0
        } else if averagePower >= maxVisibleDb {
            normalizedAverage = 1.0
        } else {
            normalizedAverage = (averagePower - minVisibleDb) / (maxVisibleDb - minVisibleDb)
        }

        let normalizedPeak: Float
        if peakPower < minVisibleDb {
            normalizedPeak = 0.0
        } else if peakPower >= maxVisibleDb {
            normalizedPeak = 1.0
        } else {
            normalizedPeak = (peakPower - minVisibleDb) / (maxVisibleDb - minVisibleDb)
        }

        // Apply EMA smoothing with thread-safe access
        smoothedValuesLock.lock()
        smoothedAverage = smoothedAverage * 0.6 + normalizedAverage * 0.4
        smoothedPeak = smoothedPeak * 0.6 + normalizedPeak * 0.4
        let newAudioMeter = AudioMeter(averagePower: Double(smoothedAverage), peakPower: Double(smoothedPeak))
        smoothedValuesLock.unlock()

        // Dispatch to main queue for UI updates (more efficient than Task)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.audioMeter = newAudioMeter
        }
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
