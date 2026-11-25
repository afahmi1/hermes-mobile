import Foundation
import Security
import CryptoKit

struct MediaCapabilities: Decodable {
    let images: Bool
    let files: Bool
    let video: Bool
    let maxVideoBytes: Int
    let maxFileBytes: Int
    enum CodingKeys: String, CodingKey {
        case images, files, video
        case maxVideoBytes = "max_video_bytes"
        case maxFileBytes = "max_file_bytes"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        images = try c.decodeIfPresent(Bool.self, forKey: .images) ?? false
        // Bridges from before file attachments only advertised images/video.
        files = try c.decodeIfPresent(Bool.self, forKey: .files) ?? false
        video = try c.decodeIfPresent(Bool.self, forKey: .video) ?? false
        maxVideoBytes = try c.decodeIfPresent(Int.self, forKey: .maxVideoBytes) ?? 4 * 1024 * 1024
        maxFileBytes = try c.decodeIfPresent(Int.self, forKey: .maxFileBytes) ?? maxVideoBytes
    }
}

enum APIError: LocalizedError {
    case notSignedIn
    case http(Int, String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .notSignedIn: "Sign in to your Hermes server first."
        case .http(401, let message): message.isEmpty ? "Sign in to Hermes again." : message
        case .http(let code, let msg): msg.isEmpty ? "The server answered \(code)." : msg
        case .badResponse: "The server sent something unexpected."
        }
    }
}

/// Talks to the Hermes Mobile bridge on the Mac. Every chat and setting lives in Hermes's own
/// state.db there; this client keeps nothing but the server address and a sign-in token.
private final class BridgeTransport: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var detached = false
    func detach() { lock.withLock { detached = true } }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        if lock.withLock({ detached }) { task.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // The bridge serves fixed API routes. Login bodies and bearer tokens must stay at this origin.
        completionHandler(nil)
    }
}

final class API: @unchecked Sendable {
    private static let lock = NSLock()
    static let accounts = SavedGateways(defaults: .standard, read: Keychain.read, write: Keychain.write, remove: Keychain.delete)
    private static var client = API(accounts.restore())

    static var shared: API { lock.withLock { client } }
    private let login: GatewayLogin?
    let accountID: String?
    var baseURL: URL? { login?.server }
    var token: String? { login?.token }
    var isSignedIn: Bool { login != nil }
    private let transport = BridgeTransport()
    private init(_ login: GatewayLogin?) {
        self.login = login
        self.accountID = login.map(Self.accountID(for:))
        self.session = Self.makeSession(stream: false, transport: transport)
        self.streamSession = Self.makeSession(stream: true, transport: transport)
    }

    deinit {
        session.invalidateAndCancel()
        streamSession.invalidateAndCancel()
    }

    /// All outstanding work keeps its original destination. Closing the old sessions detaches local streams.
    static func activate(_ login: GatewayLogin?) {
        let old = lock.withLock {
            let previous = client
            client = API(login)
            return previous
        }
        old.transport.detach()
        for session in [old.session, old.streamSession] {
            session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        }
    }

    private let session: URLSession
    private let streamSession: URLSession

