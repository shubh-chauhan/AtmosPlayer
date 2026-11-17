import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var coordinator: PlayerCoordinator

    @State private var urlText = ""
    @State private var showFilePicker = false
    @State private var message: String?

    /// Filled in by the CI build: where this repo's TestMedia folder is served from.
    private var testMediaBase: String {
        (Bundle.main.object(forInfoDictionaryKey: "TestMediaBase") as? String) ?? ""
    }

    /// The repo's "testmedia" release, where CI publishes the HDR test clips:
    /// raw.githubusercontent.com/OWNER/REPO/… → github.com/OWNER/REPO/releases/download/testmedia
    private var hdrClipsBase: URL? {
        guard let url = URL(string: testMediaBase), url.host == "raw.githubusercontent.com" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2 else { return nil }
        return URL(string: "https://github.com/\(parts[0])/\(parts[1])/releases/download/testmedia")
    }

    var body: some View {
        NavigationStack {
            List {
                if let engineError = model.engineError {
                    Section {
                        Text("Player engine failed to start: \(engineError)")
                            .foregroundStyle(.red)
                    }
                }

                DownloadsSection()

                Section("Play a link") {
                    TextField("https://… (.mkv, .mp4, .m3u8)", text: $urlText)
                        .keyboardType(.URL)
                        .submitLabel(.go)
                        .onSubmit { playTypedURL() }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack {
                        Button("Paste") {
                            if let pasted = UIPasteboard.general.string {
                                urlText = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                        Button("Play") { playTypedURL() }
                            .buttonStyle(.borderedProminent)
                            .tint(Brand.accent)
                            .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if let message {
                        Text(message).font(.footnote).foregroundStyle(.red)
                    }
                }

                Section("Test") {
                    Button("Open a file from Files…") { showFilePicker = true }
                    if !testMediaBase.isEmpty,
                       let testURL = URL(string: testMediaBase + "/dolby-atmos-test.m3u8") {
                        Button("Dolby Atmos test stream (audio only)") {
                            start(PlayItem(url: testURL))
                        }
                    }
                }

                if let base = hdrClipsBase {
                    Section {
                        Button("HDR10 test pattern") { start(PlayItem(url: base.appendingPathComponent("hdr10-test.mkv"))) }
                        Button("Dolby Vision test pattern") { start(PlayItem(url: base.appendingPathComponent("dolby-vision-test.mkv"))) }
                        Button("HLG test pattern") { start(PlayItem(url: base.appendingPathComponent("hlg-test.mkv"))) }
                    } header: {
                        Text("HDR check")
                    } footer: {
                        Text("Grey patches at known brightness. With HDR working, the right-hand patches glow clearly brighter than the white text and the player's buttons; without it they all look the same white. Tap the HDR badge next to the title (or More > Stream Details): the Screen row should read \"HDR on now\". Low Power Mode turns HDR off.")
                    }
                }

                if !history.entries.isEmpty {
                    Section("Recent") {
                        ForEach(history.entries, id: \.self) { entry in
                            Button {
                                urlText = entry
                                playTypedURL()
                            } label: {
                                Text(entry)
                                    .font(.footnote)
                                    .lineLimit(2)
                                    .foregroundStyle(.primary)
                            }
                        }
                        .onDelete { history.remove(at: $0) }
                        Button("Clear history", role: .destructive) { history.clear() }
                    }
                }
            }
            .readableWidth()
            .navigationTitle("Links")
            .scrollDismissesKeyboard(.immediately)
            .keyboardDoneButton()
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let fileURL):
                let scoped = fileURL.startAccessingSecurityScopedResource()
                start(PlayItem(url: fileURL, securityScoped: scoped))
            case .failure(let error):
                message = error.localizedDescription
            }
        }
    }

    private func playTypedURL() {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            message = "That doesn't look like an http(s) link."
            return
        }
        message = nil
        history.add(url)
        start(PlayItem(url: url))
    }

    private func start(_ item: PlayItem) {
        guard model.engine != nil else {
            message = "Player engine unavailable."
            return
        }
        coordinator.play(item)
    }
}
