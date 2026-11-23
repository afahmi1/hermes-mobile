import Foundation

// Network side of owner management: /m/manage/* (docs/build5-contract.md, slice B).
// Paths carry only ids (percent-escaped); the deletion PIN goes only in the JSON body.

extension API {
    private static func manageEsc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? s
    }

    private func manageCall(_ path: String, method: String = "GET", body: Any? = nil) async throws -> Data {
        let status: Int, data: Data
        do { (status, data) = try await manageRaw(path, method: method, body: body) }
        catch is CancellationError { throw CancellationError() }
        catch let e as URLError where e.code == .cancelled { throw e }
        catch APIError.notSignedIn { throw ManageFailure.signedOut }
        catch APIError.badResponse { throw ManageFailure.malformed }
        catch { throw ManageFailure.classify(error) }
        guard (200..<300).contains(status) else { throw ManageFailure.from(status: status, data: data) }
        return data
    }

    func manageBots() async throws -> ManageBotsInfo { try ManageBotsInfo.decode(try await manageCall("/m/manage/bots")) }
    func manageArchived() async throws -> ArchivedInfo { try ArchivedInfo.decode(try await manageCall("/m/manage/archived")) }

    func manageCreateProject(_ draft: ProjectDraft) async throws -> Project {
        try ManageEnvelope.project(try await manageCall("/m/manage/projects", method: "POST", body: draft.body))
    }

    func manageEditProject(id: String, title: String, summary: String) async throws {
        _ = try await manageCall("/m/manage/projects/\(Self.manageEsc(id))", method: "PATCH", body: ["title": title, "summary": summary])
    }

    func manageArchiveProject(id: String, pin: String) async throws {
        _ = try await manageCall("/m/manage/projects/\(Self.manageEsc(id))/archive", method: "POST", body: ["pin": pin])
    }

    func manageRestoreProject(id: String) async throws {
        _ = try await manageCall("/m/manage/projects/\(Self.manageEsc(id))/restore", method: "POST", body: [String: Any]())
    }

    func manageCreateBot(name: String, persona: String, host: String) async throws -> ManagedPersona {
        try ManageEnvelope.persona(try await manageCall("/m/manage/bots", method: "POST",
                                                        body: ["name": name, "persona": persona, "host": host]))
    }

    func manageArchiveBot(id: String, pin: String) async throws {
        _ = try await manageCall("/m/manage/bots/\(Self.manageEsc(id))/archive", method: "POST", body: ["pin": pin])
    }

    func manageRestoreBot(id: String) async throws {
        _ = try await manageCall("/m/manage/bots/\(Self.manageEsc(id))/restore", method: "POST", body: [String: Any]())
    }

    /// Creates a session on the persona's host and links it; returns (profile, sessionId) to open.
    func manageNewPersonaChat(id: String, fallbackHost: String) async throws -> (profile: String, session: String) {
        let data = try await manageCall("/m/manage/bots/\(Self.manageEsc(id))/chats", method: "POST", body: [String: Any]())
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sid = (o["session_id"] as? String) ?? (o["id"] as? String), !sid.isEmpty else { throw ManageFailure.malformed }
        let profile = (o["profile"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackHost
        return (profile, sid)
    }

    /// Whether this Mac has a deletion PIN (owner only). Never returns anything about the PIN itself.
    func managePinConfigured() async throws -> Bool {
        let data = try await manageCall("/m/manage/pin")
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let c = o["configured"] as? Bool
        else { throw ManageFailure.malformed }
        return c
    }

    /// First set or change of the deletion PIN; the values go only in the JSON body.
    func manageSetPin(_ body: [String: String]) async throws {
        _ = try await manageCall("/m/manage/pin", method: "POST", body: body)
    }
}
