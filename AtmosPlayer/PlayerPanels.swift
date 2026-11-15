import SwiftUI
import AetherEngine

/// Audio tracks, embedded / external subtitles, and subtitles from subtitle addons.
struct TracksPanel: View {
    @ObservedObject var engine: AetherEngine
    let onlineSubtitles: [AddonSubtitle]
    @Binding var addedSubtitleURLs: [String: Int]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Audio") {
                    if engine.audioTracks.isEmpty {
                        Text("No audio tracks").foregroundStyle(.secondary)
                    }
                    ForEach(engine.audioTracks) { track in
                        Button {
                            engine.selectAudioTrack(index: track.id)
                        } label: {
                            TrackRow(title: track.name, detail: audioDetail(track),
                                     selected: engine.activeAudioTrackIndex == track.id,
                                     badge: track.isAtmos ? "ATMOS" : (track.isDTSX ? "DTS:X" : nil))
                        }
                    }
                }

                Section("Subtitles") {
                    Button {
                        engine.clearSubtitle()
                    } label: {
                        TrackRow(title: "Off", detail: nil, selected: !engine.isSubtitleActive, badge: nil)
                    }
                    ForEach(engine.subtitleTracks) { track in
                        Button {
                            engine.selectSubtitleTrack(index: track.id)
                        } label: {
                            TrackRow(title: track.name, detail: subtitleDetail(track),
                                     selected: engine.activeSubtitleTrackIndex == track.id, badge: nil)
                        }
                    }
                }

                if !onlineSubtitles.isEmpty {
                    Section("Online subtitles") {
                        ForEach(groupedOnline, id: \.0) { language, subs in
                            DisclosureGroup("\(language) (\(subs.count))") {
                                ForEach(Array(subs.enumerated()), id: \.element.id) { index, sub in
                                    Button {
                                        select(sub, index: index)
                                    } label: {
                                        TrackRow(title: "\(language) \(index + 1)", detail: nil,
                                                 selected: isSelected(sub), badge: nil)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .tint(.primary)
            .navigationTitle("Audio & Subtitles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .scrollContentBackground(.hidden)
        }
    }

    private var groupedOnline: [(String, [AddonSubtitle])] {
        var order: [String] = []
        var groups: [String: [AddonSubtitle]] = [:]
        for sub in onlineSubtitles {
            let name = sub.languageName
            if groups[name] == nil { order.append(name) }
            groups[name, default: []].append(sub)
        }
        // The device's language first.
        let preferred = Locale.current.localizedString(forLanguageCode: Locale.current.language.languageCode?.identifier ?? "en")
        order.sort { a, b in
            if a == preferred { return true }
            if b == preferred { return false }
            return a < b
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    // The engine reports no index while an external file is showing, so remember which one we picked.
    private static let activeKey = "__active"

    private func isSelected(_ sub: AddonSubtitle) -> Bool {
        guard let id = addedSubtitleURLs[sub.url] else { return false }
        return engine.isSubtitleActive && engine.activeSubtitleTrackIndex == nil
            && addedSubtitleURLs[Self.activeKey] == id
    }

    private func select(_ sub: AddonSubtitle, index: Int) {
        if let existing = addedSubtitleURLs[sub.url] {
            engine.selectSubtitleTrack(index: existing)
            addedSubtitleURLs[Self.activeKey] = existing
            return
        }
        guard let url = URL(string: sub.url) else { return }
        let track = engine.addExternalSubtitleTrack(
            ExternalSubtitleTrack(url: url, name: "\(sub.languageName) \(index + 1) (online)", language: sub.lang))
        addedSubtitleURLs[sub.url] = track.id
        addedSubtitleURLs[Self.activeKey] = track.id
        engine.selectSubtitleTrack(index: track.id)
    }

    private func audioDetail(_ track: TrackInfo) -> String {
        var parts: [String] = []
        parts.append(track.codec.uppercased())
        if let layout = track.channelLayout { parts.append(layout) } else if track.channels > 0 { parts.append("\(track.channels) ch") }
        if track.bitrate > 0 { parts.append("\(track.bitrate / 1000) kbps") }
        if track.isCommentary { parts.append("Commentary") }
        return parts.joined(separator: " · ")
    }

    private func subtitleDetail(_ track: TrackInfo) -> String? {
        var parts: [String] = [track.codec.uppercased()]
        if track.isForced { parts.append("Forced") }
        if track.isHearingImpaired { parts.append("SDH") }
        if track.isExternal { parts.append("External") }
        return parts.joined(separator: " · ")
    }
}

struct TrackRow: View {
    let title: String
    let detail: String?
    let selected: Bool
    let badge: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark")
                .font(.body.weight(.semibold))
                .opacity(selected ? 1 : 0)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                    if let badge {
                        Text(badge)
                            .font(.caption2.weight(.heavy))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(lineWidth: 1))
                    }
                }
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }
}

/// Playback speed, audio sync, subtitle timing and look, skip interval, debug info.
struct SettingsPanel: View {
    @ObservedObject var engine: AetherEngine
    @Binding var speed: Float
    @Binding var audioDelay: Double
    @Binding var subtitleOffset: Double
    @Binding var subtitleScale: Double
    @Binding var subtitleBackground: Bool
    @Binding var showDebug: Bool
    @Binding var skipSeconds: Double
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Playback") {
                    Picker("Speed", selection: Binding(
                        get: { speed },
                        set: { speed = $0; engine.setRate($0) })) {
                        ForEach([Float(0.5), 0.75, 1, 1.25, 1.5, 2], id: \.self) { value in
                            Text(value == 1 ? "Normal" : String(format: "%g×", value)).tag(value)
                        }
                    }
                    Picker("Skip interval", selection: $skipSeconds) {
                        ForEach([5.0, 10, 15, 30], id: \.self) { value in
                            Text("\(Int(value)) seconds").tag(value)
                        }
                    }
                }

                Section {
                    Stepper(value: Binding(
                        get: { audioDelay },
                        set: { audioDelay = ($0 * 20).rounded() / 20; engine.setAudioDelay(audioDelay) }),
                            in: -3...3, step: 0.05) {
                        LabeledContent("Audio delay", value: offsetLabel(audioDelay))
                    }
                    if audioDelay != 0 {
                        Button("Reset audio delay") { audioDelay = 0; engine.setAudioDelay(0) }
                    }
                } header: {
                    Text("Audio sync")
                } footer: {
                    Text("Positive values play the sound later. Bluetooth headphones add their own delay, which iOS already compensates for.")
                }

                Section("Subtitles") {
                    Stepper(value: Binding(
                        get: { subtitleOffset },
                        set: { subtitleOffset = ($0 * 10).rounded() / 10 }),
                            in: -10...10, step: 0.1) {
                        LabeledContent("Timing", value: offsetLabel(subtitleOffset))
                    }
                    if subtitleOffset != 0 {
                        Button("Reset timing") { subtitleOffset = 0 }
                    }
                    VStack(alignment: .leading) {
                        LabeledContent("Size", value: "\(Int(subtitleScale * 100))%")
                        Slider(value: $subtitleScale, in: 0.6...2.0, step: 0.1)
                    }
                    Toggle("Background", isOn: $subtitleBackground)
                }

                Section {
                    Toggle("Show playback info", isOn: $showDebug)
                } footer: {
                    Text("Shows the audio format, whether Dolby Atmos reaches your headphones, and the engine log.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .scrollContentBackground(.hidden)
        }
    }

    private func offsetLabel(_ value: Double) -> String {
        if value == 0 { return "Off" }
        return String(format: "%+.2f s", value)
    }
}

struct ChaptersPanel: View {
    @ObservedObject var engine: AetherEngine
    let onPick: () -> Void

    var body: some View {
        NavigationStack {
            List(engine.mediaChapters) { chapter in
                Button {
                    Task { await engine.seek(to: chapter.startSeconds) }
                    onPick()
                } label: {
                    HStack {
                        Text(chapter.name.isEmpty ? "Chapter \(chapter.id + 1)" : chapter.name)
                        Spacer()
                        Text(formatTime(chapter.startSeconds))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(.primary)
            }
            .navigationTitle("Chapters")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
        }
    }
}
