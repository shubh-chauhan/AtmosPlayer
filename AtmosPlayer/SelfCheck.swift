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
        checkCatalogs()
        checkRecommendations()
        checkSearch()
        checkAdditions()
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
                    "posters": [{"file_path": "/tp.jpg", "iso_639_1": null, "vote_average": 5, "width": 2000}]},
         "videos": {"results": [{"key": "teaser", "site": "YouTube", "type": "Teaser"},
                                {"key": "main", "site": "YouTube", "type": "Trailer", "official": true}]},
         "watch/providers": {"results": {"US": {"link": "L",
            "flatrate": [{"provider_id": 8, "provider_name": "Netflix", "logo_path": "/n.png", "display_priority": 1}],
            "rent": [{"provider_id": 2, "provider_name": "Apple TV", "logo_path": "/a.png", "display_priority": 3}]}}},
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
        expect(extras.heroArt(portrait: true) == TMDB.imageBase + "original/tp.jpg"
               && extras.heroArt(portrait: false) == extras.textlessBackdrop, "portrait frames get the textless poster")
        var titled = extras
        titled.textlessPoster = nil
        titled.poster = TMDB.imageBase + "w780/p.jpg"
        expect(titled.heroArt(portrait: true) == TMDB.imageBase + "original/p.jpg",
               "no textless poster: a tall frame takes the full-size poster, not a cropped backdrop")
        expect(extras.cast.first?.role == "Hero" && extras.cast.first?.photo == TMDB.imageBase + "w185/c.jpg",
               "cast with character and photo")
        expect(extras.companies == ["Studio"] && extras.countries == ["France"], "companies and countries")
        expect(extras.originalTitle == "Show O" && extras.tmdbRating == 7.6, "original title and TMDB rating")

        let us = details.availability(region: "US")
        expect(us.offers.map(\.name) == ["Netflix", "Apple TV"] && us.offers.first?.kind == .subscription
               && us.offers.last?.kind == .rent && us.link == "L", "where to watch: subscription and rent, in order")
        expect(details.availability(region: "GB").offers.isEmpty, "nothing claimed for a region TMDB doesn't list")
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

    private static func preview(_ id: String) -> MetaPreview {
        MetaPreview(id: id, type: "movie", name: id, poster: "p", background: "b", logo: nil, description: "d",
                    releaseInfo: "2020", imdbRating: nil, genres: [], runtime: nil, trailerId: nil)
    }

    /// Home rows as data: sources save and read back, and a title shows in one row only.
    private static func checkCatalogs() {
        // Every row shares the same 10 titles and has 10 of its own.
        let shared = (0..<10).map { preview("tt-shared-\($0)") }
        var results: [String: [MetaPreview]] = [:]
        for spec in HomeFeed.topSpecs + HomeFeed.restSpecs {
            results[spec.id] = shared + (0..<10).map { preview("tt-\(spec.id)-\($0)") }
        }
        let (top, rest) = HomeFeed.sections(results)
        var seen: [String: String] = [:]
        var repeats: [String] = []
        for row in top + rest where row.style != .ranked {
            for item in row.items {
                if let first = seen[item.id] { repeats.append("\(item.id) in \(first) and \(row.id)") }
                seen[item.id] = seen[item.id] ?? row.id
            }
        }
        expect(repeats.isEmpty, "no title in two rows: \(repeats.prefix(3))")
        expect(top.count + rest.count == (HomeFeed.topSpecs + HomeFeed.restSpecs).count, "every row kept")

        // Artwork: best source first, the next ones to fall back on.
        let tmdbPoster = "https://image.tmdb.org/t/p/w500/a.jpg"
        let hubPoster = "https://images.metahub.space/poster/medium/tt1/img"
        expect(ArtworkURL.posters(id: "tt1", poster: tmdbPoster) == [tmdbPoster, hubPoster], "TMDB poster, then MetaHub")
        expect(ArtworkURL.posters(id: "tt1", poster: "https://addon.example/p.jpg") == [hubPoster, "https://addon.example/p.jpg"],
               "MetaHub before an addon's own poster")
        expect(ArtworkURL.posters(id: "tt1", poster: "https://images.metahub.space/poster/small/tt1/img") == [hubPoster],
               "Cinemeta's poster not tried twice")
        expect(ArtworkURL.posters(id: "kitsu:1", poster: "https://addon.example/p.jpg") == ["https://addon.example/p.jpg"],
               "non-IMDb titles keep their addon's poster")
        expect(ArtworkURL.backdrops(id: "tt1", background: nil, poster: "p").last == "p", "poster is the last backdrop")

        // Saved rows read back through the Stremio decoder.
        let item = MetaPreview(id: "tt1", type: "series", name: "N", poster: "p", background: nil, logo: "l",
                               description: nil, releaseInfo: "2021", imdbRating: "8.0", genres: ["Drama"],
                               runtime: nil, trailerId: "yt")
        if let data = try? JSONEncoder().encode([item]), let back = try? JSONDecoder().decode([MetaPreview].self, from: data) {
            expect(back == [item], "a saved row reads back unchanged")
        } else {
            expect(false, "a saved row encodes and decodes")
        }
        let source = CatalogSource.tmdbDiscover(kind: "movie", query: ["b": "2", "a": "1"])
        if let data = try? JSONEncoder().encode(source), let back = try? JSONDecoder().decode(CatalogSource.self, from: data) {
            expect(back == source && back.cacheKey == "tmdb/discover/movie/a=1&b=2", "a source saves, with a stable key")
        } else {
            expect(false, "a source encodes and decodes")
        }

        expect(TMDBGenres.names([10765, 878], tv: true) == ["Sci-Fi", "Fantasy"], "TMDB genres in Cinemeta's names")
        expect(TMDBGenres.names([878], tv: false) == ["Sci-Fi"], "Science Fiction is Sci-Fi")

        // Addon catalogs: genres and paging only when the manifest lists them.
        let manifest = """
        {"type": "movie", "id": "c", "name": "C",
         "extra": [{"name": "genre", "options": ["Action", "Drama"]}, {"name": "skip"}]}
        """
        let plain = """
        {"type": "movie", "id": "d", "name": "D"}
        """
        let rich = try? JSONDecoder().decode(StremioCatalog.self, from: Data(manifest.utf8))
        let bare = try? JSONDecoder().decode(StremioCatalog.self, from: Data(plain.utf8))
        expect(rich?.supportsSkip == true && rich?.genreOptions == ["Action", "Drama"], "addon genres and paging read")
        expect(bare?.supportsSkip == false && bare?.genreOptions == [] && bare?.isBrowsable == true, "plain catalog stays plain")
    }

    /// Taste from history, and the ranking that uses it.
    private static func checkRecommendations() {
        let now = Date()
        var finished = WatchedStore.Record()
        finished.videos = ["tt-done"]
        finished.changed = now
        var oldShow = WatchedStore.Record()
        oldShow.videos = ["tt-old:1:1", "tt-old:1:2"]
        oldShow.changed = now.addingTimeInterval(-365 * 86400)
        let stale = WatchStore.Entry(ref: VideoRef(type: "movie", metaId: "tt-quit", videoId: "tt-quit", name: "Quit",
                                                   poster: nil, episodeLabel: nil),
                                     position: 300, duration: 6000, updated: now.addingTimeInterval(-40 * 86400))
        let signals = TasteSignals.collect(records: ["tt-done": finished, "tt-old": oldShow], watching: [stale],
                                           list: [MetaRef(id: "tt-list", type: "movie", name: "L", poster: nil)],
                                           library: [], abandoned: ["tt-quit"], now: now)
        let weight = Dictionary(signals.map { ($0.metaId, $0.weight) }, uniquingKeysWith: +)
        expect((weight["tt-done"] ?? 0) > (weight["tt-list"] ?? 0), "a finished film counts more than a saved one")
        expect((weight["tt-quit"] ?? 0) < 0, "an abandoned title counts against")
        expect((weight["tt-old"] ?? 0) < 2.4 / 4, "a year-old series has faded")
        expect(signals.first(where: { $0.metaId == "tt-old" })?.type == "series", "episodes mean a series")

        let metas: [String: StremioMeta] = [
            "tt-done": StremioMeta(id: "tt-done", type: "movie", name: "A", releaseInfo: "2019", genres: ["Sci-Fi", "Thriller"]),
            "tt-quit": StremioMeta(id: "tt-quit", type: "movie", name: "Q", genres: ["Romance"]),
        ]
        let profile = TasteProfile.build(signals, metas: metas, extras: ["tt-done": MetaExtras(originalLanguage: "en")])
        expect(profile.genres["Sci-Fi"] == 1, "favourite genre tops out at 1")
        expect((profile.genres["Romance"] ?? 0) < 0, "abandoned genre goes negative")
        expect(profile.topGenres(1) == ["Sci-Fi"] || profile.topGenres(1) == ["Thriller"], "top genre")
        expect(profile.decades[2010] == 1, "decade")

        func candidate(_ id: String, _ genres: [String], vote: Double, votes: Int) -> Candidate {
            Candidate(preview: MetaPreview(id: id, type: "movie", name: id, poster: "p", background: nil, logo: nil,
                                           description: nil, releaseInfo: "2020", imdbRating: nil, genres: genres,
                                           runtime: nil, trailerId: nil),
                      voteAverage: vote, voteCount: votes, popularity: 50, language: "en")
        }
        let ranked = RecommendationRanker.rank([
            candidate("tt-romcom", ["Romance"], vote: 7.5, votes: 5000),
            candidate("tt-scifi", ["Sci-Fi"], vote: 7.5, votes: 5000),
            candidate("tt-done", ["Sci-Fi"], vote: 9, votes: 9000),
            candidate("tt-scifi", ["Sci-Fi"], vote: 7.5, votes: 5000),
        ], profile: profile, excluding: ["tt-done"], limit: 10)
        expect(ranked.map(\.id) == ["tt-scifi", "tt-romcom"], "matching genre first, seen left out, no repeats: \(ranked.map(\.id))")
        let fewVotes = RecommendationRanker.score(candidate("a", [], vote: 9.5, votes: 10), profile: TasteProfile())
        let manyVotes = RecommendationRanker.score(candidate("b", [], vote: 8.2, votes: 20000), profile: TasteProfile())
        expect(manyVotes > fewVotes, "a rating from many votes beats one from few")
    }

    /// Search: one list, merged on IMDb id only, best match first.
    private static func checkSearch() {
        func item(_ id: String, _ name: String, poster: String? = "p") -> MetaPreview {
            MetaPreview(id: id, type: "movie", name: name, poster: poster, background: nil, logo: nil, description: nil,
                        releaseInfo: nil, imdbRating: nil, genres: [], runtime: nil, trailerId: nil)
        }
        expect(UnifiedSearch.match("The Office", "the office") == 1, "exact match ignores case")
        expect(UnifiedSearch.match("Amélie", "amelie") == 1, "and accents")
        expect(UnifiedSearch.match("The Office (UK)", "the office") > UnifiedSearch.match("Office Space", "the office"),
               "prefix beats partial")
        let merged = UnifiedSearch.merge("dune", [
            [item("tt2", "Dune: Part Two"), item("tt1", "Dune", poster: nil)],
            [item("tt1", "Dune"), item("tt3", "Dune")],
        ])
        expect(merged.map(\.id) == ["tt1", "tt3", "tt2"], "exact names first, found twice ranks higher: \(merged.map(\.id))")
        expect(merged.first?.poster == "p", "a merged title keeps the artwork another source had")
        expect(merged.filter { $0.name == "Dune" }.count == 2, "same name, different id: two results")
    }
    /// Best-stream pick, saved writes, MDBList scores, Trakt bodies, anime ids, Spotlight ids
    /// and image expiry.
    private static func checkAdditions() {
        // One-tap Play: the best playable stream, never a camera copy, within the filters.
        func streams(_ json: String) -> [StremioStream] {
            (try? JSONDecoder().decode([StremioStream].self, from: Data(json.utf8))) ?? []
        }
        let first = streams(#"[{"name":"A","title":"Movie 1080p WEB-DL","url":"https://a.example/1"},"#
            + #"{"name":"B","title":"Movie 2160p DV Atmos BluRay","url":"https://a.example/2"},"#
            + #"{"name":"C","title":"Movie 2160p HDCAM DV","url":"https://a.example/3"},"#
            + #"{"name":"D","title":"Movie 2160p DV Atmos REMUX","externalUrl":"https://a.example/4"}]"#)
        let second = streams(#"[{"name":"E","title":"Movie 2160p DV Atmos BluRay","url":"https://b.example/1"}]"#)
        expect(first.count == 4, "streams decode")
        let best = QuickPlay.pickBest([first, second], selected: [])
        expect(best?.stream.name == "B" && best?.addon == 0, "best stream: highest quality, first addon on a tie, no cam, playable only")
        expect(QuickPlay.pickBest([first], selected: [.r1080])?.stream.name == "A", "best stream respects the filters")
        expect(QuickPlay.pickBest([[]], selected: []) == nil, "no streams, no pick")

        // Saved writes: the newest per title replaces older ones, and they survive a round trip.
        let ref = VideoRef(type: "series", metaId: "tt1", videoId: "tt1:1:2", name: "Show", poster: nil, episodeLabel: "S1E2")
        let older = PendingWrites.Op.stremioProgress(ref: ref, position: 100, duration: 1000, at: Date(timeIntervalSince1970: 1))
        let newer = PendingWrites.Op.stremioProgress(ref: ref, position: 300, duration: 1000, at: Date(timeIntervalSince1970: 2))
        expect(older.key == newer.key, "progress for one title shares a key")
        let history = PendingWrites.Op.traktHistory(metaId: "tt1", type: "series", videoIds: ["tt1:1:2"], add: true, at: Date())
        expect(history.key != older.key && !history.isStremio && older.isStremio, "Trakt and Stremio writes kept apart")
        let encoded = try? JSONEncoder().encode([newer, history])
        let decoded = encoded.flatMap { try? JSONDecoder().decode([PendingWrites.Op].self, from: $0) }
        expect(decoded == [newer, history], "saved writes round-trip")
        expect(PendingWrites.isTemporary(URLError(.notConnectedToInternet)), "offline is retried")
        expect(!PendingWrites.isTemporary(StremioAPI.Failure.sessionExpired), "an expired session isn't retried")

        // MDBList: known sources only, in order, empty scores dropped.
        let mdb = Data(#"{"ratings":[{"source":"imdb","value":8.1},{"source":"metacritic","value":74,"score":74},"#
            .appending(#"{"source":"tomatoes","value":93,"score":93},{"source":"letterboxd","value":4.1,"score":82},"#)
            .appending(#"{"source":"tomatoesaudience","value":null,"score":0}]}"#).utf8)
        let scores = MDBList.parse(mdb) ?? []
        expect(scores.map(\.source) == ["tomatoes", "metacritic", "letterboxd"], "MDBList sources and order")
        expect(scores.first.map(MDBList.text) == "93%" && MDBList.symbol(scores[0]) == "🍅", "Tomatometer reads 93% fresh")
        expect(scores.count > 2 && MDBList.text(scores[2]) == "4.1", "Letterboxd out of 5")

        // Trakt bodies.
        let episodeBody = TraktAccount.historyBody(metaId: "tt1", type: "series", videoIds: ["tt1:2:5", "tt1:1:1", "tt1:2:1"], at: nil)
        let shows = episodeBody?["shows"] as? [[String: Any]]
        let seasons = shows?.first?["seasons"] as? [[String: Any]]
        expect(seasons?.compactMap { $0["number"] as? Int } == [1, 2], "Trakt history groups episodes by season")
        expect((seasons?.last?["episodes"] as? [[String: Any]])?.compactMap { $0["number"] as? Int } == [1, 5], "episodes sorted")
        expect(TraktAccount.historyBody(metaId: "kitsu:1", type: "movie", videoIds: [], at: nil) == nil, "Trakt only for IMDb ids")
        expect(TraktAccount.item(ref).flatMap { $0["episode"] as? [String: Int] } == ["season": 1, "number": 2], "scrobble body for an episode")

        // PKCE: RFC 7636's own example.
        expect(PKCE.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
               "PKCE challenge")
        expect(PKCE.verifier().count >= 43 && !PKCE.verifier().contains("="), "PKCE verifier length and alphabet")

        // Anime ids map through TMDB; other ids don't.
        expect(KitsuMap.kitsuNumber("kitsu:1376:5") == "1376" && KitsuMap.kitsuNumber("tt1") == nil, "Kitsu number")
        expect(MetaResolver.mappable("kitsu:1376") && MetaResolver.mappable("tt1") && !MetaResolver.mappable("tmdb:1"), "mappable ids")

        // Spotlight identifiers round-trip, names with "|" too.
        let titled = MetaRef(id: "tt9", type: "movie", name: "A | B", poster: nil)
        let back = SpotlightIndex.ref(SpotlightIndex.identifier(titled))
        expect(back?.id == "tt9" && back?.type == "movie" && back?.name == "A | B", "Spotlight id round-trip")

        // Scrub picture spots: the whole timeline maps onto 0..<cells, the end onto the last one.
        let spots = ScrubStillSource.cells
        expect(ScrubStillSource.cell(0, duration: 100) == 0 && ScrubStillSource.cell(100, duration: 100) == spots - 1
               && ScrubStillSource.cell(-5, duration: 100) == 0 && ScrubStillSource.cell(50, duration: 0) == 0,
               "scrub spots stay in range")
        expect(ScrubStillSource.cell(ScrubStillSource.centre(of: 37, duration: 5400), duration: 5400) == 37,
               "a spot's centre falls in that spot")

        // Images older than a month are fetched again.
        func response(daysAgo: Double) -> URLResponse {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            let date = formatter.string(from: Date().addingTimeInterval(-daysAgo * 86400))
            return HTTPURLResponse(url: URL(string: "https://i.example/a.jpg")!, statusCode: 200, httpVersion: nil,
                                   headerFields: ["Date": date])!
        }
        expect(ImagePipeline.isStale(response(daysAgo: 40)) && !ImagePipeline.isStale(response(daysAgo: 2)), "image expiry by Date header")
    }
}
#endif
