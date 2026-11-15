import SwiftUI
import UIKit

// MARK: - Stored preferences

/// Keys and defaults for everything in Settings, so the player and the screens agree.
enum Prefs {
    // Playback
    static let skipSeconds = "player.skipSeconds"
    static let showRemaining = "player.showRemaining"
    static let autoplayNext = "player.autoplayNext"
    static let nextCountdown = "player.nextCountdown"
    // Audio
    static let audioLanguage = "audio.language"            // "device" or an ISO 639-1 code
    static let objectAudio = "audio.objectRendering"       // TrueHD / DTS:X heights
    // Subtitles
    static let subtitleLanguage = "subtitle.language"      // "off", "device" or a code
    static let subtitleScale = "subtitle.scale"
    static let subtitleBackground = "subtitle.background"
    static let subtitleBackgroundOpacity = "subtitle.backgroundOpacity"
    static let subtitleColor = "subtitle.color"            // "white", "yellow", "cyan"
    static let subtitleBold = "subtitle.bold"
    static let subtitleLift = "subtitle.lift"              // extra distance from the bottom, points
    // Streams
    static let atmosOnly = "streams.atmosOnly"

    static func bool(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }
}

/// Languages offered in the pickers.
enum LanguageChoices {
    static let codes = ["en", "hi", "es", "fr", "de", "it", "pt", "ja", "ko", "zh", "ar", "ru",
                        "ta", "te", "ml", "kn", "bn", "mr", "pa", "gu", "tr", "nl", "pl", "sv", "th", "id"]

    static func name(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? code
    }

    static var device: [String] {
        Locale.preferredLanguages.compactMap { Locale(identifier: $0).language.languageCode?.identifier }
    }
}

enum AudioPreferences {
    /// Preferred audio languages for a load: the chosen one, then the device's, then English.
    static var languages: [String] {
        let chosen = UserDefaults.standard.string(forKey: Prefs.audioLanguage) ?? "device"
        var list = chosen == "device" ? LanguageChoices.device : [chosen] + LanguageChoices.device
        list.append("en")
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }

    static var objectAudioOn: Bool { Prefs.bool(Prefs.objectAudio, default: true) }
}

enum SubtitlePreferences {
    /// Languages whose subtitles turn on by themselves; empty means subtitles start off.
    static var autoLanguages: [String] {
        let chosen = UserDefaults.standard.string(forKey: Prefs.subtitleLanguage) ?? "off"
        switch chosen {
        case "off": return []
        case "device": return LanguageChoices.device
        default: return [chosen]
        }
    }

    static func color(_ name: String) -> Color {
        switch name {
        case "yellow": return Color(red: 1, green: 0.9, blue: 0.2)
        case "cyan": return Color(red: 0.5, green: 0.95, blue: 1)
        default: return .white
        }
    }
}

// MARK: - Settings screen

struct AppSettingsView: View {
    @EnvironmentObject private var watch: WatchStore
    @EnvironmentObject private var history: HistoryStore

    @AppStorage(Prefs.skipSeconds) private var skipSeconds = 10.0
    @AppStorage(Prefs.showRemaining) private var showRemaining = true
    @AppStorage(Prefs.autoplayNext) private var autoplayNext = true
    @AppStorage(Prefs.nextCountdown) private var nextCountdown = 8
    @AppStorage(Prefs.audioLanguage) private var audioLanguage = "device"
    @AppStorage(Prefs.objectAudio) private var objectAudio = true
    @AppStorage(VideoPreferences.dolbyVisionKey) private var dolbyVision = true
    @AppStorage(Prefs.subtitleLanguage) private var subtitleLanguage = "off"
    @AppStorage(Prefs.subtitleScale) private var subtitleScale = 1.0
    @AppStorage(Prefs.subtitleBackground) private var subtitleBackground = true
    @AppStorage(Prefs.subtitleBackgroundOpacity) private var subtitleBackgroundOpacity = 0.45
    @AppStorage(Prefs.subtitleColor) private var subtitleColor = "white"
    @AppStorage(Prefs.subtitleBold) private var subtitleBold = true
    @AppStorage(Prefs.subtitleLift) private var subtitleLift = 0.0
    @AppStorage(Prefs.atmosOnly) private var atmosOnly = false

