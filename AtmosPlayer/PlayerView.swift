import SwiftUI
import UIKit
import MediaPlayer
import AetherEngine

/// Full-screen player: Infuse-style controls over AetherEngine's surface.
struct PlayerView: View {
    @ObservedObject var engine: AetherEngine
    @EnvironmentObject private var watch: WatchStore
    @EnvironmentObject private var addons: AddonStore
    @Environment(\.dismiss) private var dismiss

    /// The item playing now. Starts as the one we were opened with; "Next episode" replaces it.
    @State private var item: PlayItem
    @StateObject private var pip = PiPController()

    @AppStorage("player.debug") private var showDebug = false
    @AppStorage("subtitle.scale") private var subtitleScale = 1.0
    @AppStorage("subtitle.background") private var subtitleBackground = true
    @AppStorage("player.skipSeconds") private var skipSeconds = 10.0

    @State private var showControls = true
    @State private var locked = false
    @State private var scrubbing = false
    @State private var hideTask: Task<Void, Never>?
    @State private var panel: PlayerPanel?
    @State private var fill = false
    @State private var speed: Float = 1
    @State private var audioDelay = 0.0
    @State private var subtitleOffset = 0.0
    @State private var seekFlash: SeekFlash?
    @State private var loadError: String?
    @State private var onlineSubtitles: [AddonSubtitle] = []
    @State private var addedSubtitleURLs: [String: Int] = [:]
    @State private var nextState: NextState = .idle
    @State private var showRemaining = false

    enum NextState: Equatable {
        case idle
        case countdown(Int)
        case resolving
        case failed
    }

