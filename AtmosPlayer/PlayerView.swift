import SwiftUI
import UIKit
import MediaPlayer
import AVFoundation
import EngineBundle

/// Full-screen player in the style of the Apple TV app: glass buttons, a bare centre
/// transport, the title and a thin timeline at the bottom.
struct PlayerView: View {
    /// Not observed here: the screen follows `status`, which changes only when something the
    /// layout depends on changes. Child views observe the engine for their own parts.
    let engine: AetherEngine
    @StateObject private var status = PlayerStatus()
    @EnvironmentObject private var watch: WatchStore
    @EnvironmentObject private var addons: AddonStore
    @EnvironmentObject private var coordinator: PlayerCoordinator
    /// Set while the player fades out, so a second tap can't close twice.
    @State private var closing = false
    @Environment(\.scenePhase) private var scenePhase

    /// The item playing now. Starts as the one we were opened with; "Next episode" replaces it.
    @State private var item: PlayItem
    @StateObject private var pip = PiPController()
    @StateObject private var torrent = TorrentStatsMonitor()

    @AppStorage("subtitle.scale") private var subtitleScale = 1.0
    @AppStorage("subtitle.background") private var subtitleBackground = true
    @AppStorage("player.skipSeconds") private var skipSeconds = 10.0
    @AppStorage("player.showRemaining") private var showRemaining = true

    @State private var showControls = true
    @State private var locked = false
    @State private var scrubbing = false
    @State private var hideTask: Task<Void, Never>?
    /// A menu was opened: keep the controls up (hiding them closes the menu mid-tap).
    @State private var menuHeld = false
    // Swipe for brightness / volume, hold for 2x.
    @State private var hud: AdjustmentHUD?
    @State private var swipeKind: SwipeAdjustment?
    @State private var swipeStart = 0.0
    @State private var hudHideTask: Task<Void, Never>?
    @State private var boosting = false
    @State private var rateBeforeBoost: Float = 1
    @State private var countdownTask: Task<Void, Never>?
    @State private var sidePanel: PlayerSidePanel?
    @State private var fill = false
    @State private var speed: Float = 1
    @State private var audioDelay = 0.0
    @State private var subtitleOffset = 0.0
    /// Where the centre buttons and the bottom controls sit, so subtitles can avoid them.
    @State private var centerRect = CGRect.zero
    @State private var bottomTop: CGFloat = 0
    @State private var seekFlash: SeekFlash?
    @State private var loadError: String?
    @State private var onlineSubtitles: [AddonSubtitle] = []
    @State private var addedSubtitleURLs: [String: Int] = [:]
    @State private var nextState: NextState = .idle
    /// Sleep timer: minutes until playback pauses, `SleepTimer.endOfEpisode`, or nil for off.
    @State private var sleepChoice: Int?
    @State private var sleepTask: Task<Void, Never>?
    /// One quiet retry per item when a stream fails mid-playback (a dropped connection,
    /// a debrid link that expired), resuming where it stopped.
    @State private var retriedItemId: UUID?
    /// Pictures for the timeline while scrubbing. Kept here, not in the timeline, which goes
    /// away each time the controls hide.
    @State private var stills = ScrubStillSource()
    /// Whether it was playing when the app left the screen, to come back the same way.
    @State private var playingWhenLeft = false
    /// What a tap on play / pause asked for, shown at once; the engine's own state replaces it
    /// as soon as it arrives (or after a moment, if it never changes).
    @State private var playIntent: Bool?
    @State private var playIntentReset: Task<Void, Never>?

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

    /// Until the picture (or, for audio-only, playback) is up, the loading screen shows.
    private var starting: Bool {
        loadError == nil
            && !status.hasFirstFrame
            && status.state != .playing
            && status.state != .paused
    }

    /// Playback has really begun, so the position means something.
    private var hasStarted: Bool {
        loadError == nil && engine.duration > 0
            && (engine.hasFirstFrameReadyForDisplay || engine.state == .playing || engine.state == .paused
                || engine.state == .ended)
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
                                lifted: showControls && !locked,
                                centerControls: centerRect, bottomControlsTop: bottomTop)

                HiddenVolumeView()
                    .frame(width: 1, height: 1)
                    .position(x: -50, y: -50)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                gestureLayer(size: geo.size)

