import Foundation

private func check(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
    if !condition() { fatalError("FAILED (line \(line)): \(message)") }
}

private let fixture = """
{"schema_version":1,"configured":true,
 "roots":[{"id":"repo1","label":"Prometheus","kind":"repo"},{"id":"vault1","label":"Notes","kind":"vault"},{"id":"odd","label":"Odd","kind":"future"}],
 "projects":[
  {"id":"p-alpha","title":"Alpha","summary":"First project","bot_ids":["sample-reviewer","ghost"],
   "sources":[{"provider":"github","source":"org/alpha"}],
   "related_files":[{"root":"repo1","path":"docs/plan.md"},{"root":"vault1","path":"a/b.md"},
                    {"root":"repo1","path":"/etc/passwd"},{"root":"repo1","path":"../secret"},
                    {"root":"repo1","path":"file:///tmp/x"},{"root":"gone","path":"x.md"},{"root":"repo1","path":"a/../b"}]},
  {"id":"p-beta","title":"Beta","bot_ids":["sample-reviewer"],"sources":[],"related_files":[]},
  {"id":"p-none","title":"Gamma notes","bot_ids":[],"sources":[],"related_files":[]},
  {"id":"p-alpha","title":"Duplicate","bot_ids":[],"sources":[],"related_files":[]}
 ]}
"""

