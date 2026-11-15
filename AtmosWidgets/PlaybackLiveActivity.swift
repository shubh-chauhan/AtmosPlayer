import WidgetKit
import SwiftUI
import ActivityKit
import AppIntents

/// Playback controls on the Lock Screen and in the Dynamic Island.
struct PlaybackLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PlaybackAttributes.self) { context in
            LockScreenPlayback(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.75))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    AppMark(size: 40)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    RemainingTime(state: context.state)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 1) {
                        Text(context.attributes.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        if let subtitle = context.attributes.subtitle {
                            Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 10) {
                        PlaybackProgress(state: context.state)
                        PlaybackButtons(state: context.state)
                    }
                    .padding(.horizontal, 6)
                }
            } compactLeading: {
                Image(systemName: context.state.isPlaying ? "play.fill" : "pause.fill")
                    .foregroundStyle(.white)
            } compactTrailing: {
                RemainingTime(state: context.state)
                    .font(.caption2.monospacedDigit())
                    .frame(maxWidth: 44)
                    .foregroundStyle(.white)
            } minimal: {
                Image(systemName: context.state.isPlaying ? "play.fill" : "pause.fill")
                    .foregroundStyle(.white)
            }
            .keylineTint(.white)
        }
    }
}

private struct LockScreenPlayback: View {
    let attributes: PlaybackAttributes
    let state: PlaybackAttributes.ContentState

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                AppMark(size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(attributes.title).font(.headline).lineLimit(1)
                    if let subtitle = attributes.subtitle {
                        Text(subtitle).font(.subheadline).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                RemainingTime(state: state)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.65))
            }
            PlaybackProgress(state: state)
            PlaybackButtons(state: state)
        }
        .foregroundStyle(.white)
        .padding(16)
    }
}

private struct PlaybackButtons: View {
    let state: PlaybackAttributes.ContentState

    var body: some View {
        HStack(spacing: 44) {
            Button(intent: SkipPlaybackIntent(seconds: -10)) {
                Image(systemName: "gobackward.10")
            }
            Button(intent: TogglePlaybackIntent()) {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .frame(width: 30)
            }
            Button(intent: SkipPlaybackIntent(seconds: 10)) {
                Image(systemName: "goforward.10")
            }
        }
        .font(.title3)
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }
}

private struct PlaybackProgress: View {
    let state: PlaybackAttributes.ContentState

    var body: some View {
        Group {
            if state.isPlaying && state.duration > 0 {
                // Advances on its own between updates.
                ProgressView(timerInterval: state.startDate...state.endDate, countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
            } else {
                ProgressView(value: state.progress)
            }
        }
        .progressViewStyle(.linear)
        .tint(.white)
    }
}

private struct RemainingTime: View {
    let state: PlaybackAttributes.ContentState

    var body: some View {
        if state.isPlaying && state.duration > 0 {
            Text(timerInterval: Date()...max(state.endDate, Date().addingTimeInterval(1)), countsDown: true)
                .multilineTextAlignment(.trailing)
        } else {
            Text("-" + Self.format(max(state.duration - state.position, 0)))
        }
    }

    static func format(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// The app's play mark (corner dots and bars), drawn so the widget needs no image asset.
private struct AppMark: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(Color(white: 0.06))
            Canvas { context, canvas in
                let h = canvas.height * 0.58
                let w = h * 0.8
                let r = h * 0.115
                let left = canvas.width / 2 - w * 0.47
                let a = CGPoint(x: left, y: canvas.height / 2 - h / 2)
                let b = CGPoint(x: left, y: canvas.height / 2 + h / 2)
                let c = CGPoint(x: left + w, y: canvas.height / 2)
                for point in [a, b, c] {
                    context.fill(Path(ellipseIn: CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2)),
                                 with: .color(.white))
                }
                for (p, q) in [(a, b), (a, c), (b, c)] {
                    let dx = q.x - p.x, dy = q.y - p.y
                    let length = sqrt(dx * dx + dy * dy)
                    let ux = dx / length, uy = dy / length
                    let trim = r * 2.6
                    var path = Path()
                    path.move(to: CGPoint(x: p.x + ux * trim, y: p.y + uy * trim))
                    path.addLine(to: CGPoint(x: q.x - ux * trim, y: q.y - uy * trim))
                    context.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: r * 2, lineCap: .round))
                }
            }
        }
        .frame(width: size, height: size)
    }
}