                VStack(spacing: 10) {
                    if boosting {
                        SpeedBoostPill().transition(.scale(scale: 0.85).combined(with: .opacity))
                    }
                    if let hud {
                        AdjustmentHUDView(hud: hud).transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 22)
                .allowsHitTesting(false)
                .animation(.spring(response: 0.3, dampingFraction: 0.85), value: boosting)
                .animation(.spring(response: 0.3, dampingFraction: 0.85), value: hud == nil)

                if !starting {
                    BufferingIndicator(engine: engine)
                }

                if let seekFlash {
                    SeekFlashView(flash: seekFlash)
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: seekFlash.forward ? .trailing : .leading)
                        .padding(.horizontal, geo.size.width * 0.12)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                if showControls && !starting {
                    if locked {
                        lockedOverlay
                            .transition(.opacity)
                    } else {
                        controls
                            .transition(.opacity)
                    }
                }

                upNextCard

                if !locked && !starting && sidePanel == nil {
                    SkipSegmentOverlay(engine: engine, clock: engine.clock, lifted: showControls) {
                        interacted()
                    }
                }

                if let sidePanel, !starting {
                    SidePanelContainer(title: sidePanel.title, onClose: closePanel) {
                        panelContent(sidePanel)
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(2)
                }

                if starting {
                    PlayerStartupView(engine: engine, torrent: torrent,
                                      title: item.watch?.name ?? item.displayTitle,
                                      subtitle: item.watch?.episodeLabel,
                                      artwork: item.watch?.background ?? item.poster,
                                      logo: ArtworkURL.logo(forMetaId: item.watch?.metaId),
                                      isTorrent: item.stream?.isTorrent == true,
                                      onClose: { close() })
                        .transition(.opacity)
                }

                if let loadError {
                    errorBanner(loadError)
                }
            }
            .coordinateSpace(.named(SubtitleOverlay.space))
            .animation(.easeInOut(duration: 0.35), value: starting)
            .animation(.spring(response: 0.35, dampingFraction: 0.9), value: sidePanel)
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .task(id: item.id) {
            PlaybackRemote.shared.attach(engine: engine, title: item.watch?.name ?? item.displayTitle,
                                         subtitle: item.watch?.episodeLabel)
            await load()
            await saveWhilePlaying()
        }
        .onAppear {
            status.attach(engine)
            PlayerBrightness.shared.enter()
            UIApplication.shared.isIdleTimerDisabled = true
            // iPad plays in whichever way it is held; iPhone turns to landscape.
            OrientationLock.set(Device.isPad ? .all : .landscape)
            pip.attach(engine)
            scheduleHide()
        }
        .onDisappear {
            recordProgress(push: true)
            PlayerBrightness.shared.leave()
            hideTask?.cancel()
            countdownTask?.cancel()
            sleepTask?.cancel()
            torrent.stop()
            pip.stop()
            let stills = stills
            Task { await stills.reset() }
            PlaybackRemote.shared.detach()
            engine.stop()
            UIApplication.shared.isIdleTimerDisabled = false
            OrientationLock.set(AppDelegate.defaultMask)
            if item.securityScoped { item.url.stopAccessingSecurityScopedResource() }
        }
        .onChange(of: scenePhase) { old, phase in
            if old == .active {
                playingWhenLeft = status.state == .playing
                PlayerBrightness.shared.resign()
            }
            if phase == .active { PlayerBrightness.shared.resume() }
            // iOS may end the app while it's in the background; save first.
            if phase == .background { recordProgress(push: true) }
            // Back from the background: rebuild the picture iOS made the engine release, paused
            // or playing as it was left, so it shows at once and Play works.
            if phase == .active { Task { await restoreAfterBackground(play: playingWhenLeft) } }
        }
        .onChange(of: status.state) { _, state in
            if case .error(let message) = state {
                handlePlaybackFailure(message)
                return
            }
            if state == .ended {
                startNextCountdown()
            } else if case .countdown = nextState {
                // Seeking back after the end stops the countdown.
                countdownTask?.cancel()
                nextState = .idle
            }
            if state == .playing { scheduleHide() }
            if playIntent != nil {
                playIntentReset?.cancel()
                withAnimation(.snappy(duration: 0.22)) { playIntent = nil }
            }
        }
    }

    // MARK: Panels

