import PaperCore
import SwiftUI

struct SpeakingReviewPanel: View {
    @ObservedObject var store: AppStore
    @ObservedObject var session: SpeakingSession
    let edit: (SpeakingPracticeExpression) -> Void

    private var hasLearnerTurn: Bool {
        session.transcript.contains { $0.role == .user && $0.isFinal && !$0.text.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { title; Spacer(minLength: 12); actions }
                VStack(alignment: .leading, spacing: 10) { title; actions }
            }
            if hasLearnerTurn {
                Text("生成建议时，会把最近最多 12 条自己的发言发给 OpenAI，供你挑选最多 3 条修改建议。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let message = store.speakingMessage {
                Text(message).font(.callout).foregroundStyle(Palette.ink).textSelection(.enabled)
            }
            ForEach(store.speakingSuggestions) { suggestion in
                Divider()
                SpeakingExpressionText(expression: suggestion)
                Button { edit(suggestion) } label: {
                    Label("编辑并保存", systemImage: "bookmark")
                }.controlSize(.small)
            }
            let words = store.speakingMaterials.filter { $0.wordID != nil }
            if !words.isEmpty {
                Divider()
                Text("生词自评").font(.headline).foregroundStyle(Palette.ink)
                    .help("选择熟悉程度后，将更新这个词的复习进度。")
                ForEach(words) { source in
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            Text(source.title).fixedSize()
                            Spacer(minLength: 8)
                            rating(for: source)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text(source.title).fixedSize(horizontal: false, vertical: true)
                            rating(for: source)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.line).allowsHitTesting(false) }
        .accessibilityIdentifier("speaking.review")
    }

    private var title: some View {
        Text("练习复盘").font(.system(size: 19, weight: .medium, design: .serif))
            .foregroundStyle(Palette.ink).accessibilityAddTraits(.isHeader)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                edit(.init(original: "", improved: "", mode: store.speakingMode))
            } label: { Label("手动记一句", systemImage: "square.and.pencil") }
            Button { store.suggestSpeakingExpressions() } label: {
                HStack(spacing: 5) {
                    if store.speakingFeedbackBusy { ProgressView().controlSize(.mini) }
                    Text(store.speakingFeedbackBusy ? "正在生成…" : "生成表达建议")
                }
            }.buttonStyle(.borderedProminent).tint(Palette.green)
                .disabled(!hasLearnerTurn || store.speakingFeedbackBusy)
        }.fixedSize()
    }

    @ViewBuilder private func rating(for source: SpeakingPracticeSource) -> some View {
        if let id = source.wordID, store.speakingRated.contains(id) {
            Label("已评分", systemImage: "checkmark").font(.caption).foregroundStyle(Palette.green)
        } else {
            HStack(spacing: 5) {
                ForEach(Grade.allCases, id: \.rawValue) { grade in
                    Button(grade.title) { store.rateSpeakingSource(source, grade: grade) }
                        .accessibilityLabel("\(source.title)，\(grade.title)")
                }
            }.controlSize(.small)
        }
    }
}

struct SpeakingSavedExpressionsView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        if store.speakingExpressions.isEmpty {
            EmptyContent(icon: "bookmark", title: "还没有保存的表达", detail: "练习结束后，在对话中选「保存这句」，下次就能在这里找到。")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let days = Dictionary(grouping: store.speakingExpressions) { Calendar.current.startOfDay(for: $0.created) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(days.keys.sorted(by: >), id: \.self) { day in
                        Text(day.formatted(.dateTime.year().month().day().weekday()))
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                            .padding(.top, 9).accessibilityAddTraits(.isHeader)
                        ForEach(days[day] ?? []) { expression in
                            SpeakingSavedRow(store: store, expression: expression, showsDate: false)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 10)
            }
        }
    }
}

struct SpeakingSavedRow: View {
    @ObservedObject var store: AppStore
    let expression: SpeakingPracticeExpression
    var showsDate = true
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text(expression.mode.title).font(.caption.weight(.semibold)).foregroundStyle(Palette.green)
                Text(expression.created.formatted(date: showsDate ? .abbreviated : .omitted, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { editing = true } label: { Label("编辑", systemImage: "pencil") }
                    .controlSize(.small)
            }
            SpeakingExpressionText(expression: expression)
            if let source = expression.source {
                if let paper = store.papers.first(where: { $0.id == source.paperID }) {
                    Button { store.open(paper, page: source.page) } label: {
                        Label((source.paperTitle ?? paper.title) + (source.page.map { " · 第 \($0 + 1) 页" } ?? ""), systemImage: "doc.text")
                            .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    }.buttonStyle(.link).tint(Palette.green).font(.caption)
                } else {
                    Label(source.title, systemImage: source.wordID == nil ? "doc.text" : "text.book.closed")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.line).allowsHitTesting(false) }
        .sheet(isPresented: $editing) {
            SpeakingExpressionEditor(store: store, expression: expression, sources: expression.source.map { [$0] } ?? [])
        }
    }
}

private struct SpeakingExpressionText: View {
    let expression: SpeakingPracticeExpression

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(expression.improved.isEmpty ? expression.original : expression.improved)
                .font(.system(size: 16, weight: .medium, design: .serif)).foregroundStyle(Palette.ink)
            if !expression.original.isEmpty && !expression.improved.isEmpty && expression.improved != expression.original {
                Text("我的原话  " + expression.original).font(.callout).foregroundStyle(.secondary)
            }
            if !expression.reason.isEmpty {
                Text(expression.reason).font(.callout).foregroundStyle(Palette.ink)
            }
        }.textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }
}
