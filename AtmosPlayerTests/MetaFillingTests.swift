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

final class ArtworkFocusTests: XCTestCase {
    func testCentredWhenNothingFound() {
        XCTAssertEqual(ArtworkFocus(salient: [], text: []).centre(keep: 0.4), 0.5, accuracy: 0.001)
    }

    func testFollowsTheSubject() {
        // A person on the right of a wide still (Lupin's backdrop).
        let focus = ArtworkFocus(salient: [CGRect(x: 0.5, y: 0, width: 0.4, height: 1)], text: [])
        XCTAssertEqual(focus.centre(keep: 0.4), 0.7, accuracy: 0.03)
    }

    func testKeepsPrintedTitleOutOfFrame() {
        // A face on the left and the title lettering on the right (Spider-Man's backdrop).
        let focus = ArtworkFocus(salient: [CGRect(x: 0, y: 0, width: 0.4, height: 1),
                                           CGRect(x: 0.42, y: 0.3, width: 0.55, height: 0.3)],
                                 text: [CGRect(x: 0.42, y: 0.35, width: 0.55, height: 0.2)])
        let centre = focus.centre(keep: 0.4)
        XCTAssertLessThanOrEqual(centre + 0.2, 0.42 + 0.001, "the kept window must stop before the text")
    }

    func testNoShiftWhenTheImageFits() {
        let focus = ArtworkFocus(salient: [CGRect(x: 0.8, y: 0, width: 0.2, height: 1)], text: [])
        XCTAssertEqual(ArtworkFocus.shift(image: CGSize(width: 1000, height: 1500),
                                          frame: CGSize(width: 400, height: 600), focus: focus), 0)
        // A wide image in a tall frame moves left to bring the right-hand subject in.
        XCTAssertLessThan(ArtworkFocus.shift(image: CGSize(width: 1920, height: 1080),
                                             frame: CGSize(width: 400, height: 560), focus: focus), 0)
    }
}
