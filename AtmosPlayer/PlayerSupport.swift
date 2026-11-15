import SwiftUI
import AVFoundation
import Combine
import EngineBundle

// MARK: - What the player screen itself needs to know

/// The few engine values the player's own layout depends on, republished only when they actually
/// change. The engine publishes many fast-moving values (subtitle cues, buffered ranges, …); if
/// the whole player observed it directly, every one of those would rebuild every control, which
/// is what made open menus snap back and scrolling reset.
@MainActor
final class PlayerStatus: ObservableObject {
    @Published private(set) var state: PlaybackState = .idle
    @Published private(set) var hasFirstFrame = false
    @Published private(set) var busy = false
    @Published private(set) var hasChapters = false
    @Published private(set) var hasDuration = false

    private var cancellables: Set<AnyCancellable> = []
    private weak var engine: AetherEngine?

    func attach(_ engine: AetherEngine) {
        guard self.engine !== engine else { return }
        self.engine = engine
        cancellables.removeAll()
        state = engine.state
        hasFirstFrame = engine.hasFirstFrameReadyForDisplay

        engine.$state.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] in self?.state = $0 }.store(in: &cancellables)
        engine.$hasFirstFrameReadyForDisplay.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] in self?.hasFirstFrame = $0 }.store(in: &cancellables)
        engine.$playbackPhase
            .map { phase -> Bool in
                switch phase {
                case .loading, .rebuffering, .seeking, .stalled: return true
                default: return false
                }
            }
            .removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] in self?.busy = $0 }.store(in: &cancellables)
        engine.$mediaChapters.map { !$0.isEmpty }.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] in self?.hasChapters = $0 }.store(in: &cancellables)
        engine.$duration.map { $0 > 0 }.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] in self?.hasDuration = $0 }.store(in: &cancellables)
    }
}

// MARK: - Display capabilities

enum DisplayCapabilities {
    /// This iPhone's screen shows Dolby Vision (every iPhone with an HDR display does).
    static var dolbyVision: Bool {
        AVPlayer.availableHDRModes.contains(.dolbyVision)
    }

    /// This iPhone can play HDR10 / HLG in HDR.
    static var hdr: Bool {
        AVPlayer.eligibleForHDRPlayback
    }
}

// MARK: - Side panels

enum PlayerSidePanel: String, Identifiable {
    case tracks, details, settings, chapters
    var id: String { rawValue }

    var title: String {
        switch self {
        case .tracks: return "Audio & Subtitles"
        case .details: return "Stream Details"
        case .settings: return "Playback Settings"
        case .chapters: return "Chapters"
        }
    }
}

/// A glass panel on the right of the player with its own scrolling, used for every list the
/// player shows. It fits the landscape screen (unlike a sheet) and keeps its scroll position
/// while playback updates underneath it.
struct SidePanelContainer<Content: View>: View {
    let title: String
    let onClose: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .trailing) {
                // Tapping the picture closes the panel.
                Color.black.opacity(0.25)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onClose)

                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(title).font(.headline)
                        Spacer()
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .bold))
                                .frame(width: 32, height: 32)
                                .background(.white.opacity(0.15), in: Circle())
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 16)
                    .padding(.bottom, 10)

                    ScrollView {
                        content()
                            .padding(.horizontal, 18)
                            .padding(.bottom, 18)
                    }
                    .scrollIndicators(.visible)
                    .scrollBounceBehavior(.basedOnSize)
                }
                .frame(width: min(max(geo.size.width * 0.42, 320), 440))
                .frame(maxHeight: .infinity)
                .glass(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .padding(.vertical, 10)
                .padding(.trailing, 12)
            }
        }
        .foregroundStyle(.white)
        .tint(.white)
    }
}

