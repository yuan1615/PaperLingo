import PaperCore
import SwiftUI

struct SpeakingMaterialPicker: View {
    @ObservedObject var store: AppStore
    let active: Bool
    @State private var showsMaterials = false
    @State private var browsing = false
    @State private var query = ""

    private var mode: SpeakingPracticeMode { store.speakingMode }
    private var source: SpeakingPracticeSource? { store.selectedSpeakingSource }
    private var modeSelection: Binding<SpeakingPracticeMode> {
        Binding(get: { store.speakingMode }, set: { store.changeSpeakingMode($0) })
    }

    var body: some View {
        Group {
            if active {
                HStack(spacing: 12) {
                    Menu {
                        Picker("练习主题", selection: modeSelection) {
                            ForEach(SpeakingPracticeMode.allCases, id: \.self) { choice in
                                Label(choice.title, systemImage: icon(choice)).tag(choice)
                            }
                        }.pickerStyle(.inline)
                    } label: {
                        Label(mode.title, systemImage: icon(mode)).fontWeight(.semibold)
                    }.menuStyle(.borderlessButton).fixedSize()
                        .accessibilityLabel("切换练习主题，当前为" + mode.title)
                    if let last = store.speakingMaterials.last {
                        Text(last.title).font(.callout).foregroundStyle(Palette.muted).lineLimit(1)
                            .truncationMode(.middle).help(last.title)
                    }
                    Spacer(minLength: 0)
                    if mode != .free || !store.speakingMaterials.isEmpty {
                        Button { openMaterials() } label: {
                            Label(store.speakingMaterials.isEmpty ? "选择材料" : "材料（\(store.speakingMaterials.count)）",
                                  systemImage: "paperclip")
                        }.fixedSize().accessibilityIdentifier("speaking.materials")
                            .popover(isPresented: $showsMaterials) { materialPanel }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("练习主题").font(.headline)
                    HStack(spacing: 8) {
                        ForEach(SpeakingPracticeMode.allCases, id: \.self) { choice in
                            Button { store.changeSpeakingMode(choice) } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: icon(choice)).accessibilityHidden(true)
                                    Text(choice.title).fontWeight(.medium)
                                }.font(.callout).frame(maxWidth: .infinity).padding(.vertical, 10)
                                    .foregroundStyle(choice == mode ? Palette.green : Palette.ink)
                                    .background(choice == mode ? Palette.pale : .clear, in: RoundedRectangle(cornerRadius: 8))
                                    .overlay { RoundedRectangle(cornerRadius: 8).stroke(choice == mode ? Palette.green : Palette.line) }
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .accessibilityAddTraits(choice == mode ? .isSelected : [])
                                .accessibilityIdentifier("speaking.mode." + choice.rawValue)
                        }
                    }
                    if mode != .free {
                        if hasChoices {
                            Button { openMaterials() } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "paperclip").foregroundStyle(Palette.muted)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(source?.title ?? chooseLabel).font(.callout).lineLimit(1).truncationMode(.middle)
                                        if let source { Text(coverage(source)).font(.caption).foregroundStyle(Palette.muted) }
                                    }
                                    Spacer(minLength: 4)
                                    Text(source == nil ? "选择" : "查看或更换").font(.callout)
                                    Image(systemName: "chevron.right").font(.caption)
                                }.foregroundStyle(Palette.green).padding(.vertical, 4).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityIdentifier("speaking.materials")
                                .popover(isPresented: $showsMaterials) { materialPanel }
                        } else {
                            Text(mode == .paper ? "导入论文后，可以选取摘要或一段原文来讨论。" : "查词后可从生词本选择词条，也可以直接告诉教练想练哪个词。")
                                .font(.callout).foregroundStyle(Palette.muted)
                        }
                    }
                }
            }
        }
    }

    private var chooseLabel: String { mode == .paper ? "选择论文" : "选择生词" }
    private var hasChoices: Bool { mode == .paper ? !store.papers.isEmpty : !store.words.isEmpty }

    private func openMaterials() {
        query = ""
        browsing = mode != .free && hasChoices && source == nil && (!active || store.speakingMaterials.isEmpty)
        showsMaterials = true
    }

    private func icon(_ choice: SpeakingPracticeMode) -> String {
        switch choice {
        case .paper: return "doc.text"
        case .vocabulary: return "text.book.closed"
        case .free: return "bubble.left.and.bubble.right"
        }
    }

    private func coverage(_ value: SpeakingPracticeSource) -> String {
        [value.coverage, value.page.map { "第 \($0 + 1) 页" }].compactMap { $0 }.joined(separator: " · ")
    }

    private var materialPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(browsing ? chooseLabel : (active ? "对话材料" : "材料预览")).font(.headline)
                Spacer()
                Button("完成") { showsMaterials = false }.controlSize(.small)
            }
            if browsing {
                browser
            } else {
                if mode != .free && hasChoices {
                    Button(source == nil ? chooseLabel : (mode == .paper ? "更换论文" : "更换生词")) {
                        query = ""
                        browsing = true
                    }
                }
                if let source {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(source.title).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                        Text(coverage(source)).font(.caption).foregroundStyle(Palette.muted)
                    }
                    if !source.text.isEmpty {
                        ScrollView { Text(source.text).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                            .font(.callout).lineSpacing(3).frame(maxHeight: 150)
                    }
                    if active {
                        if store.speakingMaterials.contains(source) {
                            Label("已加入对话", systemImage: "checkmark").font(.callout).foregroundStyle(Palette.green)
                        } else {
                            Button("将这份材料带入当前对话") { store.addSpeakingMaterial() }
                                .buttonStyle(.borderedProminent).tint(Palette.green)
                                .accessibilityIdentifier("speaking.addMaterial")
                        }
                    }
                }
                if active, !store.speakingMaterials.isEmpty, !(store.speakingMaterials.count == 1 && store.speakingMaterials.first == source) {
                    Divider()
                    Text("已加入的材料").font(.subheadline.weight(.medium))
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(store.speakingMaterials, id: \.self) { item in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title).font(.callout)
                                    Text(coverage(item)).font(.caption).foregroundStyle(Palette.muted)
                                }.textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 110)
                } else if active, source == nil, !hasChoices, mode != .free {
                    Text(mode == .paper ? "研究库里还没有论文。" : "生词本里还没有词条。").font(.callout).foregroundStyle(Palette.muted)
                }
            }
        }.padding(16).frame(width: 360, alignment: .leading).foregroundStyle(Palette.ink)
    }

    private var browser: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(mode == .paper ? "搜索论文标题" : "搜索生词或短语", text: $query)
                .textFieldStyle(.roundedBorder)
            let results = mode == .paper
                ? store.papers.filter { matches($0.title) }.map { (id: $0.id, title: $0.title) }
                : store.words.filter { matches($0.text) }.map { (id: $0.id, title: $0.text) }
            if results.isEmpty {
                Text("没有匹配的材料").font(.callout).foregroundStyle(Palette.muted)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(results, id: \.id) { row in
                            Button { choose(row.id) } label: {
                                HStack {
                                    Text(row.title).font(.callout).lineLimit(2).multilineTextAlignment(.leading)
                                    Spacer(minLength: 4)
                                    if row.id == (mode == .paper ? store.speakingPaperID : store.speakingWordID) {
                                        Image(systemName: "checkmark").foregroundStyle(Palette.green)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(6).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(maxHeight: 230)
            }
            if source != nil {
                Button("清除选择") { choose(nil) }.controlSize(.small)
            }
        }
    }

    private func matches(_ title: String) -> Bool {
        query.isEmpty || title.localizedCaseInsensitiveContains(query)
    }

    private func choose(_ id: String?) {
        if mode == .paper {
            store.speakingPaperID = id
            store.speakingExcerpt = nil
        } else {
            store.speakingWordID = id
        }
        browsing = false
        if id == nil && !active { showsMaterials = false }
    }
}