    private func openPanel(_ which: PlayerSidePanel) {
        hideTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) { showControls = false }
        sidePanel = which
    }

    private func closePanel() {
        sidePanel = nil
        interacted()
    }

    @ViewBuilder
    private func panelContent(_ which: PlayerSidePanel) -> some View {
        switch which {
        case .tracks:
            TrackPickerPanel(engine: engine, onlineSubtitles: onlineSubtitles,
                             addedSubtitleURLs: $addedSubtitleURLs, subtitleOffset: $subtitleOffset)
        case .details:
            DebugOverlay(engine: engine, clock: engine.clock, torrent: torrent, item: item)
        case .settings:
            PlayerSettingsPanel(engine: engine, speed: $speed, audioDelay: $audioDelay,
                                subtitleOffset: $subtitleOffset, subtitleScale: $subtitleScale,
                                subtitleBackground: $subtitleBackground, skipSeconds: $skipSeconds)
        case .chapters:
            ChapterListPanel(engine: engine) { closePanel() }
        }
    }

    // MARK: Gestures

    private func gestureLayer(size: CGSize) -> some View {
        let width = size.width
        return Color.clear
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
            // Swipe up / down: brightness on the left half, volume on the right.
            .simultaneousGesture(
                DragGesture(minimumDistance: 14)
                    .onChanged { value in swipeChanged(value, size: size) }
                    .onEnded { _ in swipeEnded() }
            )
            // Hold anywhere: 2x until you let go.
            .onLongPressGesture(minimumDuration: 0.45, maximumDistance: 14) {
                startBoost()
            } onPressingChanged: { pressing in
                if !pressing { endBoost() }
            }
    }

    private func swipeChanged(_ value: DragGesture.Value, size: CGSize) {
        guard !locked, !boosting, sidePanel == nil else { return }
        if swipeKind == nil {
            // Only a mostly vertical swipe away from the very top / bottom edges counts.
            let dx = abs(value.translation.width), dy = abs(value.translation.height)
            guard dy > dx * 1.4,
                  value.startLocation.y > 40, value.startLocation.y < size.height - 40 else { return }
            let kind: SwipeAdjustment = value.startLocation.x < size.width / 2 ? .brightness : .volume
            swipeKind = kind
            swipeStart = kind == .brightness ? DeviceLevels.shared.brightness : DeviceLevels.shared.volume
            hudHideTask?.cancel()
        }
        guard let kind = swipeKind else { return }
        // A swipe across 60 % of the screen's height goes from 0 to full.
        let level = min(max(swipeStart - value.translation.height / (size.height * 0.6), 0), 1)
        switch kind {
        case .brightness:
            DeviceLevels.shared.brightness = level
            PlayerBrightness.shared.swiped(to: level)
        case .volume: DeviceLevels.shared.volume = level
        }
        hud = AdjustmentHUD(kind: kind, value: level)
    }

    private func swipeEnded() {
        guard swipeKind != nil else { return }
        swipeKind = nil
        hudHideTask?.cancel()
        hudHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            hud = nil
        }
    }

    private func startBoost() {
        guard !locked, !boosting, status.state == .playing, sidePanel == nil else { return }
        rateBeforeBoost = speed
        boosting = true
        engine.setRate(2)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func endBoost() {
        guard boosting else { return }
        boosting = false
        engine.setRate(rateBeforeBoost)
    }

    private func toggleControls() {
        menuHeld = false
        withAnimation(.easeInOut(duration: 0.25)) { showControls.toggle() }
        if showControls { scheduleHide() }
    }

    /// Hide the controls after a few seconds of no interaction while playing.
    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, engine.state == .playing, !scrubbing, sidePanel == nil, !menuHeld else { return }
            withAnimation(.easeInOut(duration: 0.35)) { showControls = false }
        }
    }

    /// Keeps the controls up while a menu is open (hiding them would close the menu).
    private func holdControls() {
        menuHeld = true
        hideTask?.cancel()
    }

    private func interacted() {
        if !showControls { withAnimation { showControls = true } }
        scheduleHide()
    }

    // MARK: Controls

    private var controls: some View {
        ZStack {
            // Soft shading so white controls read on any picture.
            LinearGradient(stops: [
                .init(color: .black.opacity(0.55), location: 0),
                .init(color: .black.opacity(0), location: 0.28),
                .init(color: .black.opacity(0), location: 0.5),
                .init(color: .black.opacity(0.8), location: 1),
            ], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            centerTransport

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                bottomArea
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
        .foregroundStyle(.white)
        .tint(.white)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            GlassIconButton(symbol: "xmark") { close() }
            if pip.isPossible {
                GlassIconButton(symbol: pip.isActive ? "pip.exit" : "pip.enter") { pip.toggle(); interacted() }
            }
            Spacer()
            AirPlayButton()
                .frame(width: 44, height: 44)
                .glass(Circle(), interactive: true)
            GlassIconButton(symbol: "lock.open.fill") {
                withAnimation { locked = true }
                scheduleHide()
            }
        }
    }

    private var isBusy: Bool { status.busy }

    /// The play / pause icon: your tap first, then the engine.
    private var showsPlaying: Bool { playIntent ?? (status.state == .playing) }

    private func togglePlayback() {
        let play = !showsPlaying
        withAnimation(.snappy(duration: 0.22)) { playIntent = play }
        if engine.needsForegroundVideoRestore {
            Task { await restoreAfterBackground(play: true) }
        } else if play {
            engine.play()
        } else {
            engine.pause()
        }
        // The engine normally answers within a beat; if it doesn't, show what it is doing.
        playIntentReset?.cancel()
        playIntentReset = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.snappy(duration: 0.22)) { playIntent = nil }
        }
        interacted()
    }

    private var centerTransport: some View {
        HStack(spacing: 70) {
            Button { skip(-skipSeconds, flash: false) } label: {
                Image(systemName: skipSymbol(back: true))
                    .font(.system(size: 34, weight: .regular))
                    .frame(width: 64, height: 64)
                    .contentShape(Circle())
            }
            Button(action: togglePlayback) {
                Image(systemName: showsPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 54, weight: .regular))
                    .frame(width: 84, height: 84)
                    .contentShape(Circle())
                    .contentTransition(.symbolEffect(.replace.downUp, options: .speed(1.5)))
                    // The buffering spinner takes this spot while it shows.
                    .opacity(isBusy && playIntent == nil ? 0 : 1)
                    .animation(.easeInOut(duration: 0.18), value: isBusy)
            }
            .buttonStyle(PressScaleButtonStyle(scale: 0.86))
            .sensoryFeedback(.impact(weight: .light), trigger: playIntent) { _, new in new != nil }
            .accessibilityLabel(showsPlaying ? "Pause" : "Play")
            Button { skip(skipSeconds, flash: false) } label: {
                Image(systemName: skipSymbol(back: false))
                    .font(.system(size: 34, weight: .regular))
                    .frame(width: 64, height: 64)
                    .contentShape(Circle())
            }
        }
        .buttonStyle(PressScaleButtonStyle())
        .shadow(color: .black.opacity(0.4), radius: 12)
        // Subtitles keep clear of these buttons while the controls show.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(SubtitleOverlay.space)) } action: { centerRect = $0 }
    }

    private var bottomArea: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    if let episode = item.watch?.episodeLabel {
                        Text(episode)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                    HStack(spacing: 8) {
                        Text(item.watch?.name ?? item.displayTitle)
                            .font(.title3.weight(.bold))
                            .lineLimit(1)
                        if let badge = status.formatBadge {
                            Text(badge.text)
                                .font(.caption2.weight(.heavy))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .foregroundStyle(badge.warning ? Color.black : Color.white)
                                .background(badge.warning ? Color.orange : Color.white.opacity(0.18),
                                            in: RoundedRectangle(cornerRadius: 4))
                                .onTapGesture { openPanel(.details) }
                        }
                    }
                }
                Spacer(minLength: 12)
                HStack(spacing: 10) {
                    speedMenu
                    audioSubtitleMenu
                    if !item.queue.isEmpty {
                        GlassIconButton(symbol: "forward.end.fill") { Task { await playNext() } }
                            .disabled(nextState == .resolving)
                    }
                    moreMenu
                }
            }
            ScrubBar(engine: engine, clock: engine.clock, stills: stills, url: item.url, headers: item.headers,
                     scrubbing: $scrubbing,
                     showRemaining: $showRemaining) { scheduleHide() }
        }
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(SubtitleOverlay.space)).minY } action: { bottomTop = $0 }
    }

    // MARK: Menus

    private var speedMenu: some View {
        SpeedMenuButton(speed: speed, options: speedOptions, label: speedLabel,
                        onOpen: holdControls, onPick: { setSpeed($0) })
            .equatable()
    }

    private var audioSubtitleMenu: some View {
        GlassIconButton(symbol: "text.bubble") { openPanel(.tracks) }
    }

    private var moreMenu: some View {
        MoreMenuButton(fill: fill, hasChapters: status.hasChapters, sleep: sleepChoice,
                       onOpen: holdControls) { action in
            menuHeld = false
            switch action {
            case .sleep(let choice):
                setSleepTimer(choice)
                interacted()
            case .fill:
                setFill(!fill)
                interacted()
            case .chapters: openPanel(.chapters)
            case .tracks: openPanel(.tracks)
            case .settings: openPanel(.settings)
            case .details: openPanel(.details)
            case .lock:
                withAnimation { locked = true }
                scheduleHide()
            }
        }
        .equatable()
    }

    private var lockedOverlay: some View {
        VStack {
            Spacer()
            Button {
                withAnimation { locked = false }
                scheduleHide()
            } label: {
                Label("Tap to Unlock", systemImage: "lock.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .contentShape(Capsule())
                    .glass(Capsule(), interactive: true)
            }
            .buttonStyle(PressScaleButtonStyle())
            .foregroundStyle(.white)
            .padding(.bottom, 24)
        }
    }

    // MARK: Up next

    @ViewBuilder
    private var upNextCard: some View {
        if !item.queue.isEmpty && !locked && !starting {
            UpNextOverlay(engine: engine, clock: engine.clock, next: item.queue[0], state: nextState,
                          lifted: showControls,
                          onPlay: { Task { await playNext() } },
                          onCancel: {
                              countdownTask?.cancel()
                              nextState = .idle
                          },
                          onNearEnd: { startNextCountdown() },
                          onLeave: {
                              if case .countdown = nextState {
                                  countdownTask?.cancel()
                                  nextState = .idle
                              }
                          })
                .id(item.id)
        }
    }

    /// Pauses after the chosen time. "End of episode" just stops the next one from starting.
    private func setSleepTimer(_ choice: Int?) {
        sleepTask?.cancel()
        sleepChoice = choice
        guard let minutes = choice, minutes > 0 else { return }
        sleepTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(minutes) * 60 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            if engine.state == .playing { engine.togglePlayPause() }
            sleepChoice = nil
            withAnimation(.easeInOut(duration: 0.2)) { showControls = true }
        }
    }

    private func startNextCountdown() {
        guard sleepChoice != SleepTimer.endOfEpisode else { return }
        guard !item.queue.isEmpty, nextState == .idle, Prefs.bool(Prefs.autoplayNext, default: true) else { return }
        let seconds = UserDefaults.standard.object(forKey: Prefs.nextCountdown) as? Int ?? 8
        nextState = .countdown(seconds)
        countdownTask?.cancel()
        countdownTask = Task { @MainActor in
            while case .countdown(let left) = nextState, !Task.isCancelled {
                if left <= 0 {
                    await playNext()
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                if case .countdown(let current) = nextState, current == left {
                    nextState = .countdown(left - 1)
                }
            }
        }
    }

    private func playNext() async {
        guard !item.queue.isEmpty, nextState != .resolving else { return }
        countdownTask?.cancel()
        let current = item
        nextState = .resolving
        if let next = await StreamResolver.next(after: current, addons: addons) {
            guard item.id == current.id else { return }
            // This episode counts as watched.
            if let ref = current.watch {
                let length = max(engine.duration, 1)
                watch.record(ref, position: length, duration: length, next: next.watch)
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

    private func handlePlaybackFailure(_ message: String) {
        // Keep the place first, so a retry (automatic or Try Again) resumes there.
        recordProgress(push: false)
        if retriedItemId != item.id, hasStarted || engine.clock.currentTime > 0 {
            retriedItemId = item.id
            let failedId = item.id
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard item.id == failedId, case .error = engine.state else { return }
                await load()
            }
            return
        }
        loadError = "Playback stopped.\n\(message)"
    }

    private func load() async {
        loadError = nil
        torrent.watch(item.stream)
        let loadingId = item.id
        var options = LoadOptions()
        options.confirmAtmos = true
        options.httpHeaders = item.headers
        options.preferredAudioLanguages = AudioPreferences.languages
        options.preferredSubtitleLanguages = SubtitlePreferences.autoLanguages
        // Picture: Dolby Vision and HDR10 / HLG as the screen shows them.
        options.panelPresentsDolbyVision = DisplayCapabilities.dolbyVision
        options.panelIsInHDRMode = DisplayCapabilities.hdr
        options.dolbyVisionHandling = VideoPreferences.dolbyVisionOn ? .automatic : .baseLayerOnly
        // Sound: TrueHD Atmos and DTS:X keep their heights (7.1.4, spatialised on AirPods).
        options.objectAudioRendering = AudioPreferences.objectAudioOn ? .render(.l714) : .off
        // Optional: map HDR10 mastered brighter than this screen to its real peak.
        if let peak = VideoPreferences.toneMapPeak {
            options.videoProcessing = VideoProcessingOptions(targetPeakNits: peak)
        }
        let resume = item.startOver ? nil
            : item.watch.flatMap { watch.resumePosition(for: $0.videoId) }.flatMap { $0 > 0 ? $0 : nil }

        var info: [String: Any] = [MPMediaItemPropertyTitle: item.watch?.episodeLabel ?? item.displayTitle]
        if let name = item.watch?.name, item.watch?.episodeLabel != nil {
            info[MPMediaItemPropertyArtist] = name
        }
        engine.setNowPlayingInfo(info)

        // Side loads check they still belong to the item playing before writing.
        Task { await loadOnlineSubtitles(for: loadingId) }
        Task { await loadArtwork(into: info, for: loadingId) }

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

    /// After a while in the background the engine releases the video (it must not hold a decoder
    /// across a suspension) and keeps the source, position and tracks; it has to be rebuilt
    /// before it can play again. Without this, Play after an app switch sat on a spinner.
    private func restoreAfterBackground(play: Bool) async {
        guard engine.needsForegroundVideoRestore, loadError == nil else { return }
        do {
            try await engine.reloadAtCurrentPosition { $0.autoplay = play }
        } catch is CancellationError {
            // A newer load or a close took over.
        } catch {
            // Can't be rebuilt in place: open it again where it was.
            recordProgress(push: false)
            await load()
        }
    }

    /// Saves the position every 30 seconds while playing (locally only), so a crash or an
    /// app kill loses little.
    private func saveWhilePlaying() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            if engine.state == .playing { recordProgress(push: false) }
        }
    }

    private func loadOnlineSubtitles(for id: UUID) async {
        guard let ref = item.watch else { return }
        let sources = addons.supporting("subtitles", type: ref.type, id: ref.videoId)
        var found: [AddonSubtitle] = []
        for addon in sources {
            if let subs = try? await StremioClient.subtitles(addon, type: ref.type, id: ref.videoId) {
                found.append(contentsOf: subs)
            }
        }
        if item.id == id { onlineSubtitles = found }
    }

    private func loadArtwork(into info: [String: Any], for id: UUID) async {
        guard let poster = item.watch?.poster ?? item.poster, let url = URL(string: poster),
              let image = await ImagePipeline.shared.image(url, maxPixel: 600),
              item.id == id else { return }
        var updated = info
        updated[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        engine.setNowPlayingInfo(updated)
    }

    private func recordProgress(push: Bool) {
        guard let ref = item.watch, hasStarted else { return }
        let next = item.queue.first
        watch.record(ref, position: engine.clock.currentTime, duration: engine.duration, next: next, push: push)
    }

    // MARK: Actions

    /// Leaves the player: sound stops at once, the picture fades back to the app, and the
    /// heavier teardown (saving, stopping the engine) runs as the player goes away.
    private func close() {
        guard !closing else { return }
        closing = true
        hideTask?.cancel()
        countdownTask?.cancel()
        sleepTask?.cancel()
        if engine.state == .playing { engine.togglePlayPause() }
        // The screen glides back to the phone's brightness as the player fades out.
        PlayerBrightness.shared.leave()
        coordinator.current = nil
    }

    private func skip(_ delta: Double, flash: Bool) {
        var target = max(engine.clock.currentTime + delta, 0)
        if engine.duration > 0 { target = min(target, max(engine.duration - 1, 0)) }
        Task {
            await engine.seek(to: target)
            PlaybackRemote.shared.refresh()
        }
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
        menuHeld = false
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
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.yellow)
            Text(text).font(.footnote).multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button {
                    Task { await load() }
                } label: {
                    Text("Try Again")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(.white, in: Capsule())
                        .foregroundStyle(.black)
                }
                Button {
                    close()
                } label: {
                    Text("Close")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .glass(Capsule(), interactive: true)
                }
            }
            .buttonStyle(PressScaleButtonStyle())
        }
        .foregroundStyle(.white)
        .padding(22)
        .frame(maxWidth: 420)
        .glass(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(40)
    }
}