/// One selectable line in a panel.
struct PanelRow: View {
    let title: String
    var detail: String? = nil
    var badge: String? = nil
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: "checkmark")
                    .font(.subheadline.weight(.bold))
                    .opacity(selected ? 1 : 0)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.subheadline.weight(selected ? .semibold : .regular))
                            .multilineTextAlignment(.leading)
                        if let badge {
                            Text(badge)
                                .font(.caption2.weight(.heavy))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.white, in: RoundedRectangle(cornerRadius: 3))
                                .foregroundStyle(.black)
                        }
                    }
                    if let detail, !detail.isEmpty {
                        Text(detail).font(.caption).foregroundStyle(.white.opacity(0.6))
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 10)
            .background(selected ? Color.white.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct PanelSectionHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white.opacity(0.5))
            .padding(.top, 14)
            .padding(.bottom, 4)
            .padding(.horizontal, 10)
    }
}

// MARK: - Audio & Subtitles

/// Audio tracks, subtitle tracks, online subtitles and subtitle timing.
///
/// The track lists are copied out of the engine and refreshed only when they change, so the
/// panel doesn't rebuild with every playback tick.
struct TrackPickerPanel: View {
    let engine: AetherEngine
    let onlineSubtitles: [AddonSubtitle]
    @Binding var addedSubtitleURLs: [String: Int]
    @Binding var subtitleOffset: Double

    @State private var audio: [TrackInfo] = []
    @State private var subtitles: [TrackInfo] = []
    @State private var activeAudio: Int?
    @State private var activeSubtitle: Int?
    @State private var subtitleOn = false
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            PanelSectionHeader(title: "Audio")
            if audio.isEmpty {
                Text("No audio tracks").font(.subheadline).foregroundStyle(.white.opacity(0.6)).padding(.horizontal, 10)
            }
            ForEach(audio) { track in
                PanelRow(title: track.name, detail: TrackText.audioDetail(track),
                         badge: track.isAtmos ? "ATMOS" : (track.isDTSX ? "DTS:X" : nil),
                         selected: activeAudio == track.id) {
                    engine.selectAudioTrack(index: track.id)
                }
            }

            PanelSectionHeader(title: "Subtitles")
            PanelRow(title: "Off", selected: !subtitleOn) { engine.clearSubtitle() }
            ForEach(subtitles.filter { !addedTrackIds.contains($0.id) }) { track in
                PanelRow(title: track.name, detail: TrackText.subtitleDetail(track),
                         selected: subtitleOn && activeSubtitle == track.id) {
                    engine.selectSubtitleTrack(index: track.id)
                }
            }

