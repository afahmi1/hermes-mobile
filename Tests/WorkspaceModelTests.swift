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
        saveInstructions: { t, r in log.saved.append(t); log.revisions.append(r); return "rev-\(log.saved.count)" },
        addFile: { n, d in log.files.append(n); return WorkspaceFile(id: "f\(log.files.count)", name: n, size: d.count) },
        deleteFile: { log.deleted.append($0) },
        createChat: { p, t in
            log.chatProfiles.append(p)
            return WorkspaceChat(profile: p, sessionId: "s1", title: t)
        })
}
private final class Log: @unchecked Sendable {
    var revisions: [String?] = [], saved: [String] = [], files: [String] = [], deleted: [String] = [], chatProfiles: [String] = []
}

private func dataOf(_ s: String) -> Data { Data(s.utf8) }

private final class Calls: @unchecked Sendable {
    var assignSaves: [([String], Int)] = [], fileSaves: [(String, String, String)] = [], created: [(String, Data)] = []
    var instrRevs: [String?] = [], fileGets = 0
}

private func assignDetail(mode: String = "owner", editable: Bool = true, rev: Int = 3, assigned: [String] = ["alpha"],
                          inactive: [String] = [], eligible: [String] = ["alpha", "beta"], hidden: Int = 0) -> WorkspaceDetail {
    WorkspaceDetail(instructions: "x", mode: mode, instructionsRevision: "r1",
                    assignment: WorkspaceAssignment(editable: editable, revision: rev, assigned: assigned, inactive: inactive, eligible: eligible),
                    hiddenChats: hidden)
}

