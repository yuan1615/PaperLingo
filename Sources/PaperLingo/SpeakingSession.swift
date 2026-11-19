import AppKit
import AVFoundation
import Combine
import PaperCore

enum SpeakingPhase: Equatable {
    case idle, requestingPermission, connecting, listening, userSpeaking, thinking, assistantSpeaking, ended, failed
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
    @Published private(set) var isMuted = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var transcript: [SpeakingTurn] = []

    var isActive: Bool { generation != nil }
    private var generation: UUID?
    private var session: VoicePracticeSession?
    private var audio: SpeakingAudioIO?
    private var connectionTask: Task<Void, Never>?
    private var microphoneTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?
    private var interruptTask: Task<Void, Never>?
    private var updates: AsyncStream<Update>.Continuation?
    private var pendingUpdates: AsyncStream<Update>?
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
               voice: String = OpenAIClient.defaultVoice) {
        guard !isActive else { return }
        let token = UUID()
        generation = token
        currentInstructions = instructions
        sharedMaterial = Set([material].compactMap { $0 })
        fullyPlayed.removeAll()
        interruptedItems.removeAll()
        transcript = []
        errorMessage = nil
        isMuted = false
        lastMuteChange = 0
        let (stream, sink) = AsyncStream<Update>.makeStream()
        pendingUpdates = stream
        updates = sink
        phase = .requestingPermission
        sleepObserver = workspaceNotifications.addObserver(forName: NSWorkspace.willSleepNotification,
                                                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.fail("Mac 已进入睡眠。唤醒后可重新开始练习。", token: token) }
        }
        connectionTask = Task { [weak self] in
            guard let self else { return }
            let permitted = await microphonePermission()
            guard generation == token else { return }
            guard permitted else {
                fail("请在系统设置的「隐私与安全性」→「麦克风」中允许 PaperLingo 使用麦克风，再开始练习。", token: token)
                return
            }
            phase = .connecting
            do {
                let connection = try client.voicePracticeSession(instructions: instructions, material: material, voice: voice,
                    onEvent: { [weak self] event in await self?.receive(event, token: token) },
                    interruptPlayback: { [weak self] itemID in await self?.stopPlaying(itemID, token: token) })
                session = connection
                try await connection.run()
                fail("语音连接已关闭，可重新开始练习。", token: token)
            } catch { fail(error.localizedDescription, token: token) }
        }
    }

    func updateInstructions(_ instructions: String, material: String? = nil) {
        guard isActive else { return }
        let newMaterial = material.flatMap { sharedMaterial.insert($0).inserted ? $0 : nil }
        guard instructions != currentInstructions || newMaterial != nil else { return }
        currentInstructions = instructions
        updates?.yield(Update(instructions: instructions, material: newMaterial))
    }

    func toggleMute() {
        guard isActive else { return }
        lastMuteChange = mach_absolute_time()
        isMuted.toggle()
        audio?.setMuted(isMuted)
    }

    func interrupt() {
        guard let session, let token = generation, interruptTask == nil,
              phase == .thinking || phase == .assistantSpeaking else { return }
        interruptTask = Task { [weak self] in
            do {
                try await session.interrupt()
                guard let self, generation == token else { return }
                interruptTask = nil
                if phase == .thinking || phase == .assistantSpeaking { phase = .listening }
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
            guard let session, audio == nil, let pendingUpdates else { return }
            let device = makeAudio()
            audio = device
            do {
                let input = try device.start(onPlayed: { [weak self] item in self?.didPlay(item, token: token) },
                    onDeviceChange: { [weak self] in self?.fail("音频设备已改变。请确认麦克风和输出设备后重新开始。", token: token) })
                device.setMuted(isMuted)
                startSending(input, updates: pendingUpdates, session: session, token: token)
                self.pendingUpdates = nil
                phase = .listening
            } catch { fail(error.localizedDescription, token: token) }
        case .userSpeaking(let itemID):
            ensureTurn(id: itemID, role: .user)
            phase = .userSpeaking
        case .userFinished(let itemID):
            ensureTurn(id: itemID, role: .user)
            phase = .thinking
        case .assistantStarted:
            phase = .thinking
        case .audio(let itemID, let pcm):
            guard !interruptedItems.contains(itemID) else { return }
            do {
                try audio?.enqueue(pcm, itemID: itemID)
                assistantItemID = itemID
                ensureTurn(id: itemID, role: .assistant)
                phase = .assistantSpeaking
            } catch { fail(error.localizedDescription, token: token) }
        case .transcript(let itemID, let isUser, let text):
            guard !interruptedItems.contains(itemID) else { return }
            ensureTurn(id: itemID, role: isUser ? .user : .assistant)
            if let index = transcript.firstIndex(where: { $0.id == itemID }) {
                transcript[index].text = text
                transcript[index].isFinal = isUser || fullyPlayed.contains(itemID)
            }
        case .assistantFinished:
            if assistantItemID != nil { audio?.responseFinished() }
            else if phase == .thinking { phase = .listening }
        }
    }

    private func startSending(_ input: AsyncThrowingStream<SpeakingMicrophoneChunk, Error>, updates: AsyncStream<Update>,
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
        updateTask = Task { [weak self] in
            do {
                for await update in updates {
                    guard self?.generation == token, !Task.isCancelled else { return }
                    try await session.update(instructions: update.instructions, material: update.material)
                }
            } catch { self?.fail(error.localizedDescription, token: token) }
        }
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
        updates?.finish()
        updates = nil
        pendingUpdates = nil
        microphoneTask?.cancel()
        microphoneTask = nil
        updateTask?.cancel()
        updateTask = nil
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
        errorMessage = message
        self.phase = phase
    }
}