            if subtitleOn {
                PanelSectionHeader(title: "Subtitle timing")
                HStack(spacing: 10) {
                    timingButton("minus", -0.25)
                    Text(subtitleOffset == 0 ? "In sync" : String(format: "%+.2f s", subtitleOffset))
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .frame(maxWidth: .infinity)
                    timingButton("plus", 0.25)
                }
                .padding(.horizontal, 10)
                if subtitleOffset != 0 {
                    Button("Reset timing") { subtitleOffset = 0 }
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.top, 4)
                }
            }

            if !onlineSubtitles.isEmpty {
                PanelSectionHeader(title: "Online subtitles")
                ForEach(groupedOnline, id: \.language) { group in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if expanded.contains(group.language) {
                                expanded.remove(group.language)
                            } else {
                                expanded.insert(group.language)
                            }
                        }
                    } label: {
                        HStack {
                            Text(group.language).font(.subheadline.weight(.semibold))
                            Text("\(group.subs.count)").font(.caption).foregroundStyle(.white.opacity(0.5))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                                .rotationEffect(.degrees(expanded.contains(group.language) ? 90 : 0))
                        }
                        .padding(.vertical, 9)
                        .padding(.horizontal, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if expanded.contains(group.language) {
                        ForEach(Array(group.subs.enumerated()), id: \.element.id) { index, sub in
                            PanelRow(title: "\(group.language) \(index + 1)",
                                     selected: isSelected(sub)) {
                                select(sub, name: "\(group.language) \(index + 1)")
                            }
                            .padding(.leading, 12)
                        }
                    }
                }
            }
        }
        .onAppear {
            audio = engine.audioTracks
            subtitles = engine.subtitleTracks
            activeAudio = engine.activeAudioTrackIndex
            activeSubtitle = engine.activeSubtitleTrackIndex
            subtitleOn = engine.isSubtitleActive
            if expanded.isEmpty, let first = groupedOnline.first { expanded = [first.language] }
        }
        .onReceive(engine.$audioTracks.removeDuplicates()) { audio = $0 }
        .onReceive(engine.$subtitleTracks.removeDuplicates()) { subtitles = $0 }
        .onReceive(engine.$activeAudioTrackIndex.removeDuplicates()) { activeAudio = $0 }
        .onReceive(engine.$activeSubtitleTrackIndex.removeDuplicates()) { activeSubtitle = $0 }
        .onReceive(engine.$isSubtitleActive.removeDuplicates()) { subtitleOn = $0 }
    }

    private func timingButton(_ symbol: String, _ step: Double) -> some View {
        Button {
            subtitleOffset = min(max(((subtitleOffset + step) * 100).rounded() / 100, -10), 10)
        } label: {
            Image(systemName: symbol)
                .font(.subheadline.weight(.bold))
                .frame(width: 44, height: 36)
                .background(.white.opacity(0.15), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.92))
    }

    private struct LanguageGroup {
        let language: String
        let subs: [AddonSubtitle]
    }

    private var groupedOnline: [LanguageGroup] {
        var order: [String] = []
        var groups: [String: [AddonSubtitle]] = [:]
        for sub in onlineSubtitles {
            let name = sub.languageName
            if groups[name] == nil { order.append(name) }
            groups[name, default: []].append(sub)
        }
        let preferred = Locale.current.localizedString(forLanguageCode: Locale.current.language.languageCode?.identifier ?? "en")
        order.sort { a, b in
            if a == preferred { return true }
            if b == preferred { return false }
            if a == "English" { return true }
            if b == "English" { return false }
            return a < b
        }
        return order.map { LanguageGroup(language: $0, subs: groups[$0] ?? []) }
    }

    private var addedTrackIds: Set<Int> {
        Set(addedSubtitleURLs.values)
    }

    private func isSelected(_ sub: AddonSubtitle) -> Bool {
        guard let id = addedSubtitleURLs[sub.url] else { return false }
        return subtitleOn && activeSubtitle == id
    }

    private func select(_ sub: AddonSubtitle, name: String) {
        if let existing = addedSubtitleURLs[sub.url] {
            engine.selectSubtitleTrack(index: existing)
            return
        }
        guard let url = URL(string: sub.url) else { return }
        let track = engine.addExternalSubtitleTrack(
            ExternalSubtitleTrack(url: url, name: "\(name) (online)", language: sub.lang))
        addedSubtitleURLs[sub.url] = track.id
        engine.selectSubtitleTrack(index: track.id)
    }
}

/// How tracks are described in the panels.
enum TrackText {
    static func audioDetail(_ track: TrackInfo) -> String {
        var parts: [String] = [track.codec.uppercased()]
        if let layout = track.channelLayout { parts.append(layout) } else if track.channels > 0 { parts.append("\(track.channels) ch") }
        if track.bitrate > 0 { parts.append("\(track.bitrate / 1000) kbps") }
        if track.isCommentary { parts.append("Commentary") }
        return parts.joined(separator: " · ")
    }

