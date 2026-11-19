#if DEBUG
import Foundation

/// Checks for pure logic, run by CI: `simctl launch --console-pty … -selfCheck YES` prints
/// SELFCHECK PASS or a FAIL line per broken check, then the app quits.
@MainActor
enum SelfCheck {
    static func runIfAsked() {
        guard UserDefaults.standard.bool(forKey: "selfCheck") else { return }
        checkFilling()
        checkSavedMeta()
        checkTMDBMapping()
        checkTokenAndPolicy()
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

    /// A saved title reads back the same through the addon decoder (MetaCache).
    private static func checkSavedMeta() {
        let meta = StremioMeta(id: "tt1", type: "series", name: "Show", poster: "p", background: "b", logo: "l",
                               description: "d", releaseInfo: "2020", imdbRating: "7.1", runtime: "50 min",
                               genres: ["Drama"], videos: [episode("tt1:1:1", 1, 1, title: "Pilot", thumbnail: "t")],
                               cast: ["A"], directors: ["D"], writers: ["W"], awards: "aw", country: "UK",
                               status: "Ended", released: "2020-01-01", trailerId: "yt", shareURL: "s", language: "en")
        guard let data = try? JSONEncoder().encode(meta),
              let back = try? JSONDecoder().decode(StremioMeta.self, from: data) else {
            expect(false, "meta encodes and decodes")
            return
        }
        expect(MetaResolver.changedFields(meta, back).isEmpty,
               "saved meta reads back unchanged: \(MetaResolver.changedFields(meta, back))")
        expect(back.shareURL == "s" && back.id == "tt1" && back.type == "series", "ids and share link survive")
        expect(MetaResolver.changedFields(meta, meta.filling(from: StremioMeta(id: "x", type: "series", name: "X",
                                                                              description: "other"))).isEmpty,
               "filling never replaces a value")
    }

    /// A TMDB answer becomes the app's model under the IMDb id, and nothing is invented.
    private static func checkTMDBMapping() {
        let json = """
        {"id": 42, "name": "Show", "original_name": "Show O", "original_language": "fr",
         "overview": "Plot", "first_air_date": "2021-01-08", "episode_run_time": [45],
         "status": "Returning Series", "genres": [{"name": "Drama"}], "vote_average": 7.6, "vote_count": 900,
         "poster_path": "/p.jpg", "backdrop_path": "/b.jpg",
         "production_companies": [{"name": "Studio"}], "production_countries": [{"iso_3166_1": "FR", "name": "France"}],
         "spoken_languages": [{"english_name": "French", "iso_639_1": "fr"}],
         "seasons": [{"season_number": 0}, {"season_number": 1}],
         "credits": {"cast": [{"name": "Lead", "character": "Hero", "profile_path": "/c.jpg", "order": 0}],
                     "crew": [{"name": "Boss", "job": "Director", "department": "Directing"},
                              {"name": "Pen", "job": "Writer", "department": "Writing"}]},
         "external_ids": {"imdb_id": "tt9", "tvdb_id": 77},
         "images": {"backdrops": [{"file_path": "/t.jpg", "iso_639_1": null, "vote_average": 5, "width": 3840},
                                  {"file_path": "/x.jpg", "iso_639_1": "en", "vote_average": 9, "width": 1920}],
                    "logos": [{"file_path": "/l.png", "iso_639_1": "en", "vote_average": 5, "width": 800}],
                    "posters": []},
         "videos": {"results": [{"key": "teaser", "site": "YouTube", "type": "Teaser"},
                                {"key": "main", "site": "YouTube", "type": "Trailer", "official": true}]},
         "season/1": {"season_number": 1, "episodes": [
            {"season_number": 1, "episode_number": 1, "name": "One", "overview": "", "still_path": "/s.jpg",
             "air_date": "2021-01-08", "vote_average": 0}]}}
        """
        guard let details = try? JSONDecoder().decode(TMDB.Details.self, from: Data(json.utf8)) else {
            expect(false, "TMDB details decode")
            return
        }
        let meta = details.stremioMeta(imdb: "tt9", type: "series")
        expect(meta.id == "tt9", "keeps the IMDb id (streams match on it)")
        expect(meta.runtime == "45 min" && meta.releaseInfo == "2021", "runtime and year")
        expect(meta.status == "Continuing", "running series reads as Continuing")
        expect(meta.trailerId == "main", "official trailer before a teaser")
        expect(meta.directors == ["Boss"] && meta.writers == ["Pen"], "director and writer")
        expect(meta.imdbRating == nil, "no IMDb rating invented from TMDB's")
        expect(meta.background == TMDB.imageBase + "w1280/x.jpg", "best-voted backdrop")
        expect(meta.videos.map(\.id) == ["tt9:1:1"], "episodes under Stremio ids")
        expect(meta.videos.first?.overview == nil, "empty synopsis stays empty")
        expect(meta.videos.first?.rating == nil, "no 0.0 rating")
        expect(meta.videos.first?.thumbnail == TMDB.imageBase + "w780/s.jpg", "episode still")

        let extras = details.extras(imdb: "tt9")
        expect(extras.tmdbId == 42 && extras.tvdbId == 77 && extras.tmdbKind == "tv", "ids recorded")
        expect(extras.textlessBackdrop == TMDB.imageBase + "w1280/t.jpg", "textless backdrop is the no-language one")
        expect(extras.cast.first?.role == "Hero" && extras.cast.first?.photo == TMDB.imageBase + "w185/c.jpg",
               "cast with character and photo")
        expect(extras.companies == ["Studio"] && extras.countries == ["France"], "companies and countries")
        expect(extras.originalTitle == "Show O" && extras.tmdbRating == 7.6, "original title and TMDB rating")
    }

    private static func checkTokenAndPolicy() {
        // CI stores the token reversed and base64'd: "abc" → "cba" → "Y2Jh".
        expect(TMDB.descramble("Y2Jh") == "abc", "token descrambles")
        expect(TMDB.descramble("") == nil && TMDB.descramble("$(TMDB_TOKEN)") == nil, "no token, no TMDB")

        let policy = MetaCachePolicy()
        let running = StremioMeta(id: "tt1", type: "series", name: "S", status: "Continuing")
        let ended = StremioMeta(id: "tt1", type: "series", name: "S", status: "Ended")
        expect(policy.ttl(for: running) < policy.ttl(for: ended), "running series refresh sooner")
        let entry = MetaCache.Entry(meta: ended, extras: nil, enriched: false,
                                    savedAt: Date().addingTimeInterval(-policy.endedSeries - 60))
        expect(!entry.isFresh(policy), "an old entry is stale")
        expect(policy.maximumAge <= 183 * 24 * 3600, "nothing kept past six months (TMDB terms)")
    }
}
#endif
