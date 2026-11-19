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
    func inject(_ event: [String: Any]) { channel.continuation.yield(try! JSONSerialization.data(withJSONObject: event)) }
    func receive() async throws -> Data {
        var iterator = channel.stream.makeAsyncIterator()
        guard let event = await iterator.next() else { throw CancellationError() }
        return event
    }
    func send(_ json: String) async throws {
        lock.withLock { messages.append(json) }
        let body = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        if body?["type"] as? String == "session.update" { inject(["type": "session.updated"]) }
        if body?["type"] as? String == "conversation.item.create",
           let item = body?["item"] as? [String: Any], item["id"] != nil {
            inject(["type": "conversation.item.added", "item": item])
        }
    }
    func beginReply(_ id: String) {
        inject(["type": "response.created", "response": ["id": id]])
        inject(["type": "response.output_audio.delta", "response_id": id, "item_id": id + "-item",
                "content_index": 0, "delta": Data(repeating: 0, count: 480).base64EncodedString()])
    }
    func finishReply(_ id: String, transcript: String) {
        inject(["type": "response.output_audio_transcript.done", "response_id": id, "item_id": id + "-item", "transcript": transcript])
        inject(["type": "response.done", "response": ["id": id, "status": "completed"]])
    }
    func close() { channel.continuation.finish() }
}

