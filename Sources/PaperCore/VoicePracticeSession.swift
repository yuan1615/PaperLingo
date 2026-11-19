import Foundation

public enum VoicePracticeEvent: Sendable {
    case ready
    case userSpeaking(itemID: String)
    case userFinished(itemID: String)
    case assistantStarted
    case audio(itemID: String, pcm: Data)
    case transcript(itemID: String, isUser: Bool, text: String)
    case assistantFinished
}

/// A single Realtime conversation. PCM in both directions is mono signed 16-bit LE at 24 kHz.
public actor VoicePracticeSession {
    public static let maximumTextCharacters = 4_096
    private enum Phase { case initial, opening, configuring, ready, closed }
    private struct Output {
        let responseID: String
        let itemID: String
        let contentIndex: Int
        var bytes: Int
    }
    private struct Caption {
        var text = ""
        var isFinal = false
    }
    private struct Failure: LocalizedError {
        var errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
    private typealias JSON = [String: Any]

    private let instructions: String
    private let material: String?
    private let voice: String
    private let keyboardOnly: Bool
    private let timeout: Duration
    private let connect: @Sendable () -> any RealtimeSpeechSocket
    private let onEvent: @Sendable (VoicePracticeEvent) async -> Void
    private let interruptPlayback: @Sendable (String) async -> Int?
    private var phase = Phase.initial
    private var socket: (any RealtimeSpeechSocket)?
    private var sendTail: Task<Void, Error>?
    private var queuedSends = 0
    private var watchdog: Task<Void, Never>?
    private var ping: Task<Void, Never>?
    private var lastPing: ContinuousClock.Instant?
    private var deadline: ContinuousClock.Instant?
    private var sendDeadline: ContinuousClock.Instant?
    private var updateDeadlines: [ContinuousClock.Instant] = []
    private var failure: Failure?
    private var activeResponse: String?
    private var captions: [String: Caption] = [:]
    private var mutedResponse: String?
    private var mutedItem: String?
    private var awaitingResponse = false
    private var pendingText: (id: String, text: String)?
    private var cancelNextResponse = false
    // Retain the item after response.done. Queued audio may still be audible on the Mac.
    private var output: Output?

    init(instructions: String, material: String?, voice: String, keyboardOnly: Bool, timeout: Duration,
         connect: @escaping @Sendable () -> any RealtimeSpeechSocket,
         onEvent: @escaping @Sendable (VoicePracticeEvent) async -> Void,
         interruptPlayback: @escaping @Sendable (String) async -> Int?) {
        self.instructions = instructions
        self.material = material
        self.voice = voice
        self.keyboardOnly = keyboardOnly
        self.timeout = timeout
        self.connect = connect
        self.onEvent = onEvent
        self.interruptPlayback = interruptPlayback
    }

    static func validate(instructions: String, material: String?) throws {
        guard !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              instructions.utf8.count <= 32_000, (material?.utf8.count ?? 0) <= 64_000 else {
            throw Failure("教练指令为空或本次练习材料过长，请减少材料后重试。")
        }
    }

    public func run() async throws {
        try Task.checkCancellation()
        if phase == .closed { return }
        guard phase == .initial else { throw Failure("语音练习已连接。") }
        phase = .opening
        let connection = connect()
        socket = connection
        deadline = .now + timeout
        lastPing = .now
        let interval = min(Duration.seconds(1), max(.milliseconds(10), timeout / 2))
        watchdog = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                checkConnection()
            }
        }
        defer { close() }
        do {
            try await withTaskCancellationHandler {
                while phase != .closed {
                    let data = try await connection.receive()
                    try Task.checkCancellation()
                    guard phase != .closed else { break }
                    guard data.count <= RealtimeSpeech.maximumEventBytes,
                          let event = (try? JSONSerialization.jsonObject(with: data)) as? JSON,
                          let type = event["type"] as? String else { throw invalidEvent() }
                    try await receive(type, event)
                }
            } onCancel: { Task { await self.close() } }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if let failure { throw failure }
            if phase == .closed { return }
            throw (error as? Failure) ?? Failure("语音连接已中断，请检查网络、密钥及 Realtime 模型权限后重新开始。")
        }
        if let failure { throw failure }
        try Task.checkCancellation()
    }

    public func close() {
        guard phase != .closed else { return }
        phase = .closed
        watchdog?.cancel()
        watchdog = nil
        ping?.cancel()
        ping = nil
        socket?.close()
        socket = nil
        sendTail?.cancel()
        sendTail = nil
        output = nil
        captions.removeAll()
        pendingText = nil
    }

    public func appendAudio(_ pcm: Data) async throws {
        guard phase == .ready else { throw Failure("语音练习尚未连接。") }
        guard !keyboardOnly else { throw Failure("当前对话使用键盘输入。") }
        guard !pcm.isEmpty, pcm.count.isMultiple(of: 2), pcm.count <= 96_000 else {
            throw Failure("麦克风音频片段格式无效。")
        }
        try await send([["type": "input_audio_buffer.append", "audio": pcm.base64EncodedString()]])
    }

    public func sendText(_ text: String) async throws {
        guard phase == .ready else { throw Failure("请等待练习连接完成。") }
        guard keyboardOnly else { throw Failure("请使用键盘输入模式发送文字。") }
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, message.count <= Self.maximumTextCharacters, message.utf8.count <= 64_000 else {
            throw Failure("请输入一段简短的文字，每次最多 \(Self.maximumTextCharacters) 个字符。")
        }
        guard !awaitingResponse, activeResponse == nil else { throw Failure("请等待教练完成当前回复。") }
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        pendingText = (id, message)
        awaitingResponse = true
        deadline = .now + timeout
        // Queue both frames as a single batch so a material change cannot split the turn.
        try await send([textItem(message, id: id),
                        ["type": "response.create", "response": ["output_modalities": ["audio"]]]])
    }

    /// Supply only newly selected material. Earlier messages remain in the conversation.
    public func update(instructions: String, material: String? = nil) async throws {
        try Self.validate(instructions: instructions, material: material)
        guard phase == .ready else { throw Failure("请等待语音练习连接完成。") }
        var events: [JSON] = [["type": "session.update", "session": ["type": "realtime", "instructions": instructions]]]
        if let item = materialEvent(material) { events.append(item) }
        updateDeadlines.append(.now + timeout)
        try await send(events)
    }

    /// A button press cancels generation explicitly. With VAD the server has already cancelled it.
    public func interrupt() async throws {
        guard phase == .ready else { return }
        if awaitingResponse { cancelNextResponse = true }
        try await stopOutput(manual: true)
    }

    private func stopOutput(manual: Bool) async throws {
        let response = activeResponse
        let playing = output
        let otherCaptionItems = captions.keys.filter { $0 != playing?.itemID }
        captions.removeAll()
        output = nil
        if let id = response ?? playing?.responseID {
            if id != mutedResponse { mutedItem = nil }
            mutedResponse = id
            if playing?.responseID == id { mutedItem = playing?.itemID }
        }
        var events: [JSON] = []
        if manual, let response { events.append(["type": "response.cancel", "response_id": response]) }
        if let playing, let milliseconds = await interruptPlayback(playing.itemID) {
            events.append(["type": "conversation.item.truncate", "item_id": playing.itemID,
                           "content_index": playing.contentIndex,
                           "audio_end_ms": max(0, min(milliseconds, playing.bytes / 48))])
        }
        // A transcript can reach the Mac before its first audio buffer. Discard that
        // unfinished bubble too, even though the player has no duration to truncate.
        for item in otherCaptionItems { _ = await interruptPlayback(item) }
        guard phase == .ready, !events.isEmpty else { return }
        try await send(events)
    }

    private func checkConnection() {
        guard phase != .closed else { return }
        let now = ContinuousClock.now
        if [deadline, sendDeadline, updateDeadlines.first].compactMap({ $0 }).contains(where: { $0 <= now }) {
            terminate("语音服务等待超时，请检查网络后重新开始。")
            return
        }
        guard phase == .ready, let heartbeat = socket as? any RealtimeHeartbeat, let lastPing else { return }
        if ping != nil {
            if now - lastPing >= .seconds(15) { terminate("语音连接已中断，请检查网络后重新开始。") }
        } else if now - lastPing >= .seconds(20) {
            self.lastPing = now
            ping = Task {
                do { try await heartbeat.ping() }
                catch { if !Task.isCancelled { terminate("语音连接已中断，请检查网络后重新开始。") } }
                ping = nil
            }
        }
    }

    @discardableResult private func terminate(_ message: String) -> Failure {
        let error = Failure(message)
        guard phase != .closed else { return failure ?? error }
        failure = error
        close()
        return error
    }

    private func send(_ events: [JSON]) async throws {
        guard let socket, phase != .closed else { throw CancellationError() }
        guard queuedSends < 40 else {
            throw terminate("语音网络发送积压，请检查网络后重新开始。")
        }
        let messages = try events.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        // An actor is reentrant while a send awaits I/O. Preserve wire order even if capture
        // and a mode change arrive while the preceding frame is still in flight.
        let previous = sendTail
        let pending = Task {
            if let previous { try await previous.value }
            try Task.checkCancellation()
            for message in messages { try await socket.send(message) }
        }
        sendTail = pending
        if queuedSends == 0 { sendDeadline = .now + timeout }
        queuedSends += 1
        defer {
            queuedSends -= 1
            sendDeadline = queuedSends == 0 ? nil : .now + timeout
            if queuedSends == 0 { sendTail = nil }
        }
        do {
            try await pending.value
            if phase == .closed { throw CancellationError() }
        } catch {
            if phase == .closed {
                if let failure { throw failure }
                throw CancellationError()
            }
            throw terminate("发送语音练习数据失败，请检查网络后重新开始。")
        }
    }

    private func materialEvent(_ material: String?) -> JSON? {
        guard let material, !material.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return textItem(material)
    }

    private func textItem(_ text: String, id: String? = nil) -> JSON {
        var item: JSON = ["type": "message", "role": "user", "content": [["type": "input_text", "text": text]]]
        if let id { item["id"] = id }
        return ["type": "conversation.item.create", "item": item]
    }

    private func configure() async throws {
        guard phase == .opening else { throw invalidEvent() }
        phase = .configuring
        let format: JSON = ["type": "audio/pcm", "rate": 24_000]
        let vad: JSON = ["type": "server_vad", "create_response": true, "interrupt_response": true,
                         "prefix_padding_ms": 300, "silence_duration_ms": 800]
        let input: JSON = keyboardOnly ? ["turn_detection": NSNull()]
            : ["format": format, "turn_detection": vad, "transcription": ["model": "gpt-transcribe"]]
        let config: JSON = ["type": "realtime", "instructions": instructions, "output_modalities": ["audio"],
                            "tools": [], "tool_choice": "none",
                            "audio": ["input": input, "output": ["format": format, "voice": voice]]]
        var events: [JSON] = [["type": "session.update", "session": config]]
        if let item = materialEvent(material) { events.append(item) }
        try await send(events)
    }

    private func receive(_ type: String, _ event: JSON) async throws {
        switch type {
        case "session.created": try await configure()
        case "session.updated":
            if phase == .configuring {
                phase = .ready
                deadline = nil
                await onEvent(.ready)
            } else if phase == .ready, !updateDeadlines.isEmpty {
                updateDeadlines.removeFirst()
            }
        case "conversation.item.added", "conversation.item.done":
            guard let pendingText, let item = event["item"] as? JSON,
                  item["id"] as? String == pendingText.id, item["role"] as? String == "user" else { return }
            self.pendingText = nil
            await onEvent(.transcript(itemID: pendingText.id, isUser: true, text: pendingText.text))
        case "input_audio_buffer.speech_started":
            guard let id = event["item_id"] as? String else { throw invalidEvent() }
            deadline = nil
            awaitingResponse = false
            cancelNextResponse = false
            try await stopOutput(manual: false)
            await onEvent(.userSpeaking(itemID: id))
        case "input_audio_buffer.speech_stopped":
            guard let id = event["item_id"] as? String else { throw invalidEvent() }
            deadline = .now + timeout
            awaitingResponse = true
            await onEvent(.userFinished(itemID: id))
        case "response.created":
            guard let response = event["response"] as? JSON, let id = response["id"] as? String else { throw invalidEvent() }
            activeResponse = id
            captions.removeAll()
            awaitingResponse = false
            deadline = .now + timeout
            if cancelNextResponse {
                cancelNextResponse = false
                try await stopOutput(manual: true)
                return
            }
            await onEvent(.assistantStarted)
        case "response.output_audio.delta":
            guard let response = event["response_id"] as? String else { throw invalidEvent() }
            guard response == activeResponse else { return }
            guard let item = event["item_id"] as? String, let index = event["content_index"] as? Int,
                  let encoded = event["delta"] as? String, let pcm = Data(base64Encoded: encoded),
                  !pcm.isEmpty, pcm.count.isMultiple(of: 2) else { throw invalidEvent() }
            if response == mutedResponse {
                // Cancellation can cross the first audio packet before its item ID is known.
                if mutedItem != item {
                    mutedItem = item
                    try await send([["type": "conversation.item.truncate", "item_id": item, "content_index": index, "audio_end_ms": 0]])
                }
                return
            }
            if output?.itemID != item {
                output = Output(responseID: response, itemID: item, contentIndex: index, bytes: 0)
            }
            output?.bytes += pcm.count
            deadline = .now + timeout
            await onEvent(.audio(itemID: item, pcm: pcm))
        case "response.output_audio_transcript.delta", "response.output_audio_transcript.done":
            guard let id = event["response_id"] as? String else { throw invalidEvent() }
            guard id == activeResponse, id != mutedResponse else { return }
            guard let item = event["item_id"] as? String else { throw invalidEvent() }
            let final = type == "response.output_audio_transcript.done"
            guard let fragment = event[final ? "transcript" : "delta"] as? String else { throw invalidEvent() }
            guard captions[item]?.isFinal != true else { return }
            if final {
                captions[item] = Caption(text: fragment, isFinal: true)
            } else {
                guard !fragment.isEmpty else { return }
                captions[item, default: Caption()].text.append(fragment)
            }
            deadline = .now + timeout
            if let caption = captions[item] {
                await onEvent(.transcript(itemID: item, isUser: false, text: caption.text))
            }
        case "conversation.item.input_audio_transcription.completed":
            guard let item = event["item_id"] as? String, let text = event["transcript"] as? String else { throw invalidEvent() }
            if !text.isEmpty { await onEvent(.transcript(itemID: item, isUser: true, text: text)) }
        case "conversation.item.input_audio_transcription.failed":
            throw Failure("用户语音转写失败，请检查模型权限后重新开始。")
        case "response.done":
            guard let response = event["response"] as? JSON, let id = response["id"] as? String else { throw invalidEvent() }
            guard id == activeResponse else { return }
            let status = response["status"] as? String
            if status != "completed" && status != "cancelled" {
                let details = response["status_details"] as? JSON
                throw serviceError(details?["error"] as? JSON)
            }
            if status == "cancelled", id != mutedResponse { try await stopOutput(manual: false) }
            activeResponse = nil
            captions.removeAll()
            if !awaitingResponse {
                deadline = nil
                await onEvent(.assistantFinished)
            }
        case "error":
            let fields = event["error"] as? JSON
            // VAD and a manual cancellation may cross after the response has already finished.
            if fields?["code"] as? String == "response_cancel_not_active" { return }
            throw serviceError(fields)
        default: break
        }
    }

    private func invalidEvent() -> Failure { Failure("OpenAI 返回了无效的语音练习事件。") }

    private func serviceError(_ fields: JSON?) -> Failure {
        switch fields?["code"] as? String {
        case "insufficient_quota", "billing_hard_limit_reached": return Failure("OpenAI 语音额度不足，请检查项目账单。")
        case "rate_limit_exceeded": return Failure("OpenAI 语音请求过于频繁，请稍后重新开始。")
        case "invalid_api_key", "model_not_found", "permission_denied": return Failure("请检查 OpenAI 密钥及语音模型权限。")
        case "session_expired": return Failure("本次语音会话已到期，请开始新对话。")
        default: return Failure("OpenAI 未完成此次语音练习请求，请稍后重新开始。")
        }
    }
}
