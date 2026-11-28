#if DEBUG
import Foundation

/// Screenshot QA (debug builds only). `-HMDemo 1` signs in to a fixture gateway that lives in this file:
/// every request to it is answered by `DemoURLProtocol`, so nothing reaches the network, the Keychain or the
/// Mac's bridge, and no token is issued anywhere. Release builds compile none of this.
///
/// - `-HMOpenChat default/demo-thermocline` opens the demo conversation (existing DEBUG hook).
/// - `-HMDemoDraft 1` puts a draft in that chat's composer, so the send button shows its live state.
/// - `-HMDemoFallback 1` makes a different model the last to answer, so the chat header names both models.
/// - `-HMDemoLive 1` makes that chat's reply still running on the "Mac": a live tool row and the stop button.
/// - `-HMDemoKaomoji 1` (with Live) adds a Hermes-style status for checking the Kawaii faces switch.
/// - `-HMDemoApproval 1` (with Live) adds an approval request to the running reply.
/// - `-HMDemoFinishAfter N` (with Live) finishes that reply N seconds after its stream opens. Send the app to the
///   background first and the reply notification fires, as it would on a phone.
enum DemoMode {
    static let origin = URL(string: "https://demo.tail0000.ts.net")!
    static let chatID = "demo-thermocline"
    static let runID = "turn_demo0000000000000000000000000001"

    static var isOn: Bool { flag("HMDemo") }
    static var live: Bool { flag("HMDemoLive") }
    static var approval: Bool { flag("HMDemoApproval") }
    static var draft: Bool { flag("HMDemoDraft") }
    static var finishAfter: TimeInterval? {
        let seconds = UserDefaults.standard.double(forKey: "HMDemoFinishAfter")
        return seconds > 0 ? seconds : nil
    }

    /// The live reply finished (`-HMDemoFinishAfter`): the Mac no longer lists it, and the transcript has the answer.
    static var finished: Bool {
        get { finishedLock.withLock { finishedValue } }
        set { finishedLock.withLock { finishedValue = newValue } }
    }
    private static let finishedLock = NSLock()
    nonisolated(unsafe) private static var finishedValue = false

    private static func flag(_ key: String) -> Bool {
        UserDefaults.standard.bool(forKey: key) || ProcessInfo.processInfo.environment[key] == "1"
    }
}

/// Answers every request while demo mode is on. Unknown routes get a 404 like an older bridge would.
final class DemoURLProtocol: URLProtocol {
    /// Heartbeats for an open event stream, on the loading thread's run loop (where the client must be called).
    private var heartbeat: Timer?

