import Foundation
import ActivityKit
import AppIntents

/// The Live Activity shown on the Lock Screen and in the Dynamic Island while something plays.
struct PlaybackAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var isPlaying: Bool
        /// Seconds into the title at `updatedAt`.
        var position: Double
        var duration: Double
        var updatedAt: Date

        /// When the title started, as if it had played without pause (drives the live progress).
        var startDate: Date { updatedAt.addingTimeInterval(-position) }
        var endDate: Date { startDate.addingTimeInterval(max(duration, 1)) }
        var progress: Double { duration > 0 ? min(max(position / duration, 0), 1) : 0 }
    }

    var title: String
    var subtitle: String?
}

// The buttons on the Live Activity. Their `perform` runs inside the app (that is what a
// LiveActivityIntent does), so the widget extension only needs them to exist.

struct TogglePlaybackIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Play or Pause"

    init() {}

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await PlaybackRemote.shared.togglePlayPause()
        #endif
        return .result()
    }
}

struct SkipPlaybackIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Skip"

    @Parameter(title: "Seconds")
    var seconds: Int

    init() { seconds = 10 }

    init(seconds: Int) { self.seconds = seconds }

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await PlaybackRemote.shared.skip(Double(seconds))
        #endif
        return .result()
    }
}
