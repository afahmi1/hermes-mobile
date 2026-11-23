import Foundation

/// Uses an isolated preferences suite and fake Keychain, then two independent localhost HTTP servers.
/// The API client under test is the same class used by the app.
@main struct DeviceAccountsTests {
    static func main() async throws {
        let suite = "HermesTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = URL(string: "https://First.EXAMPLE:443/")!
        let b = URL(string: "https://first.example:8443")!
        let originA = SavedGateways.origin(a)!
        precondition(originA.absoluteString == "https://first.example")
        precondition(SavedGateways.origin(URL(string: "https://u:p@first.example/")!) == nil)
        let tailnet = URL(string: "https://alpha.example.ts.net:10001")!
        precondition(SavedGateways.peerOrigin(" Beta-2 ", relativeTo: tailnet)?.absoluteString == "https://beta-2.example.ts.net:10001")
        for invalid in ["https://new.example", "new.host", "not/a/host", "-bad", "bad-", "localhost", "127", "two words"] {
            precondition(SavedGateways.peerOrigin(invalid, relativeTo: tailnet) == nil)
        }
        precondition(SavedGateways.peerOrigin("peer", relativeTo: a) == nil)
        var credentials = ["token": "old-install-fixture"]
        let vault = SavedGateways(defaults: defaults, read: { credentials[$0] },
                                  write: { credentials[$0] = $1; return true },
                                  remove: { credentials.removeValue(forKey: $0); return true })
        defaults.set(a.absoluteString, forKey: "server")
        precondition(vault.restore() == GatewayLogin(server: originA, token: "old-install-fixture"))
        precondition(credentials["token"] == nil)
        precondition(vault.remember(GatewayLogin(server: b, token: "second-fixture")))
        precondition(vault.servers == [originA, b] && vault.restore()?.token == "second-fixture")
        precondition(vault.credential(a)?.token == "old-install-fixture")
        defaults.set("fixture A", forKey: "runtime.bot/session")
        defaults.set(Date(), forKey: "status.seenEvents")
        defaults.set("fixture B", forKey: "B|bot|runtime/session")
        defaults.set(Date(), forKey: "device.B.status.seenEvents")
        DevicePreferences.migrate(account: "A", defaults: defaults)
        precondition(defaults.string(forKey: "A|bot|runtime/session") == "fixture A")
        precondition(defaults.object(forKey: "device.A.status.seenEvents") != nil)
        DevicePreferences.forget("A", defaults: defaults)
        precondition(defaults.string(forKey: "A|bot|runtime/session") == nil)
        precondition(defaults.string(forKey: "B|bot|runtime/session") == "fixture B")
        precondition(defaults.object(forKey: "device.B.status.seenEvents") != nil)
        precondition(vault.forget(b) && vault.restore() == nil && vault.credential(a) != nil)
        precondition(vault.servers == [originA])
        let keys = defaults.dictionaryRepresentation()
        precondition(!keys.values.contains { ($0 as? String) == "old-install-fixture" })

        // Each server refuses the other endpoint's bearer. The second can redirect back to the first.
        let fixture = Process()
        fixture.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        fixture.arguments = ["python3", "-u", "-c", #"""
import hashlib,json,sys,threading,time
from urllib.parse import urlsplit, parse_qs
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        path = urlsplit(self.path)
        if self.headers.get('Authorization') != 'Bearer ' + self.server.label: self.send_error(401); return
        if path.path == '/m/search':
            text = parse_qs(path.query).get('q', [''])[0]
            if text == 'redirect':
                self.send_response(307); self.send_header('Location', first + self.path); self.end_headers(); return
            if text != 'two + two & three': self.send_error(400); return
            if self.server.label == 'first-fixture': time.sleep(0.40)
            result = dict(data=[dict(id='shared-id', profile='default', title=self.server.label)])
        elif path.path == '/m/capabilities':
            result = dict(protocol=2, features=[], device_id=self.server.label, manage_devices=False)
        else: self.send_error(404); return
        payload = json.dumps(result).encode()
        self.send_response(200); self.send_header('Content-Length', str(len(payload))); self.end_headers(); self.wfile.write(payload)
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        if self.path.endswith(('/send-receipt','/send-once')):
            assert self.headers.get('Authorization') == 'Bearer ' + self.server.label
            body = json.loads(raw)
            receipt = self.path.endswith('/send-receipt')
            if receipt and '/old/' in self.path: self.send_error(404); return
            if receipt and '/busy/' in self.path: self.send_error(503); return
            if receipt:
                assert 'attachments' not in body and len(raw) < 1024
                assert body['manifest'][0]['sha256'] == hashlib.sha256(b'x' * 4194304).hexdigest()
            else:
                assert '/old/' in self.path and len(raw) > 5592400 and 'attachments' in body
            print('Recovery request bytes',len(raw),'receipt' if receipt else 'upload',file=sys.stderr)
            payload = json.dumps(dict(turn_id='turn_'+body['submission_id'].replace('-','').lower())).encode()
            self.send_response(200); self.send_header('Content-Length',str(len(payload))); self.end_headers(); self.wfile.write(payload); return
        self.send_response(307); self.send_header('Location', first + '/m/pair'); self.end_headers()
servers = [ThreadingHTTPServer(('127.0.0.1',0), Handler) for _ in range(2)]
for label, s in zip(['first-fixture','second-fixture'], servers):
    s.label = label; threading.Thread(target=s.serve_forever, daemon=True).start()
urls = ['http://127.0.0.1:' + str(s.server_port) for s in servers]
first = urls[0]; print(' '.join(urls), flush=True)
sys.stdin.read()
"""#]
        let output = Pipe(), keepAlive = Pipe()
        fixture.standardOutput = output
        fixture.standardInput = keepAlive
        try fixture.run()
        defer {
            try? keepAlive.fileHandleForWriting.close()
            fixture.waitUntilExit()
        }
        let line = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
        let endpoints = line.split(whereSeparator: \.isWhitespace).compactMap { URL(string: String($0)) }
        precondition(endpoints.count == 2 && endpoints[0] != endpoints[1])
        let first = GatewayLogin(server: endpoints[0], token: "first-fixture")
        let second = GatewayLogin(server: endpoints[1], token: "second-fixture")
        API.activate(first)
        let originalClient = API.shared
        let firstCaps = try await originalClient.capabilities()
        precondition(firstCaps.deviceID == first.token)
        let file = SendAttachment(mime: "audio/mpeg", filename: "audio.mp3",
                                  base64: Data(repeating: 120, count: 4 * 1024 * 1024).base64EncodedString())
        let submission = UUID()
        for sid in ["received", "old"] {
            let receipt = try await originalClient.startRun(profile: "default", session: sid, text: "hello", choice: .botDefault,
                                                             submission: submission, attachments: [file], recovering: true)
            precondition(receipt == "turn_" + submission.uuidString.lowercased().replacingOccurrences(of: "-", with: ""))
        }
        do {
            _ = try await originalClient.startRun(profile: "default", session: "busy", text: "hello", choice: .botDefault,
                                                  submission: submission, attachments: [file], recovering: true)
            fatalError("Temporary receipt failure triggered a full upload")
        } catch APIError.http(503, _) { }
        let started = ContinuousClock.now
        try await withThrowingTaskGroup(of: (GatewayLogin, [SessionSummary]).self) { group in
            for login in [first, second] {
                group.addTask { (login, try await originalClient.searchDestination(login, text: "two + two & three")) }
            }
            var order: [GatewayLogin] = []
            for try await (login, rows) in group {
                precondition(rows.count == 1 && rows[0].key == "default/shared-id" && rows[0].title == login.token)
                print("Search result from " + login.token + " at " + String(describing: started.duration(to: .now)))
                order.append(login)
            }
            precondition(order == [second, first] && API.shared === originalClient)
        }
        do {
            _ = try await originalClient.searchDestination(second, text: "redirect")
            fatalError("Cross-origin search followed redirect")
        } catch APIError.http(307, _) { }
        do {
            _ = try await originalClient.searchDestination(GatewayLogin(server: second.server, token: "expired"), text: "expired")
            fatalError("Unpaired search succeeded")
        } catch APIError.http(401, _) { }
        let stillFirst = try await originalClient.capabilities()
        precondition(stillFirst.deviceID == first.token)
        API.activate(second)
        let secondCaps = try await API.shared.capabilities()
        precondition(secondCaps.deviceID == second.token)
        precondition(originalClient.baseURL == first.server && originalClient.token == first.token)
        do { _ = try await originalClient.capabilities(); fatalError("detached client accepted a request") }
        catch { }
        do {
            _ = try await API.shared.pair(server: endpoints[1], code: "test", device: "test")
            fatalError("redirect was followed")
        } catch APIError.http(307, _) { }
        API.activate(first)
        let returned = try await API.shared.capabilities()
        precondition(returned.deviceID == first.token)
        API.activate(nil)
        print("Gateway migration, origin isolation, scoped sign-out, redirect rejection and switching across two HTTP endpoints passed.")
    }
}
