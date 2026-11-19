import AppKit
import Foundation
@_spi(Testing) import PaperCore

// Run with PAPERLINGO_UI_CHECK_SOURCE=Tests/PaperLingoUITests/OnlineSpeechChecks.swift
// bash scripts/check-review-ui.sh. All requests are intercepted inside the process.
private final class SpeechFixture: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var inputs: [String] = []
    private static var cancellations = 0
    private var held = false
    static var received: [String] { lock.withLock { inputs } }
    static var cancelled: Int { lock.withLock { cancellations } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        guard request.url?.absoluteString == "https://api.openai.com/v1/audio/speech",
              let fields = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let input = fields["input"] as? String,
              Set(fields.keys) == ["model","voice","input","response_format"] else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        held = input.contains("Hold this request")
        Self.lock.withLock { Self.inputs.append(input) }
        if held { return }
        // One second of silent mono PCM16 at 16 kHz.
        let wav = Data(base64Encoded: "UklGRiR9AABXQVZFZm10IBAAAAABAAEAgD4AAAB9AAACABAAZGF0YQB9AAA=")! + Data(count: 32000)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":"audio/wav"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: wav)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        if held { Self.lock.withLock { Self.cancellations += 1 } }
    }
}

@main private struct OnlineSpeechChecks {
    @MainActor static func wait(_ message: String, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            if Date() > deadline { throw AppError.message(message) }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
    @MainActor static func run() async throws {
        let audio = AudioService()
        let preferences = UserDefaults.standard
        let oldProvider = preferences.object(forKey: "speechProvider")
        let oldVoice = preferences.object(forKey: "openAIVoice")
        defer {
            audio.stop()
            preferences.set(oldProvider, forKey: "speechProvider")
            preferences.set(oldVoice, forKey: "openAIVoice")
        }
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw AppError.message(message) }
            print("PASS " + message)
        }
        let client = OpenAIClient(apiKey: "synthetic-speech-fixture", protocolClass: SpeechFixture.self)
        var preemptions = 0
        audio.onlineClient = { client }
        audio.prepareForSpeech = { preemptions += 1 }
        audio.researchBusy = true
        preferences.set("openai", forKey: "speechProvider")
        preferences.set("marin", forKey: "openAIVoice")
        let sentences = (1...22).map { "We evaluate metric \($0) under the same experimental conditions." }
        let original = "A paper [2] calls this useful. " + sentences.joined(separator: " ")
        let cleaned = SpeechText.prepare(original)
        let parts = AudioService.onlineSegments(cleaned)
        try check(parts.count >= 3 && parts.first == "A paper calls this useful." && parts.joined(separator: " ") == cleaned,
                  "The first sentence is separate and the complete cleaned text is retained")
        let unbroken = String(repeating: "A", count: 1200)
        let chunks = AudioService.onlineSegments(unbroken)
        try check(chunks.joined() == unbroken && chunks.allSatisfy { $0.count <= 450 }, "Even a long single token fits the segment limit")

        audio.speak(original)
        audio.togglePause()
        try await wait("First WAV unavailable") { audio.currentPart == 1 }
        try check(preemptions == 0 && audio.playing && audio.paused && audio.totalParts == parts.count &&
                  SpeechFixture.received == [parts[0]], "Online playback starts before later requests and respects pause during synthesis")
        audio.togglePause()
        try await wait("Next WAV unavailable") { audio.generatedParts == 2 }
        try check(audio.currentPart == 1 && SpeechFixture.received == Array(parts.prefix(2)), "Only one segment is prefetched during playback")
        try await wait("Playback incomplete") { !audio.playing && !audio.generating }
        try check(SpeechFixture.received == parts && audio.currentPart == parts.count && audio.error == nil, "All WAV segments played in order")

        let firstCount = SpeechFixture.received.count
        audio.speak(parts[0], slow: true)
        try await wait("Slow playback unavailable") { audio.currentPart == 1 }
        try check(audio.label.contains("慢速") && SpeechFixture.received.count == firstCount, "Slow replay reuses this voice's cached audio")
        preferences.set("cedar", forKey: "openAIVoice")
        audio.speak(parts[0])
        try await wait("Switched voice unavailable") { audio.currentPart == 1 }
        try check(audio.label.contains("cedar") && SpeechFixture.received.count == firstCount + 1, "Changing voice fetches distinct audio")
        audio.resetOnlineSpeech()
        audio.speak(parts[0])
        try await wait("New credential context unavailable") { audio.currentPart == 1 }
        try check(SpeechFixture.received.count == firstCount + 2, "Resetting credentials clears the session cache")

        audio.speak("Hold this request. Later sentences must stay on this Mac.")
        try await wait("Pending request unavailable") { SpeechFixture.received.last == "Hold this request." }
        let stoppingCount = SpeechFixture.received.count
        audio.stop()
        try await wait("In-flight transfer still active") { SpeechFixture.cancelled == 1 }
        try check(SpeechFixture.received.count == stoppingCount && !audio.generating && !audio.playing && audio.currentPart == 0,
                  "Stopping cancels the in-flight request and every unsent sentence")
        audio.onlineClient = { throw AppError.message("fixture missing credential") }
        audio.speak(parts[0])
        try check(audio.error == "fixture missing credential" && SpeechFixture.received.count == stoppingCount,
                  "Missing credentials stop online playback before any request")
    }
    @MainActor static func main() async {
        do { try await run() } catch { print("FAIL " + error.localizedDescription); exit(1) }
    }
}
