import AppKit
import CoreText
import SwiftUI
import Vision
@_spi(Testing) import PaperCore

// Run with PAPERLINGO_UI_CHECK_SOURCE=Tests/PaperLingoUITests/SpeakingPracticeChecks.swift
// scripts/check-review-ui.sh. All audio, responses, papers and credentials are fixtures.
private final class SpeakingSocket: RealtimeSpeechSocket, @unchecked Sendable {
    private let channel = AsyncStream<Data>.makeStream()
    private let lock = NSLock()
    private var messages: [String] = []
    var sent: [String] { lock.withLock { messages } }
    init() { inject(["type": "session.created"]) }
    func inject(_ event: [String: String]) { channel.continuation.yield(try! JSONEncoder().encode(event)) }
    func receive() async throws -> Data {
        var iterator = channel.stream.makeAsyncIterator()
        guard let event = await iterator.next() else { throw CancellationError() }
        return event
    }
    func send(_ json: String) async throws {
        lock.withLock { messages.append(json) }
        let body = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        if body?["type"] as? String == "session.update" { inject(["type": "session.updated"]) }
    }
    func close() { channel.continuation.finish() }
}

@MainActor private final class MockSpeakingAudio: SpeakingAudioIO {
    func start(onPlayed: @escaping @MainActor (String) -> Void, onDeviceChange: @escaping @MainActor () -> Void)
        throws -> AsyncThrowingStream<SpeakingMicrophoneChunk, Error> { AsyncThrowingStream { $0.finish() } }
    func setMuted(_ muted: Bool) {}
    func enqueue(_ pcm: Data, itemID: String) throws {}
    func responseFinished() {}
    func interrupt(_ itemID: String) -> Int? { nil }
    func stop() {}
}

