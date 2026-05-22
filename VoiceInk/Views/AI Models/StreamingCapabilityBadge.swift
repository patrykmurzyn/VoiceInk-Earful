import SwiftUI

/// Small capsule shown next to model names that indicates whether the model
/// supports real-time (streaming) transcription or only batch processing of
/// the full recording after stop.
struct StreamingCapabilityBadge: View {
    let supportsStreaming: Bool

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: supportsStreaming ? "bolt.fill" : "clock")
                .font(.system(size: 8, weight: .semibold))
            Text(supportsStreaming ? "Real-time" : "Batch")
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(supportsStreaming ? Color.green : Color.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill((supportsStreaming ? Color.green : Color.secondary).opacity(0.12))
        )
        .help(supportsStreaming
              ? "Transcribes incrementally while you speak."
              : "Transcribes the full recording after you stop.")
    }
}
