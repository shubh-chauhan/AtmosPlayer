import SwiftUI
import AVFoundation
import Combine
import AetherEngine

// MARK: - Torrent statistics

/// Live numbers for a torrent stream, read from the streaming server's stats.json once a second
/// (the same numbers Stremio shows: peers, download speed, how much of the file is ready).
@MainActor
final class TorrentStatsMonitor: ObservableObject {
    struct Stats: Equatable {
        var peers = 0
        var unchoked = 0
        var swarmSize = 0
        var downloadSpeed: Double = 0   // bytes per second
        var uploadSpeed: Double = 0
        var downloaded: Double = 0      // bytes
        var streamProgress: Double = 0  // 0...1 of the file being played
        var streamLength: Double = 0    // bytes
        var name: String?
    }

    @Published private(set) var stats: Stats?
    private var task: Task<Void, Never>?
    private var target: URL?

    /// Starts polling for a torrent stream, or stops when `stream` isn't a torrent.
    func watch(_ stream: SavedStream?) {
        let url = Self.statsURL(for: stream)
        guard url != target else { return }
        target = url
        task?.cancel()
        stats = nil
        guard let url else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                if let fresh = await Self.fetch(url) { self?.stats = fresh }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        target = nil
    }

    private static func statsURL(for stream: SavedStream?) -> URL? {
        guard let stream, stream.isTorrent, let hash = stream.infoHash?.lowercased(),
              let server = StreamingServer.baseURL else { return nil }
        if let index = stream.fileIdx, index >= 0 {
            return URL(string: "\(server)/\(hash)/\(index)/stats.json")
        }
        return URL(string: "\(server)/\(hash)/stats.json")
    }

    private nonisolated static func fetch(_ url: URL) async -> Stats? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func number(_ key: String) -> Double { (json[key] as? NSNumber)?.doubleValue ?? 0 }
        var stats = Stats()
        stats.peers = Int(number("peers"))
        stats.unchoked = Int(number("unchoked"))
        stats.swarmSize = Int(number("swarmSize"))
        stats.downloadSpeed = number("downloadSpeed")
        stats.uploadSpeed = number("uploadSpeed")
        stats.downloaded = number("downloaded")
        stats.streamProgress = number("streamProgress")
        stats.streamLength = number("streamLen")
        stats.name = (json["streamName"] as? String) ?? (json["name"] as? String)
        return stats
    }
}

func formatBytes(_ bytes: Double) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(max(bytes, 0)), countStyle: .file)
}

func formatSpeed(_ bytesPerSecond: Double) -> String {
    let bits = bytesPerSecond * 8
    if bits >= 1_000_000 { return String(format: "%.1f Mbps", bits / 1_000_000) }
    return String(format: "%.0f kbps", bits / 1_000)
}

// MARK: - Startup screen

/// Shown from pressing Play until the picture is up, like Stremio's loading screen: the title's
/// artwork, what's happening, and for torrents the peers and speed.
struct PlayerStartupView: View {
    @ObservedObject var engine: AetherEngine
    @ObservedObject var torrent: TorrentStatsMonitor
    let title: String
    let subtitle: String?
    let artwork: String?
    let isTorrent: Bool
    let onClose: () -> Void

    @State private var pulse = false

    private var stageText: String {
        guard let stage = engine.startupProgress?.stage else {
            return isTorrent ? "Connecting to peers" : "Connecting"
        }
        switch stage {
        case .connecting: return isTorrent ? "Connecting to peers" : "Connecting"
        case .openingContainer: return "Opening the file"
        case .analyzingStreams: return "Reading audio and video tracks"
        case .preparingDisplay, .selectingRoute, .buildingSession: return "Preparing playback"
        case .preparingPlayback, .awaitingFirstFrame: return "Buffering"
        case .presenting: return "Starting"
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let artwork {
                Color.clear
                    .overlay { RemoteImage(url: artwork, maxPixel: 1200, placeholderSymbol: "") }
                    .clipped()
                    .blur(radius: 24)
                    .opacity(0.45)
                    .ignoresSafeArea()
            }
            LinearGradient(colors: [.black.opacity(0.2), .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                VStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 30, weight: .bold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    if let subtitle {
                        Text(subtitle)
                            .font(.headline)
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                }
                .opacity(pulse ? 1 : 0.55)
                .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulse)

                VStack(spacing: 10) {
                    ProgressView(value: engine.startupProgress?.fraction ?? 0.04)
                        .progressViewStyle(.linear)
                        .tint(.white)
                        .frame(width: 220)
                        .animation(.easeOut(duration: 0.3), value: engine.startupProgress?.fraction)
                    Text(stageText)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.8))
                        .contentTransition(.opacity)
                    if isTorrent, let stats = torrent.stats {
                        HStack(spacing: 14) {
                            Label("\(stats.peers) peers", systemImage: "person.2.fill")
                            Label(formatSpeed(stats.downloadSpeed), systemImage: "arrow.down.circle.fill")
                            if stats.streamProgress > 0 {
                                Label("\(Int(stats.streamProgress * 100))%", systemImage: "square.stack.3d.down.forward.fill")
                            }
                        }
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                        .transition(.opacity)
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 40)

            VStack {
                HStack {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .foregroundStyle(.white)
                    .glass(Circle(), interactive: true)
                    Spacer()
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)
        }
        .onAppear { pulse = true }
    }
}

// MARK: - Statistics

/// The player's statistics panel ("Stream details"): network, torrent, video, audio and the
/// Atmos check. Audio-route values aren't published, so it re-reads them once a second.
struct DebugOverlay: View {
    @ObservedObject var engine: AetherEngine
    @ObservedObject var clock: PlaybackClock
    @ObservedObject var torrent: TorrentStatsMonitor
    let item: PlayItem
    let onClose: () -> Void

