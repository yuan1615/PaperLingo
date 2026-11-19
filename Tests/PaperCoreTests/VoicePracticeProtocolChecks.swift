import Foundation
@_spi(Testing) import PaperCore

private final class PracticeSocketFixture: RealtimeSpeechSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var incoming: [Data] = []
    private var waiting: CheckedContinuation<Data, Error>?
    private var ended = false
    private var sentMessages: [String] = []
    private var requests: [URLRequest] = []

    var sent: [[String: Any]] {
        lock.withLock { sentMessages.map { try! JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] } }
    }
    var connections: [URLRequest] { lock.withLock { requests } }
    var closed: Bool { lock.withLock { ended } }

    func client(key: String = "synthetic-key", timeout: Duration = .seconds(2)) -> OpenAIClient {
        OpenAIClient(apiKey: key, protocolClass: URLProtocol.self, realtimeTimeout: timeout) { request in
            self.lock.withLock { self.requests.append(request) }
            return self
        }
    }
    func send(_ json: String) async throws {
        try lock.withLock {
            if ended { throw URLError(.cancelled) }
            sentMessages.append(json)
        }
    }
    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { next in
            lock.withLock {
                if ended { next.resume(throwing: URLError(.cancelled)) }
                else if !incoming.isEmpty { next.resume(returning: incoming.removeFirst()) }
                else { waiting = next }
            }
        }
    }
    func inject(_ event: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: event)
        lock.withLock {
            if let waiting {
                self.waiting = nil
                waiting.resume(returning: data)
            } else { incoming.append(data) }
        }
    }
    func close() {
        lock.withLock {
            ended = true
            waiting?.resume(throwing: URLError(.cancelled))
            waiting = nil
        }
    }
}

private actor PracticeEvents {
    var ready = false
    var starts: [String] = []
    var finishes: [String] = []
    var transcripts: [String] = []
    var audio: [String] = []
    var interrupted: [String] = []
    var completed = 0

    func event(_ event: VoicePracticeEvent) {
        switch event {
        case .ready: ready = true
        case let .userSpeaking(id): starts.append(id)
        case let .userFinished(id): finishes.append(id)
        case .assistantStarted: break
        case let .audio(item, pcm): audio.append("\(item)/\(pcm.count)")
        case let .transcript(item, user, text): transcripts.append("\(item)/\(user)/\(text)")
        case .assistantFinished: completed += 1
        }
    }
    func stop(_ item: String) -> Int? {
        interrupted.append(item)
        return 100
    }
}

