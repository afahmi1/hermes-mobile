// Compile with App/Sources/Models.swift, then pass the synthetic JSON paths from timeline.py.
import Foundation

@main enum DecodeTimeline {
    static func main() throws {
        for file in CommandLine.arguments.dropFirst() {
            let data = try Data(contentsOf: URL(fileURLWithPath: file))
            var times: [Double] = []
            for _ in 0..<50 {
                let start = ProcessInfo.processInfo.systemUptime
                let rows = try JSONDecoder().decode(MessagesPage.self, from: data).data
                precondition(rows.count == 100)
                times.append(1000 * (ProcessInfo.processInfo.systemUptime - start))
            }
            times.sort()
            print(URL(fileURLWithPath: file).lastPathComponent, "decode p50/p95 ms", times[25], times[47])
        }
    }
}
