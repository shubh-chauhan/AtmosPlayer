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
    @AppStorage(TrailerPreviews.key) private var trailerPreviews = true
    @AppStorage(Prefs.showRemaining) private var showRemaining = true
    @AppStorage(Prefs.autoplayNext) private var autoplayNext = true
    @AppStorage(Prefs.nextCountdown) private var nextCountdown = 8
    @AppStorage(Prefs.audioLanguage) private var audioLanguage = "device"
    @AppStorage(Prefs.objectAudio) private var objectAudio = true
    @AppStorage(VideoPreferences.dolbyVisionKey) private var dolbyVision = true
    @AppStorage(VideoPreferences.toneMapKey) private var toneMapPeak = 0
    @AppStorage(Prefs.subtitleLanguage) private var subtitleLanguage = "off"
    @AppStorage(Prefs.subtitleScale) private var subtitleScale = 1.0
    @AppStorage(Prefs.subtitleBackground) private var subtitleBackground = true
    @AppStorage(Prefs.subtitleBackgroundOpacity) private var subtitleBackgroundOpacity = 0.45
    @AppStorage(Prefs.subtitleColor) private var subtitleColor = "white"
    @AppStorage(Prefs.subtitleBold) private var subtitleBold = true
    @AppStorage(Prefs.subtitleLift) private var subtitleLift = 0.0
    @AppStorage(StreamFilterStore.key) private var savedFilters = ""
    @AppStorage(QuickPlay.autoPickKey) private var autoPickBest = false

    @State private var cacheCleared = false
    @State private var confirmClearWatch = false
    @AppStorage(TMDB.regionKey) private var region = ""
    private static let regions = ["US", "GB", "IN", "CA", "AU", "IE", "DE", "FR", "ES", "IT", "NL", "SE", "NO", "DK", "BR", "MX", "JP", "KR"]

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
                    Toggle("Trailer previews", isOn: $trailerPreviews)
                } header: {
                    Text("Browsing")
                } footer: {
                    Text("Muted trailers play in the big cards on Home and behind title pages after a moment. Never in Low Power Mode.")
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
                    Picker("HDR10 tone mapping", selection: $toneMapPeak) {
                        Text("Off").tag(0)
                        Text("1000 nits").tag(1000)
                        Text("1200 nits").tag(1200)
                        Text("1600 nits (Pro iPhones)").tag(1600)
                        Text("2000 nits").tag(2000)
                    }
                } header: {
                    Text("Video")
                } footer: {
                    Text("Dolby Vision, HDR10 and HLG play in HDR on this iPhone. Turn Dolby Vision off only if a file's colours look wrong; it then plays its HDR10 picture.\n\nTone mapping keeps detail in HDR10 films mastered brighter than your screen (often 4000 nits) by mapping them to its real peak. Pick your iPhone's HDR peak brightness. Those films then play on the engine's own renderer: Picture in Picture is unavailable and E-AC-3 Atmos plays as its 5.1/7.1 bed. Dolby Vision, HDR10+ and HLG are not affected.")
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

                Section {
                    Toggle("Play starts the best stream", isOn: $autoPickBest)
                    Toggle("Show Dolby Atmos streams only", isOn: atmosOnly)
                    if !savedFilters.isEmpty {
                        Button("Clear stream filters") { savedFilters = "" }
                    }
                } header: {
                    Text("Streams")
                } footer: {
                    Text("The first time you play a title you choose its stream; after that Play starts the one you chose. With the best stream on, Play instead starts the highest quality stream your addons have (resolution, then Dolby Vision or HDR, then Atmos) within your stream filters. Touch and hold Play to choose one any time.\n\nFilter by quality, HDR, audio, codec and source from the chips on the stream list. Your selection is remembered.")
                }

                TraktSection()

                Section {
                    if MDBList.isConfigured {
                        Label("Rotten Tomatoes, Metacritic & Letterboxd on", systemImage: "checkmark.circle.fill")
                    } else {
                        Label("IMDb and TMDB only", systemImage: "info.circle")
                    }
                } header: {
                    Text("Ratings")
                } footer: {
                    Text(MDBList.isConfigured
                         ? "Critics' and audience scores on title pages come from MDBList."
                         : "To show Rotten Tomatoes, Metacritic and Letterboxd scores on title pages, add a free MDBList API key (mdblist.com › Preferences › API) as the MDBLIST_KEY repository secret.")
                }

                if TMDB.isConfigured {
                    Section {
                        Picker("Region", selection: $region) {
                            Text("Automatic (\(Locale.current.region?.identifier ?? "US"))").tag("")
                            ForEach(Self.regions, id: \.self) { code in
                                Text(Locale.current.localizedString(forRegionCode: code) ?? code).tag(code)
                            }
                        }
                    } header: {
                        Text("Where to Watch")
                    } footer: {
                        Text("Which country's streaming services title pages and Discover show. Data from JustWatch via TMDB; it's about licensing, not whether your addons have a stream.")
                    }
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
                    if PendingWrites.shared.count > 0 {
                        LabeledContent("Waiting to sync", value: "\(PendingWrites.shared.count)")
                    }
                }

                Section {
                    LabeledContent("Version", value: appVersion)
                    LabeledContent("Player engine", value: "AetherEngine")
                } header: {
                    Text("About")
                } footer: {
                    // TMDB's terms ask for this notice wherever its data is shown.
                    if TMDB.isConfigured {
                        Text("Title details and artwork come in part from TMDB. This product uses TMDB and the TMDB APIs but is not endorsed, certified, or otherwise approved by TMDB.")
                    }
                }
            }
            .readableWidth()
            .navigationTitle("Settings")
            .confirmationDialog("Clear Continue Watching on this \(Device.isPad ? "iPad" : "iPhone")?", isPresented: $confirmClearWatch,
                                titleVisibility: .visible) {
                Button("Clear", role: .destructive) { watch.clearAll() }
            } message: {
                Text("Resume points are removed here. Your Stremio account isn't changed.")
            }
        }
    }

    private var atmosOnly: Binding<Bool> {
        Binding(get: { StreamFilterStore.decode(savedFilters).contains(.atmos) },
                set: { on in
                    var set = StreamFilterStore.decode(savedFilters)
                    if on { set.insert(.atmos) } else { set.remove(.atmos) }
                    savedFilters = StreamFilterStore.encode(set)
                })
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
        return "\(version) (\(build))"
    }
}