struct SeekFlash: Equatable {
    let forward: Bool
    let seconds: Double
    let stamp = UUID()
}

// MARK: - Small building blocks

/// A round glass button with a symbol, the player's standard control.
struct GlassIconButton: View {
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .glass(Circle(), interactive: true)
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.92))
        .foregroundStyle(.white)
    }
}

struct SeekFlashView: View {
    let flash: SeekFlash

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: flash.forward ? "forward.fill" : "backward.fill")
                .font(.title2)
            Text("\(Int(flash.seconds)) s").font(.subheadline.weight(.semibold).monospacedDigit())
        }
        .foregroundStyle(.white)
        .frame(width: 100, height: 100)
        .glass(Circle())
    }
}

/// Spinner while loading, seeking, rebuffering or reconnecting.
struct BufferingIndicator: View {
    @ObservedObject var engine: AetherEngine

    private var label: String? {
        switch engine.playbackPhase {
        case .loading: return ""
        case .rebuffering: return "Buffering"
        case .seeking: return ""
        case .stalled(let reconnecting): return reconnecting ? "Reconnecting" : "Waiting for network"
        default: return nil
        }
    }

    var body: some View {
        if let label {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
                // Hung below the spinner, so the spinner stays dead centre whether a word shows or not.
                .overlay(alignment: .top) {
                    if !label.isEmpty {
                        Text(label).font(.footnote.weight(.medium)).foregroundStyle(.white.opacity(0.85))
                            .fixedSize()
                            .offset(y: 46)
                    }
                }
                .shadow(color: .black.opacity(0.5), radius: 8)
                .allowsHitTesting(false)
        }
    }
}

