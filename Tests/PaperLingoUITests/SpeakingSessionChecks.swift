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
    private let failSending: String?

    init(failSending: String? = nil) {
        self.failSending = failSending
        (stream, sink) = AsyncThrowingStream<Data, Error>.makeStream()
    }
    func open() -> Self {
        lock.withLock { openCount += 1 }
        return self
    }
    var connections: Int { lock.withLock { openCount } }
    func send(_ json: String) async throws {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        if let failSending, object["type"] as? String == failSending { throw URLError(.networkConnectionLost) }
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
    let usesVoiceProcessing: Bool
    var startError: Error?
    private(set) var playbackOnlyStarts = 0
    var input: AsyncThrowingStream<SpeakingMicrophoneChunk, Error>.Continuation?
    var played: ((String) -> Void)?
    var deviceChanged: (() -> Void)?
    var pending: [Data] = []
    var muted = false
    var finished = false
    var stopped = false
    init(usesVoiceProcessing: Bool = true) { self.usesVoiceProcessing = usesVoiceProcessing }
    func start(onPlayed: @escaping @MainActor (String) -> Void,
               onDeviceChange: @escaping @MainActor () -> Void) throws -> AsyncThrowingStream<SpeakingMicrophoneChunk, Error> {
        played = onPlayed
        deviceChanged = onDeviceChange
        let (stream, sink) = AsyncThrowingStream<SpeakingMicrophoneChunk, Error>.makeStream()
        input = sink
        if let startError { throw startError }
        return stream
    }
    func startPlaybackOnly(onPlayed: @escaping @MainActor (String) -> Void,
                           onDeviceChange: @escaping @MainActor () -> Void) throws {
        playbackOnlyStarts += 1
        played = onPlayed
        deviceChanged = onDeviceChange
        if let startError { throw startError }
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
        for (rate, channels): (Double, AVAudioChannelCount) in [(16_000, 1), (44_100, 2), (48_000, 2)] {
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
            let encoder = try SpeakingMicrophoneConverter(input: format)
            let frames = UInt32(rate / 100)
            var result = Data()
            for _ in 0..<100 {
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
                buffer.frameLength = frames
                for channel in 0..<Int(channels) {
                    for frame in 0..<Int(frames) { buffer.floatChannelData![channel][frame] = 0.25 }
                }
                result.append(try encoder.encode(buffer))
            }
            try check(abs(result.count - 48_000) < 400, "24 kHz mono PCM16 duration mismatch")
            let middle = result.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 20_000, as: Int16.self) }
            try check(abs(Int(middle) - 8192) <= 4, "PCM amplitude mismatch")
        }
    }

    @MainActor private static func checkAudioStartup() async throws {
        let voice = SpeakingAudioFixture()
        let standard = SpeakingAudioFixture(usesVoiceProcessing: false)
        var attempts: [Bool] = []
        var stoppedBeforeFallback = false
        let audio = SpeakingSessionAudio(makeDevice: { voiceProcessing in
            attempts.append(voiceProcessing)
            if !voiceProcessing { stoppedBeforeFallback = voice.stopped }
            return voiceProcessing ? voice : standard
        })
        var played: String?
        var changed = false
        func start() throws -> AsyncThrowingStream<SpeakingMicrophoneChunk, Error> {
            try audio.start(onPlayed: { played = $0 }, onDeviceChange: { changed = true })
        }
        defer { audio.stop() }

        voice.startError = NSError(domain: NSOSStatusErrorDomain, code: -10875)
        standard.startError = NSError(domain: NSOSStatusErrorDomain, code: -10868)
        var failure: String?
        do { _ = try start() } catch { failure = error.localizedDescription }
        try check(attempts == [true, false] && stoppedBeforeFallback && standard.stopped,
                  "Failed audio graphs were not tried and cleaned up in order")
        try check(failure?.contains("-10875") == true && failure?.contains("-10868") == true,
                  "Startup failure omitted an audio device error code")

        attempts = []
        voice.stopped = false
        standard.stopped = false
        standard.startError = nil
        let input = try start()
        try check(attempts == [true, false] && stoppedBeforeFallback && !audio.usesVoiceProcessing,
                  "A voice-processing failure did not select the standard audio graph")
        let samples = Data([1, 0, 2, 0])
        standard.input?.yield(.init(pcm: samples, hostTime: 42))
        var iterator = input.makeAsyncIterator()
        let chunk = try await iterator.next()
        try check(chunk?.pcm == samples && chunk?.hostTime == 42, "Fallback microphone stream was lost")
        audio.setMuted(true)
        try audio.enqueue(samples, itemID: "coach")
        audio.responseFinished()
        try check(standard.muted && standard.pending == [samples] && standard.finished,
                  "Playback or mute did not reach the active fallback device")
        standard.played?("coach")
        standard.deviceChanged?()
        try check(played == "coach" && changed && audio.interrupt("coach") == 20,
                  "Fallback callbacks or interruption were lost")
        audio.stop()
        try check(standard.stopped, "Fallback graph was not stopped")

        attempts = []
        voice.startError = nil
        _ = try start()
        try check(attempts == [true] && audio.usesVoiceProcessing,
                  "A later session did not try voice processing first")

        let output = SpeakingAudioFixture(usesVoiceProcessing: false)
        var outputAttempts: [Bool] = []
        let playback = SpeakingSessionAudio(makeDevice: { mode in outputAttempts.append(mode); return output })
        defer { playback.stop() }
        func startPlayback() throws {
            try playback.startPlaybackOnly(onPlayed: { played = $0 }, onDeviceChange: { changed = true })
        }
        output.startError = NSError(domain: NSOSStatusErrorDomain, code: -10868)
        failure = nil
        do { try startPlayback() } catch { failure = error.localizedDescription }
        try check(outputAttempts == [false] && output.stopped && output.input == nil &&
                  failure?.contains("-10868") == true && failure?.contains("麦克风") == false,
                  "Output failure should release the speaker and report an output error without opening input")
        output.startError = nil
        played = nil
        changed = false
        try startPlayback()
        try playback.enqueue(samples, itemID: "typed-reply")
        playback.responseFinished()
        output.played?("typed-reply")
        output.deviceChanged?()
        try check(outputAttempts == [false, false] && output.playbackOnlyStarts == 2 &&
                  output.input == nil && !playback.usesVoiceProcessing && output.pending == [samples] &&
                  output.finished && played == "typed-reply" && changed && playback.interrupt("typed-reply") == 20,
                  "Output-only reply lost playback or touched a microphone graph")
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

    @MainActor private static func checkKeyboardConversation() async throws {
        let socket = SpeakingSocketFixture()
        let client = OpenAIClient(apiKey: "fixture", protocolClass: URLProtocol.self, realtimeSocket: { _ in socket.open() })
        let audio = SpeakingAudioFixture()
        let session = SpeakingSession(microphonePermission: { fatalError("Typing requested microphone access") }, makeAudio: { audio })
        session.start(client: client, instructions: "paper", inputMode: .keyboard)
        defer { session.stop() }
        try check(session.phase == .connecting && !session.canSendText, "Typing skipped the connection handshake")
        try socket.push(["type": "session.created"])
        try await wait { socket.messages("session.update").count == 1 }
        try socket.push(["type": "session.updated"])
        try await wait { session.canSendText }
        session.toggleMute()
        try check(audio.playbackOnlyStarts == 1 && audio.input == nil && !session.isMuted && !session.usingStandardAudio,
                  "Typing activated a microphone or microphone control")
        try check(!(await session.sendText("  ")) && session.canSendText, "Whitespace started a turn")
        let oversized = String(repeating: "x", count: VoicePracticeSession.maximumTextCharacters + 1)
        try check(!(await session.sendText(oversized)) && session.canSendText, "Oversize input disrupted the session")

        session.updateInstructions("vocabulary", material: "Reference vocabulary")
        let question = "How would I use this word?"
        let first = Task { await session.sendText(question) }
        try await wait { !socket.messages("response.create").isEmpty }
        let items = socket.messages("conversation.item.create").compactMap { $0["item"] as? [String: Any] }
        let texts = items.compactMap { ($0["content"] as? [[String: Any]])?.first?["text"] as? String }
        try check(texts == ["Reference vocabulary", question], "Typed message preceded the new practice material")
        guard let item = items.last, let id = item["id"] as? String else { throw SpeakingAudioError("Typed item missing") }
        try socket.push(["type": "conversation.item.added", "item": item])
        try check(await first.value, "Initial typed turn failed")
        try await wait { session.transcript.first?.text == question }
        try check(session.transcript.first?.id == id && session.transcript.first?.isFinal == true && !session.canSendText,
                  "Confirmed typed turn was not preserved")
        try check(!(await session.sendText("duplicate")), "Duplicate submitted while the coach was thinking")
        try socket.push(["type": "session.updated"])
        try socket.push(["type": "response.created", "response": ["id": "r1"]])
        let pcm = Data(repeating: 2, count: 4800)
        try socket.push(["type": "response.output_audio.delta", "response_id": "r1", "item_id": "a1",
                         "content_index": 0, "delta": pcm.base64EncodedString()])
        try socket.push(["type": "response.output_audio_transcript.done", "response_id": "r1",
                         "item_id": "a1", "transcript": "An example"])
        try socket.push(["type": "response.done", "response": ["id": "r1", "status": "completed"]])
        try await wait { audio.finished }
        try check(audio.pending == [pcm] && !session.canSendText, "Reopened input before coach audio finished")
        audio.played?("a1")
        try check(session.canSendText && session.transcript.last?.isFinal == true, "Follow-up did not unlock after playback")
        let followUp = Task { await session.sendText("One more example.") }
        try await wait { socket.messages("response.create").count == 2 }
        let secondItem = socket.messages("conversation.item.create").last?["item"] as? [String: Any]
        try socket.push(["type": "conversation.item.done", "item": secondItem ?? [:]])
        try check(await followUp.value, "Follow-up failed")
        try await wait { session.transcript.last?.text == "One more example." }
        session.interrupt()
        try check(session.phase == .interrupting && !session.canSendText, "Interrupt allowed an overlapping typed response")
        try socket.push(["type": "response.created", "response": ["id": "r2"]])
        try await wait { socket.messages("response.cancel").count == 1 }
        try check(!session.canSendText, "Typed input unlocked before cancellation acknowledgment")
        try socket.push(["type": "response.done", "response": ["id": "r2", "status": "cancelled"]])
        try await wait { session.canSendText }
        session.stop()
        try await wait { socket.closed }
        try check(audio.stopped && !session.canSendText && socket.messages("input_audio_buffer.append").isEmpty &&
                  session.transcript.map(\.text) == [question, "An example", "One more example."],
                  "Typed conversation lost turn history or uploaded microphone audio")

        let broken = SpeakingSocketFixture(failSending: "response.create")
        let reconnect = OpenAIClient(apiKey: "fixture", protocolClass: URLProtocol.self, realtimeSocket: { _ in broken.open() })
        session.start(client: reconnect, instructions: "free", inputMode: .keyboard)
        try broken.push(["type": "session.created"])
        try await wait { broken.messages("session.update").count == 1 }
        try broken.push(["type": "session.updated"])
        try await wait { session.canSendText }
        try check(!(await session.sendText("Keep this draft.")), "Partial network failure cleared the draft")
        try await wait { session.phase == .failed && broken.closed }
        try check(!session.isActive && session.transcript.isEmpty, "Failed turn appeared in conversation history")
    }

    @MainActor private static func checkSessionAudioRetry() async throws {
        let voice = SpeakingAudioFixture()
        voice.startError = NSError(domain: NSOSStatusErrorDomain, code: -10875)
        let standard = SpeakingAudioFixture(usesVoiceProcessing: false)
        standard.startError = NSError(domain: NSOSStatusErrorDomain, code: -10868)
        let session = SpeakingSession(microphonePermission: { true }, makeAudio: {
            SpeakingSessionAudio(makeDevice: { $0 ? voice : standard })
        })
        func connect() async throws -> SpeakingSocketFixture {
            let socket = SpeakingSocketFixture()
            let client = OpenAIClient(apiKey: "fixture", protocolClass: URLProtocol.self, realtimeSocket: { _ in socket.open() })
            session.start(client: client, instructions: "free")
            try socket.push(["type": "session.created"])
            try await wait { socket.messages("session.update").count == 1 }
            try socket.push(["type": "session.updated"])
            return socket
        }
        defer { session.stop() }

        let first = try await connect()
        try await wait { session.phase == .audioUnavailable && first.closed }
        try check(!session.isActive && !session.usingStandardAudio && voice.stopped && standard.stopped,
                  "Audio failure retained an active session, mode indicator, or audio graph")
        try check(session.errorMessage?.contains("-10875") == true && session.errorMessage?.contains("-10868") == true,
                  "Audio failure did not reach the session with both device error codes")

        standard.startError = nil
        standard.stopped = false
        let retry = try await connect()
        try await wait { session.phase == .listening }
        try check(session.isActive && session.usingStandardAudio && session.errorMessage == nil,
                  "Retry did not clear the error and expose the active standard-audio mode")
        session.stop()
        try await wait { retry.closed }
        try check(session.phase == .ended && !session.isActive && !session.usingStandardAudio && standard.stopped,
                  "Stopping a recovered session retained the standard-audio mode or its device")
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
            try await checkAudioStartup()
            try await checkSession()
            try await checkKeyboardConversation()
            try await checkSessionAudioRetry()
            try await checkLifecycle()
            print("PASS playback-only keyboard conversations, typed follow-ups, cancellation and failed sends, microphone conversion, voice-processing startup and fallback, audio failure and retry, standard-mode indicator cleanup, permissions, mute, mode changes, transcript order, automatic and manual interruption, early stop, sleep, route change and disconnect")
        } catch { print("FAIL " + error.localizedDescription); exit(1) }
    }
}