@MainActor
func run() async {
    // Decoding and normalisation
    let snap = try! ProjectsSnapshot.decode(Data(fixture.utf8))
    check(snap.configured, "configured")
    check(snap.projects.count == 3, "duplicate project ids dropped, got \(snap.projects.count)")
    check(snap.projects[0].summary == "First project" && snap.projects[1].summary == nil, "optional summary")
    check(snap.roots.map(\.kind) == [.repo, .vault, .other], "unknown kind tolerated")

    // Disabled bridge
    let off = try! ProjectsSnapshot.decode(Data(#"{"schema_version":1,"configured":false,"roots":[],"projects":[]}"#.utf8))
    check(!off.configured, "disabled")
    check(ProjectsLoadState(snapshot: off) == .notConfigured, "disabled -> notConfigured")
    check(ProjectsLoadState(snapshot: try! ProjectsSnapshot.decode(Data(#"{"schema_version":1,"configured":true,"roots":[],"projects":[]}"#.utf8))) == .empty, "empty")
    check(ProjectsLoadState(snapshot: snap) == .loaded(snap), "loaded")

    // Missing arrays tolerated, bad / mixed versions rejected
    let bare = try! ProjectsSnapshot.decode(Data(#"{"schema_version":1,"configured":true,"roots":[],"projects":[{"id":"x","title":"X"}]}"#.utf8))
    check(bare.projects[0].botIds.isEmpty && bare.projects[0].sources.isEmpty, "missing arrays default empty")
    do { _ = try ProjectsSnapshot.decode(Data(#"{"schema_version":2,"configured":true,"roots":[],"projects":[]}"#.utf8)); check(false, "v2 must throw") }
    catch { check((error as? ProjectsFailure) == .unsupportedVersion, "v2 -> unsupportedVersion") }
    do { _ = try ProjectsSnapshot.decode(Data("<html>".utf8)); check(false, "garbage must throw") }
    catch { check((error as? ProjectsFailure) == .malformed, "garbage -> malformed") }
    do { _ = try ProjectsSnapshot.decode(Data(#"{"configured":true,"roots":[],"projects":[]}"#.utf8)); check(false, "no version must throw") }
    catch { check((error as? ProjectsFailure) == .malformed, "no version -> malformed") }
    for malformed in [#"{"schema_version":1,"configured":true,"roots":[]}"#,
                      #"{"schema_version":1,"configured":true,"roots":[],"projects":[{"id":"x"}]}"#] {
        do { _ = try ProjectsSnapshot.decode(Data(malformed.utf8)); check(false, "incomplete envelope must throw") }
        catch { check((error as? ProjectsFailure) == .malformed, "bad V1 payload -> malformed") }
    }

    // Error classification
    check(ProjectsFailure.fromHTTP(404) == .bridgeTooOld, "404 old bridge")
    check(ProjectsFailure.fromHTTP(503) == .unavailable, "503")
    check(ProjectsFailure.fromHTTP(401) == .signedOut, "401")
    check(ProjectsFailure.fromHTTP(500) == .unavailable, "500")
    check(ProjectsFailure.classify(URLError(.notConnectedToInternet)) == .network, "offline")
    check(ProjectsFailure.classify(ProjectsFailure.signedOut) == .signedOut, "passthrough")
    check(ProjectsFailure.classify(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "/Users/x/secret"))) == .malformed, "decoding")
    for f in [ProjectsFailure.bridgeTooOld, .unavailable, .malformed, .network, .signedOut, .unsupportedVersion] {
        check(!f.message.contains("/") && !f.message.isEmpty, "message is plain: \(f.message)")
    }
    check(ProjectsFailure.bridgeTooOld.isUpgrade && ProjectsFailure.unsupportedVersion.isUpgrade && !ProjectsFailure.network.isUpgrade, "upgrade flag")

    // References: named root + safe relative path; unsafe ones are hidden and never echoed
    let refs = snap.references(for: snap.projects[0])
    check(refs.hidden == 5, "unsafe hidden: \(refs.hidden)")
    check(refs.shown.map(\.copyText) == ["repo1: docs/plan.md", "vault1: a/b.md"], "stable root ID in copy text")
    check(refs.shown[0].rootName == "Prometheus" && refs.shown[0].kind == .repo, "root name")
    check(SafeRelativePath.normalize("docs/a b/é.md") == "docs/a b/é.md", "keep a valid path as is")
    for invalid in ["./a//b.md", "a\\b", "", "~/x", "a%2eb", "a#b", "a?b", "a\u{202E}b", "a/"] {
        check(SafeRelativePath.normalize(invalid) == nil, "reject invalid reference")
    }

    // Bot associations
    let known = [Bot(id: "sample-reviewer", name: "Sample Reviewer", blurb: "", model: "m", provider: "p", reachable: true, front: false),
             Bot(id: "off", name: "Offline", blurb: "", model: "m", provider: "p", reachable: false, front: false)]
    let links = snap.botLinks(for: snap.projects[0], bots: known)
    check(links.count == 2 && links[0].displayName == "Sample Reviewer" && links[0].isLinkable, "known reachable bot linkable")
    check(links[1].displayName == "ghost" && !links[1].isLinkable, "unknown bot id still listed")
    let offline = ProjectsSnapshot.botLinks(ids: ["off"], bots: known)
    check(offline[0].displayName == "Offline" && !offline[0].isLinkable, "unreachable not linkable")
    check(snap.botLinks(for: snap.projects[2], bots: known).isEmpty, "no bot -> empty")
    check(snap.projects(forBot: "sample-reviewer").map(\.id) == ["p-alpha", "p-beta"], "same bot across projects")

    // Search
    check(snap.filtered("alpha").map(\.id) == ["p-alpha"], "title search")
    check(snap.filtered("  ").count == 3, "blank search")
    check(snap.filtered("first").map(\.id) == ["p-alpha"], "summary search")
    check(snap.filtered("org/alpha").map(\.id) == ["p-alpha"], "source search")
    check(snap.filtered("zzz").isEmpty, "no match")

    // Model: load states
    let m = ProjectsModel(fetch: { snap })
    check(m.state == .idle, "idle")
    await m.load()
    check(m.state == .loaded(snap), "loaded after load")

    let old = ProjectsModel(fetch: { throw ProjectsFailure.bridgeTooOld })
    await old.load()
    check(old.state == .failed(.bridgeTooOld), "404 panel state")

    let net = ProjectsModel(fetch: { throw URLError(.timedOut) })
    await net.load()
    check(net.state == .failed(.network), "network")

    let out = ProjectsModel(fetch: { throw ProjectsFailure.signedOut })
    await out.load()
    check(out.state == .failed(.signedOut), "no sign-in handled")

    // Retry after failure recovers
    var calls = 0
    let flaky = ProjectsModel(fetch: { calls += 1; if calls == 1 { throw ProjectsFailure.unavailable }; return snap })
    await flaky.load()
    check(flaky.state == .failed(.unavailable), "503 first")
    await flaky.load()
    check(flaky.state == .loaded(snap), "retry ok")

    // Overlap: a slow older load must not overwrite a newer one
    let slowSnap = off
    var n = 0
    let racer = ProjectsModel(fetch: {
        n += 1
        if n == 1 { try await Task.sleep(for: .milliseconds(200)); return slowSnap }
        return snap
    })
    let first = Task { await racer.load() }
    try? await Task.sleep(for: .milliseconds(30))
    await racer.load()
    await first.value
    check(racer.state == .loaded(snap), "stale response discarded: \(racer.state)")

    // Cancellation does not surface as an error and does not leave a spinner
    let slow = ProjectsModel(fetch: { try await Task.sleep(for: .seconds(5)); return snap })
    let t = Task { await slow.load() }
    try? await Task.sleep(for: .milliseconds(30))
    check(slow.state == .loading, "loading")
    t.cancel()
    await t.value
    check(slow.state == .idle, "cancelled load returns to idle: \(slow.state)")

    // Cancelled refresh keeps what was already shown
    var k = 0
    let keep = ProjectsModel(fetch: { k += 1; if k == 1 { return snap }; try await Task.sleep(for: .seconds(5)); return snap })
    await keep.load()
    let r = Task { await keep.load() }
    try? await Task.sleep(for: .milliseconds(30))
    r.cancel(); await r.value
    check(keep.state == .loaded(snap), "refresh cancel keeps data")

    // reset clears everything
    keep.reset()
    check(keep.state == .idle && keep.query.isEmpty, "reset")

    print("Projects decoding, failures, references, bot links, search and load-state tests passed")
}

@main
enum ProjectsTests {
    static func main() async { await run() }
}
