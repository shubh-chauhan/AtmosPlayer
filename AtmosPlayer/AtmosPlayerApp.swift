import SwiftUI
import Combine
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

    init() {
        #if DEBUG
        SelfCheck.runIfAsked()
        #endif
    }

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
                    WatchedStore.shared.onChange = { metaId, type, watched, videoIds in
                        Task { await account.pushWatched(metaId: metaId, type: type, watched: watched, videoIds: videoIds) }
                    }
                    // Picks up downloads that carried on while the app was closed.
                    _ = DownloadStore.shared
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
    /// The tabs stop drawing once the player covers them (and start again before it leaves).
    @State private var homeHidden = false

    var body: some View {
        ZStack {
            tabs
                .opacity(homeHidden ? 0 : 1)
                .allowsHitTesting(coordinator.current == nil)
            // The player fades in over the app and fades out back to it. It is drawn in the
            // same window (not a separate full-screen cover), so leaving it never waits on a
            // presentation animation or a forced rotation.
            if let item = coordinator.current {
                player(item)
                    .transition(.asymmetric(insertion: .opacity,
                                            removal: .opacity.combined(with: .scale(scale: 0.97))))
                    .zIndex(1)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .animation(.easeInOut(duration: 0.32), value: coordinator.current?.id)
        .onChange(of: coordinator.current?.id) { _, id in
            if id == nil {
                homeHidden = false
            } else {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    if coordinator.current != nil { homeHidden = true }
                }
            }
        }
    }

    @ViewBuilder
    private func player(_ item: PlayItem) -> some View {
        if let engine = model.engine {
            PlayerView(item: item, engine: engine)
                .id(item.id)
        } else {
            VStack(spacing: 16) {
                Text("Player engine unavailable: \(model.engineError ?? "unknown error")")
                    .multilineTextAlignment(.center)
                Button("Close") { coordinator.current = nil }
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.accent)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.ignoresSafeArea())
        }
    }

    private var tabs: some View {
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
            // CI screenshots only: turn to landscape for the "-landscape" screens.
            if PreviewMode.screen?.hasSuffix("-landscape") == true {
                OrientationLock.set(.landscapeRight)
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
        // atmosplayer://play?url=<percent-encoded link>, for handing a link over from another app.
        .onOpenURL { incoming in
            guard incoming.scheme == "atmosplayer",
                  let components = URLComponents(url: incoming, resolvingAgainstBaseURL: false) else { return }
            // atmosplayer://resume?id=<video id>, from the Continue Watching widget.
            if components.host == "resume",
               let id = components.queryItems?.first(where: { $0.name == "id" })?.value {
                tab = 0
                coordinator.pendingResume = id
                return
            }
            guard let value = components.queryItems?.first(where: { $0.name == "url" })?.value,
                  let target = URL(string: value) else { return }
            history.add(target)
            coordinator.play(PlayItem(url: target))
        }
        // Keep the home-screen widget in step with Continue Watching.
        .onReceive(watch.$entries.debounce(for: .seconds(2), scheduler: RunLoop.main)) { entries in
            WidgetBridge.update(entries)
        }
    }
}
