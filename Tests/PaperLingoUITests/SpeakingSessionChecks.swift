import AVFoundation
import AppKit
@_spi(Testing) import PaperCore

// Synthetic microphone and speaker. The check can run without device access or credentials.
private final class SpeakingSocketFixture: RealtimeSpeechSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [[String: Any]] = []
    private var openCount = 0
    private var closeCount = 0
    private let stream: AsyncThrowingStream<Data, Error>
    private let sink: AsyncThrowingStream<Data, Error>.Continuation

    init() { (stream, sink) = AsyncThrowingStream<Data, Error>.makeStream() }
    func open() -> Self {
        lock.withLock { openCount += 1 }
        return self
    }
    var connections: Int { lock.withLock { openCount } }
    func send(_ json: String) async throws {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        lock.withLock { sent.append(object) }
    }
    func receive() async throws -> Data {
        var iterator = stream.makeAsyncIterator()
        guard let data = try await iterator.next() else { throw URLError(.networkConnectionLost) }
        return data
    }
    func push(_ fields: [String: Any]) throws { sink.yield(try JSONSerialization.data(withJSONObject: fields)) }
    func close() {
        lock.withLock { closeCount += 1 }
        sink.finish()
    }
    var closed: Bool { lock.withLock { closeCount > 0 } }
    var messages: [[String: Any]] { lock.withLock { sent } }
    func messages(_ type: String) -> [[String: Any]] { messages.filter { $0["type"] as? String == type } }
    func disconnect() { sink.finish(throwing: URLError(.networkConnectionLost)) }
}

@MainActor private final class SpeakingAudioFixture: SpeakingAudioIO {
    var input: AsyncThrowingStream<SpeakingMicrophoneChunk, Error>.Continuation?
    var played: ((String) -> Void)?
    var deviceChanged: (() -> Void)?
    var pending: [Data] = []
    var muted = false
    var finished = false
    var stopped = false
    func start(onPlayed: @escaping @MainActor (String) -> Void,
               onDeviceChange: @escaping @MainActor () -> Void) throws -> AsyncThrowingStream<SpeakingMicrophoneChunk, Error> {
        played = onPlayed
        deviceChanged = onDeviceChange
        let (stream, sink) = AsyncThrowingStream<SpeakingMicrophoneChunk, Error>.makeStream()
        input = sink
        return stream
    }
    func setMuted(_ muted: Bool) { self.muted = muted }
    func enqueue(_ pcm: Data, itemID: String) { pending.append(pcm) }
    func responseFinished() { finished = true }
    func interrupt(_ itemID: String) -> Int? { pending.removeAll(); return 20 }
    func stop() { input?.finish(); stopped = true }
}

@main private struct SpeakingSessionChecks {
    private static func check(_ ok: Bool, _ message: String) throws {
        if !ok { throw SpeakingAudioError(message) }
    }
    @MainActor private static func wait(_ test: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !test() {
            try check(Date() < deadline, "Timed out waiting for fixture")
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private static func checkConversion() throws {
        for rate in [44_100.0, 48_000.0] {
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
            let encoder = try SpeakingMicrophoneConverter(input: format)
            let frames = UInt32(rate / 100)
            var result = Data()
            for _ in 0..<100 {
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
                buffer.frameLength = frames
                for channel in 0..<2 {
                    for frame in 0..<Int(frames) { buffer.floatChannelData![channel][frame] = 0.25 }
                }
                result.append(try encoder.encode(buffer))
            }
            try check(abs(result.count - 48_000) < 400, "24 kHz mono PCM16 duration mismatch")
            let middle = result.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 20_000, as: Int16.self) }
            try check(abs(Int(middle) - 8192) <= 4, "PCM amplitude mismatch")
        }
    }

