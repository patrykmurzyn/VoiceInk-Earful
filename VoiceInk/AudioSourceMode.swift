import Foundation

enum AudioSourceMode: String, CaseIterable, Identifiable {
    case microphone
    case systemAudio
    case mixed

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .microphone: return "Microphone"
        case .systemAudio: return "System Audio"
        case .mixed: return "Mic + System"
        }
    }

    var description: String {
        switch self {
        case .microphone: return "Record from your input device"
        case .systemAudio: return "Capture audio playing through speakers"
        case .mixed: return "Record both with [ME]/[THEM] labels"
        }
    }

    var iconName: String {
        switch self {
        case .microphone: return "mic.circle.fill"
        case .systemAudio: return "speaker.wave.3.fill"
        case .mixed: return "person.2.wave.2.fill"
        }
    }

    static let userDefaultsKey = "audioSourceMode"

    static var current: AudioSourceMode {
        guard let raw = UserDefaults.standard.string(forKey: userDefaultsKey),
              let mode = AudioSourceMode(rawValue: raw) else {
            return .microphone
        }
        return mode
    }
}
