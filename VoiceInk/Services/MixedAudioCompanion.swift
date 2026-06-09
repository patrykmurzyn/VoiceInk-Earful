import Foundation

enum MixedAudioCompanion {
    struct RemovalResult {
        let deletedCount: Int
        let failedCount: Int

        var didFail: Bool { failedCount > 0 }
    }

    static func systemAudioURL(forPrimaryAudioURL url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("system.wav")
    }

    static func existingSystemAudioURL(forPrimaryAudioURL url: URL) -> URL? {
        let companion = systemAudioURL(forPrimaryAudioURL: url)
        return FileManager.default.fileExists(atPath: companion.path) ? companion : nil
    }

    @discardableResult
    static func removePrimaryAndCompanion(forPrimaryAudioURL url: URL) -> RemovalResult {
        let fileManager = FileManager.default
        var deletedCount = 0
        var failedCount = 0

        for candidate in [url, systemAudioURL(forPrimaryAudioURL: url)] {
            guard fileManager.fileExists(atPath: candidate.path) else { continue }
            do {
                try fileManager.removeItem(at: candidate)
                deletedCount += 1
            } catch {
                failedCount += 1
            }
        }

        return RemovalResult(deletedCount: deletedCount, failedCount: failedCount)
    }
}
