import PaperCore
import SwiftUI

struct SpeakingPracticeScreen: View {
    @ObservedObject var store: AppStore
    @ObservedObject var session: SpeakingSession
    @State private var showSaved = false
    @State private var edit: SpeakingPracticeExpression?
    @State private var showTranscript = false
    @State private var showSource = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("口语练习").font(.system(size: 26, weight: .medium, design: .serif))
                Spacer()
                Button {
                    showSaved.toggle()
                } label: {
                    Label(showSaved ? "回到练习" : "已保存表达（\(store.speakingExpressions.count)）",
                          systemImage: showSaved ? "arrow.uturn.backward" : "bookmark")
                }.disabled(session.isActive)
            }
            if showSaved {
                if store.speakingExpressions.isEmpty {
                    EmptyContent(icon: "bookmark", title: "还没有保存的表达", detail: "练习后，挑一句想在下次用到的英语存到这里。")
                } else {
                    ScrollView { LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(store.speakingExpressions) { SpeakingSavedRow(store: store, expression: $0) }
                    } }
                }
            } else {
                Picker("练习模式", selection: Binding(get: { store.speakingMode }, set: { store.changeSpeakingMode($0) })) {
                    ForEach(SpeakingPracticeMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 430)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        materialCard
                        callCard
                        if !session.transcript.isEmpty { transcript }
                        if session.phase == .ended || (!session.isActive && !session.transcript.isEmpty) { recap }
                    }.padding(.bottom, 15).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onReceive(session.$transcript) { store.trackSpeakingTurns($0) }
        .sheet(item: $edit) { expression in
            SpeakingExpressionEditor(store: store, expression: expression, sources: store.speakingMaterials)
        }
    }

    private var materialCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch store.speakingMode {
            case .paper:
                Picker("讨论论文", selection: Binding(get: { store.speakingPaperID }, set: {
                    store.speakingPaperID = $0; store.speakingExcerpt = nil
                })) {
                    Text("选择论文").tag(nil as String?)
                    ForEach(store.papers) { Text($0.title).tag(Optional($0.id)) }
                }.disabled(store.papers.isEmpty)
                if store.papers.isEmpty { Text("导入一篇论文后，可以围绕它的摘要或原文选区练口语。").font(.callout) }
            case .vocabulary:
                Picker("目标词", selection: $store.speakingWordID) {
                    Text("选择词条").tag(nil as String?)
                    ForEach(store.words) { Text($0.text).tag(Optional($0.id)) }
                }.disabled(store.words.isEmpty)
                if store.words.isEmpty { Text("在阅读空间查过的词会出现在这里，也可以直接告诉教练你想练哪个词。").font(.callout) }
            case .free:
                Text("今天想聊什么？").font(.system(size: 18, weight: .medium, design: .serif))
                Text("用英语说说刚读到的观点，或者让教练问你一个问题。").font(.callout).foregroundStyle(Palette.muted)
            }
            if let source = store.selectedSpeakingSource {
                DisclosureGroup(isExpanded: $showSource) {
                    Text(source.text.isEmpty ? source.title : source.text)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                } label: {
                    Text([source.coverage, source.page.map { "第 \($0 + 1) 页" }].compactMap { $0 }.joined(separator: " · "))
                }.font(.callout)
                if session.isActive && !store.speakingMaterials.contains(source) {
                    Button("将这份材料带入当前对话") { store.addSpeakingMaterial() }.buttonStyle(.bordered)
                }
            }
            if session.isActive, !store.speakingMaterials.isEmpty {
                Text("本次已选 · " + store.speakingMaterials.map(\.title).joined(separator: "、"))
                    .font(.caption).foregroundStyle(Palette.muted).textSelection(.enabled)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
    }

    private var status: String {
        switch session.phase {
        case .idle: return "准备开始"
        case .requestingPermission: return "正在请求麦克风权限"
        case .connecting: return "正在连接 OpenAI"
        case .listening: return "轮到你说"
        case .userSpeaking: return "正在听你说"
        case .thinking: return "教练正在思考"
        case .assistantSpeaking: return "教练正在说，可以插话"
        case .ended: return "对话已结束"
        case .failed: return "对话未连接"
        }
    }

    private var callCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(session.isMuted && session.isActive ? status + " · 已静音" : status,
                  systemImage: session.isActive ? "waveform" : "mic")
                .font(.system(size: 21, weight: .medium, design: .serif)).accessibilityIdentifier("speaking.status")
            if session.isActive {
                if let start = store.speakingStartTime { Text(start, style: .timer).monospacedDigit().font(.caption) }
                HStack {
                    Button { session.toggleMute() } label: {
                        Label(session.isMuted ? "打开麦克风" : "静音", systemImage: session.isMuted ? "mic.slash" : "mic")
                    }.buttonStyle(.bordered).disabled(session.phase == .requestingPermission || session.phase == .connecting)
                    if session.phase == .assistantSpeaking || session.phase == .thinking {
                        Button("我来说") { session.interrupt() }.buttonStyle(.bordered)
                    }
                    Spacer()
                    Button("结束对话") { session.stop() }.buttonStyle(.borderedProminent).tint(Palette.green)
                }
            } else {
                Text("开始后，麦克风声音和选中的材料将直接发给 OpenAI，按 API 用量计费。")
                    .font(.callout).foregroundStyle(Palette.ink)
                Button { store.startSpeaking() } label: {
                    Label(session.phase == .idle ? "开始对话" : "开始新对话", systemImage: "mic.fill")
                }.buttonStyle(PrimaryButton()).accessibilityIdentifier("speaking.start")
            }
            if let error = session.errorMessage { Text(error).font(.callout).foregroundStyle(Palette.orange).textSelection(.enabled) }
            if let message = store.speakingMessage { Text(message).font(.callout).textSelection(.enabled) }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.pale, in: RoundedRectangle(cornerRadius: 12))
    }

    private var transcript: some View {
        DisclosureGroup(isExpanded: $showTranscript) {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(session.transcript.filter { !$0.text.isEmpty }) { turn in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(turn.role == .user ? "我" : "教练").font(.caption).foregroundStyle(Palette.muted)
                            Spacer()
                            if turn.isFinal && turn.role == .user && !session.isActive {
                                Button("保存这句") { edit = draft(turn: turn) }.font(.caption)
                            }
                        }
                        Text(turn.text).textSelection(.enabled)
                    }
                }
            }.padding(.top, 8)
        } label: { Text("本次对话转写").font(.headline) }
    }

    private func draft(turn: SpeakingTurn? = nil) -> SpeakingPracticeExpression {
        let context = turn.flatMap { store.speakingTurnContexts[$0.id] }
        return .init(original: turn?.text ?? "", improved: "", mode: context?.mode ?? store.speakingMode, source: context?.source)
    }

    private var recap: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("练习复盘").font(.system(size: 19, weight: .medium, design: .serif))
            HStack {
                Button("生成表达建议") { store.suggestSpeakingExpressions() }
                    .disabled(store.speakingFeedbackBusy || !session.transcript.contains { $0.role == .user && !$0.text.isEmpty })
                Button("手动记一句") { edit = draft() }
                if store.speakingFeedbackBusy { ProgressView().controlSize(.small) }
            }
            Text("生成建议会将最近最多 12 段自己的转写发给 OpenAI，返回最多 3 条供你挑选。")
                .font(.caption).foregroundStyle(Palette.muted)
            ForEach(store.speakingSuggestions) { suggestion in
                VStack(alignment: .leading, spacing: 5) {
                    Text(suggestion.original).font(.callout).foregroundStyle(Palette.muted)
                    Text(suggestion.improved).font(.body)
                    Text(suggestion.reason).font(.caption)
                    Button("编辑并保存") { edit = suggestion }.buttonStyle(.bordered)
                }.padding(.vertical, 6)
            }
            ForEach(store.speakingMaterials.filter { $0.wordID != nil }) { source in
                HStack {
                    Text(source.title).lineLimit(1)
                    Spacer()
                    if let id = source.wordID, store.speakingRated.contains(id) {
                        Text("已评分").font(.caption).foregroundStyle(Palette.green)
                    } else {
                        ForEach(Grade.allCases, id: \.rawValue) { grade in
                            Button(grade.title) { store.rateSpeakingSource(source, grade: grade) }
                        }.controlSize(.small)
                    }
                }
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct SpeakingSavedRow: View {
    @ObservedObject var store: AppStore
    let expression: SpeakingPracticeExpression
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(expression.mode.title + " · " + expression.created.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(Palette.muted)
                Spacer()
                Button("编辑") { editing = true }.controlSize(.small)
            }
            if !expression.original.isEmpty { Text(expression.original).foregroundStyle(Palette.muted).textSelection(.enabled) }
            if !expression.improved.isEmpty { Text(expression.improved).font(.headline).textSelection(.enabled) }
            if !expression.reason.isEmpty { Text(expression.reason).font(.callout).textSelection(.enabled) }
            if let source = expression.source {
                if let paper = store.papers.first(where: { $0.id == source.paperID }) {
                    Button { store.open(paper, page: source.page) } label: {
                        Label((source.paperTitle ?? paper.title) + (source.page.map { " · 第 \($0 + 1) 页" } ?? ""), systemImage: "doc.text")
                    }.buttonStyle(.link).font(.caption)
                } else { Text(source.title).font(.caption).foregroundStyle(Palette.muted) }
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 9))
            .sheet(isPresented: $editing) {
                SpeakingExpressionEditor(store: store, expression: expression, sources: expression.source.map { [$0] } ?? [])
            }
    }
}

private struct SpeakingExpressionEditor: View {
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
