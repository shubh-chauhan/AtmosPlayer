import SwiftUI

/// Cinemeta's episode calendar for the series you follow (My List, your Stremio library and
/// Continue Watching): episodes that came out lately and you haven't watched, and what airs
/// next. Uses Cinemeta's `calendar-videos` catalog, which answers many series in one request.
@MainActor
final class EpisodeCalendar: ObservableObject {
    static let shared = EpisodeCalendar()

    struct Item: Identifiable, Hashable {
        let series: MetaRef
        let video: StremioMeta.Video
        let date: Date
        var id: String { video.id }
    }

    @Published private(set) var fresh: [Item] = []
    @Published private(set) var upcoming: [Item] = []

    private var lastKey = ""
    private var lastLoad = Date.distantPast

    func load(series: [MetaRef]) async {
        var seen = Set<String>()
        let follow = series.filter { $0.type == "series" && $0.id.hasPrefix("tt") && seen.insert($0.id).inserted }
        let key = follow.map(\.id).sorted().joined(separator: ",")
        // Same shows and loaded within the hour: nothing new to ask for.
        guard !follow.isEmpty else { fresh = []; upcoming = []; return }
        guard key != lastKey || Date().timeIntervalSince(lastLoad) > 3600 else { return }
        lastKey = key
        lastLoad = Date()

        let byId = Dictionary(follow.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var metas: [StremioMeta] = []
        for chunk in stride(from: 0, to: min(follow.count, 60), by: 20).map({ Array(follow[$0..<min($0 + 20, follow.count)]) }) {
            metas += await Cinemeta.calendar(ids: chunk.map(\.id))
        }

        let now = Date()
        let recent = now.addingTimeInterval(-21 * 86_400)
        let soon = now.addingTimeInterval(45 * 86_400)
        var newItems: [Item] = []
        var nextItems: [Item] = []
        for meta in metas {
            let base = byId[meta.id]
            let ref = MetaRef(id: meta.id, type: "series", name: meta.name,
                              poster: meta.poster ?? base?.poster,
                              background: meta.background ?? base?.background,
                              logo: meta.logo ?? base?.logo)
            let episodes = meta.videos.filter { ($0.season ?? 0) > 0 }
            for video in episodes {
                guard let date = video.releaseDate else { continue }
                if date <= now, date >= recent, !WatchedStore.shared.isWatched(video.id, metaId: meta.id) {
                    newItems.append(Item(series: ref, video: video, date: date))
                }
            }
            // Only the next episode of each show, so one weekly series doesn't fill the row.
            if let next = episodes.compactMap({ v in v.releaseDate.map { (v, $0) } })
                .filter({ $0.1 > now && $0.1 <= soon }).min(by: { $0.1 < $1.1 }) {
                nextItems.append(Item(series: ref, video: next.0, date: next.1))
            }
        }
        withAnimation(.easeOut(duration: 0.25)) {
            fresh = Array(newItems.sorted { $0.date > $1.date }.prefix(20))
            upcoming = nextItems.sorted { $0.date < $1.date }
        }
    }

    static func relative(_ date: Date) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()),
                                           to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        case 2...6: return date.formatted(.dateTime.weekday(.wide))
        case ...(-2): return "\(-days) days ago"
        default: return date.formatted(.dateTime.month(.abbreviated).day())
        }
    }
}

/// A wide card for one episode: its still, the show's logo, and when it aired or airs.
struct CalendarEpisodeCard: View {
    let item: EpisodeCalendar.Item
    let upcoming: Bool
    var width: CGFloat = Device.size(280)

    private var still: [String] {
        var list: [String] = []
        if let thumbnail = item.video.thumbnail { list.append(thumbnail) }
        if let background = item.series.background { list.append(background) }
        if let poster = item.series.poster { list.append(poster) }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .bottomLeading) {
                LandscapeArtwork(candidates: still, maxPixel: 900)
                LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .center, endPoint: .bottom)
                if let logo = item.series.logo, let url = URL(string: logo) {
                    LogoImage(url: url, failed: .constant(false))
                        .frame(maxWidth: width * 0.45, maxHeight: 38, alignment: .bottomLeading)
                        .padding(12)
                }
            }
            .overlay(alignment: .topLeading) {
                Text(upcoming ? EpisodeCalendar.relative(item.date).uppercased() : "NEW")
                    .font(.caption2.weight(.heavy))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(upcoming ? Color.black.opacity(0.6) : Color.white,
                                in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .foregroundStyle(upcoming ? Color.white : Color.black)
                    .padding(10)
            }
            .frame(width: width, height: width * 9 / 16)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.08)))

            Text(item.series.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text([item.video.code, item.video.title, upcoming ? nil : EpisodeCalendar.relative(item.date)]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
    }
}
