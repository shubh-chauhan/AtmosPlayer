import SwiftUI
import WebKit

// MARK: - Trailer previews
//
// Like the TV app: after you rest on a big card for a moment, its trailer fades in over the
// artwork, muted, cropped to fill the card. Trailers are YouTube videos (Cinemeta lists their
// ids), played through YouTube's own embedded player. The video only fades in once it is
// actually playing, so a slow or blocked trailer just leaves the artwork as it was.

enum TrailerPreviews {
    static let key = "previews.trailers"

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    /// Off in Low Power Mode, and in the CI screenshots (except the one that tests them).
    static var allowed: Bool {
        !ProcessInfo.processInfo.isLowPowerModeEnabled && (PreviewMode.screen == nil || diagnosing)
    }

    /// The CI screenshot that checks a trailer really plays: shows the player's state on the card.
    static var diagnosing: Bool { PreviewMode.screen == "home-trailer" }

    /// YouTube wants an embed inside an app to identify itself as https://<bundle id>; a page
    /// without a recognised origin gets "Video player configuration error" (152/153) instead of
    /// the video.
    static let origin: String = "https://" + (Bundle.main.bundleIdentifier ?? "com.atmosplayer.app").lowercased()
}

/// The trailer layer for a big card. Put it right above the artwork, below the gradients.
struct TrailerBackdrop: View {
    let youtubeId: String?
    /// The card is the one being looked at (front page, nothing covering it).
    let active: Bool
    var muted = true
    /// How long to rest on the card before the trailer starts loading.
    var delay: Double = 2.2
    /// Reports when the trailer is visible (so the card can stop its own motion or timer).
    var onShowing: (Bool) -> Void = { _ in }

    @AppStorage(TrailerPreviews.key) private var enabled = true
    @Environment(\.scenePhase) private var scenePhase
    @State private var armed = false
    @State private var showing = false
    @State private var status = "waiting"

    private var wanted: Bool {
        youtubeId != nil && active && enabled && scenePhase == .active && TrailerPreviews.allowed
    }

    private struct Key: Equatable {
        let id: String?
        let wanted: Bool
    }

