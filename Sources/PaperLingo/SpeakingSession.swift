import AppKit
import AVFoundation
import Combine
import PaperCore

enum SpeakingPhase: Equatable {
    case idle, requestingPermission, connecting, listening, userSpeaking, sendingText, thinking, assistantSpeaking, interrupting, ended, audioUnavailable, failed
}

enum SpeakingInputMode: String {
    case microphone, keyboard
}

struct SpeakingTurn: Identifiable, Equatable {
    enum Role { case user, assistant }
    let id: String
    let role: Role
    var text: String
    var isFinal: Bool
}

@MainActor final class SpeakingSession: ObservableObject {
    @Published private(set) var phase = SpeakingPhase.idle
    @Published private(set) var inputMode = SpeakingInputMode.microphone
    @Published private(set) var isMuted = false
    @Published private(set) var usingStandardAudio = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var transcript: [SpeakingTurn] = []

    var isActive: Bool { generation != nil }
    var canSendText: Bool { inputMode == .keyboard && phase == .listening && isActive }
    private var generation: UUID?
    private var session: VoicePracticeSession?
    private var audio: SpeakingAudioIO?
    private var connectionTask: Task<Void, Never>?
    private var microphoneTask: Task<Void, Never>?
    private var outgoingTask: Task<Bool, Never>?
    private var interruptTask: Task<Void, Never>?
    private var pendingUpdates: [Update] = []
    private var awaitingKeyboardReply = false
    private var sleepObserver: NSObjectProtocol?
    private var lastMuteChange: UInt64 = 0
    private var currentInstructions = ""
    private var sharedMaterial: Set<String> = []
    private var fullyPlayed: Set<String> = []
    private var interruptedItems: Set<String> = []
    private var assistantItemID: String?
    private let microphonePermission: () async -> Bool
    private let makeAudio: () -> SpeakingAudioIO
    private let workspaceNotifications: NotificationCenter

    private struct Update {
        let instructions: String
        let material: String?
    }

    init(microphonePermission: @escaping () async -> Bool = {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }, makeAudio: @escaping @MainActor () -> SpeakingAudioIO = { SpeakingSessionAudio() },
         workspaceNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.microphonePermission = microphonePermission
        self.makeAudio = makeAudio
        self.workspaceNotifications = workspaceNotifications
    }