/// "Skip Intro" / "Skip Recap": shown while playback is inside a chapter the file names as an
/// intro, opening or recap, and jumps to that chapter's end. Files without named chapters
/// simply never show it. Watches the clock itself so the player does not redraw on each tick.
struct SkipSegmentOverlay: View {
    @ObservedObject var engine: AetherEngine
    @ObservedObject var clock: PlaybackClock
    let lifted: Bool
    let onSkip: () -> Void

    private struct Segment: Equatable {
        let label: String
        let end: Double
    }

    private static func label(for name: String) -> String? {
        let name = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if ["recap", "previously"].contains(where: { name.contains($0) }) { return "Skip Recap" }
        if ["intro", "opening", "main title", "title sequence", "theme song"].contains(where: { name.contains($0) })
            || ["op", "titles"].contains(name) {
            return "Skip Intro"
        }
        return nil
    }

    private var segment: Segment? {
        let chapters = engine.mediaChapters
        let duration = engine.duration
        let now = clock.currentTime
        guard duration > 300, chapters.count > 1 else { return nil }
        for (index, chapter) in chapters.enumerated() where index + 1 < chapters.count {
            let end = chapters[index + 1].startSeconds
            guard now >= chapter.startSeconds, now < end - 2 else { continue }
            // An intro sits in the first part of the episode and is short.
            guard chapter.startSeconds < duration * 0.4, end - chapter.startSeconds <= 300,
                  let label = Self.label(for: chapter.name) else { return nil }
            return Segment(label: label, end: end)
        }
        return nil
    }

    var body: some View {
        let current = segment
        VStack {
            Spacer()
            HStack {
                Spacer()
                if let current {
                    Button {
                        Task { await engine.seek(to: current.end) }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        onSkip()
                    } label: {
                        Label(current.label, systemImage: "forward.end.fill")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 18)
                            .frame(height: 44)
                            .contentShape(Capsule())
                            .glass(Capsule(), interactive: true)
                    }
                    .buttonStyle(PressScaleButtonStyle())
                    .foregroundStyle(.white)
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
                }
            }
        }
        .padding(.trailing, 24)
        .padding(.bottom, lifted ? 138 : 36)
        .animation(.easeInOut(duration: 0.25), value: current)
        .animation(.easeInOut(duration: 0.2), value: lifted)
    }
}