private func waitForPractice(_ condition: () async -> Bool) async throws {
    let end = ContinuousClock.now + .seconds(2)
    while !(await condition()) {
        guard ContinuousClock.now < end else { throw ResearchError.message("Voice practice fixture timed out") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

func runTypedPracticeProtocolChecks() async throws {
    let fixture = PracticeSocketFixture()
    let events = PracticeEvents()
    let call = try fixture.client().voicePracticeSession(instructions: "Synthetic coach", material: "Source only",
        keyboardOnly: true, onEvent: { await events.event($0) }, interruptPlayback: { await events.stop($0) })
    do { try await call.sendText("Too early"); fail("Sent text before handshake") } catch {}
    let running = Task { try await call.run() }
    fixture.inject(["type": "session.created"])
    try await waitForPractice { fixture.sent.count == 2 }
    let config = fixture.sent[0]["session"] as? [String: Any]
    let audio = config?["audio"] as? [String: [String: Any]]
    XCTAssertEqual(config?["output_modalities"] as? [String], ["audio"])
    XCTAssertTrue(audio?["input"]?["turn_detection"] is NSNull)
    XCTAssertTrue(audio?["input"]?["transcription"] == nil)
    XCTAssertEqual((audio?["output"]?["format"] as? [String: Any])?["rate"] as? Int, 24_000)
    fixture.inject(["type": "session.updated"])
    try await waitForPractice { await events.ready }
    do { try await call.appendAudio(Data([1, 2])); fail("Keyboard practice uploaded microphone audio") } catch {}
    for text in [" \n ", String(repeating: "a", count: VoicePracticeSession.maximumTextCharacters + 1)] {
        do { try await call.sendText(text); fail("Accepted empty or oversized text") } catch {}
    }
    XCTAssertEqual(fixture.sent.count, 2)

    let text = "Could you explain this result?"
    let sent = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
        for _ in 0..<2 {
            group.addTask {
                do { try await call.sendText(" " + text + "\n"); return true } catch { return false }
            }
        }
        var count = 0
        for await success in group where success { count += 1 }
        return count
    }
    XCTAssertEqual(sent, 1)
    XCTAssertEqual(fixture.sent.count, 4)
    let item = fixture.sent[2]["item"] as? [String: Any] ?? [:]
    let itemID = item["id"] as? String ?? ""
    XCTAssertTrue(!itemID.isEmpty)
    XCTAssertEqual(fixture.sent[2]["type"] as? String, "conversation.item.create")
    XCTAssertEqual(item["role"] as? String, "user")
    XCTAssertEqual(item["content"] as? [[String: String]], [["type": "input_text", "text": text]])
    XCTAssertEqual(fixture.sent[3]["type"] as? String, "response.create")
    XCTAssertEqual((fixture.sent[3]["response"] as? [String: [String]])?["output_modalities"], ["audio"])
    fixture.inject(["type": "conversation.item.done", "item": ["role": "user", "id": "source"]])
    fixture.inject(["type": "conversation.item.added", "item": item])
    fixture.inject(["type": "conversation.item.done", "item": item])
    fixture.inject(["type": "response.created", "response": ["id": "reply"]])
    fixture.inject(["type": "response.output_audio.delta", "response_id": "reply", "item_id": "coach",
                    "content_index": 0, "delta": "AQI="])
    try await waitForPractice { await events.audio == ["coach/2"] }
    do { try await call.sendText("Too soon"); fail("Accepted text while generating a reply") } catch {}
    fixture.inject(["type": "response.output_audio_transcript.done", "response_id": "reply",
                    "item_id": "coach", "transcript": "It improved."])
    fixture.inject(["type": "response.done", "response": ["id": "reply", "status": "completed"]])
    try await waitForPractice { await events.completed == 1 }
    let captions = await events.transcripts
    XCTAssertEqual(captions, ["\(itemID)/true/\(text)", "coach/false/It improved."])

    try await call.sendText("How much?")
    XCTAssertEqual(fixture.connections.count, 1)
    try await call.interrupt() // Tapping Stop before the server creates the response.
    fixture.inject(["type": "response.created", "response": ["id": "followup"]])
    try await waitForPractice { fixture.sent.contains { $0["type"] as? String == "response.cancel" && $0["response_id"] as? String == "followup" } }
    fixture.inject(["type": "response.done", "response": ["id": "followup", "status": "cancelled"]])
    try await waitForPractice { await events.completed == 2 }
    await call.close()
    try await running.value
    do { try await call.sendText("After close"); fail("Sent text on a closed session") } catch {}
}

func runVoicePracticeProtocolChecks() async throws {
    let fixture = PracticeSocketFixture()
    let events = PracticeEvents()
    let coach = "Synthetic conversational coach"
    let source = "Quoted synthetic handout"
    let session = try fixture.client().voicePracticeSession(instructions: coach, material: source,
        onEvent: { await events.event($0) }, interruptPlayback: { await events.stop($0) })
    do { try await session.appendAudio(Data([1, 2])); fail("Uploaded audio before a confirmed session") } catch {}
    XCTAssertTrue(fixture.connections.isEmpty)
    let running = Task { try await session.run() }
    fixture.inject(["type": "session.created"])
    try await waitForPractice { fixture.sent.count == 2 }
    fixture.inject(["type": "session.updated"])
    try await waitForPractice { await events.ready }
    XCTAssertEqual(fixture.connections.map { $0.url?.absoluteString ?? "" },
                   ["wss://api.openai.com/v1/realtime?model=" + OpenAIClient.speechModel])
    XCTAssertEqual(fixture.connections.first?.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-key")
    let first = fixture.sent
    let config = first[0]["session"] as? [String: Any]
    let audio = config?["audio"] as? [String: [String: Any]]
    XCTAssertEqual(config?["instructions"] as? String, coach)
    XCTAssertEqual((audio?["input"]?["turn_detection"] as? [String: Any])?["type"] as? String, "server_vad")
    XCTAssertEqual((audio?["input"]?["transcription"] as? [String: String])?["model"], "gpt-transcribe")
    XCTAssertEqual((audio?["output"]?["format"] as? [String: Any])?["rate"] as? Int, 24_000)
    XCTAssertEqual(first[1]["type"] as? String, "conversation.item.create")
    let material = first[1]["item"] as? [String: Any]
    XCTAssertEqual(material?["role"] as? String, "user")
    XCTAssertEqual((material?["content"] as? [[String: String]])?.first?["text"], source)
    do { try await session.appendAudio(Data([7])); fail("Sent incomplete PCM sample") } catch {}
    let microphone = Data([1, 2, 3, 4])
    try await session.appendAudio(microphone)
    XCTAssertEqual(fixture.sent.last?["audio"] as? String, microphone.base64EncodedString())
    try await session.update(instructions: "Synthetic second mode")
    fixture.inject(["type": "session.updated"])
    XCTAssertEqual(fixture.connections.count, 1)
    XCTAssertEqual(fixture.sent.last?["type"] as? String, "session.update")

    func response(_ id: String, item: String) {
        fixture.inject(["type": "response.created", "response": ["id": id]])
        fixture.inject(["type": "response.output_audio.delta", "response_id": id, "item_id": item,
                        "content_index": 0, "delta": Data(repeating: 0x20, count: 9_600).base64EncodedString()])
    }
    func finished(_ id: String, status: String = "completed") {
        fixture.inject(["type": "response.done", "response": ["id": id, "status": status]])
    }
    func caption(_ delta: String, response: String, item: String) {
        fixture.inject(["type": "response.output_audio_transcript.delta", "response_id": response,
                        "item_id": item, "content_index": 0, "delta": delta])
    }
    fixture.inject(["type": "input_audio_buffer.speech_started", "item_id": "u1"])
    fixture.inject(["type": "input_audio_buffer.speech_stopped", "item_id": "u1"])
    response("r1", item: "a1")
    caption("Syn", response: "r1", item: "a1")
    try await waitForPractice { await events.transcripts.last == "a1/false/Syn" }
    caption("thetic draft", response: "r1", item: "a1")
    try await waitForPractice { await events.transcripts.last == "a1/false/Synthetic draft" }
    fixture.inject(["type": "response.output_audio_transcript.done", "response_id": "r1",
                    "item_id": "a1", "transcript": "Synthetic response"])
    caption("late fragment", response: "r1", item: "a1")
    fixture.inject(["type": "conversation.item.input_audio_transcription.completed",
                    "item_id": "u1", "transcript": "Synthetic question"])
    finished("r1")
    try await waitForPractice { await events.completed == 1 }
    let captions = await events.transcripts
    XCTAssertEqual(captions, ["a1/false/Syn", "a1/false/Synthetic draft", "a1/false/Synthetic response",
                              "u1/true/Synthetic question"])

    // Even after network generation is complete, locally queued audio must be truncated on barge-in.
    fixture.inject(["type": "input_audio_buffer.speech_started", "item_id": "u2"])
    try await waitForPractice { fixture.sent.last?["type"] as? String == "conversation.item.truncate" }
    XCTAssertEqual(fixture.sent.last?["item_id"] as? String, "a1")
    XCTAssertEqual(fixture.sent.last?["audio_end_ms"] as? Int, 100)
    fixture.inject(["type": "input_audio_buffer.speech_stopped", "item_id": "u2"])
    response("r2", item: "a2")
    try await waitForPractice { await events.audio.count == 2 }
    caption("stale response", response: "r1", item: "a1")
    fixture.inject(["type": "response.output_audio_transcript.done", "response_id": "r1", "item_id": "a1", "transcript": "stale final"])
    try await session.interrupt()
    XCTAssertEqual(fixture.sent.suffix(2).compactMap { $0["type"] as? String }, ["response.cancel", "conversation.item.truncate"])
    fixture.inject(["type": "response.output_audio.delta", "response_id": "r2", "item_id": "a2",
                    "content_index": 0, "delta": "AQI="])
    caption("unheard partial", response: "r2", item: "a2")
    fixture.inject(["type": "response.output_audio_transcript.done", "response_id": "r2",
                    "item_id": "a2", "transcript": "unheard"])
    finished("r2", status: "cancelled")
    try await waitForPractice { await events.completed == 2 }
    let delivered = await events.audio
    let finalText = await events.transcripts
    let stops = await events.interrupted
    let starts = await events.starts
    XCTAssertEqual(delivered, ["a1/9600", "a2/9600"])
    XCTAssertEqual(finalText, captions)
    XCTAssertEqual(stops, ["a1", "a2"])
    XCTAssertEqual(starts, ["u1", "u2"])

    response("r3", item: "a3")
    try await waitForPractice { await events.audio.count == 3 }
    let beforeVAD = fixture.sent.count
    fixture.inject(["type": "input_audio_buffer.speech_started", "item_id": "u3"])
    try await waitForPractice { fixture.sent.count == beforeVAD + 1 }
    XCTAssertEqual(fixture.sent.last?["type"] as? String, "conversation.item.truncate")
    finished("r3", status: "cancelled")
    fixture.inject(["type": "input_audio_buffer.speech_stopped", "item_id": "u3"])
    try await waitForPractice { await events.finishes.last == "u3" }
    // Cancel during the short interval between the user's turn ending and response.created.
    try await session.interrupt()
    response("r4", item: "a4")
    try await waitForPractice { fixture.sent.last?["item_id"] as? String == "a4" }
    XCTAssertEqual(fixture.sent.suffix(2).compactMap { $0["type"] as? String }, ["response.cancel", "conversation.item.truncate"])
    XCTAssertEqual(fixture.sent.last?["audio_end_ms"] as? Int, 0)
    let heard = await events.audio
    XCTAssertEqual(heard.count, 3)
    finished("r4", status: "cancelled")
    // A caption can arrive first. Both server cancellation and late events must
    // leave the UI with no unfinished subtitle for audio that was never heard.
    fixture.inject(["type": "response.created", "response": ["id": "r5"]])
    caption("Starting", response: "r5", item: "early")
    try await waitForPractice { await events.transcripts.last == "early/false/Starting" }
    finished("r5", status: "cancelled")
    try await waitForPractice { await events.interrupted.last == "early" }
    caption("late", response: "r5", item: "early")
    fixture.inject(["type": "conversation.item.input_audio_transcription.completed", "item_id": "later", "transcript": "Follow up"])
    try await waitForPractice { await events.transcripts.last == "later/true/Follow up" }
    let afterCancellation = await events.transcripts
    XCTAssertEqual(afterCancellation, captions + ["early/false/Starting", "later/true/Follow up"])
    await session.close()
    try await running.value
    XCTAssertTrue(fixture.closed)

    for timeout in [true, false] {
        let broken = PracticeSocketFixture()
        let client = broken.client(timeout: .milliseconds(100))
        let call = try client.voicePracticeSession(instructions: coach, onEvent: { _ in }, interruptPlayback: { _ in nil })
        if !timeout {
            broken.inject(["type": "error", "error": ["code": "insufficient_quota", "message": "synthetic-private-text"]])
        }
        do { try await call.run(); fail("Expected failed Realtime connection") }
        catch {
            XCTAssertTrue(error.localizedDescription.contains(timeout ? "超时" : "额度不足"))
            XCTAssertTrue(!error.localizedDescription.contains("synthetic-private-text"))
        }
        XCTAssertTrue(broken.closed)
    }

    let cancelled = PracticeSocketFixture()
    let call = try cancelled.client().voicePracticeSession(instructions: coach, onEvent: { _ in }, interruptPlayback: { _ in nil })
    let opening = Task { try await call.run() }
    try await waitForPractice { cancelled.connections.count == 1 }
    opening.cancel()
    do { try await opening.value; fail("Cancelled connection returned normally") } catch is CancellationError {}
    XCTAssertTrue(cancelled.closed)
}
