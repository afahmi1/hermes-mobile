import Foundation

/// Recently used models for one bot, newest first, kept on the phone. Feeds the composer model menu.
enum RecentModels {
    static let limit = 6

    private static func key(_ profile: String) -> String { "hm.recentModels.\(profile)" }

    static func load(profile: String, defaults: UserDefaults = .standard) -> [RuntimeChoice] {
        guard let data = defaults.data(forKey: key(profile)) else { return [] }
        return (try? JSONDecoder().decode([RuntimeChoice].self, from: data)) ?? []
    }

    /// Records a picked model. Bot default and effort-only choices have no model, so they are skipped.
    static func record(_ choice: RuntimeChoice, profile: String, defaults: UserDefaults = .standard) {
        guard choice.model != nil else { return }
        let list = merged([choice], load(profile: profile, defaults: defaults))
        defaults.set(try? JSONEncoder().encode(list), forKey: key(profile))
    }

    /// `first` then `rest`, deduped by provider + model (first wins), capped at `limit`.
    static func merged(_ first: [RuntimeChoice], _ rest: [RuntimeChoice]) -> [RuntimeChoice] {
        var seen = Set<String>()
        var out: [RuntimeChoice] = []
        for c in first + rest {
            guard let model = c.model, seen.insert("\(c.provider ?? "")|\(model)").inserted else { continue }
            out.append(c)
            if out.count == limit { break }
        }
        return out
    }
}

// MARK: - Slash commands (pure, no UI)

/// A `/model` or `/effort` line typed in the composer. These never go to the agent.
enum ModelCommand: Equatable {
    case picker
    case reset
    case model(query: String, provider: String?)
    case effort(String)
    case badEffort(String)

    static func parse(_ text: String, levels: [String] = Effort.allCases.map(\.rawValue)) -> ModelCommand? {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let head = words.first?.lowercased() else { return nil }
        let args = Array(words.dropFirst())
        switch head {
        case "/model":
            if args.isEmpty { return .picker }
            if args.count == 1, ["reset", "default"].contains(args[0].lowercased()) { return .reset }
            var provider: String?
            var name: [String] = []
            var i = 0
            while i < args.count {
                if args[i] == "--provider" {
                    guard i + 1 < args.count else { return .picker }
                    provider = args[i + 1]
                    i += 2
                } else {
                    name.append(args[i])
                    i += 1
                }
            }
            return name.isEmpty ? .picker : .model(query: name.joined(separator: " "), provider: provider)
        case "/effort":
            let level = args.first?.lowercased() ?? ""
            return args.count == 1 && levels.contains(level) ? .effort(level) : .badEffort(args.joined(separator: " "))
        default:
            return nil
        }
    }

    enum Resolution: Equatable {
        case found(provider: String, model: String)
        case ambiguous([String])
        case unknown
    }

    /// Matches `query` against `catalog` (provider slug to model ids). Exact match first, then a
    /// unique case-insensitive suffix match, then a unique contains match. `.` and `-` count the same.
    /// `provider:model` in the query picks the provider when that slug exists.
    static func resolve(_ query: String, provider: String? = nil, catalog: [String: [String]]) -> Resolution {
        var provider = provider
        var q = query
        if provider == nil, let colon = query.firstIndex(of: ":") {
            let slug = String(query[..<colon])
            let rest = String(query[query.index(after: colon)...])
            let exactWhole = catalog.values.contains { $0.contains(query) }
            if !exactWhole, !rest.isEmpty, catalog.keys.contains(where: { $0.lowercased() == slug.lowercased() }) {
                provider = slug
                q = rest
            }
        }
        let pool = catalog.filter { provider == nil || $0.key.lowercased() == provider!.lowercased() }
        let all = pool.flatMap { slug, models in models.map { (slug: slug, model: $0) } }
            .sorted { ($0.slug, $0.model) < ($1.slug, $1.model) }
        func norm(_ s: String) -> String { s.lowercased().replacingOccurrences(of: ".", with: "-") }
        let n = norm(q)
        let tiers: [(String, String) -> Bool] = [
            { a, _ in a == q },
            { a, b in b == n || a.lowercased() == q.lowercased() },
            { _, b in b.hasSuffix(n) },
            { _, b in b.contains(n) },
        ]
        for tier in tiers {
            let hits = all.filter { tier($0.model, norm($0.model)) }
            if hits.count == 1 { return .found(provider: hits[0].slug, model: hits[0].model) }
            if hits.count > 1 { return .ambiguous(hits.map { "\($0.slug):\($0.model)" }) }
        }
        return .unknown
    }
}
