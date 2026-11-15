import SwiftUI
import UIKit

// MARK: - What a stream is, read from the addon's text

/// Quality, picture, sound, codec, source and size, read once from the name, title,
/// description and filename the addon sent ("4K · DV · HDR10 · Atmos · 14.2 GB" and the like).
struct StreamTraits: Hashable {
    var resolution: StreamFilter?
    var picture: Set<StreamFilter> = []
    var audio: Set<StreamFilter> = []
    var codec: StreamFilter?
    var source: StreamFilter?
    /// Size in GB, when the addon says it.
    var sizeGB: Double?

    init(_ raw: String) {
        let text = raw.lowercased()
        func has(_ pattern: String) -> Bool {
            text.range(of: pattern, options: .regularExpression) != nil
        }
        // Word edges that also treat ".", "_", "-", "[", "(" as separators.
        let l = "(?<![a-z0-9])", r = "(?![a-z0-9])"

        if has("\(l)(2160p|4k|uhd)\(r)") { resolution = .r4K }
        else if has("\(l)(1440p|2k)\(r)") { resolution = .r1440 }
        else if has("\(l)(1080p|1080i|fhd)\(r)") { resolution = .r1080 }
        else if has("\(l)720p\(r)") { resolution = .r720 }
        else if has("\(l)(576p|480p|360p|sd|dvdrip|dvd)\(r)") { resolution = .rSD }

        if has("\(l)(dv|dovi|dolby[ ._-]?vision)\(r)") { picture.insert(.dolbyVision) }
        if has("\(l)(hdr10\\+|hdr10plus|hdr10p)") { picture.insert(.hdr10Plus) }
        if has("\(l)(hdr|hdr10|hlg)\(r)") || !picture.isEmpty { picture.insert(.hdr) }
        if picture.isEmpty { picture.insert(.sdr) }

        if has("atmos") { audio.insert(.atmos) }
        if has("\(l)true[ ._-]?hd\(r)") { audio.insert(.trueHD) }
        if has("\(l)dts[ ._:-]?x\(r)") { audio.insert(.dtsX) }
        else if has("\(l)dts") { audio.insert(.dts) }
        if has("\(l)(ddp|dd\\+|eac3|e-ac-3|dolby digital plus)") { audio.insert(.ddPlus) }
        if has("\(l)(7[ ._]1)\(r)") { audio.insert(.ch71) }
        else if has("\(l)(5[ ._]1)\(r)") { audio.insert(.ch51) }

        if has("\(l)(hevc|x265|h[ .]?265)\(r)") { codec = .hevc }
        else if has("\(l)av1\(r)") { codec = .av1 }
        else if has("\(l)(x264|h[ .]?264|avc)\(r)") { codec = .h264 }

        if has("remux") { source = .remux }
        else if has("\(l)(blu[ ._-]?ray|bdrip|brrip|bd)\(r)") { source = .bluray }
        else if has("\(l)(web[ ._-]?dl|webrip|web)\(r)") { source = .web }
        else if has("\(l)(hdtv|tvrip)\(r)") { source = .tv }
        else if has("\(l)(cam|hdcam|ts|telesync|hdts)\(r)") { source = .cam }

        let ns = text as NSString
        if let match = Self.sizePattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
           let value = Double(ns.substring(with: match.range(at: 1)).replacingOccurrences(of: ",", with: ".")) {
            sizeGB = ns.substring(with: match.range(at: 2)).hasPrefix("g") ? value : value / 1024
        }
    }

    private static let sizePattern = try! NSRegularExpression(pattern: "(\\d+(?:[.,]\\d+)?)\\s*(gb|gib|mb|mib)\\b")

    var all: Set<StreamFilter> {
        var set = picture.union(audio)
        for one in [resolution, codec, source] { if let one { set.insert(one) } }
        return set
    }

    /// Badges on the row, most telling first.
    var badges: [StreamFilter] {
        var out: [StreamFilter] = []
        if let resolution { out.append(resolution) }
        if picture.contains(.dolbyVision) { out.append(.dolbyVision) }
        if picture.contains(.hdr10Plus) { out.append(.hdr10Plus) }
        else if picture.contains(.hdr) && !picture.contains(.dolbyVision) { out.append(.hdr) }
        for audio in [StreamFilter.atmos, .trueHD, .dtsX, .dts, .ddPlus] where self.audio.contains(audio) {
            out.append(audio)
        }
        if let source, source == .remux { out.append(source) }
        return out
    }

    /// Higher is better: resolution, then picture, then sound, then source.
    var qualityScore: Int {
        var score = (resolution?.rank ?? 0) * 1000
        if picture.contains(.dolbyVision) { score += 300 } else if picture.contains(.hdr) { score += 200 }
        if audio.contains(.atmos) || audio.contains(.dtsX) { score += 60 }
        else if audio.contains(.trueHD) || audio.contains(.dts) || audio.contains(.ddPlus) { score += 30 }
        if source == .remux { score += 20 } else if source == .bluray { score += 10 }
        if source == .cam { score -= 5000 }
        return score
    }
}

/// One choosable value. Within a group any selected value matches; across groups all must.
enum StreamFilter: String, CaseIterable, Identifiable, Hashable {
    case r4K, r1440, r1080, r720, rSD
    case dolbyVision, hdr10Plus, hdr, sdr
    case atmos, trueHD, dtsX, dts, ddPlus, ch71, ch51
    case hevc, av1, h264
    case remux, bluray, web, tv, cam

