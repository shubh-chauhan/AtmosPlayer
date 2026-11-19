#if DEBUG
import Foundation

/// Checks for pure logic, run by CI: `simctl launch --console-pty … -selfCheck YES` prints
/// SELFCHECK PASS or a FAIL line per broken check, then the app quits.
enum SelfCheck {
    static func runIfAsked() {
        guard UserDefaults.standard.bool(forKey: "selfCheck") else { return }
        checkFilling()
        if failures.isEmpty {
            print("SELFCHECK PASS")
        } else {
            failures.forEach { print("SELFCHECK FAIL \($0)") }
        }
        fflush(stdout)
        exit(failures.isEmpty ? 0 : 1)
    }

    private static var failures: [String] = []

    private static func expect(_ ok: Bool, _ what: String, line: Int = #line) {
        if !ok { failures.append("SelfCheck.swift:\(line) \(what)") }
    }

    private static func episode(_ id: String, _ season: Int, _ number: Int, title: String? = nil,
                                thumbnail: String? = nil, overview: String? = nil) -> StremioMeta.Video {
        StremioMeta.Video(id: id, title: title, season: season, episode: number, released: nil,
                          thumbnail: thumbnail, overview: overview, rating: nil)
    }

    /// StremioMeta.filling(from:): what the title page shows when Cinemeta is missing details.
    private static func checkFilling() {
        // Own values stay; empty (or blank) ones come from the other source.
        let mine = StremioMeta(id: "tt1", type: "series", name: "Show", description: "  ",
                               runtime: "45 min", genres: [], cast: ["A"])
        let theirs = StremioMeta(id: "tt1", type: "series", name: "Other name", background: "bg",
                                 description: "Plot", runtime: "50 min", genres: ["Drama"], cast: ["B"],
                                 trailerId: "yt")
        let merged = mine.filling(from: theirs)
        expect(merged.name == "Show", "keeps its own name")
        expect(merged.runtime == "45 min", "keeps its own runtime")
        expect(merged.cast == ["A"], "keeps its own cast")
        expect(merged.description == "Plot", "blank description is filled")
        expect(merged.background == "bg", "missing background is filled")
        expect(merged.genres == ["Drama"], "missing genres are filled")
        expect(merged.trailerId == "yt", "missing trailer is filled")

        // Episodes are matched by season and number; other ids add nothing.
        let show = StremioMeta(id: "tt1", type: "series", name: "Show", videos: [
            episode("tt1:1:1", 1, 1, title: "Pilot"),
            episode("tt1:1:2", 1, 2, thumbnail: "own.jpg"),
        ])
        let other = StremioMeta(id: "other", type: "series", name: "Show", videos: [
            episode("x:1:1", 1, 1, title: "Other title", thumbnail: "1.jpg", overview: "One"),
            episode("x:1:2", 1, 2, thumbnail: "2.jpg", overview: "Two"),
            episode("x:1:3", 1, 3, title: "Three"),
        ])
        let episodes = show.filling(from: other).videos
        expect(episodes.map(\.id) == ["tt1:1:1", "tt1:1:2"], "different ids: no episodes added")
        expect(episodes.first?.title == "Pilot", "keeps its own episode title")
        expect(episodes.first?.thumbnail == "1.jpg", "fills a missing still")
        expect(episodes.first?.overview == "One", "fills a missing synopsis")
        expect(episodes.last?.thumbnail == "own.jpg", "keeps its own still")
        expect(episodes.last?.overview == "Two", "fills the second synopsis")

        // Same ids: missing regular episodes are added, specials are not.
        let short = StremioMeta(id: "tt1", type: "series", name: "Show", videos: [episode("tt1:1:1", 1, 1)])
        let full = StremioMeta(id: "tt1", type: "series", name: "Show", videos: [
            episode("tt1:1:1", 1, 1), episode("tt1:1:2", 1, 2), episode("tt1:0:1", 0, 1),
        ])
        expect(short.filling(from: full).videos.map(\.id) == ["tt1:1:1", "tt1:1:2"], "adds S1E2, not the special")

        // No episodes of its own: takes all of the other's.
        let empty = StremioMeta(id: "tt1", type: "series", name: "Show")
        let some = StremioMeta(id: "x", type: "series", name: "Show", videos: [episode("x:1:1", 1, 1)])
        expect(empty.filling(from: some).videos.count == 1, "takes every episode when it has none")
    }
}
#endif