/// Shows the up-next card once the credits start (a "Credits" chapter, or the last stretch of
/// the episode), and while the countdown runs. Watches the clock itself so the rest of the
/// player does not redraw on every tick.
struct UpNextOverlay: View {
    @ObservedObject var engine: AetherEngine
    @ObservedObject var clock: PlaybackClock
    let next: VideoRef
    let state: PlayerView.NextState
    let lifted: Bool
    let onPlay: () -> Void
    let onCancel: () -> Void
    let onNearEnd: () -> Void
    let onLeave: () -> Void

    @State private var dismissed = false

    /// Where the end credits begin.
    private var creditsStart: Double? {
        let duration = engine.duration
        guard duration > 120 else { return nil }
        if let chapter = engine.mediaChapters.last(where: { chapter in
            let name = chapter.name.lowercased()
            return ["credit", "outro", "ending", "end title", "closing"].contains { name.contains($0) }
        }), chapter.startSeconds > duration * 0.6 {
            return chapter.startSeconds
        }
        // No chapter: about the last 3 % (45 s to 2 min), where credits usually roll.
        return duration - min(max(duration * 0.03, 45), 120)
    }

    private var nearEnd: Bool {
        guard let creditsStart else { return false }
        return clock.currentTime >= creditsStart && clock.currentTime < engine.duration
    }

    var body: some View {
        let near = nearEnd
        Group {
            if (near && !dismissed) || state != .idle {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        UpNextCard(next: next, state: state, onPlay: onPlay, onCancel: onCancel,
                                   onClose: {
                                       dismissed = true
                                       onCancel()
                                   })
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, lifted ? 130 : 30)
                .animation(.easeInOut(duration: 0.25), value: lifted)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: near && !dismissed)
        .onChange(of: near) { _, now in
            if now {
                if !dismissed { onNearEnd() }
            } else {
                dismissed = false
                onLeave()
            }
        }
    }
}

struct UpNextCard: View {
    let next: VideoRef
    let state: PlayerView.NextState
    let onPlay: () -> Void
    let onCancel: () -> Void
    var onClose: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            RemoteImage(url: next.background ?? next.poster, maxPixel: 400)
                .frame(width: 128, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text("UP NEXT").font(.caption2.weight(.bold)).foregroundStyle(.white.opacity(0.6))
                Text(next.episodeLabel ?? next.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                HStack(spacing: 8) {
                    Button(action: onPlay) {
                        Group {
                            switch state {
                            case .countdown(let left): Text("Play in \(left)")
                            case .resolving: HStack(spacing: 6) { ProgressView().tint(.black); Text("Finding stream") }
                            case .failed: Text("No stream found · Retry")
                            case .idle: Text("Play Now")
                            }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(.white, in: Capsule())
                        .foregroundStyle(.black)
                    }
                    .disabled(state == .resolving)
                    if case .countdown = state {
                        Button(action: onCancel) {
                            Text("Cancel")
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .glass(Capsule(), interactive: true)
                        }
                    }
                }
                .buttonStyle(PressScaleButtonStyle(scale: 0.94))
                .font(.footnote.weight(.semibold))
            }
        }
        .foregroundStyle(.white)
        .padding(12)
        .padding(.trailing, onClose == nil ? 0 : 26)
        .frame(maxWidth: 420)
        .overlay(alignment: .topTrailing) {
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(PressScaleButtonStyle())
                .foregroundStyle(.white.opacity(0.75))
                .padding(8)
                .accessibilityLabel("Hide Up Next")
            }
        }
        .glass(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - Timeline with thumbnails

struct ScrubBar: View {
    @ObservedObject var engine: AetherEngine
    @ObservedObject var clock: PlaybackClock
    let stills: ScrubStillSource
    /// The stream playing and its request headers, so its pictures come from the right file.
    let url: URL
    let headers: [String: String]
    @Binding var scrubbing: Bool
    @Binding var showRemaining: Bool
    let onInteraction: () -> Void

    @State private var dragTime: Double?
    /// The picture in the preview: the one for the finger's spot, or the closest one fetched so far.
    @State private var thumbnail: CGImage?
    /// Fetches pictures one at a time while scrubbing (see `runStills`).
    @State private var stillWorker: Task<Void, Never>?
    /// True only while a finger is down; resets itself if the system cancels the drag.
    @GestureState private var dragging = false

    private var duration: Double { max(engine.duration, 0.1) }
    private var shownTime: Double { dragTime ?? clock.currentTime }

    private static let previewWidth: CGFloat = 208
    private static let previewHeight: CGFloat = 117

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                let width = geo.size.width
                let fraction = min(max(shownTime / duration, 0), 1)
                let buffered = min(max(clock.bufferedPosition / duration, 0), 1)
                let barHeight: CGFloat = scrubbing ? 12 : 6

                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule().fill(.white.opacity(0.35)).frame(width: width * buffered)
                    Capsule().fill(.white).frame(width: max(width * fraction, barHeight))
                }
                .frame(height: barHeight)
                .clipShape(Capsule())
                .frame(height: 30)
                .contentShape(Rectangle())
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: scrubbing)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .updating($dragging) { _, state, _ in state = true }
                        .onChanged { value in
                            guard engine.duration > 0 else { return }
                            let f = min(max(value.location.x / width, 0), 1)
                            dragTime = f * duration
                            if !scrubbing { scrubbing = true }
                            startStills()
                        }
                        .onEnded { _ in
                            if let target = dragTime {
                                Task {
                                    await engine.seek(to: target)
                                    // A newer drag may have started meanwhile; leave its time alone.
                                    if dragTime == target, !dragging { dragTime = nil }
                                }
                            }
                            endScrub()
                        }
                )
                .onChange(of: dragging) { _, isDown in
                    // Drag cancelled by the system (Control Center, a call): no onEnded comes.
                    if !isDown, scrubbing {
                        endScrub()
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            if !dragging, !scrubbing { dragTime = nil }
                        }
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if scrubbing, let dragTime {
                        let half = Self.previewWidth / 2
                        preview(time: dragTime)
                            .offset(x: min(max(width * fraction - half, 0), max(width - Self.previewWidth, 0)), y: -44)
                            .allowsHitTesting(false)
                    }
                }
            }
            .frame(height: 30)

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
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(.white.opacity(0.8))
        }
        .onDisappear {
            stillWorker?.cancel()
            stillWorker = nil
        }
    }

    private func endScrub() {
        scrubbing = false
        stillWorker?.cancel()
        stillWorker = nil
        thumbnail = nil
        let engine = engine
        Task { await engine.releaseScrubPreviewDecoders() }
        onInteraction()
    }

    /// One fixed-size frame for the whole scrub: the picture letterboxed inside it, a spinner only
    /// until the very first picture arrives. It never resizes or disappears while the finger moves.
    private func preview(time: Double) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Color.black
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(width: Self.previewWidth, height: Self.previewHeight)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.white.opacity(0.6), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 10)
            Text(formatTime(time))
                .font(.caption.monospacedDigit().weight(.bold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .glass(Capsule())
        }
        .frame(width: Self.previewWidth)
    }

    private func startStills() {
        guard stillWorker == nil else { return }
        stillWorker = Task { @MainActor in await runStills() }
    }

    /// While the finger is down: show the closest picture already fetched at once, fetch the one
    /// for the finger's spot, and while the finger rests, fill in the spots around it. One fetch
    /// runs at a time and is never abandoned for a newer position (abandoning them is why no
    /// picture ever arrived before); when it lands, the newest position is next.
    private func runStills() async {
        let stills = stills, engine = engine, url = url, headers = headers
        var failures = 0
        while !Task.isCancelled {
            guard let target = dragTime, engine.duration > 0 else {
                try? await Task.sleep(nanoseconds: 40_000_000)
                continue
            }
            let length = engine.duration
            let cell = ScrubStillSource.cell(target, duration: length)
            if let shown = stills.picture(at: cell) ?? stills.nearest(to: cell, reach: 3), shown !== thumbnail {
                thumbnail = shown
            }
            let next = stills.wants(cell) ? cell : stills.neighbourToFill(around: cell)
            guard let next else {
                try? await Task.sleep(nanoseconds: 40_000_000)
                continue
            }
            let at = next == cell ? target : ScrubStillSource.centre(of: next, duration: length)
            let image = await stills.fetch(engine, url: url, headers: headers, cell: next, at: at)
            guard !Task.isCancelled else { return }
            if image == nil {
                failures += 1
                // A source that won't give pictures: stop asking it so often.
                if failures >= 3 { try? await Task.sleep(nanoseconds: 1_500_000_000) }
            } else {
                failures = 0
            }
        }
    }
}

