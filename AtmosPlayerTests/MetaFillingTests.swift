import XCTest
@testable import AtmosPlayer

final class MetaFillingTests: XCTestCase {
    private func episode(_ id: String, _ season: Int, _ number: Int, title: String? = nil,
                         thumbnail: String? = nil, overview: String? = nil) -> StremioMeta.Video {
        StremioMeta.Video(id: id, title: title, season: season, episode: number, released: nil,
                          thumbnail: thumbnail, overview: overview, rating: nil)
    }

    func testKeepsOwnValuesAndFillsEmptyOnes() {
        let mine = StremioMeta(id: "tt1", type: "series", name: "Show", description: "  ",
                               runtime: "45 min", genres: [], cast: ["A"])
        let theirs = StremioMeta(id: "tt1", type: "series", name: "Other name", background: "bg",
                                 description: "Plot", runtime: "50 min", genres: ["Drama"], cast: ["B"],
                                 trailerId: "yt")
        let merged = mine.filling(from: theirs)
        XCTAssertEqual(merged.name, "Show")
        XCTAssertEqual(merged.runtime, "45 min")
        XCTAssertEqual(merged.cast, ["A"])
        XCTAssertEqual(merged.description, "Plot", "blank text counts as missing")
        XCTAssertEqual(merged.background, "bg")
        XCTAssertEqual(merged.genres, ["Drama"])
        XCTAssertEqual(merged.trailerId, "yt")
    }

    func testFillsEpisodesBySeasonAndNumber() {
        let mine = StremioMeta(id: "tt1", type: "series", name: "Show", videos: [
            episode("tt1:1:1", 1, 1, title: "Pilot"),
            episode("tt1:1:2", 1, 2, thumbnail: "own.jpg"),
        ])
        let theirs = StremioMeta(id: "other", type: "series", name: "Show", videos: [
            episode("x:1:1", 1, 1, title: "Other title", thumbnail: "1.jpg", overview: "One"),
            episode("x:1:2", 1, 2, thumbnail: "2.jpg", overview: "Two"),
            episode("x:1:3", 1, 3, title: "Three"),
        ])
        let merged = mine.filling(from: theirs)
        XCTAssertEqual(merged.videos.map(\.id), ["tt1:1:1", "tt1:1:2"], "ids differ: nothing is added")
        XCTAssertEqual(merged.videos[0].title, "Pilot")
        XCTAssertEqual(merged.videos[0].thumbnail, "1.jpg")
        XCTAssertEqual(merged.videos[0].overview, "One")
        XCTAssertEqual(merged.videos[1].thumbnail, "own.jpg")
        XCTAssertEqual(merged.videos[1].overview, "Two")
    }

    func testAddsMissingEpisodesOnlyWhenIdsMatch() {
        let mine = StremioMeta(id: "tt1", type: "series", name: "Show", videos: [episode("tt1:1:1", 1, 1)])
        let theirs = StremioMeta(id: "tt1", type: "series", name: "Show", videos: [
            episode("tt1:1:1", 1, 1), episode("tt1:1:2", 1, 2), episode("tt1:0:1", 0, 1),
        ])
        XCTAssertEqual(mine.filling(from: theirs).videos.map(\.id), ["tt1:1:1", "tt1:1:2"],
                       "specials (season 0) are not added")
    }

    func testTakesAllEpisodesWhenItHasNone() {
        let mine = StremioMeta(id: "tt1", type: "series", name: "Show")
        let theirs = StremioMeta(id: "x", type: "series", name: "Show", videos: [episode("x:1:1", 1, 1)])
        XCTAssertEqual(mine.filling(from: theirs).videos.count, 1)
    }
}