    override class func canInit(with request: URLRequest) -> Bool { DemoMode.isOn }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return fail() }
        let path = url.path
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ name: String) -> String? { query.first { $0.name == name }?.value }
        let method = request.httpMethod ?? "GET"

        if method == "GET", path.hasPrefix("/m/turns/"), path.hasSuffix("/events") {
            return stream(after: request.value(forHTTPHeaderField: "Last-Event-ID").flatMap(Int.init))
        }
        let parts = path.split(separator: "/").map(String.init)
        let body: Any?
        switch (method, parts.first == "m" ? Array(parts.dropFirst()) : parts) {
        case ("GET", ["health"]): body = DemoFixtures.health
        case ("GET", ["status"]): body = DemoFixtures.status()
        case ("GET", ["bots"]): body = ["bots": DemoFixtures.bots]
        case ("GET", ["sessions"]), ("GET", ["desktop"]), ("GET", ["telegram"]):
            if UserDefaults.standard.bool(forKey: "HMDemoEmpty") {
                body = ["data": [Any](), "next": NSNull()]
                break
            }
            if UserDefaults.standard.bool(forKey: "HMDemoError") { return respond(503, ["error": "Demo gateway is unavailable"]) }
            body = ["data": DemoFixtures.sessions(profile: q("profile"), exclude: q("exclude"), source: parts.last), "next": NSNull()]
        case ("GET", ["archived"]): body = ["data": [Any](), "next": NSNull()]
        case ("GET", ["search"]):
            let text = (q("q") ?? "").lowercased()
            body = ["data": DemoFixtures.sessions(profile: q("profile"), exclude: nil, source: nil).filter {
                text.isEmpty || (($0["title"] as? String) ?? "").lowercased().contains(text)
                    || (($0["preview"] as? String) ?? "").lowercased().contains(text)
            }]
        case ("GET", let p) where p.count == 6 && p[0] == "p" && p[2] == "api" && p[3] == "sessions" && p[5] == "messages":
            body = ["data": DemoFixtures.transcript(session: p[4]), "has_more": false, "next_offset": 100]
        case ("GET", let p) where p.count == 5 && p[0] == "p" && p[2] == "api" && p[3] == "model" && p[4] == "options":
            body = DemoFixtures.catalog
        case ("GET", let p) where p.count == 3 && p[0] == "runtime": body = DemoFixtures.runtime
        case ("GET", ["commands"]): body = DemoFixtures.commands
        case ("GET", let p) where p.count == 3 && p[0] == "chat" && p[2] == "media-capabilities":
            body = ["images": true, "files": true, "video": false, "max_file_bytes": 31_457_280, "max_video_bytes": 8_388_608]
        case ("GET", let p) where p.count == 4 && p[0] == "chat" && p[3] == "queue": body = ["pending": [Any](), "paused": false]
        case ("GET", let p) where p.count == 3 && p[0] == "pins":
            body = ["pins": p[2] == DemoMode.chatID ? DemoFixtures.pins : [], "limit": 50]
        case ("GET", ["turns"]):
            body = ["turns": DemoMode.live && !DemoMode.finished
                ? [["turn_id": DemoMode.runID, "profile": "default", "session_id": DemoMode.chatID, "done": false]] : []]
        case ("GET", ["projects"]): body = DemoFixtures.projects
        case ("GET", ["workspaces"]): body = DemoFixtures.workspaceIndex
        case ("GET", let p) where p.count == 2 && p[0] == "workspaces": body = DemoFixtures.workspace(p[1])
        case ("GET", let p) where p.first == "workspace-artifacts": body = ["artifacts": [Any]()]
        case ("GET", ["manage", "bots"]): body = DemoFixtures.manageBots
        case ("GET", ["manage", "archived"]): body = ["projects": [Any](), "bots": [Any]()]
        case ("GET", ["manage", "pin"]): body = ["configured": true]
        case ("GET", ["capabilities"]):
            body = ["features": ["device_grants", "restart_v1"], "device_id": "dev_demo", "manage_devices": true, "can_restart": true]
        case ("POST", ["restart"]):
            body = ["ok": true, "target": "hermes", "mode": "when_idle",
                    "message": "Hermes will restart as soon as nothing is running. Replies in progress finish first."]
        case ("GET", ["devices"]):
            body = ["devices": [["id": "dev_demo", "name": "iPhone", "method": "password",
                                 "expires": Date().addingTimeInterval(150 * 86400).timeIntervalSince1970]]]
        case ("POST", ["push", "presence"]), ("POST", ["push", "token"]): body = ["ok": true]
        default: body = nil
        }
        guard let body else { return respond(404, ["error": "not found"]) }
        respond(200, body)
    }

    override func stopLoading() {
        heartbeat?.invalidate()
        heartbeat = nil
    }

    private func fail() { client?.urlProtocol(self, didFailWithError: URLError(.badURL)) }

    private func respond(_ status: Int, _ object: Any) {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "application/json"]) else { return fail() }
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    /// The live reply: replays its numbered events, then keeps the stream open with heartbeats.
    private func stream(after last: Int?) {
        guard DemoMode.live, !DemoMode.finished, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "text/event-stream",
                                                            "X-Hermes-Replay-Epoch": "demo"]) else {
            return respond(404, ["error": "turn not found"])
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let events = DemoFixtures.events()
        for event in events where (event["seq"] as? Int ?? 0) > (last ?? -1) {
            send(event)
        }
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.client?.urlProtocol(self, didLoad: Data(": keepalive\n\n".utf8))
        }
        RunLoop.current.add(timer, forMode: .common)
        heartbeat = timer
        if let seconds = DemoMode.finishAfter {
            let finish = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
                guard let self, !DemoMode.finished else { return }
                DemoMode.finished = true
                self.send(["event": "run.completed", "seq": events.count, "turn_id": DemoMode.runID,
                           "session_id": DemoMode.chatID, "output": DemoFixtures.finalReply,
                           "runtime": ["model": "claude-opus-5-5", "provider": "anthropic"]])
                self.heartbeat?.invalidate()
                self.client?.urlProtocolDidFinishLoading(self)
            }
            RunLoop.current.add(finish, forMode: .common)
        }
    }

    private func send(_ event: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: event), let line = String(data: data, encoding: .utf8) {
            client?.urlProtocol(self, didLoad: Data("data: \(line)\n\n".utf8))
        }
    }
}

