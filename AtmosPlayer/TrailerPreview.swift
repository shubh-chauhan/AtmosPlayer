import SwiftUI
import UIKit
import WebKit

// MARK: - Trailer previews
//
// Like the TV app: after you rest on a big card for a moment, its trailer fades in over the
// artwork, muted, cropped to fill the card. Trailers are YouTube videos (Cinemeta lists their
// ids), played through YouTube's own embedded player. The video only fades in once it is
// actually playing, so a slow or blocked trailer just leaves the artwork as it was.
//
// A trailer that has played is parked (paused, kept loaded) when its card scrolls away, the
// page changes or you open the title, so coming back resumes it where it was instead of
// loading it again.

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

/// Players for trailers that have already started, paused and kept loaded, newest last.
@MainActor
final class TrailerPool {
    static let shared = TrailerPool()

    /// One in-memory store for every trailer, so YouTube's player scripts download once per
    /// session; nothing is written to disk.
    let dataStore = WKWebsiteDataStore.nonPersistent()

    fileprivate struct Parked {
        let id: String
        let web: WKWebView
        let handler: ScriptHandler
    }

    private var parked: [Parked] = []
    /// Each paused player holds a few MB of video; three covers swiping back a page or two
    /// and the title you just opened.
    private let limit = 3

    private init() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { TrailerPool.shared.clear() }
        }
    }

    func has(_ id: String?) -> Bool { parked.contains { $0.id == id } }

    fileprivate func take(_ id: String) -> Parked? {
        guard let index = parked.firstIndex(where: { $0.id == id }) else { return nil }
        return parked.remove(at: index)
    }

    fileprivate func park(_ item: Parked) {
        item.web.evaluateJavaScript("window.player && player.pauseVideo && player.pauseVideo()")
        item.handler.target = nil
        item.web.removeFromSuperview()
        if let older = take(item.id) { Self.destroy(older.web) }
        parked.append(item)
        while parked.count > limit { Self.destroy(parked.removeFirst().web) }
    }

    func clear() {
        parked.forEach { Self.destroy($0.web) }
        parked.removeAll()
    }

    fileprivate static func destroy(_ web: WKWebView) {
        web.evaluateJavaScript("window.player && player.stopVideo && player.stopVideo()")
        web.configuration.userContentController.removeScriptMessageHandler(forName: "yt")
        web.stopLoading()
        web.loadHTMLString("", baseURL: nil)
        web.removeFromSuperview()
    }
}

/// The trailer layer for a big card. Put it right above the artwork, below the gradients.
struct TrailerBackdrop: View {
    let youtubeId: String?
    /// The card is the one being looked at (front page, nothing covering it).
    let active: Bool
    var muted = true
    /// How long to rest on the card before the trailer starts loading. The player loads hidden
    /// and only fades in once the video is actually moving, so this can be short.
    var delay: Double = 0.8
    /// Reports when the trailer is visible (so the card can stop its own motion or timer).
    var onShowing: (Bool) -> Void = { _ in }

    @AppStorage(TrailerPreviews.key) private var enabled = true
    @Environment(\.scenePhase) private var scenePhase
    @State private var armed = false
    @State private var showing = false
    /// The video is moving (reported by the player).
    @State private var playing = false
    /// This trailer was parked and is being resumed: no wait, and a quicker fade.
    @State private var warm = false
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
                // oversized so a widescreen trailer's black bars fall outside the card.
                let size = Self.fill(geo.size, scale: 1.3)
                YouTubeLoop(videoId: youtubeId, muted: muted, onStatus: { status = $0 }) { isPlaying in
                    playing = isPlaying
                    // A beat after it starts, so the first frames are past (none needed on a resume).
                    Task { @MainActor in
                        if isPlaying { try? await Task.sleep(nanoseconds: warm ? 80_000_000 : 450_000_000) }
                        guard armed else { return }
                        withAnimation(.easeInOut(duration: isPlaying ? (warm ? 0.35 : 0.7) : 0.45)) { showing = isPlaying }
                    }
                }
                .id(youtubeId)
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
                // Fade the video out first, then hand the player to the pool.
                if showing {
                    withAnimation(.easeInOut(duration: 0.45)) { showing = false }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    // Wanted again during the fade: the next run brings it back.
                    guard !Task.isCancelled else { return }
                }
                armed = false
                playing = false
                return
            }
            // Came back during the fade-out: the player never left, so just show it again.
            if armed && playing {
                withAnimation(.easeInOut(duration: 0.35)) { showing = true }
                return
            }
            warm = TrailerPool.shared.has(youtubeId)
            if !warm {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
            }
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

