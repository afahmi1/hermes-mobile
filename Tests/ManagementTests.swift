import Foundation

private func check(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
    if !condition() { fatalError("FAILED (line \(line)): \(message)") }
}

private struct Boom: Error {}
private let syntheticPIN = "5807"  // synthetic test value only

@MainActor
func run() async {
    // slug preview
    check(ManageSlug.preview("My New Project!") == "my-new-project", "slug basic")
    check(ManageSlug.preview("  Café  Déjà--vu ") == "cafe-deja-vu", "slug folds accents, collapses dashes")
    check(ManageSlug.preview("日本語") == "", "non-ascii only -> empty")
    check(ManageSlug.preview(String(repeating: "a", count: 90)).count == 48, "slug capped")
    check(ManageSlug.isValid("ok-id-2") && !ManageSlug.isValid("Bad") && !ManageSlug.isValid("-x") && !ManageSlug.isValid("a--b") && !ManageSlug.isValid(""), "slug validity")

    // project create validation
    check(!ManageValidation.project(title: "  ", summary: "", id: "").isEmpty, "blank title rejected")
    check(ManageValidation.project(title: "Alpha", summary: "", id: "").isEmpty, "valid project")
    check(ManageValidation.project(title: "Alpha", summary: "", id: "Bad Id").first?.field == .id, "bad id")
    check(ManageValidation.project(title: "日本語", summary: "", id: "").first?.field == .id, "no slug derivable asks for id")
    check(ManageValidation.project(title: "日本語", summary: "", id: "jp").isEmpty, "typed id ok")
    check(!ManageValidation.project(title: String(repeating: "x", count: 81), summary: "", id: "").isEmpty, "title too long")
    check(!ManageValidation.project(title: "A", summary: String(repeating: "x", count: 501), id: "").isEmpty, "summary too long")

    // persona byte limit (bytes, not characters)
    check(ManageValidation.bot(name: "B", persona: String(repeating: "a", count: 4096), host: "h").isEmpty, "4096 bytes ok")
    check(ManageValidation.bot(name: "B", persona: String(repeating: "a", count: 4097), host: "h").first?.field == .persona, "4097 bytes rejected")
    check(ManageValidation.bot(name: "B", persona: String(repeating: "é", count: 2049), host: "h").first?.field == .persona, "multibyte counted in bytes")
    check(ManageValidation.personaBytes("é") == 2, "byte counter")
    check(ManageValidation.bot(name: "", persona: "p", host: "h").first?.field == .name, "name required")
    check(ManageValidation.bot(name: "B", persona: "p", host: nil).first?.field == .host, "host required")

    // PIN field filter
    check(PINField.filter("12ab34567") == "1234", "digits only, max 4")
    check(PINField.filter("٣٤٥٦") == "", "non-ascii digits dropped")
    check(PINField.filter(" 5-8 07 ") == "5807", "separators dropped")
    check(PINField.isComplete("5807") && !PINField.isComplete("580") && !PINField.isComplete("58a7"), "complete")

    // error mapping
    check(ManageFailure.from(status: 403, code: "pin_wrong").message == "That PIN isn't right.", "pin_wrong")
    check(ManageFailure.from(status: 429, code: "pin_locked", retryAfter: 300) == .pinLocked(minutes: 5), "locked 5 min")
    check(ManageFailure.from(status: 429, code: "pin_locked", retryAfter: 301).message == "Too many tries. Try again in 6 minutes.", "rounds up")
    check(ManageFailure.from(status: 429, code: "pin_locked", retryAfter: 30).message == "Too many tries. Try again in 1 minute.", "singular")
    check(ManageFailure.from(status: 503, code: "pin_unset").message == "Set a deletion PIN on the Mac first.", "pin_unset")
    let busy = Data(#"{"error": "Your Mac is busy for a moment. Trying again.", "retry": true}"#.utf8)
    check(ManageFailure.from(status: 503, data: busy) == .server, "a busy 503 is not a PIN problem")
    check(ManageFailure.from(status: 503, data: Data(#"{"code": "pin_unset", "retry": true}"#.utf8)) == .pinUnset, "codes still win")
    check(ManageFailure.from(status: 403, code: "owner_required").message == "Sign in again on this phone to manage projects and bots.", "owner_required")
    check(ManageFailure.from(status: 403, code: "read_only") == .readOnly, "read_only")
    check(ManageFailure.from(status: 409, code: "") == .duplicate, "409")
    check(ManageFailure.from(status: 401, code: "") == .signedOut, "401")
    let body = Data(#"{"error":"server words must not show","code":"pin_locked","retry_after":125}"#.utf8)
    check(ManageFailure.from(status: 429, data: body) == .pinLocked(minutes: 3), "body parse")
    check(!ManageFailure.from(status: 429, data: body).message.contains("server words"), "server text never shown")
    check(ManageFailure.from(status: 500, data: Data("junk".utf8)) == .server, "junk body")
    check(ManageFailure.classify(URLError(.timedOut)) == .network, "network")

    // decoding
    let bots = try! ManageBotsInfo.decode(Data(#"""
    {"personas":[{"id":"p1","name":"Coach","persona":"Be brief","host":"sample-reviewer"}],
     "hosts":["sample-reviewer",{"id":"h2","name":"Second"}],"manageable":["tmp","default"]}
    """#.utf8))
    check(bots.personas.first?.host == "sample-reviewer" && bots.hosts.map(\.id) == ["sample-reviewer", "h2"], "bots decode")
    check(bots.hosts[1].name == "Second", "host object name")
    check(bots.canArchive("tmp") && !bots.canArchive("default") && !bots.canArchive("other"), "default and unlisted never archivable")
    let emptyBots = try! ManageBotsInfo.decode(Data("{}".utf8))
    check(emptyBots.hosts.isEmpty && emptyBots.personas.isEmpty && !emptyBots.canArchive("x"), "empty tolerated")
    check((try? ManageBotsInfo.decode(Data("[1]".utf8))) == nil, "bad shape throws")
    let arch = try! ArchivedInfo.decode(Data(#"{"projects":[{"id":"a","title":"A"}],"bots":[{"id":"b","name":"Bee"},"c"]}"#.utf8))
    check(arch.projects.first?.title == "A" && arch.bots.map(\.title) == ["Bee", "c"], "archived decode")
    let proj = try! ManageEnvelope.project(Data(#"{"project":{"id":"x","title":"X","managed":true}}"#.utf8))
    check(proj.managed && proj.id == "x", "wrapped project, managed flag")
    let bare = try! ManageEnvelope.project(Data(#"{"id":"y","title":"Y"}"#.utf8))
    check(!bare.managed, "managed defaults false")
    let persona = try! ManageEnvelope.persona(Data(#"{"id":"p","name":"N","persona":"x","host":"h"}"#.utf8))
    check(persona.host == "h", "persona decode")
    check(ProjectDraft(title: " T ", summary: " ", id: nil).body.count == 1, "draft omits empty summary and id")
    check(ProjectDraft(title: "T", summary: "S", id: "t-1").body["id"] as? String == "t-1", "draft id")

    // AddProjectModel
    var sent: [ProjectDraft] = []
    let add = AddProjectModel(create: { d in
        sent.append(d)
        return try ManageEnvelope.project(Data(#"{"id":"made","title":"Made","managed":true}"#.utf8))
    })
    check(!add.canSave, "empty cannot save")
    add.title = "Hello World"
    check(add.effectiveID == "hello-world" && add.canSave, "slug preview + save enabled")
    add.idText = "custom"
    check(add.effectiveID == "custom", "typed id wins")
    let r1 = await add.save()
    check(r1 && sent.first?.id == "custom" && add.created?.id == "made", "create sent")
    let addFail = AddProjectModel(create: { _ in throw ManageFailure.duplicate })
    addFail.title = "T"
    let r2 = await addFail.save()
    check(!r2 && addFail.failure == .duplicate, "server code mapped")

    // AddBotModel
    let ab = AddBotModel(loadHosts: { [] }, create: { n, p, h in ManagedPersona(id: "n", name: n, persona: p, host: h) })
    ab.name = "N"; ab.persona = "P"
    await ab.load()
    check(ab.noHosts && !ab.canSave, "no hosts -> save disabled")
    let ab2 = AddBotModel(loadHosts: { [ManageHost(id: "h", name: "H")] }, create: { n, p, h in ManagedPersona(id: "n", name: n, persona: p, host: h) })
    ab2.name = "N"; ab2.persona = "P"
    check(!ab2.canSave, "not loaded -> disabled")
    await ab2.load()
    check(ab2.hostID == "h" && ab2.canSave, "host preselected")
    let r3 = await ab2.save()
    check(r3 && ab2.created?.host == "h", "bot created")

    // Archive model: PIN cleared after success and failure
    var received: [String] = []
    let ok = ArchiveModel(archive: { received.append($0) })
    ok.pinInput = "58x07999"
    check(ok.pin == syntheticPIN && ok.canSubmit, "filtered and submittable")
    let r4 = await ok.submit()
    check(r4, "archive success")
    check(received == [syntheticPIN] && ok.pin.isEmpty && ok.done, "success: sent once, pin cleared")
    let bad = ArchiveModel(archive: { _ in throw ManageFailure.pinWrong })
    bad.pinInput = syntheticPIN
    let r5 = await bad.submit()
    check(!r5 && bad.failure == .pinWrong && bad.pin.isEmpty && !bad.done, "failure: pin cleared, error kept")
    let net = ArchiveModel(archive: { _ in throw Boom() })
    net.pinInput = syntheticPIN
    let r6 = await net.submit()
    check(!r6 && net.pin.isEmpty && net.failure == .network, "unknown error -> network, pin cleared")
    let short = ArchiveModel(archive: { _ in fatalError("must not run") })
    short.pinInput = "580"
    let r7 = await short.submit()
    check(!short.canSubmit && !r7, "3 digits cannot submit")
    short.clear(); check(short.pin.isEmpty, "clear on dismiss")

    // Archived model
    var restored: [String] = []
    let am = ArchivedModel(fetch: { arch }, restoreProject: { restored.append("p" + $0) }, restoreBot: { restored.append("b" + $0) })
    await am.load()
    check(am.state == .loaded(arch), "archived loaded")
    let r8 = await am.restore(project: true, id: "a")
    check(r8 && restored == ["pa"], "restore project")
    let r9 = await am.restore(project: false, id: "b")
    check(r9 && restored == ["pa", "bb"], "restore bot")
    if case .loaded(let i) = am.state { check(i.projects.isEmpty && i.bots.map(\.id) == ["c"], "restored removed") } else { check(false, "state") }

    // ManageBotsModel fails closed
    let mb = ManageBotsModel(fetch: { throw Boom() })
    await mb.load()
    check(!mb.canArchive("tmp") && mb.state == .failed(.network), "failed load -> no archive action")
    let mb2 = ManageBotsModel(fetch: { bots })
    await mb2.load()
    check(mb2.canArchive("tmp") && !mb2.canArchive("default"), "manageable gate")

    // deletion PIN setup (synthetic values only)
    check(PINSetup.problem(new: "5807", confirm: "5807", current: "", configured: false) == nil, "first set ok")
    check(PINSetup.problem(new: "5807", confirm: "5808", current: "", configured: false) != nil, "mismatch refused")
    check(PINSetup.problem(new: "58a7", confirm: "58a7", current: "", configured: false) != nil, "non-digits refused")
    check(PINSetup.problem(new: "3916", confirm: "3916", current: "", configured: true) != nil, "change needs current")
    check(PINSetup.body(new: "3916", confirm: "3916", current: "5807", configured: true)["current"] == "5807", "change body")
    check(PINSetup.body(new: "5807", confirm: "5807", current: "x", configured: false)["current"] == nil, "first-set body has no current")

    print("Management slug, validation, PIN filter/clearing, error mapping, decoding and model tests passed")
}

@main
enum ManagementTests {
    static func main() async { await run() }
}