/// Where scrub pictures come from, and the ones already fetched for the item playing. The timeline
/// is cut into `cells` spots that each keep one picture, so moving back over a stretch shows its
/// pictures at once, and a second scrub starts with what the first one found.
///
/// A picture comes from the engine when that part of the video is already downloaded (instant, no
/// network), else from a frame reader with its own connection to the stream. Sources that refuse
/// a second connection only show the time.
@MainActor
final class ScrubStillSource {
    static let cells = 100

    private var extractor: FrameExtractor?
    private var itemURL: URL?
    private var pictures: [Int: CGImage] = [:]
    /// Spots that just failed, not asked again for a few seconds.
    private var failedAt: [Int: Date] = [:]

    /// The spot a time falls in (the end of the timeline is the last spot).
    nonisolated static func cell(_ seconds: Double, duration: Double) -> Int {
        guard duration > 0, seconds.isFinite else { return 0 }
        return min(max(Int(seconds / duration * Double(cells)), 0), cells - 1)
    }

    /// The middle of a spot, where a filled-in picture is taken.
    nonisolated static func centre(of cell: Int, duration: Double) -> Double {
        (Double(cell) + 0.5) / Double(cells) * duration
    }

    func picture(at cell: Int) -> CGImage? { pictures[cell] }

    /// The closest picture already fetched, at most `reach` spots away.
    func nearest(to cell: Int, reach: Int) -> CGImage? {
        for distance in 1...max(reach, 1) {
            if let found = pictures[cell - distance] ?? pictures[cell + distance] { return found }
        }
        return nil
    }

    /// Whether a spot still needs its picture.
    func wants(_ cell: Int) -> Bool {
        guard cell >= 0, cell < Self.cells, pictures[cell] == nil else { return false }
        if let failed = failedAt[cell], Date().timeIntervalSince(failed) < 5 { return false }
        return true
    }

    /// The nearest spot around `cell` (up to five each way) still without a picture.
    func neighbourToFill(around cell: Int) -> Int? {
        for distance in 1...5 {
            for candidate in [cell + distance, cell - distance] where wants(candidate) { return candidate }
        }
        return nil
    }

    /// Fetches the picture at `seconds` for `cell` and keeps it.
    func fetch(_ engine: AetherEngine, url: URL, headers: [String: String], cell: Int, at seconds: Double) async -> CGImage? {
        if itemURL != url { await reset(); itemURL = url }
        var image: CGImage?
        if engine.supportsCacheBackedStills {
            image = await engine.scrubThumbnail(atSeconds: seconds, maxWidth: 320)
        }
        if image == nil, !Task.isCancelled {
            if extractor == nil { extractor = FrameExtractor(url: url, httpHeaders: headers) }
            // shortcut: asks at the playback position, which is the file's own time for nearly every
            // file; one whose first frame isn't at 0 shows a picture that far off.
            image = await extractor?.thumbnail(at: seconds, maxWidth: 320)
        }
        guard itemURL == url else { return nil }   // the episode changed meanwhile
        if let image {
            pictures[cell] = image
            failedAt[cell] = nil
        } else if !Task.isCancelled {
            failedAt[cell] = Date()
        }
        return image
    }