    init(item: PlayItem, engine: AetherEngine) {
        _item = State(initialValue: item)
        self.engine = engine
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                AetherPlayerSurface(engine: engine)
                    .ignoresSafeArea()

                SubtitleOverlay(engine: engine, clock: engine.clock,
                                offset: subtitleOffset, scale: subtitleScale,
                                background: subtitleBackground,
                                lifted: showControls && !locked)

                gestureLayer(width: geo.size.width)

                BufferingIndicator(engine: engine)

                if let seekFlash {
                    SeekFlashView(flash: seekFlash)
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: seekFlash.forward ? .trailing : .leading)
                        .padding(.horizontal, geo.size.width * 0.12)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                if showDebug {
                    DebugOverlay(engine: engine)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(.top, 70)
                        .padding(.horizontal, 16)
                        .allowsHitTesting(false)
                }

                if showControls {
                    if locked {
                        lockedOverlay
                    } else {
                        controls
                            .transition(.opacity)
                    }
                }

                upNextCard

                if let loadError {
                    errorBanner(loadError)
                }
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .task(id: item.id) { await load() }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            OrientationLock.set(.landscape)
            pip.attach(engine)
            scheduleHide()
        }
        .onDisappear {
            recordProgress()
            pip.stop()
            engine.stop()
            UIApplication.shared.isIdleTimerDisabled = false
            OrientationLock.set(.all)
            if item.securityScoped { item.url.stopAccessingSecurityScopedResource() }
        }
        .onChange(of: engine.state) { _, state in
            if state == .ended { startNextCountdown() }
            if state == .playing { scheduleHide() }
        }
        .sheet(item: $panel) { which in
            switch which {
            case .tracks:
                TracksPanel(engine: engine, onlineSubtitles: onlineSubtitles,
                            addedSubtitleURLs: $addedSubtitleURLs)
                    .presentationDetents([.medium, .large])
                    .presentationBackground(.ultraThinMaterial)
            case .settings:
                SettingsPanel(engine: engine, speed: $speed, audioDelay: $audioDelay,
                              subtitleOffset: $subtitleOffset, subtitleScale: $subtitleScale,
                              subtitleBackground: $subtitleBackground, showDebug: $showDebug,
                              skipSeconds: $skipSeconds)
                    .presentationDetents([.medium, .large])
                    .presentationBackground(.ultraThinMaterial)
            case .chapters:
                ChaptersPanel(engine: engine) { panel = nil }
                    .presentationDetents([.medium, .large])
                    .presentationBackground(.ultraThinMaterial)
            }
        }
        .onChange(of: panel) { _, value in
            if value == nil { scheduleHide() } else { hideTask?.cancel() }
        }
    }

    // MARK: Gestures

    private func gestureLayer(width: CGFloat) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture(count: 2)
                    .onEnded { value in
                        guard !locked else { return }
                        let forward = value.location.x > width / 2
                        skip(forward ? skipSeconds : -skipSeconds, flash: true)
                    }
                    .exclusively(before: TapGesture(count: 1).onEnded { toggleControls() })
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onEnded { value in
                        guard !locked else { return }
                        setFill(value.magnification > 1)
                    }
            )
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
        if showControls { scheduleHide() }
    }

    /// Hide the controls after a few seconds of no interaction while playing.
    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, engine.state == .playing, !scrubbing, panel == nil else { return }
            withAnimation(.easeInOut(duration: 0.3)) { showControls = false }
        }
    }

    private func interacted() {
        if !showControls { withAnimation { showControls = true } }
        scheduleHide()
    }

    // MARK: Controls

    private var controls: some View {
        ZStack {
            // Darken top and bottom so white controls read on any picture.
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 140)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 190)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                Spacer()
                centerButtons
                Spacer()
                bottomBar
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .foregroundStyle(.white)
        .tint(.white)
    }

    private var topBar: some View {
        HStack(alignment: .center, spacing: 18) {
            CircleButton(symbol: "xmark") { dismiss() }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.watch?.name ?? item.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                if let episode = item.watch?.episodeLabel {
                    Text(episode).font(.subheadline).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                }
            }
            Spacer()
            if pip.isPossible {
                CircleButton(symbol: pip.isActive ? "pip.exit" : "pip.enter") { pip.toggle(); interacted() }
            }
            AirPlayButton()
                .frame(width: 40, height: 40)
            CircleButton(symbol: "info.circle") { showDebug.toggle(); interacted() }
        }
    }

    private var centerButtons: some View {
        HStack(spacing: 56) {
            CircleButton(symbol: skipSymbol(back: true), size: 30) { skip(-skipSeconds, flash: false) }
            Button {
                engine.togglePlayPause()
                interacted()
            } label: {
                Image(systemName: engine.state == .playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .frame(width: 84, height: 84)
                    .background(.ultraThinMaterial, in: Circle())
                    .contentTransition(.symbolEffect(.replace))
            }
            CircleButton(symbol: skipSymbol(back: false), size: 30) { skip(skipSeconds, flash: false) }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            ScrubBar(engine: engine, clock: engine.clock, scrubbing: $scrubbing,
                     showRemaining: $showRemaining) { scheduleHide() }

            HStack(spacing: 22) {
                ControlChip(symbol: "lock.open", label: "Lock") {
                    withAnimation { locked = true }
                    scheduleHide()
                }
                ControlChip(symbol: fill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                            label: fill ? "Fit" : "Fill") { setFill(!fill); interacted() }
                Menu {
                    ForEach(speedOptions, id: \.self) { value in
                        Button {
                            setSpeed(value)
                        } label: {
                            if value == speed {
                                Label(speedLabel(value), systemImage: "checkmark")
                            } else {
                                Text(speedLabel(value))
                            }
                        }
                    }
                } label: {
                    ChipLabel(symbol: "gauge.with.dots.needle.67percent", label: speedLabel(speed))
                }
                if !engine.mediaChapters.isEmpty {
                    ControlChip(symbol: "list.bullet.rectangle", label: "Chapters") { panel = .chapters }
                }
                Spacer()
                ControlChip(symbol: "captions.bubble", label: "Audio & Subtitles") { panel = .tracks }
                ControlChip(symbol: "slider.horizontal.3", label: "Settings") { panel = .settings }
                if !item.queue.isEmpty {
                    ControlChip(symbol: "forward.end.fill", label: "Next") { Task { await playNext() } }
                }
            }
        }
    }

    private var lockedOverlay: some View {
        VStack {
            Spacer()
            Button {
                withAnimation { locked = false }
                scheduleHide()
            } label: {
                Label("Unlock", systemImage: "lock.fill")
                    .font(.headline)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .foregroundStyle(.white)
            .padding(.bottom, 30)
        }
    }

    // MARK: Up next

    @ViewBuilder
    private var upNextCard: some View {
        if !item.queue.isEmpty && !locked {
            UpNextOverlay(engine: engine, clock: engine.clock, next: item.queue[0], state: nextState,
                          lifted: showControls,
                          onPlay: { Task { await playNext() } },
                          onCancel: { nextState = .idle })
        }
    }

    private func startNextCountdown() {
        guard !item.queue.isEmpty, nextState == .idle else { return }
        nextState = .countdown(8)
        Task { @MainActor in
            while case .countdown(let left) = nextState {
                if left <= 0 {
                    await playNext()
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if case .countdown(let current) = nextState, current == left {
                    nextState = .countdown(left - 1)
                }
            }
        }
    }

    private func playNext() async {
        guard !item.queue.isEmpty else { return }
        nextState = .resolving
        if let next = await StreamResolver.next(after: item, addons: addons) {
            // This episode counts as watched.
            if let ref = item.watch {
                watch.record(ref, position: max(engine.duration, 1), duration: max(engine.duration, 1))
            }
            nextState = .idle
            onlineSubtitles = []
            addedSubtitleURLs = [:]
            item = next
        } else {
            nextState = .failed
        }
    }

    // MARK: Loading

    private func load() async {
        loadError = nil
        var options = LoadOptions()
        options.confirmAtmos = true
        options.httpHeaders = item.headers
        options.preferredAudioLanguages = preferredLanguages
        let resume = item.watch.flatMap { watch.resumePosition(for: $0.videoId) }

        var info: [String: Any] = [MPMediaItemPropertyTitle: item.watch?.episodeLabel ?? item.displayTitle]
        if let name = item.watch?.name, item.watch?.episodeLabel != nil {
            info[MPMediaItemPropertyArtist] = name
        }
        engine.setNowPlayingInfo(info)

        Task { await loadOnlineSubtitles() }
        Task { await loadArtwork(into: info) }

        do {
            _ = try await engine.load(url: item.url, startPosition: resume, options: options)
            if speed != 1 { engine.setRate(speed) }
            if audioDelay != 0 { engine.setAudioDelay(audioDelay) }
            engine.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        } catch is CancellationError {
            // A newer load replaced this one; not a failure.
        } catch {
            loadError = "Could not play this stream.\n\(error.localizedDescription)"
        }
    }

    private var preferredLanguages: [String] {
        Locale.preferredLanguages.compactMap { Locale(identifier: $0).language.languageCode?.identifier }
            + ["en"]
    }

    private func loadOnlineSubtitles() async {
        guard let ref = item.watch else { return }
        let sources = addons.supporting("subtitles", type: ref.type, id: ref.videoId)
        var found: [AddonSubtitle] = []
        for addon in sources {
            if let subs = try? await StremioClient.subtitles(addon, type: ref.type, id: ref.videoId) {
                found.append(contentsOf: subs)
            }
        }
        onlineSubtitles = found
    }

    private func loadArtwork(into info: [String: Any]) async {
        guard let poster = item.watch?.poster ?? item.poster, let url = URL(string: poster),
              let image = await ImagePipeline.shared.image(url, maxPixel: 600) else { return }
        var updated = info
        updated[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        engine.setNowPlayingInfo(updated)
    }

    private func recordProgress() {
        if let ref = item.watch {
            watch.record(ref, position: engine.clock.currentTime, duration: engine.duration)
        }
    }

    // MARK: Actions

    private func skip(_ delta: Double, flash: Bool) {
        let target = min(max(engine.clock.currentTime + delta, 0), max(engine.duration - 1, 0))
        Task { await engine.seek(to: target) }
        if flash {
            let previous = (seekFlash?.forward == (delta > 0)) ? (seekFlash?.seconds ?? 0) : 0
            let flashValue = SeekFlash(forward: delta > 0, seconds: previous + abs(delta))
            withAnimation(.easeOut(duration: 0.15)) { seekFlash = flashValue }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 700_000_000)
                if seekFlash == flashValue { withAnimation { seekFlash = nil } }
            }
        } else {
            interacted()
        }
    }

    private func setFill(_ value: Bool) {
        fill = value
        engine.videoGravity = value ? .resizeAspectFill : .resizeAspect
    }

    private let speedOptions: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    private func setSpeed(_ value: Float) {
        speed = value
        engine.setRate(value)
        interacted()
    }

    private func speedLabel(_ value: Float) -> String {
        value == 1 ? "1×" : String(format: "%g×", value)
    }

    private func skipSymbol(back: Bool) -> String {
        let seconds = Int(skipSeconds)
        let supported = [5, 10, 15, 30, 45, 60, 75, 90]
        let value = supported.contains(seconds) ? seconds : 10
        return back ? "gobackward.\(value)" : "goforward.\(value)"
    }

    private func errorBanner(_ text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.yellow)
            Text(text).font(.footnote).multilineTextAlignment(.center)
            HStack {
                Button("Retry") { Task { await load() } }
                    .buttonStyle(.borderedProminent)
                Button("Close") { dismiss() }
                    .buttonStyle(.bordered)
            }
        }
        .foregroundStyle(.white)
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(40)
    }
}

