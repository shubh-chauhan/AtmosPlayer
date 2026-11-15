import SwiftUI
import AetherEngine

struct PlayerView: View {
    let item: PlayItem
    @ObservedObject var engine: AetherEngine
    @EnvironmentObject private var watch: WatchStore
    @Environment(\.dismiss) private var dismiss

    @State private var showControls = true
    @State private var showDebug = true
    @State private var loadError: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            AetherPlayerSurface(engine: engine)
                .ignoresSafeArea()

            SubtitleOverlay(engine: engine, clock: engine.clock)

            // Full-screen tap target under the controls: shows / hides them.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() } }

            if showDebug {
                DebugOverlay(engine: engine)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 52)
                    .padding(.horizontal, 10)
                    .allowsHitTesting(false)
            }

            if let loadError {
                Text(loadError)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(Color.red.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
                    .padding()
            }

            if showControls {
                controls
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .task { await load() }
        .onDisappear {
            if let ref = item.watch {
                watch.record(ref, position: engine.clock.currentTime, duration: engine.duration)
            }
            engine.stop()
            if item.securityScoped { item.url.stopAccessingSecurityScopedResource() }
        }
    }

    private var controls: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button { dismiss() } label: { Image(systemName: "xmark") }
                Text(item.displayTitle)
                    .font(.footnote)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                audioMenu
                subtitleMenu
                Button { showDebug.toggle() } label: {
                    Image(systemName: showDebug ? "ladybug.fill" : "ladybug")
                }
            }
            .font(.title3)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.55))

            Spacer()

            TransportBar(engine: engine, clock: engine.clock)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.55))
        }
        .foregroundStyle(.white)
        .tint(.white)
    }

    private var audioMenu: some View {
        Menu {
            ForEach(engine.audioTracks) { track in
                Button {
                    engine.selectAudioTrack(index: track.id)
                } label: {
                    if engine.activeAudioTrackIndex == track.id {
                        Label(audioLabel(track), systemImage: "checkmark")
                    } else {
                        Text(audioLabel(track))
                    }
                }
            }
        } label: {
            Image(systemName: "waveform")
        }
        .disabled(engine.audioTracks.isEmpty)
    }

    private var subtitleMenu: some View {
        Menu {
            Button {
                engine.clearSubtitle()
            } label: {
                if engine.activeSubtitleTrackIndex == nil {
                    Label("Off", systemImage: "checkmark")
                } else {
                    Text("Off")
                }
            }
            ForEach(engine.subtitleTracks) { track in
                Button {
                    engine.selectSubtitleTrack(index: track.id)
                } label: {
                    if engine.activeSubtitleTrackIndex == track.id {
                        Label(track.name, systemImage: "checkmark")
                    } else {
                        Text(track.name)
                    }
                }
            }
        } label: {
            Image(systemName: "captions.bubble")
        }
        .disabled(engine.subtitleTracks.isEmpty)
    }

    private func audioLabel(_ track: TrackInfo) -> String {
        var parts: [String] = [track.name]
        if track.isAtmos { parts.append("Atmos") }
        if track.isDTSX { parts.append("DTS:X") }
        if track.channels > 0 { parts.append("\(track.channels) ch") }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        loadError = nil
        var options = LoadOptions()
        // Decode a little of each E-AC-3 track up front so the Atmos badge is confirmed, not guessed.
        options.confirmAtmos = true
        // Headers the addon asked for (some debrid / proxy links need them).
        options.httpHeaders = item.headers
        let resume = item.watch.flatMap { watch.resumePosition(for: $0.videoId) }
        do {
            _ = try await engine.load(url: item.url, startPosition: resume, options: options)
        } catch is CancellationError {
            // A newer load replaced this one; not a failure.
        } catch {
            loadError = "Could not play this link.\n\(error)"
        }
    }
}

/// Play / pause, skip and the seek bar. Observes the ~10 Hz clock on its own so the rest of the
/// player screen does not redraw on every tick.
struct TransportBar: View {
    @ObservedObject var engine: AetherEngine
    @ObservedObject var clock: PlaybackClock

    @State private var scrubValue: Double?

    private var isPlaying: Bool { engine.state == .playing }
    private var canSeek: Bool { engine.duration > 0 }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 36) {
                Button { skip(-10) } label: { Image(systemName: "gobackward.10") }
                    .disabled(!canSeek)
                Button { engine.togglePlayPause() } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.largeTitle)
                }
                Button { skip(10) } label: { Image(systemName: "goforward.10") }
                    .disabled(!canSeek)
            }
            .font(.title2)

            HStack(spacing: 10) {
                Text(formatTime(scrubValue ?? clock.currentTime))
                Slider(
                    value: Binding(
                        get: { scrubValue ?? min(clock.currentTime, max(engine.duration, 1)) },
                        set: { scrubValue = $0 }
                    ),
                    in: 0...max(engine.duration, 1),
                    onEditingChanged: { editing in
                        guard !editing, let target = scrubValue else { return }
                        Task {
                            await engine.seek(to: target)
                            scrubValue = nil
                        }
                    }
                )
                .disabled(!canSeek)
                Text(formatTime(engine.duration))
            }
            .font(.caption.monospacedDigit())
        }
    }

    private func skip(_ delta: Double) {
        let target = min(max(clock.currentTime + delta, 0), max(engine.duration - 1, 0))
        Task { await engine.seek(to: target) }
    }
}

/// Draws the engine's text subtitle cues. Cues are stamped in source time, so they are matched
/// against `clock.sourceTime`, not the transport time.
struct SubtitleOverlay: View {
    @ObservedObject var engine: AetherEngine
    @ObservedObject var clock: PlaybackClock

    private var activeText: String {
        let now = clock.sourceTime
        return engine.subtitleCues
            .filter { $0.startTime <= now && now <= $0.endTime }
            .compactMap { $0.text }
            .joined(separator: "\n")
    }

    var body: some View {
        let text = activeText
        VStack {
            Spacer()
            if !text.isEmpty {
                Text(text)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .shadow(color: .black, radius: 2, x: 0, y: 1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                    .padding(.horizontal, 24)
                    .padding(.bottom, 28)
            }
        }
        .allowsHitTesting(false)
    }
}
