import SwiftUI
import EngineBundle

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
    @StateObject private var account = StremioAccount()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(account)
                .environmentObject(model)
                .environmentObject(history)
                .environmentObject(addons)
                .environmentObject(watch)
                .environmentObject(favorites)
                .environmentObject(coordinator)
                .preferredColorScheme(.dark)
                .tint(.white)
                .toggleStyle(BrandToggleStyle())
                .task {
                    // Progress recorded when the player closes also goes to the Stremio account.
                    let account = self.account
                    watch.onRecord = { ref, position, duration in
                        Task { await account.pushProgress(ref, position: position, duration: duration) }
                    }
                    watch.onRemove = { ref in
                        Task { await account.clearProgress(ref) }
                    }
                    await account.sync(addons: addons, watch: watch)
                }
                .onChange(of: scenePhase) { _, phase in
                    // Pick up what was watched in the Stremio apps meanwhile.
                    if phase == .active {
                        Task { await account.sync(addons: addons, watch: watch, ifOlderThan: 120) }
                    }
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var watch: WatchStore
    @EnvironmentObject private var addons: AddonStore
    @EnvironmentObject private var coordinator: PlayerCoordinator
    @State private var tab = PreviewMode.initialTab

    var body: some View {
        TabView(selection: $tab) {
            Tab("Home", systemImage: "play.tv.fill", value: 0) {
                HomeScreen()
            }
            Tab("Links", systemImage: "link", value: 1) {
                HomeView()
            }
            Tab("Stremio", systemImage: "puzzlepiece.extension.fill", value: 2) {
                AddonsView()
            }
            Tab("Settings", systemImage: "gearshape.fill", value: 4) {
                AppSettingsView()
            }
            Tab(value: 3, role: .search) {
                SearchScreen()
            }
        }
        .task {
            // CI screenshots only: open the player on the Dolby test stream.
            if PreviewMode.screen == "player", let base = Bundle.main.object(forInfoDictionaryKey: "TestMediaBase") as? String,
               !base.isEmpty, let url = URL(string: base + "/dolby-atmos-test.m3u8") {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                coordinator.play(PlayItem(url: url, title: "Dolby Atmos test"))
            }
        }
        .fullScreenCover(item: $coordinator.current) { item in
            if let engine = model.engine {
                PlayerView(item: item, engine: engine)
                    .environmentObject(watch)
                    .environmentObject(addons)
            } else {
                VStack(spacing: 16) {
                    Text("Player engine unavailable: \(model.engineError ?? "unknown error")")
                        .multilineTextAlignment(.center)
                    Button("Close") { coordinator.current = nil }
                        .buttonStyle(.borderedProminent)
                        .tint(Brand.accent)
                }
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
