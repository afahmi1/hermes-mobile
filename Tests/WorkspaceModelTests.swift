import Foundation

private func check(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
    if !condition() { fatalError("FAILED (line \(line)): \(message)") }
}

private func bot(_ id: String, reachable: Bool = true) -> Bot {
    Bot(id: id, name: id.capitalized, blurb: "", model: "m", provider: "p", reachable: reachable, front: false)
}
private let aid = "art_" + String(repeating: "a1", count: 16)

private func client(detail: WorkspaceDetail = WorkspaceDetail(instructions: "be brief", profiles: ["alpha", "beta", "off"]),
                    log: Log = Log()) -> WorkspaceClient {
    WorkspaceClient(
        detail: { detail },
        saveInstructions: { log.saved.append($0) },
        addFile: { n, d in log.files.append(n); return WorkspaceFile(id: "f\(log.files.count)", name: n, size: d.count) },
        deleteFile: { log.deleted.append($0) },
        createChat: { p, t in
            log.chatProfiles.append(p)
            return WorkspaceChat(profile: p, sessionId: "s1", title: t)
        })
}
private final class Log: @unchecked Sendable {
    var saved: [String] = [], files: [String] = [], deleted: [String] = [], chatProfiles: [String] = []
}

@MainActor
func run() async {
    // Index decode: only enabled IDs
    let idx = try! WorkspaceIndex.decode(Data(#"{"projects":["p1"],"profiles":["alpha"]}"#.utf8))
    check(idx.isEnabled(project: "p1") && !idx.isEnabled(project: "p2"), "index")
    check((try? WorkspaceIndex.decode(Data("[]".utf8))) == nil, "bad index rejected")

    // Detail decode + artifact ID validation / dedupe
    let json = """
    {"instructions":"hi","files":[{"id":"f1","name":"a.md","size":3}],
     "chats":[{"profile":"alpha","session_id":"s9","title":"T"}],
     "artifacts":[{"id":"\(aid)","name":"x.txt","size":4,"project_id":"p1","profile":"alpha","session_id":"s9","mime":"text/plain"},
                  {"id":"\(aid)","name":"dup","size":1},{"id":"art_../etc","name":"bad","size":1},{"id":"ART_\(aid.dropFirst(4))","name":"up","size":1}],
     "profiles":["alpha"]}
    """
    let d = try! WorkspaceDetail.decode(Data(json.utf8))
    check(d.artifacts.count == 1 && d.artifacts[0].mime == "text/plain", "artifact ids validated: \(d.artifacts.count)")
    check(d.chats[0].sessionId == "s9" && d.files[0].size == 3, "detail fields")
    check(WorkspaceArtifact.isValidID(aid) && !WorkspaceArtifact.isValidID(aid + "0") && !WorkspaceArtifact.isValidID("art_" + String(repeating: "g", count: 32)), "id regex")

    // Instruction byte limit counts UTF-8 bytes, not characters
    let m = WorkspaceProjectModel(client: client())
    await m.load()
    check(m.phase == .loaded && m.instructionsDraft == "be brief", "loaded")
    check(!m.canSaveInstructions, "unchanged not savable")
    m.instructionsDraft = String(repeating: "é", count: 2049)  // 4098 bytes, 2049 chars
    check(m.instructionsOverLimit && !m.canSaveInstructions, "bytes over limit")
    m.instructionsDraft = String(repeating: "é", count: 2048)
    check(m.canSaveInstructions, "exactly 4096 bytes ok")

    // File validation
    func bad(_ n: String, _ d: Data, count: Int = 0) -> WorkspaceValidation.Problem? {
        do { try WorkspaceValidation.checkFile(name: n, data: d, existingCount: count); return nil }
        catch { return error as? WorkspaceValidation.Problem }
    }
    check(bad("a.txt", Data("x".utf8)) == nil && bad("A.MD", Data("x".utf8)) == nil && bad("b.csv", Data("x".utf8)) == nil && bad("c.json", Data("{}".utf8)) == nil, "supported")
    check(bad("a.pdf", Data("x".utf8)) == .unsupportedType, "type")
    check(bad("a.txt", Data(count: 8193)) == .fileTooLarge && bad("a.txt", Data(repeating: 65, count: 8192)) == nil, "size boundary")
    check(bad("a.txt", Data([0xff, 0xfe, 0x41])) == .notUTF8, "utf8")
    check(bad("a.txt", Data("x".utf8), count: 4) == .tooManyFiles, "count")
    check(bad("../a.txt", Data("x".utf8)) == .badName && bad("a/b.txt", Data("x".utf8)) == .badName && bad(".txt", Data("x".utf8)) == .badName, "names")
    check(bad("a.txt", Data()) == .empty, "empty")
    let body = WorkspaceValidation.fileBody(name: "a.txt", data: Data([0xfb, 0xff]))
    check(body["data"] as? String == "+/8=" && body["name"] as? String == "a.txt", "standard base64 (not url-safe)")

    // Bounded read never loads more than limit+1
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ws-\(UUID().uuidString).txt")
    try! Data(repeating: 65, count: 1_000_000).write(to: tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }
    do { _ = try WorkspaceValidation.boundedRead(tmp); check(false, "oversize read should throw") }
    catch { check(error as? WorkspaceValidation.Problem == .fileTooLarge, "bounded read throws") }
    try! Data("ok".utf8).write(to: tmp)
    check(try! WorkspaceValidation.boundedRead(tmp) == Data("ok".utf8), "small read")

    // Save / add / delete go through client; invalid ones never reach it
    let log = Log()
    let m2 = WorkspaceProjectModel(client: client(log: log))
    await m2.load()
    m2.instructionsDraft = "new"
    await m2.saveInstructions()
    check(log.saved == ["new"] && !m2.canSaveInstructions, "saved")
    m2.instructionsDraft = String(repeating: "a", count: 4097)
    await m2.saveInstructions()
    check(log.saved == ["new"], "oversize not sent")
    await m2.addFile(name: "x.exe", data: Data("x".utf8))
    check(log.files.isEmpty, "bad type not sent")
    for i in 0..<5 { await m2.addFile(name: "f\(i).txt", data: Data("x".utf8)) }
    check(log.files.count == 4 && m2.detail.files.count == 4 && !m2.canAddFile, "max 4 files")
    await m2.deleteFile(m2.detail.files[0])
    check(log.deleted.count == 1 && m2.detail.files.count == 3, "delete")

    // Bots: explicit, exact ID, reachable, in detail.profiles; never auto-selected
    let bots = [bot("alpha"), bot("beta", reachable: false), bot("Alpha"), bot("gamma"), bot("off")]
    let sel = m.selectableBots(bots).map(\.id)
    check(sel == ["alpha", "off"], "selectable exact IDs: \(sel)")
    check(m.selectedBot == nil, "no auto selection")
    let rno_bot__no_chat = await m.startChat(bots: bots)
    check(rno_bot__no_chat == nil && log.chatProfiles.isEmpty, "no bot, no chat")
    m2.selectedBot = "gamma"   // not in profiles
    let runlisted_bot_refused = await m2.startChat(bots: bots)
    check(runlisted_bot_refused == nil && log.chatProfiles.isEmpty, "unlisted bot refused")
    m2.selectedBot = "beta"    // listed but unreachable
    let runreachable_bot_refused = await m2.startChat(bots: bots)
    check(runreachable_bot_refused == nil && log.chatProfiles.isEmpty, "unreachable bot refused")
    m2.selectedBot = "alpha"
    let chat = await m2.startChat(bots: bots, title: "  Plan  ")
    check(chat?.sessionId == "s1" && chat?.title == "Plan" && log.chatProfiles == ["alpha"], "chat started with explicit bot")
    check(m2.detail.chats.first?.id == "alpha/s1", "chat listed")

    // Failure keeps working; stale load discarded
    let failing = WorkspaceProjectModel(client: WorkspaceClient(detail: { throw WorkspacesFailure.disabled }, saveInstructions: { _ in }, addFile: { _, _ in throw WorkspacesFailure.rejected }, deleteFile: { _ in }, createChat: { _, _ in throw WorkspacesFailure.unavailable }))
    await failing.load()
    check(failing.phase == .failed(.disabled), "404 -> disabled")
    check(WorkspacesFailure.fromHTTP(404) == .disabled && WorkspacesFailure.fromHTTP(413) == .rejected && WorkspacesFailure.fromHTTP(500) == .unavailable && WorkspacesFailure.fromHTTP(401) == .signedOut, "http map")
    let index = WorkspaceIndexModel(fetch: { throw WorkspacesFailure.disabled })
    await index.load()
    check(!index.isEnabled("p1") && index.failure == .disabled, "index failure leaves nothing enabled")

    // Per-send project context
    check(ProjectContext.chosen(scope: "p1", optedIn: false) == nil, "default off")
    check(ProjectContext.chosen(scope: "p1", optedIn: true) == "p1", "opt in")
    check(ProjectContext.chosen(scope: nil, optedIn: true) == nil, "no scope, no context even if flag set")
    var b: [String: Any] = ["text": "hi"]
    ProjectContext.apply(to: &b, projectID: nil)
    check(b["project_context"] == nil, "regular chat unchanged")
    ProjectContext.apply(to: &b, projectID: "p1")
    check(b["project_context"] as? String == "p1", "context added")
    var b2: [String: Any] = [:]
    ProjectContext.apply(to: &b2, projectID: "bad\nid")
    check(b2.isEmpty, "control chars rejected")
    check(ProjectContext.summary(from: ["project_context": ["instructions": true, "files": 2]]) == "Project context accepted: instructions + 2 files", "summary")
    check(ProjectContext.summary(from: [:]) == nil, "no summary when absent")
    check(ProjectContext.disclosure.contains("this bot with this message") && ProjectContext.disclosure.contains("history"), "disclosure")

    // Artifact preview and filename
    check(ArtifactPreview.make(data: Data("<b>x</b>".utf8), mime: "text/plain; charset=utf-8") == .text("<b>x</b>"), "literal text")
    check(ArtifactPreview.make(data: Data("<b>".utf8), mime: "text/html") == .exportOnly, "html not previewed")
    check(ArtifactPreview.make(data: Data("x".utf8), mime: "application/pdf") == .exportOnly, "pdf export only")
    check(ArtifactPreview.make(data: Data(count: 70_000), mime: "text/plain") == .exportOnly, "large text export only")
    check(ArtifactPreview.make(data: Data([0xff]), mime: "text/plain") == .exportOnly, "bad utf8 export only")
    check(ArtifactPreview.filename(disposition: #"attachment; filename="../../etc/pass wd.txt""#, fallback: "f") == "pass wd.txt", "path stripped")
    check(ArtifactPreview.filename(disposition: "attachment; filename*=UTF-8''r%C3%A9sum%C3%A9.md", fallback: "f") == "résumé.md", "rfc5987")
    check(ArtifactPreview.filename(disposition: nil, fallback: "../x.txt") == "x.txt", "fallback sanitised")
    check(ArtifactPreview.filename(disposition: "attachment; filename=\"..\"", fallback: "") == "artifact", "dots")

    print("Workspace validation, bots, per-send context, artifacts and model tests passed")
}

@main
enum WorkspaceModelTests {
    static func main() async { await run() }
}