    @MainActor private static func checkSession() async throws {
        let socket = SpeakingSocketFixture()
        let client = OpenAIClient(apiKey: "fixture", protocolClass: URLProtocol.self, realtimeSocket: { _ in socket.open() })
        let denied = SpeakingSession(microphonePermission: { false }, makeAudio: { fatalError("unexpected device access") })
        denied.start(client: client, instructions: "test")
        try await wait { denied.phase == .failed }
        try check(socket.connections == 0 && !denied.isActive, "Denied permission opened the socket")

        let audio = SpeakingAudioFixture()
        let session = SpeakingSession(microphonePermission: { true }, makeAudio: { audio })
        session.start(client: client, instructions: "free", material: "A")
        session.updateInstructions("paper", material: "A")
        session.updateInstructions("paper", material: "B")
        session.updateInstructions("paper", material: "B")
        try socket.push(["type": "session.created"])
        try await wait { socket.messages("session.update").count == 1 }
        try socket.push(["type": "session.updated"])
        try await wait { session.phase == .listening && socket.messages("session.update").count == 3 }
        try check(socket.messages("conversation.item.create").count == 2, "Material was resent on mode switch")
        try check(socket.connections == 1, "Mode switch created a second connection")

        let spoken = Data([16, 0, 32, 0])
        func yieldInput(time: UInt64 = mach_absolute_time()) {
            audio.input?.yield(.init(pcm: spoken, hostTime: time))
        }
        yieldInput()
        try await wait { socket.messages("input_audio_buffer.append").count == 1 }
        session.toggleMute()
        try check(audio.muted, "Mute did not reach the audio device")
        yieldInput()
        try await wait { socket.messages("input_audio_buffer.append").count == 2 }
        session.toggleMute()
        yieldInput(time: 1)
        yieldInput()
        try await wait { socket.messages("input_audio_buffer.append").count == 4 }
        let actual = socket.messages("input_audio_buffer.append").compactMap { $0["audio"] as? String }
        let silence = Data(count: spoken.count).base64EncodedString()
        try check(actual == [spoken.base64EncodedString(), silence, silence, spoken.base64EncodedString()], "Muted or stale audio leaked")

        func user(_ id: String) throws {
            try socket.push(["type": "input_audio_buffer.speech_started", "item_id": id])
            try socket.push(["type": "input_audio_buffer.speech_stopped", "item_id": id])
        }
        func reply(_ response: String, item: String) throws {
            try socket.push(["type": "response.created", "response": ["id": response]])
            for byte: UInt8 in [3, 4] {
                let pcm = Data(repeating: byte, count: 4800)
                try socket.push(["type": "response.output_audio.delta", "response_id": response,
                                 "item_id": item, "content_index": 0, "delta": pcm.base64EncodedString()])
            }
            try socket.push(["type": "response.output_audio_transcript.done", "item_id": item,
                             "response_id": response, "transcript": "A coach reply"])
            try socket.push(["type": "response.done", "response": ["id": response, "status": "completed"]])
        }
        try user("u1")
        try reply("r1", item: "a1")
        try socket.push(["type": "conversation.item.input_audio_transcription.completed", "item_id": "u1",
                         "transcript": "My own words"])
        try await wait { session.transcript.first?.isFinal == true && audio.finished }
        try check(session.transcript.map(\.id) == ["u1", "a1"] && session.transcript.last?.isFinal == false,
                  "Late transcript moved or unplayed audio marked final")
        try check(audio.pending.map { $0.first } == [3, 4], "Speaker chunks arrived out of order")
        try user("u2")
        try await wait { !socket.messages("conversation.item.truncate").isEmpty }
        try check(socket.messages("conversation.item.truncate").first?["audio_end_ms"] as? Int == 20 && audio.pending.isEmpty,
                  "Truncation did not use the played position")
        try check(!session.transcript.contains { $0.id == "a1" }, "Unheard reply remained in the transcript")

        try reply("r2", item: "a2")
        try await wait { session.transcript.last?.text == "A coach reply" }
        audio.played?("a2")
        try await wait { session.transcript.last?.isFinal == true }

        try user("u3")
        try socket.push(["type": "response.created", "response": ["id": "r3"]])
        try socket.push(["type": "response.output_audio.delta", "response_id": "r3", "item_id": "a3",
                         "content_index": 0, "delta": Data(repeating: 2, count: 4800).base64EncodedString()])
        try await wait { session.phase == .assistantSpeaking }
        session.interrupt()
        try await wait { session.phase == .listening && socket.messages("response.cancel").count == 1 }
        try check(socket.messages("conversation.item.truncate").last?["item_id"] as? String == "a3",
                  "Manual interruption did not target the playing item")
        socket.disconnect()
        try await wait { session.phase == .failed && socket.closed && audio.stopped }
        try check(session.transcript.map(\.id) == ["u1", "a2"] && !session.isActive,
                  "Disconnect retained unfinished turns or audio resources")
    }

    @MainActor private static func checkLifecycle() async throws {
        var permission: CheckedContinuation<Bool, Never>?
        let unopened = SpeakingSocketFixture()
        let client = OpenAIClient(apiKey: "fixture", protocolClass: URLProtocol.self, realtimeSocket: { _ in unopened.open() })
        let pending = SpeakingSession(microphonePermission: {
            await withCheckedContinuation { permission = $0 }
        }, makeAudio: { fatalError("Stopped session opened the microphone") })
        pending.start(client: client, instructions: "free")
        try await wait { permission != nil }
        pending.stop()
        permission?.resume(returning: true)
        await Task.yield()
        try check(!pending.isActive && pending.phase == .ended && unopened.connections == 0,
                  "Permission result resurrected a stopped session")

        for scenario in ["handshake", "stop", "route", "sleep"] {
            let socket = SpeakingSocketFixture()
            let client = OpenAIClient(apiKey: "fixture", protocolClass: URLProtocol.self, realtimeSocket: { _ in socket.open() })
            let audio = SpeakingAudioFixture()
            let notifications = NotificationCenter()
            let session = SpeakingSession(microphonePermission: { true }, makeAudio: { audio }, workspaceNotifications: notifications)
            session.start(client: client, instructions: "free")
            try await wait { socket.connections == 1 }
            if scenario == "handshake" {
                session.stop()
                try await wait { socket.closed }
                try check(audio.input == nil && session.phase == .ended, "Stopped handshake opened the microphone")
                continue
            }
            try socket.push(["type": "session.created"])
            try await wait { socket.messages("session.update").count == 1 }
            try socket.push(["type": "session.updated"])
            try await wait { session.phase == .listening }
            switch scenario {
            case "route": audio.deviceChanged?()
            case "sleep": notifications.post(name: NSWorkspace.willSleepNotification, object: nil)
            default: session.stop()
            }
            try await wait { socket.closed && audio.stopped }
            let expectedPhase: SpeakingPhase = scenario == "stop" ? .ended : .failed
            try check(!session.isActive && session.phase == expectedPhase, "Lifecycle failed for " + scenario)
        }
    }

    @MainActor static func main() async {
        do {
            try checkConversion()
            try await checkSession()
            try await checkLifecycle()
            print("PASS microphone conversion, permissions, mute, mode changes, transcript order, automatic and manual interruption, early stop, sleep, route change and disconnect")
        } catch { print("FAIL " + error.localizedDescription); exit(1) }
    }
}