    var body: some View {
        GeometryReader { geo in
            if armed, let youtubeId {
                // Fill the card the way artwork does (crop, never letterbox), slightly
                // oversized so YouTube's title bar and logo fall outside the card.
                let size = Self.fill(geo.size, scale: 1.22)
                YouTubeLoop(videoId: youtubeId, muted: muted, onStatus: { status = $0 }) { playing in
                    // A short wait after it starts, so the player's own overlays are gone.
                    Task { @MainActor in
                        if playing { try? await Task.sleep(nanoseconds: 900_000_000) }
                        guard armed else { return }
                        withAnimation(.easeInOut(duration: playing ? 0.9 : 0.5)) { showing = playing }
                    }
                }
                .frame(width: size.width, height: size.height)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                .opacity(showing ? 1 : 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .clipped()
        .overlay(alignment: .center) {
            if TrailerPreviews.diagnosing {
                Text("trailer \(youtubeId ?? "none") · active \(active ? "yes" : "no") · \(armed ? status : "not armed")")
                    .font(.caption.monospaced()).padding(6)
                    .background(.black.opacity(0.7)).foregroundStyle(.yellow)
            }
        }
        .allowsHitTesting(false)
        .onChange(of: showing) { _, value in onShowing(value) }
        .task(id: Key(id: youtubeId, wanted: wanted)) {
            guard wanted else {
                // Fade the video out first, then remove the player.
                if showing {
                    withAnimation(.easeInOut(duration: 0.45)) { showing = false }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                armed = false
                return
            }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            armed = true
        }
    }

    /// The size of a 16:9 video that covers `box`.
    static func fill(_ box: CGSize, scale: CGFloat) -> CGSize {
        guard box.width > 0, box.height > 0 else { return .zero }
        let ratio: CGFloat = 16 / 9
        let size = box.width / box.height > ratio
            ? CGSize(width: box.width, height: box.width / ratio)
            : CGSize(width: box.height * ratio, height: box.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}

/// YouTube's embedded player, looping one video with no controls.
private struct YouTubeLoop: UIViewRepresentable {
    let videoId: String
    let muted: Bool
    var onStatus: (String) -> Void = { _ in }
    let onPlaying: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPlaying: onPlaying, onStatus: onStatus) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = false
        config.allowsAirPlayForMediaPlayback = false
        config.mediaTypesRequiringUserActionForPlayback = []
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(WeakHandler(context.coordinator), name: "yt")

        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.isUserInteractionEnabled = false
        web.loadHTMLString(Self.page(videoId, muted: muted), baseURL: URL(string: TrailerPreviews.origin + "/"))
        context.coordinator.muted = muted
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.onPlaying = onPlaying
        context.coordinator.onStatus = onStatus
        if context.coordinator.muted != muted {
            context.coordinator.muted = muted
            web.evaluateJavaScript(muted ? "window.setMuted && setMuted(true)" : "window.setMuted && setMuted(false)")
        }
    }

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        web.evaluateJavaScript("window.player && player.stopVideo && player.stopVideo()")
        web.configuration.userContentController.removeScriptMessageHandler(forName: "yt")
        web.stopLoading()
        web.loadHTMLString("", baseURL: nil)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var onPlaying: (Bool) -> Void
        var onStatus: (String) -> Void
        var muted = true
        init(onPlaying: @escaping (Bool) -> Void, onStatus: @escaping (String) -> Void) {
            self.onPlaying = onPlaying
            self.onStatus = onStatus
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            // Strings are status notes for the diagnostics. YouTube states: 1 playing; -2 is our
            // error signal. Buffering and the loop's restart (ended, unstarted) keep the video up,
            // so it never blinks.
            if let note = message.body as? String { onStatus(note); return }
            guard let state = message.body as? Int else { return }
            onStatus("state \(state)")
            if state == 1 { onPlaying(true) } else if state == -2 { onPlaying(false) }
        }
    }

    /// The content controller holds its handler strongly; this breaks the cycle.
    private final class WeakHandler: NSObject, WKScriptMessageHandler {
        weak var target: WKScriptMessageHandler?
        init(_ target: WKScriptMessageHandler) { self.target = target }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            target?.userContentController(controller, didReceive: message)
        }
    }

    private static func page(_ id: String, muted: Bool) -> String {
        let safe = id.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
        <style>html,body{margin:0;height:100%;background:transparent;overflow:hidden}
        #p{position:absolute;top:0;left:0;width:100%;height:100%;pointer-events:none}</style>
        </head><body><div id="p"></div>
        <script>
        var player;
        function post(s){try{window.webkit.messageHandlers.yt.postMessage(s)}catch(e){}}
        function setMuted(m){if(!player||!player.mute)return;if(m){player.mute()}else{player.unMute();player.setVolume(100)}}
        window.onerror=function(m){post('js '+m)};
        function onYouTubeIframeAPIReady(){post('api');
          player=new YT.Player('p',{videoId:'\(safe)',width:'100%',height:'100%',
            playerVars:{autoplay:1,mute:1,controls:0,playsinline:1,loop:1,playlist:'\(safe)',rel:0,
              iv_load_policy:3,disablekb:1,fs:0,cc_load_policy:0,start:4,origin:'\(TrailerPreviews.origin)',
              widget_referrer:'\(TrailerPreviews.origin)'},
            events:{
              onReady:function(e){post('ready');e.target.mute();\(muted ? "" : "e.target.unMute();")e.target.playVideo()},
              onStateChange:function(e){post(e.data)},
              onError:function(e){post('error '+e.data);post(-2)}
            }});
        }
        </script>
        <script src="https://www.youtube.com/iframe_api"></script>
        </body></html>
        """
    }
}