    private var activeTrack: TrackInfo? {
        guard let index = engine.activeAudioTrackIndex else { return nil }
        return engine.audioTracks.first { $0.id == index }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Stream Details").font(.headline)
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill").font(.title3)
                            .symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.plain)
                }

                section("Network") {
                    row("Source", sourceSummary)
                    row("Buffered ahead", bufferAhead)
                    if let stats = torrent.stats {
                        row("Peers", "\(stats.peers) connected · \(stats.unchoked) sending · \(stats.swarmSize) in swarm")
                        row("Download", formatSpeed(stats.downloadSpeed))
                        row("Upload", formatSpeed(stats.uploadSpeed))
                        if stats.streamLength > 0 {
                            row("File ready", "\(Int(stats.streamProgress * 100))% of \(formatBytes(stats.streamLength))")
                        }
                        row("Downloaded", formatBytes(stats.downloaded))
                    }
                }

                section("Video") {
                    row("Codec", videoSummary)
                    row("Path", "\(engine.videoRoute.rawValue) · \(engine.activeVideoDecoder ?? "-")")
                }

                section("Audio") {
                    row("Track", trackSummary)
                    row("Delivery", "\(engine.audioDelivery.rawValue) · \(engine.activeAudioDecoder ?? "-")")
                    row("Atmos", verdict, highlight: activeTrack?.isAtmos == true && engine.audioDelivery == .streamCopy)
                    row("Output", outputSummary)
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white)
            .padding(16)
            .frame(maxWidth: 420, alignment: .leading)
            .glass(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white.opacity(0.5))
            content()
        }
    }

    private func row(_ label: String, _ value: String, highlight: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 104, alignment: .leading)
            Text(value)
                .fontWeight(highlight ? .bold : .regular)
                .foregroundStyle(highlight ? Color.green : Color.white)
                .lineLimit(2)
        }
    }

    private var sourceSummary: String {
        if item.stream?.isTorrent == true {
            return "Torrent via streaming server"
        }
        if item.url.isFileURL { return "Local file" }
        return "HTTP · \(item.url.host ?? "-")"
    }

    private var bufferAhead: String {
        let ahead = max(clock.bufferedPosition - clock.currentTime, 0)
        return String(format: "%.0f s", ahead)
    }

    private var videoSummary: String {
        var parts: [String] = []
        if let codec = engine.sourceVideoCodecName { parts.append(codec.uppercased()) }
        if let profile = engine.sourceVideoStreamFormat?.profile { parts.append(profile) }
        parts.append(String(describing: engine.videoFormat).uppercased())
        if let fps = engine.sourceVideoFrameRate, fps > 0 { parts.append(String(format: "%.3g fps", fps)) }
        if engine.sourceVideoBitrate > 0 { parts.append(formatSpeed(Double(engine.sourceVideoBitrate) / 8)) }
        if let container = engine.sourceContainerFormat { parts.append(container) }
        return parts.joined(separator: " · ")
    }

    private var trackSummary: String {
        guard let track = activeTrack else { return "-" }
        var parts: [String] = [track.codec.uppercased()]
        if let profile = track.profile { parts.append(profile) }
        if let layout = track.channelLayout { parts.append(layout) } else { parts.append("\(track.channels) ch") }
        if track.sampleRate > 0 { parts.append("\(track.sampleRate / 1000) kHz") }
        if track.bitrate > 0 { parts.append("\(track.bitrate / 1000) kbps") }
        return parts.joined(separator: " · ")
    }

    private var verdict: String {
        guard let track = activeTrack else { return "no audio track" }
        if track.isAtmos {
            return engine.audioDelivery == .streamCopy
                ? "Dolby Atmos passed through untouched"
                : "Atmos track, but delivered as \(engine.audioDelivery.rawValue): Atmos lost"
        }
        if track.isDTSX { return "DTS:X (decoded, not Atmos)" }
        if track.channels > 2 { return "\(track.channels)-channel surround, not Atmos" }
        return "Stereo"
    }

    private var outputSummary: String {
        let session = AVAudioSession.sharedInstance()
        let ports = session.currentRoute.outputs.map { port in
            "\(port.portName)\(port.isSpatialAudioEnabled ? " · Spatial Audio on" : "")"
        }
        return ports.isEmpty ? "none" : ports.joined(separator: ", ")
    }
}