enum PlayerPanel: String, Identifiable {
    case tracks, settings, chapters
    var id: String { rawValue }
}

struct SeekFlash: Equatable {
    let forward: Bool
    let seconds: Double
    let stamp = UUID()
}

// MARK: - Small building blocks

struct CircleButton: View {
    let symbol: String
    var size: CGFloat = 18
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: size * 2.2, height: size * 2.2)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

struct ChipLabel: View {
    let symbol: String
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(label).font(.footnote.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.white.opacity(0.12), in: Capsule())
    }
}

struct ControlChip: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { ChipLabel(symbol: symbol, label: label) }
            .buttonStyle(.plain)
    }
}

struct SeekFlashView: View {
    let flash: SeekFlash

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: flash.forward ? "forward.fill" : "backward.fill")
                .font(.title)
            Text("\(Int(flash.seconds)) s").font(.headline)
        }
        .foregroundStyle(.white)
        .frame(width: 110, height: 110)
        .background(.ultraThinMaterial, in: Circle())
    }
}

/// Spinner while loading, seeking, rebuffering or reconnecting.
struct BufferingIndicator: View {
    @ObservedObject var engine: AetherEngine

    private var label: String? {
        switch engine.playbackPhase {
        case .loading: return "Loading"
        case .rebuffering: return "Buffering"
        case .seeking: return ""
        case .stalled(let reconnecting): return reconnecting ? "Reconnecting" : "Waiting for network"
        default: return nil
        }
    }

