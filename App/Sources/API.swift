import Foundation
import Security

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
final class API: @unchecked Sendable {
    static let shared = API()

    var baseURL: URL? {
        get { UserDefaults.standard.string(forKey: "server").flatMap(URL.init(string:)) }
        set { UserDefaults.standard.set(newValue?.absoluteString, forKey: "server") }
    }
    var token: String? {
        get { Keychain.read("token") }
        set { if let newValue { Keychain.write("token", newValue) } else { Keychain.delete("token") } }
    }
    var isSignedIn: Bool { baseURL != nil && token != nil }

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 60
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()
    private let streamSession: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 900
        c.timeoutIntervalForResource = 3600
        return URLSession(configuration: c)
    }()

    // MARK: plumbing

    private func request(_ path: String, method: String = "GET", body: Any? = nil, auth: Bool = true) throws -> URLRequest {
        guard let base = baseURL, let url = URL(string: path, relativeTo: base) else { throw APIError.notSignedIn }
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

    func signIn(server: URL, username: String, password: String, device: String) async throws {
        baseURL = server
        let r = try request("/m/login", method: "POST", body: ["username": username, "password": password, "device": device], auth: false)
        let data = try await send(r)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any], let t = obj["token"] as? String else {
            throw APIError.badResponse
        }
        token = t
    }

    func signOut() { token = nil }

    // MARK: reads

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

    private func workspaceGET(_ path: String) async throws -> Data {
        var r = try request(path)
        r.timeoutInterval = 15
        r.cachePolicy = .reloadIgnoringLocalCacheData
        return try await send(r)
    }

    func workspaceIndex() async throws -> WorkspaceIndex {
        try await workspaceCall { try WorkspaceIndex.decode(try await workspaceGET("/m/workspaces")) }
    }

    func workspaceDetail(project: String) async throws -> WorkspaceDetail {
        try await workspaceCall { try WorkspaceDetail.decode(try await workspaceGET("/m/workspaces/\(Self.esc(project))")) }
    }

    func saveWorkspaceInstructions(project: String, text: String) async throws {
        try WorkspaceValidation.checkInstructions(text)
        try await workspaceCall {
            let o = try await json("/m/workspaces/\(Self.esc(project))/instructions", method: "PUT", body: ["instructions": text])
            guard o["ok"] as? Bool == true else { throw APIError.badResponse }
        }
    }

    func addWorkspaceFile(project: String, name: String, data: Data) async throws -> WorkspaceFile {
        try await workspaceCall {
            let body = try await send(try request("/m/workspaces/\(Self.esc(project))/files", method: "POST",
                                                  body: WorkspaceValidation.fileBody(name: name, data: data)))
            guard let f = try? JSONDecoder().decode(WorkspaceFile.self, from: body) else { throw APIError.badResponse }
            return f
        }
    }

    func deleteWorkspaceFile(project: String, id: String) async throws {
        try await workspaceCall {
            let o = try await json("/m/workspaces/\(Self.esc(project))/files/\(Self.esc(id))", method: "DELETE", body: nil)
            guard o["ok"] as? Bool == true else { throw APIError.badResponse }
        }
    }

    func createWorkspaceChat(project: String, profile: String, title: String?) async throws -> WorkspaceChat {
        try await workspaceCall {
            var b: [String: Any] = ["profile": profile]
            if let title { b["title"] = title }
            let body = try await send(try request("/m/workspaces/\(Self.esc(project))/chats", method: "POST", body: b))
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

    func sessions(cursor: String?, profile: String? = nil, exclude: [String] = [], telegram: Bool = false) async throws -> SessionPage {
        let limit = cursor == nil ? 16 : 40
        var q = ["limit=\(limit)", "view=compact"]
        if let cursor { q.append("cursor=\(cursor)") }
        if let profile { q.append("profile=\(Self.esc(profile))") }
        if !exclude.isEmpty { q.append("exclude=\(exclude.joined(separator: ","))") }
        let path = telegram ? "/m/telegram?" : "/m/sessions?"
        return try await get(path + q.joined(separator: "&"), as: SessionPage.self)
    }
    func search(_ text: String, archived: Bool = false, profile: String? = nil, telegram: Bool = false) async throws -> [SessionSummary] {
        var components = URLComponents()
        components.path = "/m/search"
        var query = [URLQueryItem(name: "q", value: text)]
        if archived { query.append(URLQueryItem(name: "archived", value: "1")) }
        if let profile { query.append(URLQueryItem(name: "profile", value: profile)) }
        if telegram { query.append(URLQueryItem(name: "source", value: "telegram")) }
        components.queryItems = query
        // Form-style query decoders interpret literal plus signs as spaces.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let path = components.string else { throw APIError.badResponse }
        return try await get(path, as: SearchPage.self).data
    }
    func messages(profile: String, session: String, limit: Int = 100, offset: Int = 0) async throws -> [StoredMessage] {
        try await get(p(profile, "/api/sessions/\(Self.esc(session))/messages?limit=\(limit)&offset=\(offset)&order=latest"), as: MessagesPage.self).data
    }
    func catalog(profile: String) async throws -> ModelCatalog {
        try await get(p(profile, "/api/model/options"), as: ModelCatalog.self)
    }
    func served(profile: String, session: String) async throws -> ServedRuntime {
        try await get("/m/runtime/\(Self.esc(profile))/\(Self.esc(session))", as: ServedRuntime.self)
    }

    // MARK: writes

    /// Create a chat the way the desktop app does (canonical `session.create`, source `gui`),
    /// so it lands in the desktop's Recents and model/effort switches persist on it.
    func createSession(profile: String) async throws -> String {
        let obj = try await json("/m/chat/\(Self.esc(profile))/new", method: "POST", body: [:])
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
    func lockRuntime(profile: String, session: String, choice: RuntimeChoice, previous: RuntimeChoice? = nil) async throws {
        let body = Self.choiceBody(choice, previous: previous)
        guard !body.isEmpty else { return }
        _ = try await json("/m/chat/\(Self.esc(profile))/\(Self.esc(session))/runtime", method: "POST", body: body)
    }

    /// Start a turn. The Mac holds it; it keeps running if the phone locks or loses signal.
    func startRun(profile: String, session: String, text: String, choice: RuntimeChoice,
                  projectContext: String? = nil) async throws -> String {
        var body = Self.choiceBody(choice)
        body["text"] = text
        ProjectContext.apply(to: &body, projectID: projectContext)
        let obj = try await json("/m/chat/\(Self.esc(profile))/\(Self.esc(session))/send", method: "POST", body: body)
        guard let id = obj["turn_id"] as? String else { throw APIError.badResponse }
        return id
    }

    func followUp(run: String, mode: String, text: String, submission: UUID) async throws {
        let result = try await json("/m/turns/\(Self.esc(run))/\(mode)", method: "POST",
                                    body: ["text": text, "submission_id": submission.uuidString])
        let expected = mode == "queue" ? "queued" : "steer_accepted"
        guard result["status"] as? String == expected else { throw APIError.badResponse }
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
    func events(profile: String, run: String, after lastSeq: Int?) -> AsyncThrowingStream<RunEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var r = try request("/m/turns/\(Self.esc(run))/events")
                    r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    if let lastSeq { r.setValue(String(lastSeq), forHTTPHeaderField: "Last-Event-ID") }
                    let (bytes, resp) = try await streamSession.bytes(for: r)
                    guard let http = resp as? HTTPURLResponse else { throw APIError.badResponse }
                    guard http.statusCode == 200 else { throw APIError.http(http.statusCode, "") }  // 404 = turn gone
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard let d = payload.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                        let name = (obj["event"] as? String) ?? (obj["type"] as? String) ?? ""
                        continuation.yield(RunEvent(seq: obj["seq"] as? Int, name: name, raw: obj))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

enum Keychain {
    private static let service = Bundle.main.bundleIdentifier ?? "HermesMobile"

    static func write(_ key: String, _ value: String) {
        delete(key)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key, kSecValueData as String: Data(value.utf8),
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func read(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func delete(_ key: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
    }
}

extension WorkspaceClient {
    static func live(project: String) -> WorkspaceClient {
        WorkspaceClient(
            detail: { try await API.shared.workspaceDetail(project: project) },
            saveInstructions: { try await API.shared.saveWorkspaceInstructions(project: project, text: $0) },
            addFile: { try await API.shared.addWorkspaceFile(project: project, name: $0, data: $1) },
            deleteFile: { try await API.shared.deleteWorkspaceFile(project: project, id: $0) },
            createChat: { try await API.shared.createWorkspaceChat(project: project, profile: $0, title: $1) })
    }
}
