import PaperCore
import SwiftUI

struct SpeakingPracticeScreen: View {
    @ObservedObject var store: AppStore
    @ObservedObject var session: SpeakingSession
    @AppStorage("speakingInputMode") private var preferredInput = SpeakingInputMode.microphone
    @State private var reviewing = false
    @State private var showSaved = false
    @State private var edit: SpeakingPracticeExpression?
    @State private var draft = ""
    @State private var startError: String?
    @State private var sending = false
    @State private var showResearchProgress = false
    @FocusState private var focused: Bool

    private var hasReview: Bool {
        !session.isActive && (session.phase == .ended || !session.transcript.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if showSaved {
                SpeakingSavedExpressionsView(store: store)
            } else if session.isActive {
                SpeakingMaterialPicker(store: store, active: true)
                    .padding(.horizontal, 22).padding(.vertical, 9)
                Divider()
                SpeakingConversationView(session: session, mode: store.speakingMode, canUseStarter: draft.isEmpty) { starter in
                    draft = starter
                    focused = true
                }
                Divider()
                liveControls
            } else if reviewing && hasReview {
                review
            } else {
                preparation
            }
        }
        .foregroundStyle(Palette.ink)
        .onReceive(session.$transcript) { store.trackSpeakingTurns($0) }
        .onChange(of: session.phase) { _, phase in
            switch phase {
            case .ended:
                draft = ""
                reviewing = true
            case .failed, .audioUnavailable:
                reviewing = !session.transcript.isEmpty
                startError = session.errorMessage
            default: break
            }
        }
        .sheet(item: $edit) { expression in
            SpeakingExpressionEditor(store: store, expression: expression, sources: store.speakingMaterials)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { store.layout.sidebarVisible.toggle() } label: { Image(systemName: "sidebar.left") }
                .buttonStyle(ReadingButtonStyle()).help("显示或收起导航").accessibilityLabel("显示或收起导航")
            Text(showSaved ? "已保存表达" : "口语练习")
                .font(.system(size: 24, weight: .semibold, design: .serif)).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 4)
            if store.researchBusy {
                Button { showResearchProgress.toggle() } label: { Image(systemName: "doc.badge.clock") }
                    .help("查看论文整理进度").accessibilityLabel("查看论文整理进度")
                    .popover(isPresented: $showResearchProgress) { ResearchCompactStatus(store: store, audio: store.audio) }
            }
            if session.isActive {
                if let start = store.speakingStartTime {
                    Text(start, style: .timer).monospacedDigit().font(.callout).foregroundStyle(.secondary)
                        .accessibilityLabel("对话时长")
                }
                Button { session.stop() } label: { Label("结束对话", systemImage: "phone.down") }
                    .accessibilityIdentifier("speaking.finish")
            } else if showSaved {
                Button { showSaved = false } label: { Label("回到练习", systemImage: "arrow.uturn.backward") }
            } else {
                if hasReview && !reviewing {
                    Button("上次复盘") { reviewing = true }
                }
                Button { showSaved = true } label: {
                    Label("已保存表达", systemImage: "bookmark")
                }.accessibilityIdentifier("speaking.saved")
                if reviewing && hasReview {
                    Button {
                        startError = nil
                        reviewing = false
                    } label: { Label("新对话", systemImage: "plus") }
                        .buttonStyle(.borderedProminent).tint(Palette.green).accessibilityIdentifier("speaking.restart")
                }
            }
        }
        .buttonStyle(.bordered).controlSize(.regular)
        .padding(.horizontal, 22).frame(height: 58)
    }

    private var preparation: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SpeakingMaterialPicker(store: store, active: false)
                Divider()
                VStack(alignment: .leading, spacing: 9) {
                    Text("我的输入方式").font(.headline)
                    HStack(spacing: 8) {
                        inputChoice(.microphone, title: "用麦克风", icon: "mic")
                        inputChoice(.keyboard, title: "用键盘", icon: "keyboard")
                    }
                    Text(preferredInput == .keyboard
                         ? "你打字，教练用语音回答。麦克风保持关闭。"
                         : "你和教练用语音交流，教练说话时也可以插话。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Divider()
                HStack(spacing: 18) {
                    Text(preferredInput == .keyboard
                         ? "已发送的文字和选中的材料将交给 OpenAI，按 API 用量计费。"
                         : "麦克风声音和选中的材料将交给 OpenAI，按 API 用量计费。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 2)
                    Button {
                        store.startSpeaking(inputMode: preferredInput)
                        startError = session.isActive ? nil : store.speakingMessage
                    } label: {
                        Label("开始对话", systemImage: "arrow.right.circle.fill").fixedSize()
                    }.buttonStyle(PrimaryButton()).accessibilityIdentifier("speaking.start")
                }
                if let startError { errorNote(startError) }
            }
            .padding(24).frame(maxWidth: 720, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.line).allowsHitTesting(false) }
            .padding(24).frame(maxWidth: .infinity)
        }
    }

    private func inputChoice(_ mode: SpeakingInputMode, title: String, icon: String) -> some View {
        let selected = preferredInput == mode
        return Button {
            preferredInput = mode
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon).frame(width: 20)
                Text(title).fontWeight(.medium)
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Palette.green : Palette.line)
            }
            .padding(.horizontal, 12).frame(height: 39)
            .background(selected ? Palette.pale : Color.white, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Palette.green : Palette.line) }
            .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var status: (text: String, icon: String) {
        switch session.phase {
        case .requestingPermission: return ("正在请求麦克风权限", "mic")
        case .connecting: return ("正在连接 OpenAI…", "antenna.radiowaves.left.and.right")
        case .listening, .userSpeaking:
            if session.inputMode == .keyboard { return ("轮到你打字", "keyboard") }
            if session.isMuted { return ("麦克风已静音", "mic.slash") }
            return session.phase == .userSpeaking ? ("正在听你说", "waveform") : ("轮到你说", "mic.fill")
        case .sendingText: return ("正在发送…", "paperplane")
        case .thinking: return ("教练正在思考", "ellipsis.bubble")
        case .assistantSpeaking: return ("教练正在回答", "speaker.wave.2.fill")
        case .interrupting: return ("正在打断回答…", "pause")
        case .audioUnavailable: return ("音频设备未就绪", "speaker.slash")
        case .failed: return ("连接已断开", "wifi.slash")
        case .ended: return ("对话已结束", "checkmark.circle")
        case .idle: return ("准备开始", "mic")
        }
    }

    private var liveControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Label(status.text, systemImage: status.icon)
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.green)
                    .accessibilityIdentifier("speaking.status")
                if session.usingStandardAudio {
                    Image(systemName: "headphones").foregroundStyle(.secondary)
                        .help("当前使用标准音频。佩戴耳机可减少回声。").accessibilityLabel("标准音频，建议佩戴耳机")
                }
                Spacer(minLength: 4)
                if session.inputMode == .microphone {
                    Button { session.toggleMute() } label: {
                        Label(session.isMuted ? "取消静音" : "静音", systemImage: session.isMuted ? "mic.slash.fill" : "mic")
                    }.disabled(session.phase == .requestingPermission || session.phase == .connecting)
                        .accessibilityIdentifier("speaking.mute")
                }
                Button { session.interrupt() } label: { Label("打断回答", systemImage: "stop.circle") }
                    .disabled(session.phase != .assistantSpeaking && session.phase != .thinking)
                    .accessibilityIdentifier("speaking.interrupt")
            }.frame(minHeight: 27).buttonStyle(.bordered)
            if session.inputMode == .keyboard {
                HStack(alignment: .bottom, spacing: 10) {
                    TextField("写给教练…", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain).font(.system(size: 15))
                        .lineLimit(1...4).focused($focused)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(.white, in: RoundedRectangle(cornerRadius: 9))
                        .overlay {
                            RoundedRectangle(cornerRadius: 9).strokeBorder(focused ? Palette.green : Palette.line)
                                .allowsHitTesting(false)
                        }
                        .accessibilityLabel("写给教练的消息").accessibilityIdentifier("speaking.message")
                    Button(action: sendDraft) { Label("发送", systemImage: "arrow.up").fixedSize() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent).controlSize(.large).tint(Palette.green)
                        .disabled(!canSendDraft).help("发送消息（⌘↩）").accessibilityIdentifier("speaking.send")
                }
                Text(overLimit ? "每条消息最多 \(VoicePracticeSession.maximumTextCharacters) 个字符，请分开发送。" : "⌘↩ 发送")
                    .font(.caption).foregroundStyle(overLimit ? Palette.orange : .secondary)
            }
        }
        .frame(maxWidth: 900).padding(.horizontal, 22).padding(.vertical, 12)
        .frame(maxWidth: .infinity).background(Palette.cream)
        .onAppear { if session.inputMode == .keyboard { focused = true } }
    }

    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var overLimit: Bool { trimmedDraft.count > VoicePracticeSession.maximumTextCharacters || trimmedDraft.utf8.count > 64_000 }
    private var canSendDraft: Bool { session.canSendText && !sending && !trimmedDraft.isEmpty && !overLimit }

    private func sendDraft() {
        guard canSendDraft else { return }
        let message = draft
        sending = true
        Task { @MainActor in
            defer { sending = false }
            if await session.sendText(message), draft == message { draft = "" }
        }
    }

    private var review: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let error = session.errorMessage { errorNote(error) }
                SpeakingReviewPanel(store: store, session: session) { edit = $0 }
                if !session.transcript.isEmpty {
                    Text("本次对话").font(.headline)
                    ForEach(session.transcript) { turn in
                        SpeakingMessageRow(turn: turn, save: turn.isFinal && turn.role == .user ? { save(turn) } : nil)
                    }
                }
            }
            .padding(22).frame(maxWidth: 900).frame(maxWidth: .infinity)
        }
    }

    private func save(_ turn: SpeakingTurn) {
        let context = store.speakingTurnContexts[turn.id]
        edit = .init(original: turn.text, improved: "", mode: context?.mode ?? store.speakingMode, source: context?.source)
    }

    private func errorNote(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(Palette.orange)
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }
}

struct SpeakingExpressionEditor: View {
    @ObservedObject var store: AppStore
    @State var expression: SpeakingPracticeExpression
    let sources: [SpeakingPracticeSource]
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("保存口语表达").font(.title2)
            TextField("我的原话", text: $expression.original, axis: .vertical)
            TextField("更自然的说法", text: $expression.improved, axis: .vertical)
            TextField("用法或修改理由", text: $expression.reason, axis: .vertical)
            Picker("练习模式", selection: $expression.mode) {
                ForEach(SpeakingPracticeMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if !sources.isEmpty {
                Picker("关联材料", selection: $expression.source) {
                    Text("独立表达").tag(nil as SpeakingPracticeSource?)
                    ForEach(sources) { Text($0.title + " · " + $0.coverage).tag(Optional($0)) }
                }
            }
            if let error { Text(error).foregroundStyle(Palette.orange) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("存到我的表达") {
                    do { try store.saveSpeakingExpression(expression); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).disabled(TextTools.clean(expression.original + expression.improved).isEmpty)
            }
        }.padding(22).frame(width: 440)
    }
}
