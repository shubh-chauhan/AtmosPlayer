import SwiftUI
import UIKit

struct AddonsView: View {
    @EnvironmentObject private var addons: AddonStore
    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var watch: WatchStore
    @AppStorage(StremioAccount.pushProgressKey) private var pushProgress = true
    @State private var showSignIn = false
    @AppStorage(StreamingServer.key) private var serverURL = ""
    @State private var serverDraft = ""
    @State private var serverStatus: String?
    @State private var serverOK = false
    @State private var checkingServer = false

    @State private var link = ""
    @State private var installing = false
    @State private var status: String?
    @State private var statusIsError = false

    var body: some View {
        NavigationStack {
            List {
                accountSection
                serverSection

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
            .navigationTitle("Stremio")
            .toolbar { EditButton() }
            .sheet(isPresented: $showSignIn) {
                StremioSignInView()
                    .presentationDetents([.medium, .large])
            }
        }
    }

    @ViewBuilder
    private var serverSection: some View {
        Section {
            TextField("https://…:12470", text: $serverDraft)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { Task { await saveServer() } }
            HStack {
                Button("Paste") {
                    if let pasted = UIPasteboard.general.string {
                        serverDraft = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                .buttonStyle(.bordered)
                Spacer()
                if checkingServer { ProgressView() }
                Button(serverDraft == serverURL && !serverURL.isEmpty ? "Test" : "Save") {
                    Task { await saveServer() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(serverDraft.trimmingCharacters(in: .whitespaces).isEmpty || checkingServer)
            }
            if let serverStatus {
                Label(serverStatus, systemImage: serverOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(serverOK ? .green : .orange)
            }
            if !serverURL.isEmpty {
                Button("Remove Server", role: .destructive) {
                    serverURL = ""
                    serverDraft = ""
                    serverStatus = nil
                }
            }
        } header: {
            Text("Streaming server")
        } footer: {
            Text("The same address as \"Streaming server URL\" in Stremio's settings. With it, torrent streams play here just like in Stremio.")
        }
        .onAppear { if serverDraft.isEmpty { serverDraft = serverURL } }
    }

    private func saveServer() async {
        guard let normalized = StreamingServer.normalize(serverDraft) else {
            serverOK = false
            serverStatus = "That isn't a valid address."
            return
        }
        serverDraft = normalized
        serverURL = normalized
        checkingServer = true
        defer { checkingServer = false }
        if let problem = await StreamingServer.check(normalized) {
            serverOK = false
            serverStatus = "Saved, but the server didn't answer: \(problem)"
        } else {
            serverOK = true
            serverStatus = "Connected. Torrent streams will play through this server."
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        Section {
            if account.signedIn {
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.fill").font(.largeTitle)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.email ?? "Stremio account").font(.headline)
                        Group {
                            if account.syncing {
                                Text("Syncing…")
                            } else if let last = account.lastSync {
                                Text("Synced \(last.formatted(.relative(presentation: .named)))")
                            } else {
                                Text("Not synced yet")
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if account.syncing { ProgressView() }
                }
                Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") {
                    Task { await account.sync(addons: addons, watch: watch) }
                }
                .disabled(account.syncing)
                Toggle("Send watch progress to Stremio", isOn: $pushProgress)
                if let error = account.lastError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
                Button("Sign Out", role: .destructive) { account.signOut() }
            } else {
                Button {
                    showSignIn = true
                } label: {
                    Label("Sign in with Stremio", systemImage: "person.crop.circle.badge.plus")
                        .font(.headline)
                }
                if let error = account.lastError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }
        } header: {
            Text("Account")
        } footer: {
            Text(account.signedIn
                 ? "Your Stremio addons, library and Continue Watching are used here, and where you stop is sent back to Stremio."
                 : "Sign in to use the addons, library and Continue Watching from your Stremio account.")
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

struct StremioSignInView: View {
    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var addons: AddonStore
    @EnvironmentObject private var watch: WatchStore
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var password = ""
    @State private var working = false
    @State private var error: String?
    @FocusState private var focus: Field?

    private enum Field { case email, password }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Email", text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .email)
                        .submitLabel(.next)
                        .onSubmit { focus = .password }
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($focus, equals: .password)
                        .submitLabel(.go)
                        .onSubmit { Task { await signIn() } }
                } footer: {
                    Text("Your password goes only to Stremio (api.strem.io) and isn't stored on the phone. Accounts that use Facebook or Apple sign-in need a Stremio password first (set one at stremio.com).")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.footnote) }
                }
            }
            .navigationTitle("Stremio Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button("Sign In") { Task { await signIn() } }
                            .disabled(email.isEmpty || password.isEmpty)
                    }
                }
            }
            .onAppear { focus = .email }
        }
    }

    private func signIn() async {
        guard !email.isEmpty, !password.isEmpty, !working else { return }
        working = true
        error = nil
        defer { working = false }
        do {
            try await account.signIn(email: email.trimmingCharacters(in: .whitespaces), password: password)
            password = ""
            dismiss()
            await account.sync(addons: addons, watch: watch)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
