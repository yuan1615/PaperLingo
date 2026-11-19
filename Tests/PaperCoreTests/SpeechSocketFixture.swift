import Foundation
@_spi(Testing) import PaperCore

final class SpeechSocketFixture: RealtimeSpeechSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [Data]
    private(set) var request: URLRequest?
    private(set) var connections = 0
    private(set) var sent = ""
    private(set) var closed = false

    init(events: [[String: Any]]) {
        remaining = ([["type": "session.created"]] + events).map { try! JSONSerialization.data(withJSONObject: $0) }
    }
    func client(key: String = "fixture-only", timeout: Duration = .seconds(2)) -> OpenAIClient {
        OpenAIClient(apiKey: key, protocolClass: URLProtocol.self, realtimeTimeout: timeout) { request in
            self.lock.withLock { self.request = request; self.connections += 1 }
            return self
        }
    }
    func send(_ json: String) async throws { lock.withLock { sent = json } }
    func receive() async throws -> Data {
        if let data = lock.withLock({ remaining.isEmpty ? nil : remaining.removeFirst() }) { return data }
        try await Task.sleep(for: .seconds(30))
        throw URLError(.timedOut)
    }
    func close() { lock.withLock { closed = true } }
}