    private static func makeSession(stream: Bool, transport: BridgeTransport) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = stream ? 45 : 60
        if stream { configuration.timeoutIntervalForResource = 3600 }
        configuration.waitsForConnectivity = false
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration, delegate: transport, delegateQueue: nil)
    }

    // MARK: plumbing

    private func request(_ path: String, method: String = "GET", body: Any? = nil, auth: Bool = true, server: URL? = nil) throws -> URLRequest {
        guard API.shared === self, let base = server ?? baseURL, path.hasPrefix("/"), !path.hasPrefix("//"),
              let url = URL(string: path, relativeTo: base) else { throw APIError.notSignedIn }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if auth {
            guard let token else { throw APIError.notSignedIn }
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    private func send(_ r: URLRequest) async throws -> Data {
        let (data, resp) = try await session.data(for: r)
        guard let http = resp as? HTTPURLResponse else { throw APIError.badResponse }
        guard (200..<300).contains(http.statusCode) else { throw APIError.http(http.statusCode, Self.errorText(data)) }
        return data
    }

    static func errorText(_ data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        if let s = obj["error"] as? String { return s }
        if let e = obj["error"] as? [String: Any], let m = e["message"] as? String { return m }
        if let m = obj["message"] as? String { return m }
        return ""
    }

    private func get<T: Decodable>(_ path: String, as: T.Type) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await send(try request(path)))
    }

    private func json(_ path: String, method: String, body: Any?) async throws -> [String: Any] {
        let data = try await send(try request(path, method: method, body: body))
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func esc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? s
    }
    private func p(_ profile: String, _ tail: String) -> String { "/m/p/\(Self.esc(profile))\(tail)" }

    // MARK: sign-in

    func signIn(server: URL, username: String, password: String, device: String) async throws -> GatewayLogin {
        try await authenticate(server, path: "/m/login", body: ["username": username, "password": password, "device": device])
    }

    func pair(server: URL, code: String, device: String) async throws -> GatewayLogin {
        try await authenticate(server, path: "/m/pair", body: ["code": code, "device": device])
    }

    private func authenticate(_ server: URL, path: String, body: [String: String]) async throws -> GatewayLogin {
        let r = try request(path, method: "POST", body: body, auth: false, server: server)
        let data = try await send(r)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = obj["token"] as? String, !t.isEmpty else { throw APIError.badResponse }
        guard let origin = SavedGateways.origin(server) else { throw APIError.badResponse }
        return GatewayLogin(server: origin, token: t)
    }

    func capabilities() async throws -> BridgeCapabilities {
        try await get("/m/capabilities", as: BridgeCapabilities.self)
    }

    func devices() async throws -> [DeviceGrant] {
        struct Response: Decodable { let devices: [DeviceGrant] }
        return try await get("/m/devices", as: Response.self).devices
    }

    func pairingCode() async throws -> DevicePairCode {
        let result = try await send(request("/m/devices/pair-code", method: "POST"))
        return try JSONDecoder().decode(DevicePairCode.self, from: result)
    }

    func revokeDevice(_ id: String) async throws {
        _ = try await send(request("/m/devices/\(Self.esc(id))", method: "DELETE"))
    }

    /// Revoke the grant a saved, non-active gateway issued to this phone. Best effort: the host may be
    /// asleep, and the caller removes the local credential either way.
    func revokeSavedDevice(_ login: GatewayLogin) async throws {
        var r = try request("/m/devices/current", method: "DELETE", auth: false, server: login.server)
        r.setValue("Bearer " + login.token, forHTTPHeaderField: "Authorization")
        r.timeoutInterval = 6
        _ = try await send(r)
    }

    static func accountID(for login: GatewayLogin) -> String {
        SHA256.hash(data: Data((login.server.absoluteString + "|" + login.token).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: reads

    func mediaCapabilities(profile: String) async throws -> MediaCapabilities {
        try await get("/m/chat/\(Self.esc(profile))/media-capabilities", as: MediaCapabilities.self)
    }

    func health() async throws -> HealthInfo {
        var probe = try request("/m/health")
        probe.timeoutInterval = 8
        return try JSONDecoder().decode(HealthInfo.self, from: try await send(probe))
    }

    /// Everything the Mac's status dashboard shows (bots, cron jobs, running agents, providers, what's new).
    func status(refreshProviders: Bool = false) async throws -> JV {
        var r = try request("/m/status" + (refreshProviders ? "?refresh=providers" : ""))
        r.timeoutInterval = 100  // a provider refresh asks each provider for its usage
        let data = try await send(r)
        return JV(try JSONSerialization.jsonObject(with: data))
    }
    func bots() async throws -> [Bot] {
        struct R: Decodable { let bots: [Bot] }
        return try await get("/m/bots", as: R.self).bots
    }
    /// Read-only project list (bridge schema V1). Old bridges answer 404; that and other failures
    /// become a ProjectsFailure with fixed wording, never the server's text.
    func projects() async throws -> ProjectsSnapshot {
        do {
            var catalogRequest = try request("/m/projects")
            catalogRequest.timeoutInterval = 15
            catalogRequest.cachePolicy = .reloadIgnoringLocalCacheData
            return try ProjectsSnapshot.decode(try await send(catalogRequest))
        } catch let error as ProjectsFailure {
            throw error
        } catch APIError.notSignedIn {
            throw ProjectsFailure.signedOut
        } catch APIError.http(let code, _) {
            throw ProjectsFailure.fromHTTP(code)
        } catch APIError.badResponse {
            throw ProjectsFailure.malformed
        } catch {
            throw ProjectsFailure.classify(error)
        }
    }
    // MARK: workspaces (signed-in, app only)

    private func workspaceCall<T>(_ work: () async throws -> T) async throws -> T {
        do { return try await work() }
        catch let e as WorkspacesFailure { throw e }
        catch APIError.notSignedIn { throw WorkspacesFailure.signedOut }
        catch APIError.http(let code, _) { throw WorkspacesFailure.fromHTTP(code) }
        catch APIError.badResponse { throw WorkspacesFailure.malformed }
        catch is CancellationError { throw CancellationError() }
        catch let e as URLError where e.code == .cancelled { throw e }
        catch { throw WorkspacesFailure.network }
    }

    /// Like `send`, but keeps the bridge's machine `code` so 409/403 become distinct, fixed-text failures.
    private func wsSend(_ r: URLRequest) async throws -> Data {
        let (data, resp) = try await session.data(for: r)
        guard let http = resp as? HTTPURLResponse else { throw APIError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["code"] as? String
            throw WorkspacesFailure.fromResponse(status: http.statusCode, code: code)
        }
        return data
    }

    private func workspaceGET(_ path: String) async throws -> Data {
        var r = try request(path)
        r.timeoutInterval = 15
        r.cachePolicy = .reloadIgnoringLocalCacheData
        return try await wsSend(r)
    }

    private func workspaceWrite(_ path: String, method: String, body: [String: Any]?) async throws -> Data {
        var r = try request(path, method: method, body: body)
        r.timeoutInterval = 20
        return try await wsSend(r)
    }

    private func workspaceJSON(_ path: String, method: String, body: [String: Any]?) async throws -> [String: Any] {
        let data = try await workspaceWrite(path, method: method, body: body)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func workspaceIndex() async throws -> WorkspaceIndex {
        try await workspaceCall { try WorkspaceIndex.decode(try await workspaceGET("/m/workspaces")) }
    }

    func workspaceDetail(project: String) async throws -> WorkspaceDetail {
        try await workspaceCall { try WorkspaceDetail.decode(try await workspaceGET("/m/workspaces/\(Self.esc(project))")) }
    }

    /// Returns the new revision (nil from a build-4 bridge). `revision` makes a concurrent edit a 409.
    func saveWorkspaceInstructions(project: String, text: String, revision: String?) async throws -> String? {
        try WorkspaceValidation.checkInstructions(text)
        return try await workspaceCall {
            var b: [String: Any] = ["instructions": text]
            if let revision { b["revision"] = revision }
            let o = try await workspaceJSON("/m/workspaces/\(Self.esc(project))/instructions", method: "PUT", body: b)
            guard o["ok"] as? Bool == true else { throw APIError.badResponse }
            return o["revision"] as? String
        }
    }

    func saveWorkspaceAssignment(project: String, profiles: [String], revision: Int) async throws -> WorkspaceAssignment {
        try await workspaceCall {
            let data = try await workspaceWrite("/m/workspaces/\(Self.esc(project))/assignment", method: "PUT",
                                                body: ["profiles": profiles, "revision": revision])
            return try WorkspaceAssignment.decodeEnvelope(data)
        }
    }

    func workspaceFileContent(project: String, id: String) async throws -> WorkspaceFileContent {
        try await workspaceCall {
            let data = try await workspaceGET("/m/workspaces/\(Self.esc(project))/files/\(Self.esc(id))")
            guard data.count <= 64 * 1024, let c = try? JSONDecoder().decode(WorkspaceFileContent.self, from: data) else {
                throw APIError.badResponse
            }
            return c
        }
    }

    func saveWorkspaceFile(project: String, id: String, content: String, sha: String) async throws -> WorkspaceFileMeta {
        try await workspaceCall {
            let data = try await workspaceWrite("/m/workspaces/\(Self.esc(project))/files/\(Self.esc(id))", method: "PUT",
                                                body: ["content": content, "sha": sha])
            guard let m = try? JSONDecoder().decode(WorkspaceFileMeta.self, from: data) else { throw APIError.badResponse }
            return m
        }
    }

    func addWorkspaceFile(project: String, name: String, data: Data) async throws -> WorkspaceFile {
        try await workspaceCall {
            let body = try await workspaceWrite("/m/workspaces/\(Self.esc(project))/files", method: "POST",
                                                body: WorkspaceValidation.fileBody(name: name, data: data))
            guard let f = try? JSONDecoder().decode(WorkspaceFile.self, from: body) else { throw APIError.badResponse }
            return f
        }
    }

    func deleteWorkspaceFile(project: String, id: String) async throws {
        try await workspaceCall {
            let o = try await workspaceJSON("/m/workspaces/\(Self.esc(project))/files/\(Self.esc(id))", method: "DELETE", body: nil)
            guard o["ok"] as? Bool == true else { throw APIError.badResponse }
        }
    }

    func createWorkspaceChat(project: String, profile: String, title: String?) async throws -> WorkspaceChat {
        try await workspaceCall {
            var b: [String: Any] = ["profile": profile]
            if let title { b["title"] = title }
            let body = try await workspaceWrite("/m/workspaces/\(Self.esc(project))/chats", method: "POST", body: b)
            guard let c = try? JSONDecoder().decode(WorkspaceChat.self, from: body) else { throw APIError.badResponse }
            return c
        }
    }

    /// One chat's artifacts, or (`session == nil`) one bot's library within ONE project. The bridge refuses a
    /// library request with no project, so a bot's files never mix across projects.
    func workspaceArtifacts(profile: String, session: String? = nil, project: String? = nil) async throws -> [WorkspaceArtifact] {
        try await workspaceCall {
            var path = "/m/workspace-artifacts/\(Self.esc(profile))" + (session.map { "/\(Self.esc($0))" } ?? "")
            if session == nil, let project { path += "?project=\(Self.esc(project))" }
            return try WorkspaceArtifact.decodeList(try await workspaceGET(path))
        }
    }

    /// Downloads one artifact, never more than 8 MiB, with the server's Content-Disposition name.
    func workspaceFile(id: String, fallbackName: String) async throws -> WorkspaceDownload {
        guard WorkspaceArtifact.isValidID(id) else { throw WorkspacesFailure.malformed }
        return try await workspaceCall {
            var r = try request("/m/workspace-file/\(id)")
            r.setValue("*/*", forHTTPHeaderField: "Accept")
            r.timeoutInterval = 60
            r.cachePolicy = .reloadIgnoringLocalCacheData
            let (bytes, resp) = try await session.bytes(for: r)
            guard let http = resp as? HTTPURLResponse else { throw APIError.badResponse }
            guard (200..<300).contains(http.statusCode) else { throw APIError.http(http.statusCode, "") }
            let cap = WorkspaceLimits.artifactDownloadBytes
            if resp.expectedContentLength > Int64(cap) { throw WorkspacesFailure.tooLarge }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > cap { throw WorkspacesFailure.tooLarge }
            }
            return WorkspaceDownload(
                data: data,
                filename: ArtifactPreview.filename(disposition: http.value(forHTTPHeaderField: "Content-Disposition"), fallback: fallbackName),
                mime: http.value(forHTTPHeaderField: "Content-Type"))
        }
    }

    func sessions(cursor: String?, profile: String? = nil, exclude: [String] = [], source: String? = nil) async throws -> SessionPage {
        let limit = cursor == nil ? 16 : 40
        var q = ["limit=\(limit)", "view=compact"]
        if let cursor { q.append("cursor=\(cursor)") }
        if let profile { q.append("profile=\(Self.esc(profile))") }
        if !exclude.isEmpty { q.append("exclude=\(exclude.joined(separator: ","))") }
        if source == "archived" {
            do { return try await get("/m/archived?" + q.joined(separator: "&"), as: SessionPage.self) }
            catch APIError.http(404, _) {
                let rows = try await search("", archived: true, profile: profile, scope: "all")
                return SessionPage(errors: nil, reset: nil, data: rows, next: nil)
            }
        }
        let path = source == "telegram" ? "/m/telegram?" : source == "desktop" ? "/m/desktop?" : "/m/sessions?"
        return try await get(path + q.joined(separator: "&"), as: SessionPage.self)
    }
    /// Archive or pin many sessions in one request. The bridge fans the gateway's
    /// per-session PATCH out in parallel and returns the rows it could not change.
    /// Archiving a chat with pinned messages is refused by the bridge unless `confirmPins` says the person
    /// saw how many pins it holds. Refused chats come back in `heldForPins`; the pins are never deleted.
    func updateSessions(profile: String, ids: [String], fields: [String: Bool], confirmPins: Bool = false) async throws -> SessionFlagResult {
        var body: [String: Any] = ["profile": profile, "ids": ids, "fields": fields]
        if confirmPins { body["confirm_pins"] = true }
        let r = try request("/m/sessions/flags", method: "POST", body: body)
        let (data, resp) = try await session.data(for: r)
        guard let http = resp as? HTTPURLResponse else { throw APIError.badResponse }
        let d = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let held = (d["pins"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.intValue }
        if http.statusCode == 409, !held.isEmpty {
            return SessionFlagResult(updated: [], errors: d["errors"] as? [String: String] ?? [:], heldForPins: held)
        }
        guard (200..<300).contains(http.statusCode) else { throw APIError.http(http.statusCode, Self.errorText(data)) }
        return SessionFlagResult(updated: d["updated"] as? [String] ?? [],
                                 errors: d["errors"] as? [String: String] ?? [:], heldForPins: held)
    }

    // MARK: pinned messages

    private func pinPath(_ profile: String, _ session: String, _ message: Int? = nil) -> String {
        "/m/pins/\(Self.esc(profile))/\(Self.esc(session))" + (message.map { "/\($0)" } ?? "")
    }

    func pins(profile: String, session: String) async throws -> [MessagePin] {
        try await get(pinPath(profile, session), as: PinList.self).pins
    }

    /// Pins one stored message and returns the chat's full pin list.
    func pin(profile: String, session: String, message: Int) async throws -> [MessagePin] {
        let data = try await send(try request(pinPath(profile, session), method: "POST", body: ["message_id": message]))
        return try JSONDecoder().decode(PinList.self, from: data).pins
    }

    func unpin(profile: String, session: String, message: Int) async throws -> [MessagePin] {
        let data = try await send(try request(pinPath(profile, session, message), method: "DELETE"))
        return try JSONDecoder().decode(PinList.self, from: data).pins
    }

    func unpinAll(profile: String, session: String) async throws {
        _ = try await send(try request(pinPath(profile, session), method: "DELETE"))
    }

    func search(_ text: String, archived: Bool = false, profile: String? = nil, source: String? = nil, scope: String? = nil) async throws -> [SessionSummary] {
        let path = try Self.searchPath(text, archived: archived, profile: profile, source: source, scope: scope)
        return try await get(path, as: SearchPage.self).data
    }

    /// An explicit read on a paired destination. Chat writes still require the active client.
    func searchDestination(_ login: GatewayLogin, text: String) async throws -> [SessionSummary] {
        let path = try Self.searchPath(text, archived: false, profile: nil, source: nil, scope: "all")
        var r = try request(path, auth: false, server: login.server)
        r.setValue("Bearer " + login.token, forHTTPHeaderField: "Authorization")
        r.timeoutInterval = 8
        r.cachePolicy = .reloadIgnoringLocalCacheData
        return try JSONDecoder().decode(SearchPage.self, from: try await send(r)).data
    }

    private static func searchPath(_ text: String, archived: Bool, profile: String?, source: String?, scope: String?) throws -> String {
        var components = URLComponents()
        components.path = "/m/search"
        var query = [URLQueryItem(name: "q", value: text)]
        if let scope { query.append(URLQueryItem(name: "scope", value: scope)) }
        if archived { query.append(URLQueryItem(name: "archived", value: "1")) }
        if let profile { query.append(URLQueryItem(name: "profile", value: profile)) }
        if let source { query.append(URLQueryItem(name: "source", value: source)) }
        components.queryItems = query
        // Form-style query decoders interpret literal plus signs as spaces.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let path = components.string else { throw APIError.badResponse }
        return path
    }
    func messages(profile: String, session: String, limit: Int = 100, offset: Int = 0) async throws -> [StoredMessage] {
        let page = try await timeline(profile: profile, session: session, limit: limit, offset: offset)
        guard let rows = page.rows else { throw APIError.badResponse }
        return rows
    }

    func timeline(profile: String, session id: String, limit: Int = 100, offset: Int = 0,
                  validator: String? = nil) async throws -> (rows: [StoredMessage]?, validator: String?) {
        var r = try request(p(profile, "/api/sessions/\(Self.esc(id))/messages?limit=\(limit)&offset=\(offset)&order=latest"))
        r.cachePolicy = .reloadIgnoringLocalCacheData
        r.setValue("timeline-v1", forHTTPHeaderField: "X-Hermes-Transcript")
        r.setValue(validator, forHTTPHeaderField: "If-None-Match")
        let (data, response) = try await session.data(for: r)
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse }
        if http.statusCode == 304, let validator { return (nil, validator) }
        guard http.statusCode == 200 else { throw APIError.http(http.statusCode, Self.errorText(data)) }
        return (try JSONDecoder().decode(MessagesPage.self, from: data).data, http.value(forHTTPHeaderField: "ETag"))
    }
    func catalog(profile: String, fetch: CatalogFetch = .cached) async throws -> ModelCatalog {
        try await get(fetch.path(escapedProfile: Self.esc(profile)), as: ModelCatalog.self)
    }
    func served(profile: String, session: String) async throws -> ServedRuntime {
        try await get("/m/runtime/\(Self.esc(profile))/\(Self.esc(session))", as: ServedRuntime.self)
    }

    // MARK: writes

    /// Create a chat the way the desktop app does (canonical `session.create`, source `gui`),
    /// so it lands in the desktop's Recents and model/effort switches persist on it.
    func commandPalette(profile: String) async throws -> CommandPalette {
        try await get("/m/commands?profile=\(Self.esc(profile))", as: CommandPalette.self)
    }

    func slash(profile: String, session: String, command: String) async throws -> SlashResult {
        let obj = try await json("/m/chat/\(Self.esc(profile))/\(Self.esc(session))/slash", method: "POST", body: ["command": command])
        return SlashResult(output: obj["output"] as? String, warning: obj["warning"] as? String,
                           type: obj["type"] as? String, message: obj["message"] as? String,
                           display: obj["display"] as? String, notice: obj["notice"] as? String)
    }

    func chatMedia(profile: String, session: String, digest: String) async throws -> Data {
        try await send(try request("/m/chat/\(Self.esc(profile))/\(Self.esc(session))/media/\(Self.esc(digest))"))
    }

    /// Create a skill file, or append a note to one this bot already has. Returns the names Hermes now lists.
    func saveSkill(profile: String, action: String, name: String, description: String = "", body: String = "", note: String = "") async throws -> [String] {
        var payload: [String: Any] = ["profile": profile, "action": action, "name": name]
        if !description.isEmpty { payload["description"] = description }
        if !body.isEmpty { payload["body"] = body }
        if !note.isEmpty { payload["note"] = note }
        let obj = try await json("/m/skills", method: "POST", body: payload)
        return obj["skills"] as? [String] ?? []
    }

    func createSession(profile: String, draftID: UUID) async throws -> String {
        let obj = try await json("/m/chat/\(Self.esc(profile))/new", method: "POST", body: ["request_id": draftID.uuidString])
        guard let id = obj["session_id"] as? String else { throw APIError.badResponse }
        return id
    }

    func updateSession(profile: String, session: String, fields: [String: Any]) async throws {
        _ = try await json(p(profile, "/api/sessions/\(Self.esc(session))"), method: "PATCH", body: fields)
    }

    private static func choiceBody(_ choice: RuntimeChoice, previous: RuntimeChoice? = nil) -> [String: Any] {
        var body: [String: Any] = [:]
        if let v = choice.provider { body["provider"] = v }
        if let v = choice.model { body["model"] = v }
        if let v = choice.effort { body["effort"] = v }
        // "Bot default" after a pick: hand the setting back to the bot (the desktop's /model reset).
        if let previous {
            if choice.model == nil, previous.model != nil { body["reset_model"] = true }
            if choice.effort == nil, previous.effort != nil { body["reset_effort"] = true }
        }
        return body
    }

    /// Persist the chat's model/provider/effort on the session in Hermes (`session.mutate`), exactly
    /// what the desktop's picker does, so every device sees it and the next turn runs on it.
    /// `previous` is what the chat had; fields cleared since then are reset to the bot's own setting.
    func lockRuntime(profile: String, session: String, choice: RuntimeChoice, previous: RuntimeChoice? = nil) async throws -> Bool {
        let body = Self.choiceBody(choice, previous: previous)
        guard !body.isEmpty else { return false }
        let result = try await json("/m/chat/\(Self.esc(profile))/\(Self.esc(session))/runtime", method: "POST", body: body)
        return result["timing"] as? String == "next_turn"
    }

    /// Start a turn. The Mac holds it; it keeps running if the phone locks or loses signal.
    func startRun(profile: String, session: String, text: String, choice: RuntimeChoice,
                  projectContext: String? = nil, submission: UUID? = nil, attachments: [SendAttachment] = [], recovering: Bool = false) async throws -> String {
        var body = Self.choiceBody(choice)
        body["text"] = text
        ProjectContext.apply(to: &body, projectID: projectContext)
        if let submission { body["submission_id"] = submission.uuidString }
        let endpoint = "/m/chat/\(Self.esc(profile))/\(Self.esc(session))/"
        if recovering, let submission, !attachments.isEmpty {
            var probe = body
            probe["manifest"] = try attachments.map { item -> [String: String] in
                guard let data = Data(base64Encoded: item.base64) else { throw APIError.badResponse }
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                return ["filename": item.filename, "mime": item.mime, "sha256": hash]
            }
            do {
                let receipt = try await json(endpoint + "send-receipt", method: "POST", body: probe)
                let expected = "turn_" + submission.uuidString.lowercased().replacingOccurrences(of: "-", with: "")
                guard receipt["turn_id"] as? String == expected else { throw APIError.badResponse }
                return expected
            } catch APIError.http(404, _) {
                // A missing receipt or older bridge needs the original send with its original UUID.
            }
        }
        if !attachments.isEmpty {
            guard submission != nil else { throw APIError.badResponse }
            if attachments.contains(where: { $0.mime == "video/mp4" }) { body["video_analysis_consent"] = true }
            body["attachments"] = attachments.map { ["mime": $0.mime, "filename": $0.filename, "base64": $0.base64] }
        }
        let action = submission == nil ? "send" : "send-once"
        let obj = try await json(endpoint + action, method: "POST", body: body)
        guard let id = obj["turn_id"] as? String else { throw APIError.badResponse }
        return id
    }

    /// Queue the next message or steer the running reply, optionally with the files staged in the composer.
    /// Returns how many attachments the bridge accepted: an older bridge ignores them and reports none.
    @discardableResult
    func followUp(run: String, mode: String, text: String, submission: UUID, choice: RuntimeChoice,
                  attachments: [SendAttachment] = []) async throws -> Int {
        var body = mode == "queue" ? Self.choiceBody(choice) : [:]
        // Older bridges ignore unknown JSON fields. A distinct route refuses an unsupported
        // override before it can submit the message with the wrong model.
        let action = body.isEmpty ? mode : "queue-with-runtime"
        body["text"] = text
        body["submission_id"] = submission.uuidString
        if !attachments.isEmpty {
            body["attachments"] = attachments.map { ["mime": $0.mime, "filename": $0.filename, "base64": $0.base64] }
        }
        let result = try await json("/m/turns/\(Self.esc(run))/\(action)", method: "POST", body: body)
        let expected = mode == "queue" ? "queued" : "steer_accepted"
        guard result["status"] as? String == expected else { throw APIError.badResponse }
        return (result["attachments"] as? NSNumber)?.intValue ?? 0
    }

    func stopRun(profile: String, run: String) async throws {
        _ = try await json("/m/turns/\(Self.esc(run))/stop", method: "POST", body: [:])
    }

    func approve(profile: String, run: String, choice: String, requestId: String?, generation: Int?) async throws {
        var body: [String: Any] = ["choice": choice]
        if let requestId { body["request_id"] = requestId }
        if let generation { body["execution_generation"] = generation }
        _ = try await json("/m/turns/\(Self.esc(run))/approval", method: "POST", body: body)
    }

    /// Turns still running on the Mac (to re-attach after the app was killed).
    func liveTurns() async throws -> [LiveTurn] {
        struct R: Decodable { let turns: [LiveTurn] }
        return try await get("/m/turns", as: R.self).turns
    }

    /// Server-sent events for a run, resuming after `lastSeq` (the gateway replays its backlog).
    func events(profile: String, run: String, after lastSeq: Int?, epoch: String? = nil,
                routeRevision: UInt64) -> AsyncThrowingStream<RunEvent, Error> {
        // A slow UI catches up from its last applied ID instead of buffering unlimited tokens.
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(256)) { continuation in
            // Freeze the account's URL and bearer together before starting transport work.
            let r: URLRequest
            do {
                var request = try self.request("/m/turns/\(Self.esc(run))/events")
                request.timeoutInterval = 45
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                request.setValue("checkpoint-v1", forHTTPHeaderField: "X-Hermes-Replay")
                if let epoch { request.setValue(epoch, forHTTPHeaderField: "X-Hermes-Replay-Epoch") }
                if let lastSeq { request.setValue(String(lastSeq), forHTTPHeaderField: "Last-Event-ID") }
                r = request
            } catch {
                continuation.finish(throwing: error)
                return
            }
            let task = Task {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { [self] in
                        do {
                            let (bytes, resp) = try await streamSession.bytes(for: r)
                            guard let http = resp as? HTTPURLResponse else { throw APIError.badResponse }
                            guard http.statusCode == 200 else { throw APIError.http(http.statusCode, "") }  // 404 = turn gone
                            let wireEpoch = http.value(forHTTPHeaderField: "X-Hermes-Replay-Epoch")
                            for try await line in bytes.lines {
                                guard line.hasPrefix("data:") else { continue }
                                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                                guard let d = payload.data(using: .utf8),
                                      let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                                let name = (obj["event"] as? String) ?? (obj["type"] as? String) ?? ""
                                let event = RunEvent(seq: obj["seq"] as? Int, name: name, raw: obj, replayEpoch: wireEpoch)
                                switch continuation.yield(event) {
                                case .enqueued: break
                                case .dropped:
                                    continuation.finish(throwing: URLError(.networkConnectionLost))
                                    return
                                case .terminated: return
                                @unknown default: return
                                }
                            }
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                    group.addTask {
                        for await _ in StreamRoutes.shared.changes(after: routeRevision) {
                            guard !Task.isCancelled else { return }
                            continuation.finish(throwing: StreamRouteChanged())
                            return
                        }
                    }
                    await group.next()
                    group.cancelAll()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

enum Keychain {
    private static let service = Bundle.main.bundleIdentifier ?? "HermesMobile"

    static func write(_ key: String, _ value: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: key]
        let data: [String: Any] = [kSecValueData as String: Data(value.utf8),
                                   kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, data as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        return SecItemAdd(query.merging(data) { _, new in new } as CFDictionary, nil) == errSecSuccess
    }

    static func read(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func delete(_ key: String) -> Bool {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key]
        let status = SecItemDelete(q as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

extension WorkspaceClient {
    static func live(project: String) -> WorkspaceClient {
        let api = API.shared
        return WorkspaceClient(
            detail: { try await api.workspaceDetail(project: project) },
            saveInstructions: { try await api.saveWorkspaceInstructions(project: project, text: $0, revision: $1) },
            addFile: { try await api.addWorkspaceFile(project: project, name: $0, data: $1) },
            deleteFile: { try await api.deleteWorkspaceFile(project: project, id: $0) },
            createChat: { try await api.createWorkspaceChat(project: project, profile: $0, title: $1) },
            saveAssignment: { try await api.saveWorkspaceAssignment(project: project, profiles: $0, revision: $1) },
            fileContent: { try await api.workspaceFileContent(project: project, id: $0) },
            saveFile: { try await api.saveWorkspaceFile(project: project, id: $0, content: $1, sha: $2) })
    }
}
extension API {
    /// Raw status + body for the owner-management routes (they map `code` themselves). Never logs bodies.
    func manageRaw(_ path: String, method: String, body: Any?) async throws -> (Int, Data) {
        var r = try request(path, method: method, body: body)
        r.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, resp) = try await session.data(for: r)
        guard let http = resp as? HTTPURLResponse else { throw APIError.badResponse }
        return (http.statusCode, data)
    }
}