    @State private var cacheCleared = false
    @State private var confirmClearWatch = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Playback") {
                    Picker("Skip buttons", selection: $skipSeconds) {
                        ForEach([5.0, 10, 15, 30], id: \.self) { Text("\(Int($0)) seconds").tag($0) }
                    }
                    Toggle("Show time remaining", isOn: $showRemaining)
                    Toggle("Play next episode automatically", isOn: $autoplayNext)
                    if autoplayNext {
                        Picker("Countdown", selection: $nextCountdown) {
                            ForEach([5, 8, 10, 15], id: \.self) { Text("\($0) seconds").tag($0) }
                        }
                    }
                }

                Section {
                    Picker("Preferred language", selection: $audioLanguage) {
                        Text("Same as iPhone").tag("device")
                        ForEach(LanguageChoices.codes, id: \.self) { Text(LanguageChoices.name($0)).tag($0) }
                    }
                    Toggle("TrueHD & DTS:X heights", isOn: $objectAudio)
                } header: {
                    Text("Audio")
                } footer: {
                    Text("Dolby Atmos in E-AC-3 always reaches your AirPods untouched. With heights on, TrueHD Atmos and DTS:X are rendered to 7.1.4 and spatialised too.")
                }

                Section {
                    Toggle("Dolby Vision", isOn: $dolbyVision)
                } header: {
                    Text("Video")
                } footer: {
                    Text("Dolby Vision, HDR10 and HLG play in HDR on this iPhone. Turn Dolby Vision off only if a file's colours look wrong; it then plays its HDR10 picture.")
                }

                Section("Subtitles") {
                    Picker("Turn on automatically", selection: $subtitleLanguage) {
                        Text("Never").tag("off")
                        Text("iPhone language").tag("device")
                        ForEach(LanguageChoices.codes, id: \.self) { Text(LanguageChoices.name($0)).tag($0) }
                    }
                    SubtitlePreview(scale: subtitleScale, color: subtitleColor, bold: subtitleBold,
                                    background: subtitleBackground, opacity: subtitleBackgroundOpacity)
                        .listRowInsets(EdgeInsets())
                    VStack(alignment: .leading) {
                        LabeledContent("Size", value: "\(Int(subtitleScale * 100))%")
                        Slider(value: $subtitleScale, in: 0.6...2.0, step: 0.1)
                    }
                    Picker("Colour", selection: $subtitleColor) {
                        Text("White").tag("white")
                        Text("Yellow").tag("yellow")
                        Text("Cyan").tag("cyan")
                    }
                    Toggle("Bold", isOn: $subtitleBold)
                    Toggle("Background", isOn: $subtitleBackground)
                    if subtitleBackground {
                        VStack(alignment: .leading) {
                            LabeledContent("Background opacity", value: "\(Int(subtitleBackgroundOpacity * 100))%")
                            Slider(value: $subtitleBackgroundOpacity, in: 0.1...1.0, step: 0.05)
                        }
                    }
                    VStack(alignment: .leading) {
                        LabeledContent("Raise from bottom", value: "\(Int(subtitleLift)) pt")
                        Slider(value: $subtitleLift, in: 0...80, step: 4)
                    }
                }

                Section("Streams") {
                    Toggle("Show Dolby Atmos streams only", isOn: $atmosOnly)
                }

                Section("Storage") {
                    Button(cacheCleared ? "Image cache cleared" : "Clear image cache") {
                        ImagePipeline.shared.clearAll()
                        cacheCleared = true
                    }
                    .disabled(cacheCleared)
                    Button("Clear Continue Watching", role: .destructive) { confirmClearWatch = true }
                    Button("Clear recent links", role: .destructive) { history.clear() }
                        .disabled(history.entries.isEmpty)
                }

                Section("About") {
                    LabeledContent("Version", value: appVersion)
                    LabeledContent("Player engine", value: "AetherEngine")
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog("Clear Continue Watching on this iPhone?", isPresented: $confirmClearWatch,
                                titleVisibility: .visible) {
                Button("Clear", role: .destructive) { watch.clearAll() }
            } message: {
                Text("Resume points are removed here. Your Stremio account isn't changed.")
            }
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
        return "\(version) (\(build))"
    }
}

/// A frame of video with a sample subtitle in the chosen style.
struct SubtitlePreview: View {
    let scale: Double
    let color: String
    let bold: Bool
    let background: Bool
    let opacity: Double

    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [Color(red: 0.15, green: 0.2, blue: 0.35), Color(red: 0.35, green: 0.25, blue: 0.2)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Text("Where are you going?\nWe're not done yet.")
                .font(.system(size: 15 * scale, weight: bold ? .semibold : .regular))
                .multilineTextAlignment(.center)
                .foregroundStyle(SubtitlePreferences.color(color))
                .shadow(color: .black.opacity(0.9), radius: 2, x: 0, y: 1)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(background ? Color.black.opacity(opacity) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5))
                .padding(.bottom, 12)
        }
        .frame(height: 150)
        .clipped()
    }
}