    var body: some View {
        if let label {
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                if !label.isEmpty {
                    Text(label).font(.footnote).foregroundStyle(.white.opacity(0.8))
                }
            }
            .allowsHitTesting(false)
        }
    }
}

/// Shows the up-next card in the last 40 seconds, or while the countdown runs. Watches the
/// clock itself so the rest of the player does not redraw on every tick.
struct UpNextOverlay: View {
    @ObservedObject var engine: AetherEngine
    @ObservedObject var clock: PlaybackClock
    let next: VideoRef
    let state: PlayerView.NextState
    let lifted: Bool
    let onPlay: () -> Void
    let onCancel: () -> Void

    var body: some View {
        let remaining = engine.duration - clock.currentTime
        let nearEnd = engine.duration > 120 && remaining < 40 && remaining > 0
        if nearEnd || state != .idle {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    UpNextCard(next: next, state: state, onPlay: onPlay, onCancel: onCancel)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, lifted ? 120 : 30)
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }
}

struct UpNextCard: View {
    let next: VideoRef
    let state: PlayerView.NextState
    let onPlay: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(url: next.poster, maxPixel: 200)
                .frame(width: 50, height: 75)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 4) {
                Text("Up next").font(.caption).foregroundStyle(.white.opacity(0.7))
                Text(next.episodeLabel ?? next.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                HStack {
                    Button(action: onPlay) {
                        switch state {
                        case .countdown(let left): Text("Play in \(left)")
                        case .resolving: HStack(spacing: 6) { ProgressView().tint(.black); Text("Finding stream") }
                        case .failed: Text("No stream found · Retry")
                        case .idle: Text("Play now")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(.black)
                    .disabled(state == .resolving)
                    if case .countdown = state {
                        Button("Cancel", action: onCancel).buttonStyle(.bordered)
                    }
                }
                .font(.footnote.weight(.semibold))
            }
        }
        .foregroundStyle(.white)
        .padding(12)
        .frame(maxWidth: 380)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Scrub bar with thumbnails

struct ScrubBar: View {
    @ObservedObject var engine: AetherEngine
    @ObservedObject var clock: PlaybackClock
    @Binding var scrubbing: Bool
    @Binding var showRemaining: Bool
    let onInteraction: () -> Void

    @State private var dragTime: Double?
    @State private var thumbnail: CGImage?
    @State private var thumbnailTask: Task<Void, Never>?

    private var duration: Double { max(engine.duration, 0.1) }
    private var shownTime: Double { dragTime ?? clock.currentTime }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let width = geo.size.width
                let fraction = min(max(shownTime / duration, 0), 1)
                let buffered = min(max(clock.bufferedPosition / duration, 0), 1)
                let barHeight: CGFloat = scrubbing ? 8 : 5

                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22)).frame(height: barHeight)
                    Capsule().fill(.white.opacity(0.4)).frame(width: width * buffered, height: barHeight)
                    Capsule().fill(.white).frame(width: width * fraction, height: barHeight)
                    Circle()
                        .fill(.white)
                        .frame(width: scrubbing ? 20 : 14, height: scrubbing ? 20 : 14)
                        .offset(x: width * fraction - (scrubbing ? 10 : 7))
                }
                .frame(height: 28)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard engine.duration > 0 else { return }
                            let f = min(max(value.location.x / width, 0), 1)
                            let time = f * duration
                            if !scrubbing { withAnimation(.easeOut(duration: 0.1)) { scrubbing = true } }
                            dragTime = time
                            requestThumbnail(time)
                        }
                        .onEnded { _ in
                            if let target = dragTime {
                                Task {
                                    await engine.seek(to: target)
                                    dragTime = nil
                                }
                            }
                            withAnimation(.easeOut(duration: 0.15)) { scrubbing = false }
                            thumbnailTask?.cancel()
                            thumbnail = nil
                            onInteraction()
                        }
                )
                .overlay(alignment: .bottomLeading) {
                    if let dragTime {
                        preview(time: dragTime)
                            .offset(x: min(max(width * fraction - 90, 0), max(width - 180, 0)), y: -40)
                            .allowsHitTesting(false)
                    }
                }
            }
            .frame(height: 28)

            HStack {
                Text(formatTime(shownTime))
                Spacer()
                Button {
                    showRemaining.toggle()
                } label: {
                    Text(showRemaining ? "-\(formatTime(max(duration - shownTime, 0)))" : formatTime(engine.duration))
                }
                .buttonStyle(.plain)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.85))
        }
    }

    private func preview(time: Double) -> some View {
        VStack(spacing: 4) {
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Text(formatTime(time))
                .font(.caption.monospacedDigit().weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.black.opacity(0.6), in: Capsule())
        }
        .frame(width: 180)
    }

    private func requestThumbnail(_ time: Double) {
        guard engine.supportsCacheBackedStills else { return }
        thumbnailTask?.cancel()
        thumbnailTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard !Task.isCancelled else { return }
            let image = await engine.scrubThumbnail(atSeconds: time, maxWidth: 360)
            if !Task.isCancelled, let image { thumbnail = image }
        }
    }
}