    func start(client: OpenAIClient, instructions: String, material: String? = nil,
               voice: String = OpenAIClient.defaultVoice, inputMode: SpeakingInputMode = .microphone) {
        guard !isActive else { return }
        let token = UUID()
        generation = token
        self.inputMode = inputMode
        currentInstructions = instructions
        sharedMaterial = Set([material].compactMap { $0 })
        fullyPlayed.removeAll()
        interruptedItems.removeAll()
        transcript = []
        errorMessage = nil
        isMuted = false
        lastMuteChange = 0
        phase = inputMode == .microphone ? .requestingPermission : .connecting
        sleepObserver = workspaceNotifications.addObserver(forName: NSWorkspace.willSleepNotification,
                                                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.fail("Mac 已进入睡眠。唤醒后可重新开始练习。", token: token) }
        }
        connectionTask = Task { [weak self] in
            guard let self, generation == token else { return }
            if inputMode == .microphone {
                let permitted = await microphonePermission()
                guard generation == token else { return }
                guard permitted else {
                    fail("请在系统设置的「隐私与安全性」→「麦克风」中允许 PaperLingo 使用麦克风，再开始练习。", token: token)
                    return
                }
                phase = .connecting
            }
            do {
                let connection = try client.voicePracticeSession(instructions: instructions, material: material, voice: voice,
                    keyboardOnly: inputMode == .keyboard,
                    onEvent: { [weak self] event in await self?.receive(event, token: token) },
                    interruptPlayback: { [weak self] itemID in await self?.stopPlaying(itemID, token: token) })
                session = connection
                try await connection.run()
                fail("语音连接已关闭，可重新开始练习。", token: token)
            } catch { fail(error.localizedDescription, token: token) }
        }
    }

    func updateInstructions(_ instructions: String, material: String? = nil) {
        guard let token = generation else { return }
        let newMaterial = material.flatMap { sharedMaterial.insert($0).inserted ? $0 : nil }
        guard instructions != currentInstructions || newMaterial != nil else { return }
        currentInstructions = instructions
        let update = Update(instructions: instructions, material: newMaterial)
        if audio != nil, let session {
            enqueue(update, session: session, token: token)
        } else {
            pendingUpdates.append(update)
        }
    }

    func sendText(_ text: String) async -> Bool {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSendText, let token = generation, let session,
              !message.isEmpty, message.count <= VoicePracticeSession.maximumTextCharacters else { return false }
        phase = .sendingText
        awaitingKeyboardReply = true
        let sent = await enqueue(token: token) { try await session.sendText(message) }.value
        guard sent, generation == token else { return false }
        if phase == .sendingText { phase = .thinking }
        return true
    }

    func toggleMute() {
        guard isActive, inputMode == .microphone else { return }
        lastMuteChange = mach_absolute_time()
        isMuted.toggle()
        audio?.setMuted(isMuted)
    }

    func interrupt() {
        guard let session, let token = generation, interruptTask == nil,
              phase == .thinking || phase == .assistantSpeaking else { return }
        if inputMode == .keyboard { phase = .interrupting }
        interruptTask = Task { [weak self] in
            do {
                try await session.interrupt()
                guard let self, generation == token else { return }
                interruptTask = nil
                if inputMode == .keyboard {
                    if !awaitingKeyboardReply && phase == .interrupting { phase = .listening }
                } else if phase == .thinking || phase == .assistantSpeaking { phase = .listening }
            } catch { self?.fail(error.localizedDescription, token: token) }
        }
    }

    func stop() {
        guard isActive else { return }
        finish(phase: .ended, message: nil)
    }

    private func receive(_ event: VoicePracticeEvent, token: UUID) {
        guard generation == token else { return }
        switch event {
        case .ready:
            guard let session, audio == nil else { return }
            let device = makeAudio()
            audio = device
            do {
                let played: @MainActor (String) -> Void = { [weak self] in self?.didPlay($0, token: token) }
                let deviceChanged: @MainActor () -> Void = { [weak self] in
                    self?.fail("音频设备已改变。请确认系统声音设置后重新开始。", token: token)
                }
                if inputMode == .keyboard {
                    try device.startPlaybackOnly(onPlayed: played, onDeviceChange: deviceChanged)
                } else {
                    let input = try device.start(onPlayed: played, onDeviceChange: deviceChanged)
                    device.setMuted(isMuted)
                    usingStandardAudio = !device.usesVoiceProcessing
                    startMicrophone(input, session: session, token: token)
                }
                for update in pendingUpdates { enqueue(update, session: session, token: token) }
                pendingUpdates.removeAll()
                phase = .listening
            } catch { finish(phase: .audioUnavailable, message: error.localizedDescription) }
        case .userSpeaking(let itemID):
            ensureTurn(id: itemID, role: .user)
            phase = .userSpeaking
        case .userFinished(let itemID):
            ensureTurn(id: itemID, role: .user)
            phase = .thinking
        case .assistantStarted:
            if phase != .interrupting { phase = .thinking }
        case .audio(let itemID, let pcm):
            guard !interruptedItems.contains(itemID) else { return }
            do {
                try audio?.enqueue(pcm, itemID: itemID)
                assistantItemID = itemID
                ensureTurn(id: itemID, role: .assistant)
                if phase != .interrupting { phase = .assistantSpeaking }
            } catch { fail(error.localizedDescription, token: token) }
        case .transcript(let itemID, let isUser, let text):
            guard !interruptedItems.contains(itemID) else { return }
            ensureTurn(id: itemID, role: isUser ? .user : .assistant)
            if let index = transcript.firstIndex(where: { $0.id == itemID }) {
                transcript[index].text = text
                transcript[index].isFinal = isUser || fullyPlayed.contains(itemID)
            }
        case .assistantFinished:
            awaitingKeyboardReply = false
            if assistantItemID != nil { audio?.responseFinished() }
            else if phase == .thinking || phase == .assistantSpeaking || (phase == .interrupting && interruptTask == nil) { phase = .listening }
        }
    }

    private func startMicrophone(_ input: AsyncThrowingStream<SpeakingMicrophoneChunk, Error>,
                                 session: VoicePracticeSession, token: UUID) {
        microphoneTask = Task { [weak self] in
            do {
                for try await chunk in input {
                    guard let self, generation == token, !Task.isCancelled else { return }
                    // Keep sending silence for VAD to finish an utterance even when mute is pressed mid-word.
                    // A queued buffer from before the latest mute transition can never reappear after unmuting.
                    let silence = isMuted || chunk.hostTime < lastMuteChange
                    try await session.appendAudio(silence ? Data(count: chunk.pcm.count) : chunk.pcm)
                }
            } catch { self?.fail(error.localizedDescription, token: token) }
        }
    }

    private func enqueue(_ update: Update, session: VoicePracticeSession, token: UUID) {
        enqueue(token: token) { try await session.update(instructions: update.instructions, material: update.material) }
    }

    // A typed turn must follow any material or mode change the learner just made.
    @discardableResult private func enqueue(token: UUID, operation: @escaping () async throws -> Void) -> Task<Bool, Never> {
        let previous = outgoingTask
        let task = Task { [weak self] in
            if let previous { _ = await previous.value }
            guard self?.generation == token, !Task.isCancelled else { return false }
            do {
                try await operation()
                return self?.generation == token
            } catch {
                self?.fail(error.localizedDescription, token: token)
                return false
            }
        }
        outgoingTask = task
        return task
    }

    private func ensureTurn(id: String, role: SpeakingTurn.Role) {
        guard !transcript.contains(where: { $0.id == id }) else { return }
        transcript.append(SpeakingTurn(id: id, role: role, text: "", isFinal: false))
    }

    private func didPlay(_ itemID: String, token: UUID) {
        guard generation == token else { return }
        fullyPlayed.insert(itemID)
        if let index = transcript.firstIndex(where: { $0.id == itemID }), !transcript[index].text.isEmpty {
            transcript[index].isFinal = true
        }
        if assistantItemID == itemID {
            assistantItemID = nil
            if phase == .assistantSpeaking { phase = .listening }
        }
    }

    private func stopPlaying(_ itemID: String, token: UUID) -> Int? {
        guard generation == token, !fullyPlayed.contains(itemID) else { return nil }
        let played = audio?.interrupt(itemID)
        guard !fullyPlayed.contains(itemID) else { return nil }
        interruptedItems.insert(itemID)
        transcript.removeAll { $0.id == itemID }
        if assistantItemID == itemID { assistantItemID = nil }
        return played ?? 0
    }

    private func fail(_ message: String, token: UUID) {
        guard generation == token else { return }
        finish(phase: .failed, message: message)
    }

    private func finish(phase: SpeakingPhase, message: String?) {
        generation = nil
        pendingUpdates.removeAll()
        awaitingKeyboardReply = false
        microphoneTask?.cancel()
        microphoneTask = nil
        outgoingTask?.cancel()
        outgoingTask = nil
        interruptTask?.cancel()
        interruptTask = nil
        audio?.stop()
        audio = nil
        if let sleepObserver { workspaceNotifications.removeObserver(sleepObserver) }
        sleepObserver = nil
        connectionTask?.cancel()
        connectionTask = nil
        if let session { Task { await session.close() } }
        session = nil
        assistantItemID = nil
        sharedMaterial.removeAll()
        currentInstructions = ""
        fullyPlayed.removeAll()
        interruptedItems.removeAll()
        transcript.removeAll { !$0.isFinal || $0.text.isEmpty }
        isMuted = false
        usingStandardAudio = false
        errorMessage = message
        self.phase = phase
    }
}
