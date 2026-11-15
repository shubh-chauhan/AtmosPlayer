import SwiftUI
import UIKit

struct AddonsView: View {
    @EnvironmentObject private var addons: AddonStore

    @State private var link = ""
    @State private var installing = false
    @State private var status: String?
    @State private var statusIsError = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("https://…/manifest.json or stremio://…", text: $link, axis: .vertical)
                        .lineLimit(1...4)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack {
                        Button("Paste") {
                            if let pasted = UIPasteboard.general.string {
                                link = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                        if installing { ProgressView() }
                        Button("Install") { Task { await install() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty || installing)
                    }
                    if let status {
                        Text(status).font(.footnote).foregroundStyle(statusIsError ? .red : .green)
                    }
                } header: {
                    Text("Add an addon")
                } footer: {
                    Text("In Stremio, open Addons, tap the addon and use its share / copy-link button. For addons you configured (debrid etc.), copy the link from the addon's configure page. Paste it here.")
                }

                Section {
                    if addons.addons.isEmpty {
                        Text("No addons installed.").foregroundStyle(.secondary)
                    }
                    ForEach(addons.addons) { addon in
                        AddonRow(addon: addon)
                    }
                    .onDelete { addons.remove(at: $0) }
                    .onMove { addons.move(from: $0, to: $1) }
                } header: {
                    Text("Installed")
                } footer: {
                    Text("Catalogs and search come from addons with catalogs (Cinemeta). Streams come from every addon that offers them, in this order. Swipe to remove.")
                }

                if !addons.addons.contains(where: { $0.id == "com.linvo.cinemeta" }) {
                    Section {
                        Button("Install Cinemeta (official catalogs)") {
                            link = StremioClient.cinemetaURL
                            Task { await install() }
                        }
                    }
                }
            }
            .navigationTitle("Addons")
            .toolbar { EditButton() }
        }
    }

    private func install() async {
        installing = true
        status = nil
        defer { installing = false }
        do {
            let name = try await addons.install(link)
            status = "Installed \(name)."
            statusIsError = false
            link = ""
        } catch {
            status = "Could not install: \(error.localizedDescription)"
            statusIsError = true
        }
    }
}

struct AddonRow: View {
    let addon: InstalledAddon

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: addon.manifest.logo.flatMap(URL.init(string:))) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit()
                } else {
                    Image(systemName: "puzzlepiece.extension").foregroundStyle(.secondary)
                }
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(addon.manifest.name).font(.headline)
                    if let version = addon.manifest.version {
                        Text(version).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(addon.manifest.resourceNames.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let description = addon.manifest.description {
                    Text(description).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