@MainActor private final class MockSpeakingAudio: SpeakingAudioIO {
    private var played: (@MainActor (String) -> Void)?
    private var item: String?
    func start(onPlayed: @escaping @MainActor (String) -> Void, onDeviceChange: @escaping @MainActor () -> Void)
        throws -> AsyncThrowingStream<SpeakingMicrophoneChunk, Error> {
        played = onPlayed
        return AsyncThrowingStream { $0.finish() }
    }
    func startPlaybackOnly(onPlayed: @escaping @MainActor (String) -> Void, onDeviceChange: @escaping @MainActor () -> Void) throws {
        played = onPlayed
    }
    func setMuted(_ muted: Bool) {}
    func enqueue(_ pcm: Data, itemID: String) throws { item = itemID }
    func responseFinished() {
        if let item { played?(item) }
        item = nil
    }
    func interrupt(_ itemID: String) -> Int? { nil }
    func stop() { played = nil; item = nil }
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
    static func nativeViews<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        let match = (view as? T).map { [$0] } ?? []
        return match + view.subviews.flatMap { nativeViews(type, in: $0) }
    }
    static func sendButton(in view: NSView) -> NSButton? {
        nativeViews(NSButton.self, in: view).first { $0.keyEquivalent == "\r" && $0.keyEquivalentModifierMask.contains(.command) }
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
        window.makeKeyAndOrderFront(nil)
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
        socket.inject(["type": "input_audio_buffer.speech_started", "item_id": "free-turn"])
        try await wait { session.phase == .userSpeaking }
        try await settle(window)
        _ = try snapshot("speaking-1280-microphone-listening", window, in: work)
        socket.inject(["type": "input_audio_buffer.speech_stopped", "item_id": "free-turn"])
        socket.inject(["type": "conversation.item.input_audio_transcription.completed", "item_id": "free-turn", "transcript": "I compare it yesterday."])
        socket.beginReply("spoken-reply")
        socket.finishReply("spoken-reply", transcript: "What did you compare?")
        try await wait { store.speakingTurnContexts["free-turn"] != nil && session.phase == .listening }
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

        // Render the keyboard controls at the minimum window size using only fixture audio and transport.
        let keyboardSocket = SpeakingSocket()
        let keyboardSession = SpeakingSession(microphonePermission: { fatalError("Keyboard requested microphone access") },
            makeAudio: { MockSpeakingAudio() }, workspaceNotifications: .init())
        let keyboardClient = OpenAIClient(apiKey: "synthetic-key", protocolClass: FeedbackResponse.self, realtimeSocket: { _ in keyboardSocket })
        let keyboardStore = AppStore(speakingSession: keyboardSession, onlineClient: { keyboardClient })
        keyboardStore.openSpeaking()
        keyboardStore.changeSpeakingMode(.free)
        UserDefaults.standard.set("keyboard", forKey: "speakingInputMode")
        window.setContentSize(.init(width: 860, height: 620))
        window.contentView = NSHostingView(rootView: RootView(store: keyboardStore).preferredColorScheme(.light))
        defer { keyboardStore.stopSpeakingWork() }
        try await settle(window)
        _ = try snapshot("speaking-860-keyboard-idle", window, in: work)
        keyboardStore.startSpeaking(inputMode: .keyboard)
        try await wait { keyboardSession.canSendText }
        try await settle(window)
        _ = try snapshot("speaking-860-keyboard", window, in: work)
        try check(keyboardSession.inputMode == .keyboard, "Keyboard practice starts without requesting microphone permission")
        let message = "Could you explain the main finding?"
        guard let editor = window.firstResponder as? NSTextView else { throw AppError.message("The keyboard composer must receive focus") }
        editor.insertText(message, replacementRange: editor.selectedRange())
        try await settle(window)
        guard let shortcut = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) else {
            throw AppError.message("Cannot create the send shortcut")
        }
        try check(window.performKeyEquivalent(with: shortcut), "The composer handles Command-Return")
        try await wait { keyboardSocket.sent.contains { $0.contains(message) } && keyboardSocket.sent.contains { $0.contains("response.create") } }
        keyboardSocket.beginReply("keyboard-first")
        keyboardSocket.inject(["type": "response.output_audio_transcript.delta", "response_id": "keyboard-first",
                               "item_id": "keyboard-first-item", "content_index": 0, "delta": "Both methods improved recall."])
        try await wait { keyboardSession.phase == .assistantSpeaking && keyboardSession.transcript.last?.text.contains("improved recall") == true }
        try await settle(window)
        let compact = try snapshot("speaking-860-keyboard-messages", window, in: work)
        let compactText = try recognized(compact).joined(separator: " ").lowercased()
        try check(compactText.contains("main finding") && compactText.contains("improved recall"),
                  "Both sides of the live conversation are visible without expanding a transcript at minimum width")
        let followUp = "I would compare the results against a baseline."
        guard let draftEditor = window.firstResponder as? NSTextView else { throw AppError.message("The learner must be able to draft a follow-up") }
        draftEditor.insertText(followUp, replacementRange: draftEditor.selectedRange())
        try await settle(window)
        guard let send = sendButton(in: window.contentView!) else { throw AppError.message("Missing native send control") }
        try check(draftEditor.string == followUp && !send.isEnabled, "A follow-up can be drafted while the coach is speaking")
        keyboardSocket.finishReply("keyboard-first", transcript: "Both methods improved recall. How would you explain that result?")
        try await wait { keyboardSession.canSendText && keyboardSession.transcript.count == 2 &&
            keyboardSession.transcript.last?.text.contains("explain that result") == true }
        try await wait { send.isEnabled }
        send.performClick(nil)
        try await wait { keyboardSocket.sent.contains { $0.contains(followUp) } }
        try check(keyboardSocket.sent.filter { $0.contains("response.create") }.count == 2, "Clicking Send submits exactly one more spoken turn")
        window.setContentSize(.init(width: 1280, height: 800))
        keyboardSocket.beginReply("keyboard-next")
        keyboardSocket.finishReply("keyboard-next", transcript: "Good point. Which baseline would you choose, and why?")
        try await wait { keyboardSession.canSendText && keyboardSession.transcript.count == 4 && keyboardSession.transcript.allSatisfy(\.isFinal) }
        try await settle(window)
        let wide = try snapshot("speaking-1280-keyboard-messages", window, in: work)
        let wideText = try recognized(wide).joined(separator: " ").lowercased()
        try check(wideText.contains("against a baseline") && wideText.contains("which baseline"),
                  "The latest question and answer stay visible after another turn")
        let extraTurns = try await checkScrolling(session: keyboardSession, socket: keyboardSocket, window: window, work: work)
        window.setContentSize(.init(width: 1280, height: 800))
        keyboardSession.stop()
        try await settle(window)
        _ = try snapshot("speaking-1280-recap", window, in: work)
        window.setContentSize(.init(width: 860, height: 620))
        try await settle(window)
        _ = try snapshot("speaking-860-recap", window, in: work)
        try check(keyboardSession.phase == .ended && keyboardSession.transcript.filter { $0.role == .user }.map(\.text) == [message, followUp] + extraTurns,
                  "Ending a keyboard session preserves all learner turns for review")
    }

    static func checkScrolling(session: SpeakingSession, socket: SpeakingSocket, window: NSWindow, work: URL) async throws -> [String] {
        window.setContentSize(.init(width: 860, height: 620))
        try await settle(window)
        let view = window.contentView!
        guard let composerSend = sendButton(in: view) else { throw AppError.message("Missing keyboard composer") }
        let originalSendFrame = composerSend.convert(composerSend.bounds, to: nil)
        let prompts = ["Why use a control group?", "What does variance measure?", "Why report uncertainty?"]
        let replies = ["It helps isolate the treatment effect.", "It describes the spread of observations.", "It shows the range of plausible effects."]
        for index in prompts.indices {
            guard await session.sendText(prompts[index]) else { throw AppError.message("Cannot add a fixture turn") }
            let id = "scroll-\(index)"
            socket.beginReply(id)
            socket.finishReply(id, transcript: replies[index])
            try await wait { session.canSendText }
        }
        try await settle(window)
        guard let scroll = nativeViews(NSScrollView.self, in: view).first(where: {
            $0.bounds.width > 350 && $0.contentView.documentRect.height > $0.contentView.bounds.height + 100
        }) else { throw AppError.message("No scrollable message history at minimum width") }
        let clip = scroll.contentView
        func bottom() -> CGFloat { clip.isFlipped ? clip.documentRect.maxY - clip.bounds.height : clip.documentRect.minY }
        try check(abs(clip.bounds.minY - bottom()) < 4, "Incoming turns follow the newest message")
        let top = clip.isFlipped ? clip.documentRect.minY : clip.documentRect.maxY - clip.bounds.height
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: top))
        scroll.reflectScrolledClipView(clip)
        try await settle(window)
        let pinnedOrigin = clip.bounds.minY
        let last = "Could you give me another example?"
        guard await session.sendText(last) else { throw AppError.message("Cannot add another fixture turn") }
        socket.beginReply("later")
        socket.finishReply("later", transcript: "Compare two groups with similar sample sizes.")
        try await wait { session.canSendText }
        try await settle(window)
        try check(abs(clip.bounds.minY - pinnedOrigin) < 4 && abs(clip.bounds.minY - bottom()) > 100,
                  "Reading earlier messages holds its position as later messages arrive")
        guard let currentSend = sendButton(in: view) else { throw AppError.message("Composer disappeared while reading history") }
        let currentFrame = currentSend.convert(currentSend.bounds, to: nil)
        let rootFrame = view.convert(view.bounds, to: nil)
        try check(rootFrame.contains(currentFrame) && abs(currentFrame.midY - originalSendFrame.midY) < 2,
                  "The keyboard composer remains pinned in the window while the history scrolls")
        _ = try snapshot("speaking-860-reading-history", window, in: work)
        let scrollFrame = scroll.convert(scroll.bounds, to: nil)
        let jump = nativeViews(NSButton.self, in: view).first { button in
            let bounds = button.convert(button.bounds, to: nil)
            return button.isEnabled && scrollFrame.contains(NSPoint(x: bounds.midX, y: bounds.midY))
        }
        guard let jump else { throw AppError.message("Missing Return to latest button while reading history") }
        jump.performClick(nil)
        try await wait { abs(clip.bounds.minY - bottom()) < 4 }
        try await settle(window)
        let latest = try snapshot("speaking-860-latest", window, in: work)
        try check(try recognized(latest).joined(separator: " ").lowercased().contains("similar sample sizes"),
                  "Return to latest brings the newest turn back into view")
        return prompts + [last]
    }
}
