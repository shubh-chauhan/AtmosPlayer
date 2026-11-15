import SwiftUI
import AVFoundation
import AetherEngine

/// What the engine is doing with the audio, and where iOS is sending it. The line to watch is
/// "Verdict": Atmos survives only when an Atmos track is delivered as `streamCopy` (untouched).
struct DebugOverlay: View {
    @ObservedObject var engine: AetherEngine

    private var activeTrack: TrackInfo? {
        guard let index = engine.activeAudioTrackIndex else { return nil }
        return engine.audioTracks.first { $0.id == index }
    }

    var body: some View {
        // Audio-route values and log lines are not published, so re-read them once a second.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: 2) {
                row("State", String(describing: engine.state))
                row("Video", "\(engine.videoRoute.rawValue) · \(engine.activeVideoDecoder ?? "-") · \(String(describing: engine.videoFormat))")
                row("Audio path", "\(engine.audioDelivery.rawValue) · \(engine.activeAudioDecoder ?? "-")")
                row("Track", trackSummary)
                row("Verdict", verdict)
                row("Output", outputSummary)
                ForEach(Array(LogStore.shared.tail(4).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .lineLimit(1)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.white)
            .padding(8)
            .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label).foregroundStyle(.yellow)
            Text(value).lineLimit(2)
        }
    }

    private var trackSummary: String {
        guard let track = activeTrack else { return "-" }
        var parts: [String] = [track.codec]
        if let profile = track.profile { parts.append(profile) }
        parts.append("\(track.channels) ch")
        if let layout = track.channelLayout { parts.append(layout) }
        if track.sampleRate > 0 { parts.append("\(track.sampleRate) Hz") }
        if track.bitrate > 0 { parts.append("\(track.bitrate / 1000) kbps") }
        if track.isAtmos { parts.append("JOC (Atmos)") }
        if track.isDTSX { parts.append("DTS:X") }
        return parts.joined(separator: " · ")
    }

    private var verdict: String {
        guard let track = activeTrack else { return "no audio track" }
        if track.isAtmos {
            return engine.audioDelivery == .streamCopy
                ? "ATMOS passed through untouched"
                : "Atmos track, but delivery is \(engine.audioDelivery.rawValue): Atmos lost"
        }
        if track.channels > 2 {
            return "multichannel (\(track.channels) ch), not Atmos"
        }
        return "stereo / mono"
    }

    private var outputSummary: String {
        let session = AVAudioSession.sharedInstance()
        let ports = session.currentRoute.outputs.map { port in
            "\(port.portName) [\(port.portType.rawValue)] spatial=\(port.isSpatialAudioEnabled ? "on" : "off")"
        }
        let route = ports.isEmpty ? "none" : ports.joined(separator: ", ")
        return "\(route) · ch \(session.outputNumberOfChannels)/\(session.maximumOutputNumberOfChannels)"
    }
}
