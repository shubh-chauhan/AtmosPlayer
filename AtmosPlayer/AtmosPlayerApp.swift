import SwiftUI
import AetherEngine

/// One engine for the whole app (AetherEngine's rule). Created once at launch.
@MainActor
final class AppModel: ObservableObject {
    let engine: AetherEngine?
    let engineError: String?

    init() {
        // Mirror the engine's diagnostic lines into the in-app debug overlay.
        EngineLog.handler = { line in LogStore.shared.append(line) }
        do {
            let created = try AetherEngine()
            // This app plays no other audio, so let the engine release the session on stop.
            created.deactivatesAudioSessionOnStop = true
            engine = created
            engineError = nil
        } catch {
            engine = nil
            engineError = "\(error)"
        }
    }
}

@main
struct AtmosPlayerApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var history = HistoryStore()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(model)
                .environmentObject(history)
                .preferredColorScheme(.dark)
        }
    }
}
