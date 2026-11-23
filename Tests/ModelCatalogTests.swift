import Foundation

private func check(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
    if !condition() { fatalError("FAILED (line \(line)): \(message)") }
}

private struct Boom: Error {}

/// Fake clock, fake gateway. Everything is synthetic; no network.
private final class Fake: @unchecked Sendable {
    let lock = NSLock()
    var time = Date(timeIntervalSince1970: 1_000_000)
    var account: String? = "acct-A"
    var models: [String: [String]] = ["openai-codex": ["model-one"], "openai-api": ["api-one"]]
    var fail = false
    var gate: CheckedContinuation<Void, Never>?
    var holdNext = false
    var calls: [(CatalogScope, CatalogFetch)] = []
    var count: Int { lock.withLock { calls.count } }

    func json() -> Data {
        let rows = models.sorted { $0.key < $1.key }.map { #"{"slug":"\#($0.key)","name":"\#($0.key)","models":[\#($0.value.map { "\"\($0)\"" }.joined(separator: ","))],"authenticated":true}"# }
        return Data(#"{"providers":[\#(rows.joined(separator: ","))]}"#.utf8)
    }
    func fetch(_ s: CatalogScope, _ f: CatalogFetch) async throws -> ModelCatalog {
        lock.withLock { calls.append((s, f)) }
        let snapshot = json()
        if lock.withLock({ let h = holdNext; holdNext = false; return h }) {
            await withCheckedContinuation { c in lock.withLock { gate = c } }
        }
        await Task.yield()
        if fail { throw Boom() }
        return try JSONDecoder().decode(ModelCatalog.self, from: snapshot)
    }
    func release() { lock.withLock { let g = gate; gate = nil; return g }?.resume() }
}

@MainActor
func run() async {
    let fake = Fake()
    let store = ModelCatalogStore(now: { fake.time }, currentAccount: { fake.account }) { try await fake.fetch($0, $1) }
    let scope = CatalogScope(account: "acct-A", profile: "default")

    // initial load + cached within TTL
    let first = await store.load(scope)
    check(first?.provider(slug: "openai-codex")?.models == ["model-one"], "initial load")
    check(fake.count == 1, "one fetch")
    fake.time += 200
    _ = await store.load(scope)
    check(fake.count == 1, "fresh entry served from memory")

    // coalescing
    store.reset()
    let before = fake.count
    async let a = store.load(scope), b = store.load(scope), c = store.load(scope)
    _ = await (a, b, c)
    check(fake.count == before + 1, "concurrent loads share one request, got \(fake.count - before)")

    // a release appears after TTL without code changes
    fake.models["openai-codex"] = ["model-one", "synthetic-next-model"]
    fake.time += 301
    check(store.state(scope).isStale(now: fake.time), "stale after TTL")
    let updated = await store.load(scope)
    check(updated?.provider(slug: "openai-codex")?.models.contains("synthetic-next-model") == true, "new model appears after TTL")
    check(!store.state(scope).isStale(now: fake.time), "fresh again")

    // forced refresh uses ?refresh=1 kind, cadence bounded
    var n = fake.count
    _ = await store.refresh(scope)
    check(fake.count == n + 1 && fake.calls.last?.1 == .refresh, "refresh fetches live")
    check(store.state(scope).lastRefreshAt == fake.time, "lastRefreshAt set")
    n = fake.count
    fake.time += 30
    _ = await store.refresh(scope); _ = await store.refresh(scope)
    check(fake.count == n, "refresh inside min interval does not refetch")
    fake.time += 31
    _ = await store.refresh(scope)
    check(fake.count == n + 1, "refresh allowed after min interval")

    // failure keeps last-good, marks stale + error, no raw text
    fake.fail = true
    fake.time += 61
    _ = await store.refresh(scope)
    let bad = store.state(scope)
    check(bad.catalog?.provider(slug: "openai-codex")?.models.contains("synthetic-next-model") == true, "last-good survives failure")
    check(bad.lastError == ModelCatalogStore.failureText && bad.isStale(now: fake.time), "stale + fixed error")
    check(bad.caption(now: fake.time).hasPrefix("Couldn’t refresh — showing the list from"), "stale caption: \(bad.caption(now: fake.time))")
    // failed attempts are cadence-bounded too
    n = fake.count
    _ = await store.refresh(scope)
    check(fake.count == n, "no retry storm after failure")
    fake.fail = false
    fake.time += 61
    _ = await store.refresh(scope)
    check(store.state(scope).lastError == nil && store.state(scope).caption(now: fake.time) == "Checked just now", "recovers")

    // failure with no last-good
    let empty = CatalogScope(account: "acct-A", profile: "empty")
    fake.fail = true
    let none = await store.load(empty)
    check(none == nil && store.state(empty).catalog == nil && store.state(empty).lastError != nil, "error state without catalog")
    fake.fail = false

    // openCheck: plain read first, then one live refresh; second open inside TTL does nothing
    store.reset()
    n = fake.count
    await store.openCheck(scope)
    check(fake.calls[n].1 == .cached && fake.calls[n + 1].1 == .refresh && fake.count == n + 2, "open: cached then refresh")
    await store.openCheck(scope)
    check(fake.count == n + 2, "open again within TTL is free")

    // reset during in-flight discards the late response
    store.reset()
    fake.holdNext = true
    fake.models["openai-codex"] = ["late-model"]
    let late = Task { @MainActor in await store.load(scope) }
    while fake.lock.withLock({ fake.gate }) == nil { await Task.yield() }
    store.reset()
    fake.account = "acct-B"
    fake.release()
    _ = await late.value
    check(store.state(scope).catalog == nil, "late response after reset not published")
    check(store.entries.isEmpty, "no entries after reset")
    // account changed without reset still blocked at publish
    fake.account = "acct-A"
    fake.holdNext = true
    let late2 = Task { @MainActor in await store.load(scope) }
    while fake.lock.withLock({ fake.gate }) == nil { await Task.yield() }
    fake.account = "acct-B"
    fake.release()
    _ = await late2.value
    check(store.state(scope).catalog == nil, "publish checks current account")
    fake.account = "acct-A"

    // isolation between accounts/profiles
    fake.models["openai-codex"] = ["only-a"]
    _ = await store.load(scope)
    fake.models["openai-codex"] = ["only-b"]
    let other = CatalogScope(account: "acct-A", profile: "work")
    let otherAcct = CatalogScope(account: "acct-B", profile: "default")
    _ = await store.load(other)
    check(store.state(scope).catalog?.provider(slug: "openai-codex")?.models == ["only-a"], "profile A untouched")
    check(store.state(other).catalog?.provider(slug: "openai-codex")?.models == ["only-b"], "profile isolated")
    check(store.state(otherAcct).catalog == nil, "other account has nothing")

    // old/minimal payload
    let old = try! JSONDecoder().decode(ModelCatalog.self, from: Data(#"{"providers":[{"slug":"x","models":["m"]}]}"#.utf8))
    let px = old.provider(slug: "x")
    check(px?.models == ["m"] && px?.authenticated == false && px?.isCurrent == false && px?.name == "x" && px?.supportsReasoning("m") == true, "minimal payload")
    check(old.model == nil && old.provider == nil && old.usable.isEmpty, "minimal top-level")

    // exact slug
    let both = try! JSONDecoder().decode(ModelCatalog.self, from: fake.json())
    check(both.provider(slug: "openai-codex")?.models.first == "only-b" && both.provider(slug: "openai-api")?.models == ["api-one"], "exact slug")
    check(both.provider(slug: "openai") == nil && both.provider(slug: "OPENAI-CODEX") == nil, "no fuzzy match")

    // path builder
    check(CatalogFetch.cached.path(escapedProfile: "default") == "/m/p/default/api/model/options", "cached path")
    check(CatalogFetch.refresh.path(escapedProfile: "default") == "/m/p/default/api/model/options?refresh=1", "refresh path")
    let url = URL(string: CatalogFetch.refresh.path(escapedProfile: "default"), relativeTo: URL(string: "https://host.example:9131")!)!
    check(url.absoluteString == "https://host.example:9131/m/p/default/api/model/options?refresh=1", "query kept: \(url.absoluteString)")

    print("ModelCatalogTests: all checks passed")
}

@main struct Main { static func main() async { await run() } }