    /// Forgets the pictures and closes the reader (another episode, or the player closing).
    func reset() async {
        pictures = [:]
        failedAt = [:]
        itemURL = nil
        let old = extractor
        extractor = nil
        await old?.shutdown()
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
    /// The play/skip buttons and the top edge of the bottom controls, in the player's space.
    var centerControls: CGRect = .zero
    var bottomControlsTop: CGFloat = 0
    static let space = "player"
    @State private var textHeight: CGFloat = 0
    @AppStorage(Prefs.subtitleColor) private var colorName = "white"
    @AppStorage(Prefs.subtitleBold) private var bold = true
    @AppStorage(Prefs.subtitleBackgroundOpacity) private var backgroundOpacity = 0.45
    @AppStorage(Prefs.subtitleLift) private var lift = 0.0

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
                    Text(text)
                            .font(.system(size: (Device.isPad ? 28 : 20) * scale, weight: bold ? .semibold : .regular))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(SubtitlePreferences.color(colorName))
                            .shadow(color: .black.opacity(0.9), radius: 2, x: 0, y: 1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(background ? Color.black.opacity(backgroundOpacity) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                            .padding(.horizontal, 40)
                            .fixedSize(horizontal: false, vertical: true)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { textHeight = $0 }
                            .frame(maxWidth: geo.size.width)
                            .position(x: geo.size.width / 2,
                                      y: bottomEdge(in: geo) - textHeight / 2)
                            .animation(.easeInOut(duration: 0.2), value: lifted)
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// The y of the subtitle's bottom edge. With the controls up it sits between the play button
    /// and the bottom controls when it fits there, and above the play button when it doesn't
    /// (iPhone in landscape), so it never runs into either.
    private func bottomEdge(in geo: GeometryProxy) -> CGFloat {
        let resting = geo.size.height - 24 - lift
        guard lifted, bottomControlsTop > 0, centerControls != .zero else { return resting }
        let originY = geo.frame(in: .named(Self.space)).minY
        let gap: CGFloat = 10
        let aboveBottom = bottomControlsTop - originY - gap
        let belowCenter = centerControls.maxY - originY + gap
        if aboveBottom - belowCenter >= textHeight { return min(resting, aboveBottom) }
        return max(centerControls.minY - originY - gap, textHeight + 8)
    }
}


// MARK: - Menus that don't flicker

/// The playback-speed menu. Equatable on what it shows, so the player's redraws (buffering,
/// play/pause, the clock) never rebuild it while it is open; that rebuild was the flicker.
struct SpeedMenuButton: View, Equatable {
    let speed: Float
    let options: [Float]
    let label: (Float) -> String
    let onOpen: () -> Void
    let onPick: (Float) -> Void

    static func == (a: Self, b: Self) -> Bool { a.speed == b.speed && a.options == b.options }

    var body: some View {
        Menu {
            Picker("Playback Speed", selection: Binding(get: { speed }, set: onPick)) {
                ForEach(options, id: \.self) { value in
                    Text(label(value)).tag(value)
                }
            }
        } label: {
            Group {
                if speed == 1 {
                    Image(systemName: "gauge.with.dots.needle.67percent")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 44, height: 44)
                } else {
                    Text(label(speed))
                        .font(.system(size: 15, weight: .bold).monospacedDigit())
                        .frame(minWidth: 44, minHeight: 44)
                        .padding(.horizontal, 4)
                }
            }
            .contentShape(Capsule())
            .glass(Capsule(), interactive: true)
        }
        .simultaneousGesture(TapGesture().onEnded { onOpen() })
    }
}

enum SleepTimer {
    static let minutes = [15, 30, 45, 60, 90]
    static let endOfEpisode = -1

    static func label(_ choice: Int?) -> String {
        guard let choice else { return "Off" }
        return choice == endOfEpisode ? "End of Episode" : "\(choice) min"
    }
}

/// The ellipsis menu, rebuilt only when Fit/Fill or chapters change.
struct MoreMenuButton: View, Equatable {
    enum Action { case fill, chapters, tracks, settings, details, lock, sleep(Int?) }

    let fill: Bool
    let hasChapters: Bool
    var sleep: Int? = nil
    let onOpen: () -> Void
    let onAction: (Action) -> Void

    static func == (a: Self, b: Self) -> Bool {
        a.fill == b.fill && a.hasChapters == b.hasChapters && a.sleep == b.sleep
    }

    var body: some View {
        Menu {
            Button(fill ? "Fit to Screen" : "Fill Screen",
                   systemImage: fill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                onAction(.fill)
            }
            if hasChapters {
                Button("Chapters", systemImage: "list.bullet.rectangle") { onAction(.chapters) }
            }
            Button("Audio & Subtitles", systemImage: "text.bubble") { onAction(.tracks) }
            Button("Playback Settings", systemImage: "slider.horizontal.3") { onAction(.settings) }
            Button("Stream Details", systemImage: "waveform.path.ecg") { onAction(.details) }
            Menu {
                Picker("Sleep Timer", selection: Binding(get: { sleep ?? 0 },
                                                         set: { onAction(.sleep($0 == 0 ? nil : $0)) })) {
                    Text("Off").tag(0)
                    ForEach(SleepTimer.minutes, id: \.self) { Text("\($0) minutes").tag($0) }
                    Text("End of Episode").tag(SleepTimer.endOfEpisode)
                }
            } label: {
                Label(sleep == nil ? "Sleep Timer" : "Sleep Timer · \(SleepTimer.label(sleep))",
                      systemImage: sleep == nil ? "moon.zzz" : "moon.zzz.fill")
            }
            Button("Lock Controls", systemImage: "lock.fill") { onAction(.lock) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .glass(Circle(), interactive: true)
        }
        .simultaneousGesture(TapGesture().onEnded { onOpen() })
    }
}
