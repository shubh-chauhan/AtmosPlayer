import SwiftUI
import AetherEngine

/// One engine for the whole app (AetherEngine's rule). Created once at launch.
@MainActor
final class AppModel: ObservableObject {
    let engine: AetherEngine?
    let engineError: String?

    init() {
        // Mirror the engine's diagnostic lines into the in-app playback info overlay.
        EngineLog.handler = { line in LogStore.shared.append(line) }
        do {
            let created = try AetherEngine()
            // This app plays no other audio, so let the engine release the session on stop.
            created.deactivatesAudioSessionOnStop = true
            // Lock screen / Control Center: title, artwork, play/pause and seeking.
            created.ownsVideoNowPlayingSession = true
            created.ownsVideoNowPlayingCommands = true
            created.ownsSoftwareNowPlaying = true
            // The subtitle timing control goes to ±10 s; keeping less cue history saves memory.
            created.maximumSubtitleOffsetSeconds = 10
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
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var history = HistoryStore()
    @StateObject private var addons = AddonStore()
    @StateObject private var watch = WatchStore()
    @StateObject private var favorites = FavoritesStore()
    @StateObject private var coordinator = PlayerCoordinator()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(history)
                .environmentObject(addons)
                .environmentObject(watch)
                .environmentObject(favorites)
                .environmentObject(coordinator)
                .preferredColorScheme(.dark)
                .tint(.white)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var watch: WatchStore
    @EnvironmentObject private var addons: AddonStore
    @EnvironmentObject private var coordinator: PlayerCoordinator

    var body: some View {
        TabView {
            Tab("Home", systemImage: "play.tv.fill") {
                HomeScreen()
            }
            Tab("Links", systemImage: "link") {
                HomeView()
            }
            Tab("Addons", systemImage: "puzzlepiece.extension.fill") {
                AddonsView()
            }
            Tab(role: .search) {
                SearchScreen()
            }
        }
        .fullScreenCover(item: $coordinator.current) { item in
            if let engine = model.engine {
                PlayerView(item: item, engine: engine)
                    .environmentObject(watch)
                    .environmentObject(addons)
            } else {
                Text("Player engine unavailable: \(model.engineError ?? "unknown error")")
                    .padding()
            }
        }
        // atmosplayer://play?url=<percent-encoded link>, for handing a link over from another app.
        .onOpenURL { incoming in
            guard incoming.scheme == "atmosplayer",
                  let components = URLComponents(url: incoming, resolvingAgainstBaseURL: false),
                  let value = components.queryItems?.first(where: { $0.name == "url" })?.value,
                  let target = URL(string: value) else { return }
            history.add(target)
            coordinator.play(PlayItem(url: target))
        }
    }
}
