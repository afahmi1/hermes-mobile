import Foundation
import Observation

/// A lenient view over JSON from the Mac's status dashboard. The dashboard discovers bots, cron jobs and
/// running agents fresh on every call and may grow new fields; reading through this wrapper means a new
/// field or a slightly different type never breaks the app.
struct JV: Hashable {
    let raw: AnyHashable?

    init(_ any: Any?) {
        switch any {
        case let d as [String: Any]: raw = d.mapValues { JV($0) } as [String: JV]
        case let a as [Any]: raw = a.map { JV($0) }
        case let n as NSNumber:
            raw = CFGetTypeID(n) == CFBooleanGetTypeID() ? AnyHashable(n.boolValue) : AnyHashable(n.doubleValue)
        case let s as String: raw = s
        default: raw = nil
        }
    }

    subscript(_ key: String) -> JV { JV(raw: (raw as? [String: JV])?[key]?.raw) }
    private init(raw: AnyHashable?) { self.raw = raw }

    var array: [JV] { (raw as? [JV]) ?? [] }
    var string: String? {
        if let s = raw as? String { return s.isEmpty ? nil : s }
        if let d = raw as? Double { return d == d.rounded() ? String(Int(d)) : String(d) }
        return nil
    }
    var double: Double? { (raw as? Double) ?? (raw as? String).flatMap(Double.init) }
    var int: Int? { double.map { Int($0) } }
    var bool: Bool { (raw as? Bool) ?? ((raw as? Double).map { $0 != 0 } ?? false) }
    var isNull: Bool { raw == nil }

    /// ISO-8601 timestamps as the dashboard writes them (with or without fractional seconds).
    var date: Date? {
        guard let s = raw as? String else { return nil }
        return JV.iso.date(from: s) ?? JV.isoPlain.date(from: s)
    }
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let isoPlain = ISO8601DateFormatter()
}

/// The Mac's status, polled by the app. Fast while the Status tab is open, slow otherwise, so the tab
/// badge and the bot lists stay current: a bot or cron job created on the Mac shows up on its own.
@MainActor @Observable
final class StatusModel {
    var payload: JV?
    var updatedAt: Date?
    var error: String?
    var visible = false
    var refreshingProviders = false
    /// The newest "added"/"removed" event the user has seen on the Status tab.
    /// nil until the first payload: that one becomes the baseline, so old events never show as unseen.
    var seenEventsUntil: Date? = UserDefaults.standard.object(forKey: "status.seenEvents") as? Date {
        didSet { UserDefaults.standard.set(seenEventsUntil, forKey: "status.seenEvents") }
    }
    /// Shown briefly when something new appears while the app is open.
    var announcement: String?
    var announceTick = 0

    private var lastBotKey: String?
    private var lastEventAt: Date?

    var events: [JV] { payload?["changes"]["events"].array ?? [] }
    var unseenEvents: Int {
        guard let seen = seenEventsUntil else { return 0 }
        return events.filter { ($0["at"].date ?? .distantPast) > seen }.count
    }
    var newestEventAt: Date? { events.compactMap { $0["at"].date }.max() }
    var incidents: Int { payload?["jobs"]["incidents"].array.count ?? 0 }
    var badge: Int { incidents + unseenEvents }

    private var refreshID: UUID?
    private var forcingRefresh = false

    func refresh(force: Bool = false, app: AppModel) async {
        if refreshID != nil && (!force || forcingRefresh) { return }
        let id = UUID()
        refreshID = id
        forcingRefresh = force
        defer { if refreshID == id { refreshID = nil; forcingRefresh = false } }
        do {
            let p = try await API.shared.status(refreshProviders: force)
            guard refreshID == id, !Task.isCancelled, app.signedIn else { return }
            payload = p
            updatedAt = Date()
            error = nil
            noticeChanges(p, app: app)
        } catch {
            guard refreshID == id, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    func markSeen() {
        if let newest = newestEventAt, newest > (seenEventsUntil ?? .distantPast) { seenEventsUntil = newest }
    }

    /// Forget everything from the previous sign-in (it may have been a different Mac).
    func reset() {
        refreshID = nil
        forcingRefresh = false
        payload = nil
        updatedAt = nil
        error = nil
        announcement = nil
        lastBotKey = nil
        lastEventAt = nil
        seenEventsUntil = nil
    }

    private func noticeChanges(_ p: JV, app: AppModel) {
        if seenEventsUntil == nil { seenEventsUntil = newestEventAt ?? Date() }  // first payload: baseline
        // Refresh the app's bot list whenever a bot appears, goes, is renamed or becomes reachable (the
        // bridge gives a new bot its key a little after it shows up), so the Bots tab and New chat follow.
        let key = p["bots"].array.map { b in
            [b["id"].string, b["name"].string, b["served"].bool ? "s" : "", b["api_key"].bool ? "k" : ""]
                .compactMap { $0 }.joined(separator: "|")
        }.sorted().joined(separator: ",")
        if let last = lastBotKey, key != last { Task { await app.refreshBots() } }
        lastBotKey = key
        // Announce everything that happened since the last poll (one banner, summarized).
        let all = p["changes"]["events"].array
        if let last = lastEventAt {
            let fresh = all.filter { ($0["at"].date ?? .distantPast) > last }
            if !fresh.isEmpty {
                let first = fresh.first(where: { $0["kind"].string == "bot" }) ?? fresh[0]
                let verb = ["removed": "Removed", "renamed": "Renamed"][first["type"].string ?? ""] ?? "New"
                var text = "\(verb) \(first["kind"].string ?? "item"): \(first["name"].string ?? "")"
                if fresh.count > 1 { text += " and \(fresh.count - 1) more" }
                announcement = text
                announceTick += 1
            }
        }
        lastEventAt = max(newestEventAt ?? .distantPast, lastEventAt ?? .distantPast)
    }

    /// Runs for the app's lifetime: every 5 s while the Status tab is on screen, every 30 s otherwise.
    func poll(app: AppModel) async {
        var last = Date.distantPast
        while !Task.isCancelled {
            // Re-check every second, so opening the Status tab switches to the fast cadence right away.
            if app.signedIn, Date().timeIntervalSince(last) >= (visible ? 5 : 30) {
                last = Date()
                await refresh(app: app)
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}