    var id: String { rawValue }

    enum Group: String, CaseIterable {
        case quality = "Quality", picture = "Picture", audio = "Audio", codec = "Codec", source = "Source"
    }

    var group: Group {
        switch self {
        case .r4K, .r1440, .r1080, .r720, .rSD: return .quality
        case .dolbyVision, .hdr10Plus, .hdr, .sdr: return .picture
        case .atmos, .trueHD, .dtsX, .dts, .ddPlus, .ch71, .ch51: return .audio
        case .hevc, .av1, .h264: return .codec
        case .remux, .bluray, .web, .tv, .cam: return .source
        }
    }

    var label: String {
        switch self {
        case .r4K: return "4K"
        case .r1440: return "1440p"
        case .r1080: return "1080p"
        case .r720: return "720p"
        case .rSD: return "SD"
        case .dolbyVision: return "Dolby Vision"
        case .hdr10Plus: return "HDR10+"
        case .hdr: return "HDR"
        case .sdr: return "SDR"
        case .atmos: return "Atmos"
        case .trueHD: return "TrueHD"
        case .dtsX: return "DTS:X"
        case .dts: return "DTS"
        case .ddPlus: return "DD+"
        case .ch71: return "7.1"
        case .ch51: return "5.1"
        case .hevc: return "HEVC"
        case .av1: return "AV1"
        case .h264: return "H.264"
        case .remux: return "Remux"
        case .bluray: return "BluRay"
        case .web: return "WEB"
        case .tv: return "TV"
        case .cam: return "CAM"
        }
    }

    /// Short form for the row badges.
    var badge: String { self == .dolbyVision ? "DV" : label }

    var rank: Int {
        switch self {
        case .r4K: return 5
        case .r1440: return 4
        case .r1080: return 3
        case .r720: return 2
        case .rSD: return 1
        default: return 0
        }
    }

    /// Does a stream with these traits pass, given everything selected?
    static func matches(_ traits: StreamTraits, selected: Set<StreamFilter>) -> Bool {
        guard !selected.isEmpty else { return true }
        let have = traits.all
        for group in Group.allCases {
            let wanted = selected.filter { $0.group == group }
            if !wanted.isEmpty && wanted.isDisjoint(with: have) { return false }
        }
        return true
    }
}

enum StreamSort: String, CaseIterable, Identifiable {
    case addon, quality, size, sizeSmall
    var id: String { rawValue }
    var label: String {
        switch self {
        case .addon: return "Addon order"
        case .quality: return "Best quality"
        case .size: return "Largest first"
        case .sizeSmall: return "Smallest first"
        }
    }
}

/// The saved filter selection ("streams.filters", comma separated).
enum StreamFilterStore {
    static let key = "streams.filters"

    static func decode(_ text: String) -> Set<StreamFilter> {
        Set(text.split(separator: ",").compactMap { StreamFilter(rawValue: String($0)) })
    }

    static func encode(_ set: Set<StreamFilter>) -> String {
        StreamFilter.allCases.filter(set.contains).map(\.rawValue).joined(separator: ",")
    }
}

// MARK: - Filter bar

/// Chips for every value found in the loaded streams, grouped, with counts; tap to toggle
/// (several at once). A sort menu and Clear sit in front.
struct StreamFilterBar: View {
    let available: [StreamFilter: Int]
    @Binding var selected: Set<StreamFilter>
    @Binding var sort: StreamSort
    let shownCount: Int
    let totalCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(StreamSort.allCases) { Text($0.label).tag($0) }
                    }
                } label: {
                    Label(sort.label, systemImage: "arrow.up.arrow.down")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.white.opacity(0.12), in: Capsule())
                }
                .tint(.white)
                Spacer()
                if totalCount > 0 {
                    Text(selected.isEmpty ? "\(totalCount) streams" : "\(shownCount) of \(totalCount)")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if !selected.isEmpty {
                    Button("Clear") {
                        withAnimation(.snappy) { selected = [] }
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Brand.accent)
                }
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(StreamFilter.Group.allCases, id: \.self) { group in
                        let values = StreamFilter.allCases.filter {
                            $0.group == group && (available[$0, default: 0] > 0 || selected.contains($0))
                        }
                        if !values.isEmpty {
                            Text(group.rawValue.uppercased())
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.secondary)
                                .padding(.leading, group == .quality ? 0 : 8)
                            ForEach(values) { value in
                                chip(value)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 6)
    }

    private func chip(_ value: StreamFilter) -> some View {
        let on = selected.contains(value)
        let count = available[value, default: 0]
        return Button {
            withAnimation(.snappy) {
                if on { selected.remove(value) } else { selected.insert(value) }
            }
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            HStack(spacing: 4) {
                if on { Image(systemName: "checkmark").font(.caption2.weight(.bold)) }
                Text(value.label).font(.footnote.weight(.semibold))
                Text("\(count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(on ? Color.black.opacity(0.55) : Color.white.opacity(0.45))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .foregroundStyle(on ? Color.black : Color.white)
            .background(on ? Color.white : Color.white.opacity(0.12), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