/// Holds the web view and keeps it the size of the SwiftUI frame (a parked player is moved
/// between hosts).
private final class TrailerHost: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()
        subviews.forEach { $0.frame = bounds }
    }
}

/// The content controller holds its handler strongly; this breaks the cycle, and lets a parked
/// player report to whichever card picks it up next.
fileprivate final class ScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler?) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// YouTube's embedded player, looping one video with no controls.
private struct YouTubeLoop: UIViewRepresentable {
    let videoId: String
    let muted: Bool
    var onStatus: (String) -> Void = { _ in }
    let onPlaying: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPlaying: onPlaying, onStatus: onStatus) }

    func makeUIView(context: Context) -> UIView {
        let host = TrailerHost()
        host.backgroundColor = .clear
        host.isUserInteractionEnabled = false
        let coordinator = context.coordinator
        coordinator.videoId = videoId
        coordinator.muted = muted

        if let warm = TrailerPool.shared.take(videoId) {
            warm.handler.target = coordinator
            coordinator.web = warm.web
            coordinator.handler = warm.handler
            coordinator.started = true
            host.addSubview(warm.web)
            onStatus("resumed")
            warm.web.evaluateJavaScript("window.setMuted && setMuted(\(muted)); window.player && player.playVideo && player.playVideo()")
            return host
        }

        let handler = ScriptHandler(coordinator)
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = false
        config.allowsAirPlayForMediaPlayback = false
        config.mediaTypesRequiringUserActionForPlayback = []
        config.websiteDataStore = TrailerPool.shared.dataStore
        config.userContentController.add(handler, name: "yt")
        config.userContentController.addUserScript(WKUserScript(
            source: Self.videoOnly, injectionTime: .atDocumentStart, forMainFrameOnly: false))

        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.isUserInteractionEnabled = false
        // YouTube's phone player draws its play/pause/skip buttons over the video whatever the
        // embed asks for; the desktop player honours controls=0 and shows only the picture.
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        web.loadHTMLString(Self.page(videoId, muted: muted), baseURL: URL(string: TrailerPreviews.origin + "/"))
        coordinator.web = web
        coordinator.handler = handler
        host.addSubview(web)
        return host
    }

    func updateUIView(_ host: UIView, context: Context) {
        context.coordinator.onPlaying = onPlaying
        context.coordinator.onStatus = onStatus
        if context.coordinator.muted != muted {
            context.coordinator.muted = muted
            context.coordinator.web?.evaluateJavaScript("window.setMuted && setMuted(\(muted))")
        }
    }

    static func dismantleUIView(_ host: UIView, coordinator: Coordinator) {
        guard let web = coordinator.web else { return }
        coordinator.web = nil
        // Only a trailer that actually played is worth keeping; a failed one is thrown away.
        if coordinator.started, let handler = coordinator.handler {
            TrailerPool.shared.park(.init(id: coordinator.videoId, web: web, handler: handler))
        } else {
            TrailerPool.destroy(web)
        }
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var onPlaying: (Bool) -> Void
        var onStatus: (String) -> Void
        var muted = true
        var videoId = ""
        var started = false
        var web: WKWebView?
        fileprivate var handler: ScriptHandler?

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
            if state == 1 {
                started = true
                onPlaying(true)
            } else if state == -2 {
                started = false
                onPlaying(false)
            }
        }
    }

    /// Runs inside YouTube's player frame: hides every element that is not the video or one of
    /// its containers, so no play/pause/skip buttons, title, logo or spinner is ever drawn.
    private static let videoOnly = """
    if (/(^|\\.)youtube(-nocookie)?\\.com$/.test(location.hostname)) {
      var s = document.createElement('style');
      s.textContent = '*:not(:has(video)):not(video){visibility:hidden!important}video{visibility:visible!important}';
      (document.head || document.documentElement).appendChild(s);
    }
    """

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