/// Connect, sync and disconnect Trakt.
struct TraktSection: View {
    @ObservedObject private var trakt = TraktAccount.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        Section {
            if !TraktConfig.isConfigured {
                Label("Not set up in this build", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            } else if trakt.connected {
                LabeledContent("Account", value: trakt.username ?? "Connected")
                Button(trakt.syncing ? "Syncing…" : "Sync Now") { Task { await trakt.sync() } }
                    .disabled(trakt.syncing)
                if let last = trakt.lastSync {
                    LabeledContent("Last synced", value: last.formatted(.relative(presentation: .named)))
                }
                Button("Disconnect", role: .destructive) { trakt.disconnect() }
            } else if let pairing = trakt.pairing {
                VStack(alignment: .leading, spacing: 8) {
                    Text("On any device, go to \(pairing.url) and enter:")
                        .font(.subheadline)
                    Text(pairing.userCode)
                        .font(.system(.title, design: .monospaced).weight(.bold))
                        .textSelection(.enabled)
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for you to approve…").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Button("Copy Code and Open Trakt") {
                    UIPasteboard.general.string = pairing.userCode
                    if let url = URL(string: pairing.url) { openURL(url) }
                }
                Button("Cancel", role: .cancel) { trakt.cancelPairing() }
            } else if trakt.signingIn {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Signing in on Trakt…").foregroundStyle(.secondary)
                }
            } else {
                Button("Connect Trakt") { trakt.connect() }
            }
            if let error = trakt.lastError {
                Text(error).font(.footnote).foregroundStyle(.orange)
            }
        } header: {
            Text("Trakt")
        } footer: {
            Text(TraktConfig.isConfigured
                 ? "Sends what you watch to Trakt, keeps ✓ marks in step with your Trakt history, lets you rate titles from their page, and adds Trakt's picks to Home."
                 : "To use Trakt, create an app at developer.trakt.tv with the Redirect URI atmosplayer://trakt, and add its Client ID as the TRAKT_CLIENT_ID repository secret.")
        }
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
