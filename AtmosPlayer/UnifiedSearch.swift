import Foundation

// MARK: - Unified search
//
// Every title source answers the same query (TMDB, or IMDb's suggestions without a TMDB token,
// and Cinemeta's movie and series search); their answers become one list. A title is merged
// only on the same IMDb id: two films that just share a name stay two results.

enum UnifiedSearch {
    /// 0…1: how well a title's name matches what was typed (case and accents ignored).
    static func match(_ name: String, _ query: String) -> Double {
        let a = fold(name), q = fold(query)
        guard !q.isEmpty else { return 0 }
        if a == q { return 1 }
        if a.hasPrefix(q) { return 0.8 }
        let words = q.split(separator: " ")
        if words.allSatisfy({ a.contains($0) }) { return 0.6 }
        if a.contains(q) { return 0.4 }
        return 0.1
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// One list from every source's answer, best first. A title found by several sources ranks
    /// higher and keeps the artwork whichever had it; each source's own order counts a little.
    static func merge(_ query: String, _ pools: [[MetaPreview]]) -> [MetaPreview] {
        struct Hit { var item: MetaPreview; var sources: Int; var best: Int }
        var hits: [String: Hit] = [:]
        var order: [String] = []
        for pool in pools {
            for (index, item) in pool.enumerated() {
                if var hit = hits[item.id] {
                    hit.sources += 1
                    hit.best = min(hit.best, index)
                    if hit.item.poster == nil || hit.item.background == nil || hit.item.description == nil {
                        hit.item = MetaPreview(id: hit.item.id, type: hit.item.type, name: hit.item.name,
                                               poster: hit.item.poster ?? item.poster,
                                               background: hit.item.background ?? item.background,
                                               logo: hit.item.logo ?? item.logo,
                                               description: hit.item.description ?? item.description,
                                               releaseInfo: hit.item.releaseInfo ?? item.releaseInfo,
                                               imdbRating: hit.item.imdbRating ?? item.imdbRating,
                                               genres: hit.item.genres.isEmpty ? item.genres : hit.item.genres,
                                               runtime: hit.item.runtime ?? item.runtime,
                                               trailerId: hit.item.trailerId ?? item.trailerId)
                    }
                    hits[item.id] = hit
                } else {
                    hits[item.id] = Hit(item: item, sources: 1, best: index)
                    order.append(item.id)
                }
            }
        }
        func score(_ hit: Hit) -> Double {
            3 * match(hit.item.name, query) + 0.5 * Double(hit.sources - 1)
                + 0.6 * (1 - Double(min(hit.best, 20)) / 20) + (hit.item.poster == nil ? -1 : 0)
        }
        return order.compactMap { hits[$0] }
            .map { ($0, score($0)) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.best < $1.0.best }
            .map(\.0.item)
    }

    /// TMDB's search: titles (under IMDb ids) and people with photos.
    @MainActor
    static func tmdb(_ query: String) async -> (titles: [MetaPreview], people: [IMDbSuggest.Person]) {
        async let titles = TMDBCatalog.page("/search/multi", ["query": query, "include_adult": "false"], page: 1, kind: nil)
        async let people = tmdbPeople(query)
        return await (titles, people)
    }

    private struct PeoplePage: Decodable {
        struct Person: Decodable { let id: Int; let name: String?; let profile_path: String?; let known_for_department: String? }
        let results: [LossyElement<Person>]
    }

    private static func tmdbPeople(_ query: String) async -> [IMDbSuggest.Person] {
        guard let data = await TMDB.get("/search/person", [URLQueryItem(name: "query", value: query),
                                                           URLQueryItem(name: "include_adult", value: "false"),
                                                           URLQueryItem(name: "language", value: TMDB.language)]),
              let page = try? JSONDecoder().decode(PeoplePage.self, from: data) else { return [] }
        return page.results.compactMap(\.value).compactMap { person in
            guard let name = person.name else { return nil }
            return IMDbSuggest.Person(id: "tmdb-\(person.id)", name: name,
                                      photo: TMDB.Details.image(person.profile_path, size: "w185"),
                                      knownFor: person.known_for_department)
        }
    }
}
