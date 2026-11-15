import WidgetKit
import SwiftUI
import UIKit

// MARK: - Timeline

struct ContinueWatchingEntry: TimelineEntry {
    let date: Date
    let items: [WidgetWatchItem]
    let images: [String: UIImage]
    /// False when the shared storage isn't reachable (the app group was not signed in).
    let connected: Bool
}

struct ContinueWatchingProvider: TimelineProvider {
    func placeholder(in context: Context) -> ContinueWatchingEntry {
        ContinueWatchingEntry(date: Date(), items: [
            WidgetWatchItem(id: "1", name: "Your show", subtitle: "S1E2 · 32 min left", progress: 0.4, artFile: nil),
            WidgetWatchItem(id: "2", name: "A movie", subtitle: "1 h 10 min left", progress: 0.25, artFile: nil),
        ], images: [:], connected: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (ContinueWatchingEntry) -> Void) {
        completion(context.isPreview && WidgetFeed.load().isEmpty ? placeholder(in: context) : current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ContinueWatchingEntry>) -> Void) {
        // The app reloads the widget whenever Continue Watching changes.
        completion(Timeline(entries: [current()], policy: .never))
    }

    private func current() -> ContinueWatchingEntry {
        let items = Array(WidgetFeed.load().prefix(4))
        var images: [String: UIImage] = [:]
        if let folder = SharedContainer.artFolder {
            for item in items {
                guard let file = item.artFile,
                      let image = UIImage(contentsOfFile: folder.appendingPathComponent(file).path) else { continue }
                images[item.id] = image
            }
        }
        return ContinueWatchingEntry(date: Date(), items: items, images: images, connected: WidgetFeed.available)
    }
}

// MARK: - Widget

struct ContinueWatchingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ContinueWatching", provider: ContinueWatchingProvider()) { entry in
            ContinueWatchingView(entry: entry)
                .containerBackground(for: .widget) { Color.black }
        }
        .configurationDisplayName("Continue Watching")
        .description("Pick up where you left off.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

struct ContinueWatchingView: View {
    let entry: ContinueWatchingEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if entry.items.isEmpty {
            empty
        } else {
            switch family {
            case .systemSmall: small(entry.items[0])
            case .systemLarge: list(Array(entry.items.prefix(4)))
            default: medium(Array(entry.items.prefix(2)))
            }
        }
    }

    // Small: the latest item, full bleed.
    private func small(_ item: WidgetWatchItem) -> some View {
        ZStack(alignment: .bottomLeading) {
            artwork(item)
            LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).font(.subheadline.weight(.bold)).lineLimit(2)
                Text(item.subtitle).font(.caption2).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                ProgressLine(progress: item.progress)
            }
            .foregroundStyle(.white)
            .padding(12)
        }
        .widgetURL(item.link)
    }

    // Medium: two cards side by side.
    private func medium(_ items: [WidgetWatchItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            HStack(spacing: 10) {
                ForEach(items) { item in
                    Link(destination: item.link) {
                        VStack(alignment: .leading, spacing: 5) {
                            artwork(item)
                                .frame(height: 68)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            Text(item.name).font(.caption.weight(.semibold)).lineLimit(1)
                            ProgressLine(progress: item.progress)
                        }
                    }
                }
                if items.count == 1 { Spacer(minLength: 0) }
            }
        }
        .foregroundStyle(.white)
        .padding(14)
    }

    // Large: up to four rows.
    private func list(_ items: [WidgetWatchItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ForEach(items) { item in
                Link(destination: item.link) {
                    HStack(spacing: 12) {
                        artwork(item)
                            .frame(width: 112, height: 63)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(item.subtitle).font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                            ProgressLine(progress: item.progress)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(16)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "play.circle.fill")
            Text("Continue Watching")
        }
        .font(.caption.weight(.bold))
        .foregroundStyle(.white.opacity(0.75))
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "play.rectangle.on.rectangle.fill")
                .font(.title2)
            Text(entry.connected ? "Nothing to continue yet" : "Open Atmos Player once to set up this widget")
                .font(.caption.weight(.medium))
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white.opacity(0.7))
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func artwork(_ item: WidgetWatchItem) -> some View {
        if let image = entry.images[item.id] {
            Color.clear.overlay {
                Image(uiImage: image).resizable().scaledToFill()
            }
            .clipped()
        } else {
            LinearGradient(colors: [Color(white: 0.2), Color(white: 0.08)], startPoint: .top, endPoint: .bottom)
                .overlay { Image(systemName: "film").foregroundStyle(.white.opacity(0.3)) }
        }
    }
}

private struct ProgressLine: View {
    let progress: Double

    var body: some View {
        Capsule()
            .fill(.white.opacity(0.3))
            .frame(height: 3)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Capsule().fill(.white).frame(width: geo.size.width * max(progress, 0.03))
                }
            }
            .frame(height: 3)
    }
}