// MARK: - Subtitles

/// Draws the engine's subtitle cues (text and bitmap). Cues are stamped in source time, so they
/// are matched against `clock.sourceTime`, shifted by the user's offset.
struct SubtitleOverlay: View {
    @ObservedObject var engine: AetherEngine
    @ObservedObject var clock: PlaybackClock
    let offset: Double
    let scale: Double
    let background: Bool
    let lifted: Bool

    var body: some View {
        let now = clock.sourceTime - offset
        let active = engine.subtitleCues.filter { $0.startTime <= now && now <= $0.endTime }
        let text = active.compactMap { $0.text }.joined(separator: "\n")
        let images: [SubtitleImage] = active.compactMap {
            if case .image(let image) = $0.body { return image }
            return nil
        }

        GeometryReader { geo in
            ZStack {
                ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                    let rect = image.position
                    Image(decorative: image.cgImage, scale: 1)
                        .resizable()
                        .frame(width: rect.width * geo.size.width, height: rect.height * geo.size.height)
                        .position(x: rect.midX * geo.size.width, y: rect.midY * geo.size.height)
                }
                if !text.isEmpty {
                    VStack {
                        Spacer()
                        Text(text)
                            .font(.system(size: 20 * scale, weight: .semibold))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.9), radius: 2, x: 0, y: 1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(background ? Color.black.opacity(0.45) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                            .padding(.horizontal, 40)
                            .padding(.bottom, lifted ? 110 : 24)
                            .animation(.easeInOut(duration: 0.2), value: lifted)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .allowsHitTesting(false)
    }
}