/// Fixture payloads in the bridge's wire shapes. Times are relative to now, so the screenshots read fresh.
enum DemoFixtures {
    private static var now: Double { Date().timeIntervalSince1970 }
    private static func iso(_ offset: TimeInterval) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(offset))
    }

    static let health: [String: Any] = [
        "ok": true, "phase": "running", "gateway_state": "running", "version": "0.11.2",
        "image_attachments": true, "file_attachments": true, "max_file_bytes": 31_457_280,
    ]

    static let bots: [[String: Any]] = [
        ["id": "default", "name": "Muad'Dib", "blurb": "Front door. Quick answers, Mac control and building things.",
         "model": "claude-opus-5-5", "provider": "anthropic", "reachable": true, "front": true,
         "skills": ["thermocline", "hermes-mobile", "swarm-orchestration", "imessage", "github", "macos-native-app"]],
        ["id": "research", "name": "Research", "blurb": "Peer-reviewed evidence, multilingual search and the STEM briefing.",
         "model": "gpt-6.2-sol", "provider": "openai-codex", "reachable": true, "front": false,
         "skills": ["global-literature-search", "arxiv", "grounded-citations"]],
        ["id": "career", "name": "Master Splinter", "blurb": "Job search, FSE2 readiness, resumes and interview prep.",
         "model": "claude-sonnet-5-5", "provider": "anthropic", "reachable": true, "front": false,
         "skills": ["job-outreach-drafting", "docx"]],
        ["id": "3d-printing", "name": "3D Printing", "blurb": "Turns requests and photos into print-checked STLs.",
         "model": "deepseek-v4-flash", "provider": "deepseek", "reachable": true, "front": false, "skills": ["stone"]],
        ["id": "captains-log", "name": "Captain's Log", "blurb": "The journal. Entries, check-ins and weekly threads.",
         "model": "claude-haiku-5", "provider": "anthropic", "reachable": true, "front": false],
        ["id": "mentat", "name": "Mentat", "blurb": "The 2am scout: catalysts, AI tools and medtech.",
         "model": "gpt-6.2-sol", "provider": "openai-codex", "reachable": true, "front": false],
        ["id": "sandbox", "name": "Sandbox", "blurb": "Scratch profile for experiments.",
         "model": "deepseek-v4-pro", "provider": "deepseek", "reachable": false, "front": false],
    ]

    private static func session(_ id: String, _ profile: String, title: String, preview: String, ago: TimeInterval,
                                model: String, source: String = "gui", via: String? = "mobile_bridge",
                                pinned: Bool = false, pins: Int = 0, count: Int = 12) -> [String: Any] {
        var row: [String: Any] = ["id": id, "profile": profile, "source": source, "model": model, "title": title,
                                  "preview": preview, "started_at": now - ago - 1800, "last_active": now - ago,
                                  "message_count": count, "pinned": pinned, "archived": false, "pin_count": pins]
        if let via { row["created_via"] = via }
        return row
    }

    static func sessions(profile: String?, exclude: String?, source: String?) -> [[String: Any]] {
        let rows: [[String: Any]] = [
            session(DemoMode.chatID, "default", title: "Thermocline polish for Prometheus",
                    preview: "All 412 Python tests pass. The Swift suites are next.", ago: 4 * 60,
                    model: "claude-opus-5-5", pinned: true, pins: 2, count: 11),
            session("demo-grip", "research", title: "Grip strength in 3D-printed finger prostheses",
                    preview: "Six peer-reviewed studies; two report pinch force above 10 N.", ago: 38 * 60,
                    model: "gpt-6.2-sol", source: "telegram", via: nil),
            session("demo-fse2", "career", title: "FSE2 readiness: Q4 plan",
                    preview: "Three gaps left: Ion depth, SP install hours and the FSM shadow week.", ago: 2.2 * 3600,
                    model: "claude-sonnet-5-5"),
            session("demo-stand", "3d-printing", title: "Phone stand v3, 15° tilt",
                    preview: "Sliced at 0.2 mm: 2 h 14 m, 31 g of PETG. STL attached.", ago: 5.4 * 3600,
                    model: "deepseek-v4-flash", source: "bluebubbles", via: nil),
            session("demo-log", "captains-log", title: "Evening log",
                    preview: "Logged. Three entries today, one thread carried to tomorrow.", ago: 26 * 3600,
                    model: "claude-haiku-5", source: "bluebubbles", via: nil),
            session("demo-echo", "default", title: "BlueBubbles echo guard after update",
                    preview: "Reapplied both patches and restarted the gateway with --detach.", ago: 30 * 3600,
                    model: "claude-opus-5-5", source: "cli", via: nil),
            session("demo-scout", "mentat", title: "Medtech catalysts this week",
                    preview: "Two FDA decisions and one CMS rule worth reading before Friday.", ago: 3.2 * 86400,
                    model: "gpt-6.2-sol"),
            session("demo-brief", "research", title: "STEM briefing format",
                    preview: "Shorter abstracts, one figure each, sources at the end.", ago: 5.5 * 86400,
                    model: "gpt-6.2-sol", source: "desktop", via: nil),
            session("demo-review", "default", title: "Weekly review",
                    preview: "Four commitments closed, two moved, one dropped.", ago: 12 * 86400,
                    model: "claude-opus-5-5"),
        ]
        let skip = Set((exclude ?? "").split(separator: ",").map(String.init))
        return rows.filter { row in
            (profile == nil || row["profile"] as? String == profile) && !skip.contains(row["source"] as? String ?? "")
                && (source != "telegram" || row["source"] as? String == "telegram")
                && (source != "desktop" || ["gui", "desktop", "local"].contains(row["source"] as? String ?? ""))
        }
    }

    private static let reply = """
    ## Why the paper reads green

    The lead bloom sits at **13%** over `#E4E0D7`, so deep wing blue pulls the warm paper toward gray-green. \
    Dark mode is fine: the same bloom reads as depth on ink.

    - Light blooms drop to 5%
    - A faint chestnut bloom keeps the stone warm
    - Glass keeps a paper tint, so it never turns white

    ```swift title=DesignSystem.swift
    let lead = Thermocline.lead.opacity(dark ? 0.13 : 0.05)
    let warm = Thermocline.secondary.opacity(dark ? 0 : 0.05)
    ```

    > [!NOTE]
    > Contrast holds: text on surface-1 is 14.9:1 in light and 13.3:1 in dark.
    """

    static func transcript(session: String) -> [[String: Any]] {
        let t0 = now - 46 * 60
        guard session == DemoMode.chatID else {
            let row = sessions(profile: nil, exclude: nil, source: nil).first { $0["id"] as? String == session }
            return [
                ["id": 1, "role": "user", "content": row?["title"] as? String ?? "Hello", "timestamp": now - 3600],
                ["id": 2, "role": "assistant", "content": row?["preview"] as? String ?? "Hi.", "timestamp": now - 3540],
            ]
        }
        func call(_ id: String, _ name: String, _ preview: String) -> [String: Any] {
            ["id": id, "function": ["name": name, "arguments": "{}"], "preview": preview]
        }
        var rows: [[String: Any]] = [
            ["id": 101, "role": "user", "content": "The light canvas reads green-gray on the phone. Can you find out why?",
             "timestamp": t0],
            ["id": 102, "role": "assistant", "content": "", "timestamp": t0 + 20, "tool_calls": [
                call("c1", "read_file", "App/Sources/Views/DesignSystem.swift"),
                call("c2", "search_files", "RadialGradient"),
                call("c3", "terminal", "python3 tokens_check.py")]],
            ["id": 103, "role": "tool", "tool_name": "read_file", "preview": "340 lines", "ok": true, "timestamp": t0 + 24],
            ["id": 104, "role": "tool", "tool_name": "search_files", "preview": "2 matches", "ok": true, "timestamp": t0 + 31],
            ["id": 105, "role": "tool", "tool_name": "terminal", "preview": "52 pairs checked · 0 failures", "ok": true,
             "timestamp": t0 + 98],
            ["id": 106, "role": "assistant", "content": reply, "timestamp": t0 + 110],
            ["id": 107, "role": "user", "content": "Good. Pin that, then run the Python suite.", "timestamp": now - 14 * 60],
            ["id": 108, "role": "assistant", "content": "", "timestamp": now - 14 * 60 + 8, "tool_calls": [
                call("c4", "terminal", "python -m unittest discover -s Tests")]],
            ["id": 109, "role": "tool", "tool_name": "terminal", "preview": "Ran 412 tests in 38.2s · OK", "ok": true,
             "timestamp": now - 13 * 60],
            ["id": 110, "role": "assistant",
             "content": "All **412** Python tests pass under both interpreters. The Swift suites take about four minutes.",
             "timestamp": now - 12 * 60 - 30],
        ]
        if DemoMode.live {
            rows.append(["id": 111, "role": "user", "content": "Run the Swift suites, then push if they pass.",
                         "timestamp": now - 3 * 60])
            if DemoMode.finished {
                rows.append(["id": 112, "role": "assistant", "content": finalReply, "timestamp": now - 5])
            }
        }
        return rows
    }

    /// What the live reply says when `-HMDemoFinishAfter` ends it.
    static let finalReply = "All 19 Swift suites pass on the iPhone 18 Pro simulator. Pushed four commits to feat/thermocline."

    static var pins: [[String: Any]] {
        [
            ["message_id": 106, "role": "assistant", "pinned_at": now - 13 * 60, "message_at": now - 44 * 60,
             "text": "Why the paper reads green: the lead bloom sits at 13% over the warm paper, so light blooms drop to 5%."],
            ["message_id": 101, "role": "user", "pinned_at": now - 40 * 60, "message_at": now - 46 * 60,
             "text": "The light canvas reads green-gray on the phone. Can you find out why?"],
        ]
    }

    static func events() -> [[String: Any]] {
        var list: [[String: Any]] = [
            ["event": "run.started", "seq": 0, "turn_id": DemoMode.runID],
            ["event": "tool.started", "seq": 1, "tool_name": "terminal", "preview": "Tests/run-swift.sh"],
        ]
        if UserDefaults.standard.bool(forKey: "HMDemoKaomoji") {
            list.append(["event": "reasoning.delta", "seq": list.count, "delta": "(◔_◔) Comparing the colors on Light and Dark."])
            list.append(["event": "status", "seq": list.count, "text": "(｡◕‿◕｡) Checking colors…"])
        }
        if DemoMode.approval {
            list.append(["event": "approval.request", "seq": list.count, "request_id": "apr_demo_push",
                         "command": "git push origin feat/thermocline",
                         "description": "Push four commits to the open pull request branch.",
                         "choices": ["once", "session", "deny"]])
        }
        return list
    }

    static let catalog: [String: Any] = [
        "model": "claude-opus-5-5", "provider": "anthropic",
        "providers": [
            ["slug": "anthropic", "name": "Anthropic", "authenticated": true, "is_current": true,
             "models": ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5"],
             "capabilities": ["claude-opus-5-5": ["reasoning": true], "claude-sonnet-5-5": ["reasoning": true]]],
            ["slug": "openai-codex", "name": "OpenAI Codex", "authenticated": true,
             "models": ["gpt-6.2-sol", "gpt-6.2-astra"]],
            ["slug": "deepseek", "name": "DeepSeek", "authenticated": true, "models": ["deepseek-v4-pro", "deepseek-v4-flash"]],
        ],
    ]

    static var runtime: [String: Any] {
        var runtime: [String: Any] = [
            "model": "claude-opus-5-5", "provider": "anthropic", "reasoning_tokens": 18_200, "fallback_active": false,
            "policy": ["model": "claude-opus-5-5", "provider": "anthropic", "effort": "high"],
            "models_used": [["model": "claude-opus-5-5", "provider": "anthropic", "calls": 14, "reasoning_tokens": 18_200],
                            ["model": "deepseek-v4-flash", "provider": "deepseek", "calls": 2]],
            "cost": ["usd": 0, "included": true, "included_api_usd": 1.84, "unknown": false],
        ]
        if UserDefaults.standard.bool(forKey: "HMDemoFallback") {
            runtime["last_answer"] = ["model": "grok-4.7", "provider": "xai", "at": now - 240]
        }
        return runtime
    }

    static let commands: [String: Any] = [
        "commands": [
            ["name": "learn", "description": "Learn a reusable skill from what you describe, a URL, or this chat",
             "hint": "<what to learn from>", "category": "Tools & Skills"],
            ["name": "status", "description": "Session and gateway status", "hint": "", "category": "Status"],
            ["name": "usage", "description": "Token use for this chat", "hint": "", "category": "Status"],
            ["name": "compress", "description": "Summarize earlier turns to free context", "hint": "", "category": "Session"],
            ["name": "goal", "description": "Set or show the goal for this chat", "hint": "<goal>", "category": "Session"],
            ["name": "title", "description": "Rename this chat", "hint": "<title>", "category": "Session"],
        ],
        "skills": ["thermocline", "hermes-mobile", "github", "swarm-orchestration"],
        "skill_details": [
            ["name": "thermocline", "category": "design", "description": "Apply Abduel's visual signature."],
            ["name": "hermes-mobile", "category": "software-development", "description": "Test and ship Prometheus."],
            ["name": "github", "category": "software-development", "description": "PRs, issues and reviews with gh."],
            ["name": "swarm-orchestration", "category": "", "description": "Plan, delegate and check real work."],
        ],
    ]

    static func status() -> [String: Any] {
        let jobs: [[String: Any]] = [
            ["name": "STEM briefing", "profile": "research", "schedule": "every day 6:30 AM", "next_run_at": iso(15 * 3600),
             "last_status": "failed", "failure_streak": 2, "last_error": "HTTP 429 from the arXiv export API",
             "paused": false],
            ["name": "Relay drain", "profile": "default", "schedule": "every 2 min", "next_run_at": iso(70),
             "last_status": "ok", "paused": false],
            ["name": "Captain's Log check-in", "profile": "captains-log", "schedule": "every day 9:00 PM",
             "next_run_at": iso(3 * 3600), "last_status": "ok", "paused": false],
            ["name": "Mentat 2am scout", "profile": "mentat", "schedule": "every day 2:00 AM", "next_run_at": iso(10 * 3600),
             "last_status": "ok", "paused": false],
            ["name": "Palace nightly sync", "profile": "default", "schedule": "every day 3:00 AM",
             "next_run_at": iso(11 * 3600), "last_status": "ok", "paused": false],
            ["name": "Weekly review", "profile": "default", "schedule": "Sundays 6:00 PM", "next_run_at": iso(3 * 86400),
             "last_status": "ok", "paused": false],
            ["name": "Price watch: filament", "profile": "3d-printing", "schedule": "every 6 hours", "last_status": "ok",
             "paused": true, "paused_reason": "Paused from the phone on Nov 20"],
        ]
        let recent: [[String: Any]] = [
            ["name": "Relay drain", "status": "ok", "profile": "default", "claimed_at": iso(-50)],
            ["name": "STEM briefing", "status": "failed", "profile": "research", "claimed_at": iso(-9 * 3600),
             "error": "HTTP 429 from the arXiv export API"],
            ["name": "Mentat 2am scout", "status": "ok", "profile": "mentat", "claimed_at": iso(-14 * 3600)],
            ["name": "Captain's Log check-in", "status": "ok", "profile": "captains-log", "claimed_at": iso(-21 * 3600)],
        ]
        let providers: [[String: Any]] = [
            ["provider": "anthropic", "is_default": true, "credentials": [["label": "oauth"]],
             "usage": ["plan": "Max", "checked_at": iso(-120),
                       "windows": [["label": "5-hour", "used_percent": 18, "resets_at": iso(2.5 * 3600)],
                                   ["label": "Weekly", "used_percent": 62, "resets_at": iso(4 * 86400)]]],
             "local_usage": ["calls": 4820, "sessions": 212, "input_tokens": 182_000_000, "output_tokens": 6_100_000,
                             "last_seen": now - 60]],
            ["provider": "openai-codex", "credentials": [["label": "oauth"]],
             "usage": ["plan": "Pro", "checked_at": iso(-120),
                       "windows": [["label": "Weekly", "used_percent": 84, "resets_at": iso(2 * 86400 + 3600)]]],
             "local_usage": ["calls": 1310, "sessions": 74, "input_tokens": 41_000_000, "output_tokens": 2_300_000,
                             "last_seen": now - 3 * 3600]],
            ["provider": "deepseek", "credentials": [["label": "key"], ["label": "key"]],
             "usage": ["key_count": 2, "keys_reporting": 2, "checked_at": iso(-120),
                       "spend": ["usage_monthly": ["usd": 3.42, "reporting": 2]],
                       "balance": ["remaining": 18.2, "currency": "USD"]],
             "local_usage": ["calls": 960, "sessions": 88, "input_tokens": 12_000_000, "output_tokens": 900_000,
                             "last_seen": now - 5 * 3600]],
            ["provider": "fireworks", "historical_only": true,
             "local_usage": ["calls": 44, "sessions": 6, "input_tokens": 310_000, "output_tokens": 22_000,
                             "last_seen": now - 40 * 86400]],
        ]
        return [
            "gateway": ["health": "healthy", "heartbeat_age_s": 3, "state": "running", "started_at": iso(-2 * 86400 - 3 * 3600),
                        "session_store": "ok", "version": "0.11.2", "sha": "5c7bee0", "estop": [Any](), "reasons": [Any](),
                        "platforms": [["name": "iMessage", "state": "connected"], ["name": "Telegram", "state": "connected"],
                                      ["name": "API server", "state": "connected"]]],
            "agents": (DemoMode.live
                ? [["kind": "phone", "title": "Thermocline polish for Prometheus", "profile": "default",
                    "model": "claude-opus-5-5", "started_at": iso(-180), "session_id": DemoMode.chatID]] : [])
                + [["kind": "cron", "title": "Relay drain", "profile": "default", "model": "deepseek-v4-flash",
                    "started_at": iso(-20)],
                   ["kind": "subagent", "title": "Render light and dark contact sheets", "profile": "default",
                    "model": "deepseek-v4-flash", "started_at": iso(-95), "parent_session_id": "demo-echo"]],
            "jobs": [
                "jobs": jobs, "recent": recent,
                "incidents": [["name": "STEM briefing", "state": "open", "profile": "research", "failure_type": "rate limit",
                               "error": "HTTP 429 from the arXiv export API"]],
                "tokens_24h": [["model": "claude-opus-5-5", "runs": 31, "prompt": 1_420_000, "completion": 96_000],
                               ["model": "gpt-6.2-sol", "runs": 6, "prompt": 380_000, "completion": 41_000],
                               ["model": "deepseek-v4-flash", "runs": 12, "prompt": 210_000, "completion": 18_000]],
            ],
            "bots": bots.map { b -> [String: Any] in
                ["id": b["id"] ?? "", "name": b["name"] ?? "", "served": true, "api_key": b["reachable"] ?? false,
                 "new": (b["id"] as? String) == "3d-printing"]
            },
            "changes": ["events": [
                ["type": "added", "kind": "bot", "name": "3d-printing", "profile": "3d-printing", "at": iso(-2 * 86400)],
                ["type": "renamed", "kind": "cron", "name": "Captain's Log check-in", "old_name": "Journal nudge",
                 "profile": "captains-log", "at": iso(-3 * 86400)],
            ]],
            "providers": ["default_provider": "anthropic", "fetched_at": iso(-120), "providers": providers,
                          "ledger": ["profiles_read": 7, "profiles_unavailable": 0]],
        ]
    }

    static let projects: [String: Any] = [
        "schema_version": 1, "configured": true,
        "roots": [["id": "repos", "label": "Repos", "kind": "repo"], ["id": "vault", "label": "Vault", "kind": "vault"]],
        "projects": [
            ["id": "prometheus", "title": "Prometheus", "summary": "Native iPhone remote for Hermes. Build 33 ships Thermocline.",
             "bot_ids": ["default"], "sources": [["provider": "github", "source": "afahmi1/hermes-mobile"]],
             "related_files": [["root": "repos", "path": "hermes-mobile/DESIGN.md"],
                               ["root": "repos", "path": "hermes-mobile/App/Sources/Views/DesignSystem.swift"]]],
            ["id": "thermocline", "title": "Thermocline",
             "summary": "The visual signature: bird-measured palette, glass and depth, light and dark as a pair.",
             "bot_ids": ["default"], "managed": true, "sources": [["provider": "github", "source": "afahmi1/thermocline"]],
             "related_files": [["root": "vault", "path": "topics/thermocline.md"]]],
            ["id": "bme-207", "title": "BME 207 grip study",
             "summary": "Design of experiments on 3D-printed prosthetic finger grip strength.",
             "bot_ids": ["research", "3d-printing"], "sources": [["provider": "vault", "source": "school/bme-207"]]],
            ["id": "fse2", "title": "FSE2 readiness", "summary": "Gaps, evidence and the path to Field Service Manager.",
             "bot_ids": ["career"]],
            ["id": "birds", "title": "Local birds", "summary": "Field notes and photos for the personal site.",
             "bot_ids": ["research"]],
        ],
    ]

    static let workspaceIndex: [String: Any] = [
        "projects": ["prometheus", "thermocline"], "profiles": ["default", "research"], "mode": "owner",
        "workspaces": [["id": "prometheus", "assigned": ["default"], "eligible": ["default", "research"]],
                       ["id": "thermocline", "assigned": ["default"], "eligible": ["default"]]],
    ]

    static func workspace(_ id: String) -> [String: Any] {
        [
            "instructions": "Keep the native layout. Thermocline colors, type and motion only.",
            "files": [["id": "f1", "name": "palette.md", "size": 2140, "sha": "a1", "editable": true]],
            "chats": [["profile": "default", "session_id": DemoMode.chatID, "title": "Thermocline polish for Prometheus"]],
            "artifacts": [Any](), "profiles": ["default", "research"], "mode": "owner", "editable": true,
            "assignment": ["editable": true, "revision": 1, "assigned": ["default"], "inactive": [Any](),
                           "eligible": ["default", "research"]],
        ]
    }

    static let manageBots: [String: Any] = [
        "personas": [["id": "persona-editor", "name": "Editor", "persona": "Tightens drafts to short, active sentences.",
                      "host": "default"]],
        "hosts": [["id": "default", "name": "Muad'Dib"]],
        "manageable": ["3d-printing", "sandbox"],
    ]
}
#endif