    static func subtitleDetail(_ track: TrackInfo) -> String? {
        var parts: [String] = [track.codec.uppercased()]
        if track.isForced { parts.append("Forced") }
        if track.isHearingImpaired { parts.append("SDH") }
        if track.isExternal { parts.append("External") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Settings

struct PlayerSettingsPanel: View {
    let engine: AetherEngine
    @Binding var speed: Float
    @Binding var audioDelay: Double
    @Binding var subtitleOffset: Double
    @Binding var subtitleScale: Double
    @Binding var subtitleBackground: Bool
    @Binding var skipSeconds: Double
    @AppStorage(VideoPreferences.dolbyVisionKey) private var dolbyVisionOn = true
    @State private var reloading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PanelSectionHeader(title: "Playback")
            optionRow("Speed") {
                ForEach([Float(0.5), 0.75, 1, 1.25, 1.5, 2], id: \.self) { value in
                    chip(value == 1 ? "1×" : String(format: "%g×", value), selected: speed == value) {
                        speed = value
                        engine.setRate(value)
                    }
                }
            }
            optionRow("Skip interval") {
                ForEach([5.0, 10, 15, 30], id: \.self) { value in
                    chip("\(Int(value)) s", selected: skipSeconds == value) { skipSeconds = value }
                }
            }

            PanelSectionHeader(title: "Audio sync")
            stepperRow(value: audioDelay, label: offsetLabel(audioDelay)) { delta in
                audioDelay = min(max(((audioDelay + delta) * 20).rounded() / 20, -3), 3)
                engine.setAudioDelay(audioDelay)
            }
            Text("Positive values play the sound later.")
                .font(.caption).foregroundStyle(.white.opacity(0.5)).padding(.horizontal, 10)

            PanelSectionHeader(title: "Subtitles")
            stepperRow(value: subtitleOffset, label: offsetLabel(subtitleOffset), step: 0.1) { delta in
                subtitleOffset = min(max(((subtitleOffset + delta) * 10).rounded() / 10, -10), 10)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Size \(Int(subtitleScale * 100))%").font(.subheadline)
                Slider(value: $subtitleScale, in: 0.6...2.0, step: 0.1)
            }
            .padding(.horizontal, 10)
            Toggle("Background behind text", isOn: $subtitleBackground)
                .font(.subheadline)
                .padding(.horizontal, 10)

            PanelSectionHeader(title: "Video")
            Toggle(isOn: Binding(get: { dolbyVisionOn }, set: { setDolbyVision($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dolby Vision").font(.subheadline)
                    Text(reloading ? "Applying…" : "Turn off to play a Dolby Vision file's HDR10 picture instead, if its colours look wrong.")
                        .font(.caption).foregroundStyle(.white.opacity(0.5))
                }
            }
            .disabled(reloading)
            .padding(.horizontal, 10)
        }
    }

    private func setDolbyVision(_ on: Bool) {
        dolbyVisionOn = on
        reloading = true
        Task {
            _ = try? await engine.reloadAtCurrentPosition { options in
                options.dolbyVisionHandling = on ? .automatic : .baseLayerOnly
            }
            reloading = false
        }
    }

    private func optionRow<C: View>(_ title: String, @ViewBuilder _ chips: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) { chips() }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private func chip(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.footnote.weight(.semibold).monospacedDigit())
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(selected ? Color.white : Color.white.opacity(0.15), in: Capsule())
                .foregroundStyle(selected ? Color.black : Color.white)
        }
        .buttonStyle(.plain)
    }

    private func stepperRow(value: Double, label: String, step: Double = 0.05,
                            change: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 10) {
            Button { change(-step) } label: {
                Image(systemName: "minus").font(.subheadline.weight(.bold))
                    .frame(width: 44, height: 36).background(.white.opacity(0.15), in: Capsule())
            }
            Text(label).font(.subheadline.monospacedDigit().weight(.semibold)).frame(maxWidth: .infinity)
            Button { change(step) } label: {
                Image(systemName: "plus").font(.subheadline.weight(.bold))
                    .frame(width: 44, height: 36).background(.white.opacity(0.15), in: Capsule())
            }
            if value != 0 {
                Button { change(-value) } label: {
                    Image(systemName: "arrow.counterclockwise").font(.subheadline.weight(.bold))
                        .frame(width: 36, height: 36).background(.white.opacity(0.15), in: Circle())
                }
            }
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.92))
        .padding(.horizontal, 10)
    }

    private func offsetLabel(_ value: Double) -> String {
        value == 0 ? "Off" : String(format: "%+.2f s", value)
    }
}

enum VideoPreferences {
    static let dolbyVisionKey = "video.dolbyVision"
    static var dolbyVisionOn: Bool { UserDefaults.standard.object(forKey: dolbyVisionKey) as? Bool ?? true }
}

// MARK: - Chapters

struct ChapterListPanel: View {
    let engine: AetherEngine
    let onPick: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(engine.mediaChapters) { chapter in
                PanelRow(title: chapter.name.isEmpty ? "Chapter \(chapter.id + 1)" : chapter.name,
                         detail: formatTime(chapter.startSeconds), selected: false) {
                    Task { await engine.seek(to: chapter.startSeconds) }
                    onPick()
                }
            }
        }
        .padding(.top, 4)
    }
}