private final class FeedbackResponse: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 4096)
                while true {
                    let read = stream.read(&bytes, maxLength: bytes.count)
                    if read <= 0 { break }
                    data.append(contentsOf: bytes.prefix(read))
                }
            }
            let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let url = request.url, url.absoluteString == "https://api.openai.com/v1/responses",
                  let input = body?["input"] as? String,
                  try JSONDecoder().decode([String].self, from: Data(input.utf8)) == ["I compare it yesterday.", "The sample are small."] else {
                throw AppError.message("Feedback request contained unexpected study materials or transcript")
            }
            let suggestions = #"{"suggestions":[{"turn":0,"improved":"I compared it yesterday.","reason":"过去时"},{"turn":0,"improved":"Duplicate","reason":"duplicate"},{"turn":-1,"improved":"Invented","reason":"extra"},{"turn":1,"improved":"  ","reason":"blank"},{"turn":1,"improved":"The sample is small.","reason":"主谓一致"}]}"#
            let output = ["status": "completed", "output": [["type": "message", "role": "assistant",
                "content": [["type": "output_text", "text": suggestions]]]]] as [String: Any]
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: output))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main @MainActor private struct SpeakingPracticeChecks {
    static func check(_ condition: Bool, _ description: String) throws {
        guard condition else { throw AppError.message(description) }
        print("PASS " + description)
        fflush(stdout)
    }
    static func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw AppError.message("Timed out waiting for native state") }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
    static func settle(_ window: NSWindow) async throws {
        try await Task.sleep(for: .milliseconds(240))
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }
    static func snapshot(_ name: String, _ window: NSWindow, in work: URL) throws -> CGImage {
        let view = window.contentView!
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw AppError.message("No UI bitmap") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let image = bitmap.cgImage, let png = bitmap.representation(using: .png, properties: [:]) else { throw AppError.message("No rendered image") }
        try png.write(to: work.appendingPathComponent(name + ".png"))
        return image
    }
    static func selectArchiveExpressions(in view: NSView) -> Bool {
        if let segments = view as? NSSegmentedControl,
           let index = (0..<segments.segmentCount).first(where: { segments.label(forSegment: $0)?.contains("口语表达") == true }) {
            segments.selectedSegment = index
            return segments.sendAction(segments.action, to: segments.target)
        }
        return view.subviews.contains { selectArchiveExpressions(in: $0) }
    }
    static func recognized(_ image: CGImage) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["en-US", "zh-Hans"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        return request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
    }
    static func writePaper(_ url: URL, quote: String) throws {
        var box = CGRect(x: 0, y: 0, width: 480, height: 640)
        guard let pdf = CGContext(url as CFURL, mediaBox: &box, nil) else { throw AppError.message("Cannot make fixture PDF") }
        for page in 0..<4 {
            pdf.beginPDFPage(nil)
            pdf.textPosition = .init(x: 40, y: 560)
            let line = NSAttributedString(string: page == 3 ? quote : "Synthetic background page")
            CTLineDraw(CTLineCreateWithAttributedString(line), pdf)
            pdf.endPDFPage()
        }
        pdf.closePDF()
    }
    static func main() async {
        do { try await run() }
        catch { print("FAIL " + error.localizedDescription); exit(1) }
    }
    static func run() async throws {
        let work = URL(fileURLWithPath: CommandLine.arguments[1])
        guard Bundle.main.bundleIdentifier?.hasPrefix("local.paperlingo.reviewqa.") == true,
              ProcessInfo.processInfo.environment["PAPERLINGO_DATA_DIR"] == work.appendingPathComponent("data").path else {
            throw AppError.message("This test requires a separate app identity and a disposable data directory")
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let socket = SpeakingSocket()
        let session = SpeakingSession(microphonePermission: { true }, makeAudio: { MockSpeakingAudio() }, workspaceNotifications: .init())
        let mock = OpenAIClient(apiKey: "synthetic-key", protocolClass: FeedbackResponse.self, realtimeSocket: { _ in socket })
        let store = AppStore(speakingSession: session, onlineClient: { mock })
        guard let db = store.db else { throw AppError.message("Cannot open isolated database") }
        let window = NSWindow(contentRect: .init(x: 30, y: 30, width: 860, height: 620),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = NSHostingView(rootView: RootView(store: store).preferredColorScheme(.light))
        window.orderFront(nil)
        defer { store.stopSpeakingWork(); window.orderOut(nil) }

        store.openSpeaking()
        for mode in SpeakingPracticeMode.allCases {
            store.changeSpeakingMode(mode)
            try check(store.selectedSpeakingSource == nil && store.speakingMaterials.isEmpty && !session.isActive,
                      "Empty library opens " + mode.title + " without starting the microphone")
        }
        try await settle(window)
        _ = try snapshot("speaking-860-free", window, in: work)

        let paper = Paper(id: "synthetic-study", title: "Comparing two estimates", filename: "sample.pdf", kind: "PDF")
        let quote = "We compared both methods on a smaller sample."
        try writePaper(store.fileURL(paper), quote: quote)
        try db.addPaper(paper)
        for term in ["estimate", "sample", "result"] {
            try db.record(text: term, translation: "测试词条", context: "Our " + term + " helps explain the result.", paper: paper, page: 3)
        }
        try store.reload()
        store.openReview(listening: true)
        store.revealed = true
        store.grade(.good)
        store.revealed = true
        let ids = store.queue.map(\.id), index = store.reviewIndex, word = store.currentCard!
        let initialWords = try db.vocabulary(), baseline = try db.reviewsToday()
        store.openSpeaking(paper: paper)
        try check(store.speakingMode == .paper && store.selectedSpeakingSource?.coverage.contains("标题") == true, "Paper detail opens title-only discussion")
        store.openSpeaking(word: word)
        try check(store.speakingMode == .vocabulary && store.selectedSpeakingSource?.wordID == word.id, "Vocabulary entry selects its saved word")
        store.openSpeaking(paper: paper, excerpt: quote, page: 3)
        guard let excerpt = store.selectedSpeakingSource else { throw AppError.message("Missing selected paragraph") }
        try check(excerpt.text == quote && excerpt.page == 3 && store.speakingMode == .paper, "Reader selection opens a discussion on physical page four")
        try await settle(window)
        _ = try snapshot("speaking-860-paper", window, in: work)
        window.setContentSize(.init(width: 1280, height: 800))
        store.changeSpeakingMode(.free)
        store.startSpeaking()
        try await wait { session.phase == .listening }
        try check(store.speakingMaterials.isEmpty && !socket.sent.joined().contains(quote), "Free conversation sends no library material")
        socket.inject(["type": "conversation.item.input_audio_transcription.completed", "item_id": "free-turn", "transcript": "I compare it yesterday."])
        try await wait { store.speakingTurnContexts["free-turn"] != nil }
        store.openSpeaking(paper: paper, excerpt: quote, page: 3)
        store.addSpeakingMaterial()
        store.addSpeakingMaterial()
        try await wait { socket.sent.joined().contains(quote) }
        socket.inject(["type": "conversation.item.input_audio_transcription.completed", "item_id": "paper-turn", "transcript": "The sample are small."])
        try await wait { store.speakingTurnContexts["paper-turn"] != nil }
        store.openSpeaking(word: word)
        store.addSpeakingMaterial()
        try await wait { store.speakingMaterials.count == 2 && socket.sent.filter { $0.contains("conversation.item.create") }.count == 2 }
        try await settle(window)
        _ = try snapshot("speaking-1280-active", window, in: work)
        session.stop()
        store.suggestSpeakingExpressions()
        await store.speakingFeedbackTask?.value
        let suggestions = store.speakingSuggestions
        try check(suggestions.map(\.improved) == ["I compared it yesterday.", "The sample is small."],
                  "Feedback uses learner turns and drops fabricated, duplicate and blank revisions")
        try check(suggestions[0].mode == .free && suggestions[0].source == nil &&
                  suggestions[1].mode == .paper && suggestions[1].source == excerpt, "Feedback preserves the mode and source for each turn")
        try store.saveSpeakingExpression(suggestions[0])
        var corrected = suggestions[1]
        corrected.original = "The sample was small."
        try store.saveSpeakingExpression(corrected)
        try check(try db.speakingExpressions().count == 2 && db.vocabulary() == initialWords && db.reviewsToday() == baseline,
                  "Editing and saving feedback preserves the original review queue and study history")
        let source = store.speakingMaterials.first { $0.wordID == word.id }!
        store.rateSpeakingSource(source, grade: .good)
        store.rateSpeakingSource(source, grade: .again)
        store.openReview()
        try check(try db.reviewsToday() == baseline + 1 && store.queue.map(\.id) == ids && store.reviewIndex == index &&
                  store.currentCard?.stage == word.stage + 1 && store.revealed && store.listening, "One manual rating refreshes the existing card and preserves order, progress and reveal state")

        store.showArchive(paper)
        try await settle(window)
        try check(selectArchiveExpressions(in: window.contentView!), "Paper detail exposes the saved-expression segment")
        try await settle(window)
        let image = try snapshot("speaking-1280-archive", window, in: work)
        let visible = try recognized(image).joined(separator: " ")
        try check(visible.contains("The sample is small") && !visible.contains("I compared it yesterday"), "Research archive renders only this paper’s corrected expression")
        store.open(paper, page: corrected.source?.page)
        try check(store.selectedPage == 3 && store.selectedPaperID == paper.id, "Saved source returns to the fourth page")
    }
}
