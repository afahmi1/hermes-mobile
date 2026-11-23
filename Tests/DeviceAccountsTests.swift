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
import json,sys,threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        if self.path != '/m/capabilities': self.send_error(404); return
        if self.headers.get('Authorization') != 'Bearer ' + self.server.label: self.send_error(401); return
        payload = json.dumps(dict(protocol=2, features=[], device_id=self.server.label, manage_devices=False)).encode()
        self.send_response(200); self.send_header('Content-Length', str(len(payload))); self.end_headers(); self.wfile.write(payload)
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length', 0)))
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