@MainActor
func buildFiveTests() async {
    // build-4 payloads still decode (no mode / revision / sha / assignment)
    let old = try! WorkspaceDetail.decode(dataOf(#"{"instructions":"hi","files":[{"id":"f1","name":"a.md","size":3}],"chats":[],"artifacts":[],"profiles":["alpha"]}"#))
    check(old.mode == nil && old.assignment == nil && old.instructionsRevision == nil && old.hiddenChats == 0, "build-4 detail defaults")
    check(old.files[0].sha == nil && old.files[0].editable == nil && old.profiles == ["alpha"], "build-4 file defaults")
    let oldIdx = try! WorkspaceIndex.decode(dataOf(#"{"projects":["p1"],"profiles":["alpha"]}"#))
    check(oldIdx.mode == nil && oldIdx.workspaces.isEmpty && oldIdx.isEnabled(project: "p1") && !oldIdx.isOwnerManaged, "build-4 index")

    // build-5 payloads
    let new5 = try! WorkspaceDetail.decode(dataOf(#"""
    {"instructions":"hi","instructions_revision":"abc","mode":"owner","hidden_chats":2,"profiles":["alpha"],
     "files":[{"id":"f1","name":"README.md","size":3,"sha":"s1","editable":true}],
     "assignment":{"editable":true,"revision":7,"assigned":["alpha"],"inactive":["gone"],"eligible":["alpha","beta"]}}
    """#))
    check(new5.mode == "owner" && new5.instructionsRevision == "abc" && new5.hiddenChats == 2, "build-5 detail fields")
    check(new5.files[0].sha == "s1" && new5.files[0].editable == true, "file sha/editable")
    check(new5.assignment == WorkspaceAssignment(editable: true, revision: 7, assigned: ["alpha"], inactive: ["gone"], eligible: ["alpha", "beta"]), "assignment")
    let junk = try! WorkspaceDetail.decode(dataOf(#"{"mode":5,"assignment":"x","hidden_chats":"n","instructions_revision":3}"#))
    check(junk.mode == nil && junk.assignment == nil && junk.hiddenChats == 0 && junk.instructionsRevision == nil, "lenient junk")
    let idx5 = try! WorkspaceIndex.decode(dataOf(#"{"projects":["p1","zero"],"profiles":[],"mode":"owner","workspaces":[{"id":"zero","assigned":[],"eligible":["alpha"]},{"id":"p1","assigned":["alpha"],"eligible":["alpha"]}]}"#))
    check(idx5.isOwnerManaged && idx5.workspaces.count == 2 && idx5.workspaces[0].assigned.isEmpty, "build-5 index")
    check(idx5.isEnabled(project: "zero"), "Workspace visible for a zero-bot project")
    let idxBad = try! WorkspaceIndex.decode(dataOf(#"{"projects":["p1"],"profiles":["a"],"workspaces":"nope"}"#))
    check(idxBad.workspaces.isEmpty && idxBad.isEnabled(project: "p1"), "bad workspaces list ignored")
    let env = try! WorkspaceAssignment.decodeEnvelope(dataOf(#"{"assignment":{"editable":true,"revision":4,"assigned":["a"],"inactive":[],"eligible":["a"]}}"#))
    check(env.revision == 4, "assignment envelope")

    // failure mapping
    check(WorkspacesFailure.fromResponse(status: 409, code: "stale") == .conflict && WorkspacesFailure.fromHTTP(409) == .conflict, "409 stale")
    check(WorkspacesFailure.fromResponse(status: 409, code: "duplicate") == .duplicate, "409 duplicate")
    check(WorkspacesFailure.fromResponse(status: 403, code: "not_eligible") == .notEligible, "403 not_eligible")
    check(WorkspacesFailure.fromResponse(status: 403, code: "owner_required") == .ownerRequired, "403 owner_required")
    check(WorkspacesFailure.fromResponse(status: 403, code: "operator_managed") == .operatorManaged, "403 operator_managed")
    check(WorkspacesFailure.fromResponse(status: 403, code: "other") == .unavailable, "unknown 403")
    check(WorkspacesFailure.operatorManaged.message == "Bot access for this project is set on the Mac.", "operator text")

    // assignment model
    let c = Calls()
    func aclient(_ d: WorkspaceDetail, save: @escaping ([String], Int) async throws -> WorkspaceAssignment) -> WorkspaceClient {
        WorkspaceClient(detail: { d }, saveInstructions: { _, _ in nil }, addFile: { n, d in WorkspaceFile(id: "x", name: n, size: d.count) },
                        deleteFile: { _ in }, createChat: { p, t in WorkspaceChat(profile: p, sessionId: "s", title: t) },
                        saveAssignment: { ids, rev in c.assignSaves.append((ids, rev)); return try await save(ids, rev) })
    }
    let am = WorkspaceAssignmentModel(client: aclient(assignDetail(inactive: ["old"], hidden: 1)) { ids, rev in
        WorkspaceAssignment(editable: true, revision: rev + 1, assigned: ids.filter { $0 != "old" }, inactive: ["old"], eligible: ["alpha", "beta"]) })
    check(am.summary(name: { $0 }) == "Loading…", "summary before load")
    await am.load()
    check(am.phase == .loaded && am.isEditable && am.selection == ["alpha"] && !am.canSave, "assignment loaded, save disabled when unchanged")
    check(am.hiddenChatsNote == "1 chat from unassigned bots is kept and come back if you reassign the bot." || am.hiddenChatsNote?.hasPrefix("1 chat from unassigned bots are kept") == true, "hidden note: \(am.hiddenChatsNote ?? "nil")")
    am.toggle("beta")
    check(am.canSave, "changed -> savable")
    am.toggle("beta")
    check(!am.canSave, "back to original -> disabled")
    am.toggle("beta")
    await am.save()
    check(c.assignSaves.count == 1 && c.assignSaves[0].0 == ["alpha", "beta", "old"] && c.assignSaves[0].1 == 3, "sent ids + revision, inactive kept: \(c.assignSaves)")
    check(am.assignment?.revision == 4 && am.selection == ["alpha", "beta"] && !am.canSave && am.message == "Saved.", "save success")
    am.toggle("alpha"); am.discard()
    check(am.selection == ["alpha", "beta"] && !am.canSave, "cancel discards")
    check(am.summary(name: { $0.uppercased() }) == "ALPHA, BETA", "summary names")

    let stale = WorkspaceAssignmentModel(client: aclient(assignDetail()) { _, _ in throw WorkspacesFailure.conflict })
    await stale.load(); stale.toggle("beta"); await stale.save()
    check(stale.selection == ["alpha"] && stale.message?.contains("Reloaded the latest") == true && stale.phase == .loaded, "409 reloads + message")
    let ne = WorkspaceAssignmentModel(client: aclient(assignDetail()) { _, _ in throw WorkspacesFailure.notEligible })
    await ne.load(); ne.toggle("beta"); await ne.save()
    check(ne.message == WorkspacesFailure.notEligible.message && ne.selection == ["alpha", "beta"], "not_eligible fixed text, selection kept")
    for (f, _) in [(WorkspacesFailure.ownerRequired, 0), (.operatorManaged, 0)] {
        let m = WorkspaceAssignmentModel(client: aclient(assignDetail()) { _, _ in throw f })
        await m.load(); m.toggle("beta"); await m.save()
        check(m.message == f.message, "403 text \(f)")
    }
    let ro = WorkspaceAssignmentModel(client: aclient(assignDetail(mode: "operator", editable: false)) { _, _ in fatalError("never") })
    await ro.load(); ro.toggle("beta")
    check(!ro.isEditable && ro.selection == ["alpha"] && !ro.canSave, "operator read-only")
    let b4 = WorkspaceAssignmentModel(client: aclient(WorkspaceDetail(profiles: ["alpha"])) { _, _ in fatalError("never") })
    await b4.load()
    check(!b4.isEditable && b4.summary(name: { $0 }) == "alpha" && b4.eligible.isEmpty, "build-4 payload: read-only, empty")
    let empty = WorkspaceAssignmentModel(client: aclient(assignDetail(assigned: [], eligible: [])) { _, _ in fatalError("never") })
    await empty.load()
    check(empty.eligible.isEmpty && empty.summary(name: { $0 }) == "No bots assigned" && !empty.canSave, "empty eligible")

    // instructions revision + conflict keeps draft
    let log = Log()
    var failNext = true
    let ic = WorkspaceClient(detail: { assignDetail() }, saveInstructions: { t, r in
        log.revisions.append(r)
        if failNext { failNext = false; throw WorkspacesFailure.conflict }
        return "r2"
    }, addFile: { n, d in WorkspaceFile(id: "x", name: n, size: d.count) }, deleteFile: { _ in }, createChat: { p, t in WorkspaceChat(profile: p, sessionId: "s", title: t) })
    let pm = WorkspaceProjectModel(client: ic)
    await pm.load()
    pm.beginEditInstructions(); pm.instructionsDraft = "mine"
    await pm.saveInstructions()
    check(log.revisions == ["r1"] && pm.instructionsConflict && pm.instructionsDraft == "mine" && pm.instructionsEditing, "revision sent; 409 keeps draft")
    await pm.reloadLatestInstructions()
    check(pm.instructionsDraft == "x" && !pm.instructionsConflict, "reload latest is explicit")
    pm.instructionsDraft = "again"
    await pm.saveInstructions()
    check(log.revisions == ["r1", "r1"] && !pm.instructionsEditing && !pm.instructionsConflict, "retry succeeds")
    pm.beginEditInstructions(); pm.instructionsDraft = "zzz"; pm.cancelEditInstructions()
    check(pm.instructionsDraft == "again" && !pm.instructionsEditing, "cancel restores")

    // file editor
    let fc = Calls()
    var contentSha = "s1", contentText = "hello"
    var saveError: WorkspacesFailure?
    let fcl = WorkspaceClient(detail: { WorkspaceDetail() }, saveInstructions: { _, _ in nil },
        addFile: { n, d in fc.created.append((n, d)); return WorkspaceFile(id: "new", name: n, size: d.count, sha: "n1", editable: true) },
        deleteFile: { _ in }, createChat: { p, t in WorkspaceChat(profile: p, sessionId: "s", title: t) },
        fileContent: { id in fc.fileGets += 1; return WorkspaceFileContent(id: id, name: "README.md", size: 5, sha: contentSha, content: contentText) },
        saveFile: { id, content, sha in
            fc.fileSaves.append((id, content, sha))
            if let e = saveError { throw e }
            return WorkspaceFileMeta(id: id, name: "README.md", size: content.utf8.count, sha: "s2")
        })
    let file = WorkspaceFile(id: "f1", name: "README.md", size: 5, sha: "s1", editable: true)
    let fe = WorkspaceFileEditorModel(client: fcl, mode: .existing(file))
    check(fe.phase == .idle && !fe.isEditing && !fe.canSave, "editor idle")
    await fe.load()
    check(fe.phase == .loaded && fe.draft == "hello" && !fe.isEditing && !fe.canSave, "loaded read-only")
    fe.beginEdit(); fe.draft = "hello world"
    check(fe.canSave && fe.bytes == 11, "edit savable")
    fe.cancel()
    check(fe.draft == "hello" && !fe.isEditing && !fe.canSave && fc.fileSaves.isEmpty, "cancel discards")
    fe.beginEdit(); fe.draft = "hello world"
    let ok = await fe.save()
    check(ok && fc.fileSaves.count == 1 && fc.fileSaves[0].0 == "f1" && fc.fileSaves[0].1 == "hello world" && fc.fileSaves[0].2 == "s1", "save sends content + sha")
    check(!fe.isEditing && !fe.canSave, "saved, not editing")
    fe.beginEdit(); fe.draft = "third"
    saveError = .conflict
    let ok2 = await fe.save()
    check(!ok2 && fe.conflict == .stale && fe.draft == "third" && fe.isEditing && fc.fileSaves[1].2 == "s2", "stale keeps draft, uses updated sha")
    contentSha = "s9"; contentText = "theirs"
    await fe.reloadLatest()
    check(fe.draft == "theirs" && fe.conflict == nil, "reload latest replaces explicitly")
    fe.draft = "mine again"; saveError = .duplicate
    _ = await fe.save()
    check(fe.conflict == .duplicate && fe.draft == "mine again", "duplicate keeps draft")
    fe.draft = String(repeating: "a", count: 8193)
    check(!fe.canSave && fe.problem != nil, "over 8192 bytes")
    fe.draft = String(repeating: "é", count: 4096)
    check(fe.problem == nil, "8192 bytes ok")
    fe.draft = "a\0b"
    check(!fe.canSave, "NUL refused")
    let jf = WorkspaceFileEditorModel(client: fcl, mode: .existing(WorkspaceFile(id: "j", name: "d.json", size: 2)))
    await jf.load(); jf.beginEdit(); jf.draft = "{bad"
    check(!jf.canSave && jf.problem == "That isn't valid JSON.", "json parse")
    let failing = WorkspaceFileEditorModel(client: WorkspaceClient(detail: { WorkspaceDetail() }, saveInstructions: { _, _ in nil },
        addFile: { _, _ in throw WorkspacesFailure.rejected }, deleteFile: { _ in }, createChat: { _, _ in throw WorkspacesFailure.rejected }),
        mode: .existing(file))
    await failing.load()
    check(failing.phase == .failed(.disabled), "file load failure")

    // new file
    let nf = WorkspaceFileEditorModel(client: fcl, mode: .new, existingCount: 0, name: "notes.md")
    check(nf.isNew && nf.isEditing && !nf.canSave, "new file: Save disabled while empty")
    nf.draft = "# hi"
    check(nf.canSave, "content -> savable")
    nf.name = ""
    check(!nf.canSave, "no name -> disabled")
    nf.name = "notes.pdf"
    check(!nf.canSave && nf.problem == WorkspaceValidation.Problem.unsupportedType.message, "bad extension disabled")
    nf.name = "notes.md"
    let nfSaved = await nf.save()
    check(nfSaved && fc.created.count == 1 && fc.created[0].0 == "notes.md" && fc.created[0].1 == Data("# hi".utf8) && nf.created?.id == "new", "created via POST")
    let full = WorkspaceFileEditorModel(client: fcl, mode: .new, existingCount: 4, name: "x.md")
    full.draft = "x"
    check(!full.canSave, "no room for a 5th file")
    let del = WorkspaceFileEditorModel(client: fcl, mode: .existing(file))
    let delOK = await del.delete()
    check(delOK, "delete")
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
    let failing = WorkspaceProjectModel(client: WorkspaceClient(detail: { throw WorkspacesFailure.disabled }, saveInstructions: { _, _ in nil }, addFile: { _, _ in throw WorkspacesFailure.rejected }, deleteFile: { _ in }, createChat: { _, _ in throw WorkspacesFailure.unavailable }))
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

    await buildFiveTests()
    print("Workspace validation, bots, per-send context, artifacts and model tests passed")
}

@main
enum WorkspaceModelTests {
    static func main() async { await run() }
}
