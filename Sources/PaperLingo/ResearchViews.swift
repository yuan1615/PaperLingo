import AppKit
import PaperCore
import SwiftUI

struct ResearchLibraryScreen: View {
    @ObservedObject var store: AppStore
    private var status: String { store.libraryStatusFilter }
    private var category: String { store.libraryCategoryFilter }
    private var tag: String { store.libraryTagFilter }
    private var favorites: Bool { store.libraryFavoritesOnly }
    private var sort: String { store.librarySort }
    private var filtered: [Paper] {
        let hasQuery = !TextTools.clean(store.libraryQuery).isEmpty
        let ranks = Dictionary(
            store.searchHits.enumerated().map { ($0.element.paperID, $0.offset) }, uniquingKeysWith: { $1 })
        return store.papers.filter { paper in
            let record = store.record(for: paper)
            return (!hasQuery || ranks[paper.id] != nil) && (status == "全部状态" || record.status.rawValue == status)
                && (category == "全部分类" || record.category == category) && (tag == "全部标签" || record.tags.contains(tag))
                && (!favorites || record.favorite)
        }.sorted { a, b in
            if hasQuery { return (ranks[a.id] ?? Int.max) < (ranks[b.id] ?? Int.max) }
            switch sort {
            case "最近阅读":
                return (store.record(for: a).lastOpened ?? .distantPast)
                    > (store.record(for: b).lastOpened ?? .distantPast)
            case "发表年份": return store.record(for: a).year > store.record(for: b).year
            case "标题": return a.title.localizedStandardCompare(b.title) == .orderedAscending
            default: return a.added > b.added
            }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(22)
            if store.researchBusy || store.researchError != nil || !store.researchMessage.isEmpty {
                ResearchProgress(store: store).padding(.horizontal, 22).padding(.bottom, 12)
            }
            Rectangle().fill(Palette.line).frame(height: 1)
            GeometryReader { geometry in
                let compact = geometry.size.width < 850
                HStack(spacing: 0) {
                    if !compact || store.catalogPaper == nil {
                        paperList.frame(width: compact ? nil : 310).frame(maxWidth: compact ? .infinity : nil)
                    }
                    if !compact { Rectangle().fill(Palette.line).frame(width: 1) }
                    if !compact || store.catalogPaper != nil {
                        VStack(spacing: 0) {
                            if compact {
                                HStack {
                                    Button {
                                        store.catalogPaperID = nil
                                    } label: {
                                        Label("返回论文列表", systemImage: "chevron.left")
                                    }.buttonStyle(ReadingButtonStyle())
                                    Spacer()
                                }.font(.system(size: 12)).padding(.horizontal, 18).padding(.vertical, 5)
                            }
                            if let paper = store.catalogPaper {
                                ResearchPaperDetail(store: store, paper: paper).id(paper.id)
                            } else {
                                EmptyContent(
                                    icon: "books.vertical", title: "让读过的论文，成为找得到的知识。", detail: "选择论文，查看档案、整理要点，或记下你的想法。"
                                ).frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }.task { store.indexLibraryText() }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("YOUR RESEARCH LIBRARY").font(.system(size: 9, design: .monospaced)).tracking(2)
                        .foregroundStyle(Palette.muted)
                    Text("研究库").font(.system(size: 28, weight: .medium, design: .serif))
                    Text("记下为什么读，也留住下次用得上的线索。").font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Menu {
                    Button("导入 PDF…") { store.choosePDF() }
                    Button("导入链接…") { store.showLink = true }
                    Divider()
                    Button("整理尚无完整汇总的论文") {
                        store.startResearch(
                            store.papers.filter {
                                store.digests[$0.id] == nil || store.digests[$0.id]?.isPartial == true
                            })
                    }
                    .disabled(store.researchBusy || store.searching)
                    Button("建立 / 更新全部检索索引") { store.startResearch(store.papers, summarize: false) }.disabled(
                        store.researchBusy || store.searching)
                } label: {
                    Label("导入与整理", systemImage: "plus")
                }.menuStyle(.borderlessButton).fixedSize().padding(10).background(
                    Palette.pale, in: RoundedRectangle(cornerRadius: 8))
            }
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
                TextField("搜索论文概览、标题、分类或笔记", text: $store.libraryQuery).textFieldStyle(.plain).onSubmit {
                    store.searchSemantically()
                }.onChange(of: store.libraryQuery) { store.searchKeywords() }
                if !store.libraryQuery.isEmpty {
                    Button {
                        store.libraryQuery = ""
                        store.searchKeywords()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }.buttonStyle(.plain).foregroundStyle(Palette.muted)
                }
                if store.searching { ProgressView().controlSize(.small) }
                Button("按意思查找") { store.searchSemantically() }.buttonStyle(.bordered).disabled(
                    store.libraryQuery.isEmpty || store.searching || store.researchBusy)
            }.font(.system(size: 12)).padding(11).background(.white, in: RoundedRectangle(cornerRadius: 9)).overlay(
                RoundedRectangle(cornerRadius: 9).stroke(Palette.line, lineWidth: 1))
            Text("每篇论文一个索引，以 AI 概览为主；原文与实验表保留供阅读核对。").font(.system(size:10)).foregroundStyle(Palette.muted)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    filters
                    Spacer()
                    sortPicker
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack { filters }
                    HStack {
                        sortPicker
                        Spacer()
                    }
                }
            }
            if !store.categories.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(store.categories, id: \.self) { name in
                            let count = store.papers.filter { store.record(for: $0).category == name }.count
                            Button {
                                store.libraryCategoryFilter = category == name ? "全部分类" : name
                            } label: {
                                Text("\(name) · \(count)").font(.system(size: 10)).padding(.horizontal, 10).padding(
                                    .vertical, 6
                                ).background(category == name ? Palette.pale : .white.opacity(0.7), in: Capsule())
                            }.buttonStyle(.plain).foregroundStyle(Palette.green)
                        }
                    }
                }
            }
            if store.extractingLibrary {
                Label("正在提取已有论文的原文证据…", systemImage: "doc.text.magnifyingglass").font(.system(size: 10))
                    .foregroundStyle(Palette.muted)
            }
            if !store.searchMessage.isEmpty {
                Text(store.searchMessage).font(.system(size: 10)).foregroundStyle(Palette.muted).textSelection(.enabled)
            }
        }
    }
    @ViewBuilder private var filters: some View {
        Picker("状态", selection: $store.libraryStatusFilter) {
            Text("全部状态").tag("全部状态")
            ForEach(ReadingStatus.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
        }.labelsHidden().frame(width: 110)
        Picker("分类", selection: $store.libraryCategoryFilter) {
            Text("全部分类").tag("全部分类")
            ForEach(store.categories, id: \.self) { Text($0).tag($0) }
        }.labelsHidden().frame(width: 120)
        Picker("标签", selection: $store.libraryTagFilter) {
            Text("全部标签").tag("全部标签")
            ForEach(store.allPaperTags, id: \.self) { Text($0).tag($0) }
        }.labelsHidden().frame(width: 120)
        Toggle(isOn: $store.libraryFavoritesOnly) { Image(systemName: "star.fill") }.toggleStyle(.button).help("只看收藏")
    }
    private var sortPicker: some View {
        Picker("排序", selection: $store.librarySort) {
            ForEach(["最近加入", "最近阅读", "发表年份", "标题"], id: \.self) { Text($0).tag($0) }
        }
        .labelsHidden().frame(width: 115)
    }
    private var paperList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(filtered.count) / \(store.papers.count) 篇 · \(store.researchNotes.count) 条个人记录").font(
                .system(size: 10)
            ).foregroundStyle(Palette.muted).padding(15)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(filtered) { paper in
                        Button {
                            store.catalogPaperID = paper.id
                        } label: {
                            ResearchPaperRow(
                                store: store, paper: paper, hit: store.searchHits.first { $0.paperID == paper.id })
                        }.buttonStyle(ReadingButtonStyle()).contextMenu {
                            Button("打开原文") { store.open(paper) }
                            Button("编辑资料") { store.metadataEditor = paper }
                            Button("导出 Markdown…") { store.exportArchive(paper) }
                            Button("移除论文…", role: .destructive) { store.pendingPaperDeletion = paper }
                        }
                    }
                    if filtered.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "doc.text.magnifyingglass").font(.system(size: 30, weight: .light))
                            Text(store.papers.isEmpty ? "先导入一篇论文" : "没有符合条件的论文").font(.system(size: 13))
                            Text("可调整筛选、换个关键词，\n或在建立索引后按意思查找。").font(.system(size: 11)).multilineTextAlignment(.center)
                                .foregroundStyle(Palette.muted)
                        }.frame(maxWidth: .infinity).padding(.vertical, 50)
                    }
                }.padding(.horizontal, 12).padding(.bottom, 20)
            }
        }.background(.white.opacity(0.25))
    }
}

struct ResearchPaperRow: View {
    @ObservedObject var store: AppStore
    let paper: Paper
    let hit: ResearchSearchHit?
    var body: some View {
        let record = store.record(for: paper)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(paper.title).font(.system(size: 13, weight: .semibold, design: .serif)).lineLimit(3)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                if record.favorite {
                    Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(Palette.orange)
                }
            }
            HStack {
                Text(record.status.rawValue)
                Text("·")
                Text(record.year.isEmpty ? paper.kind : record.year)
                Spacer()
                if let digest = store.digests[paper.id] {
                    Image(systemName: digest.isPartial == true ? "clock" : "sparkles").help(
                        digest.isPartial == true ? "阶段概览，全文尚未完成" : "已有 AI 汇总")
                }
            }.font(.system(size: 10)).foregroundStyle(Palette.muted)
            Text(([record.category] + Array(record.tags.prefix(2))).joined(separator: " · ")).font(.system(size: 10))
                .foregroundStyle(Palette.green).lineLimit(1)
            if let hit, !store.libraryQuery.isEmpty {
                Text(hit.snippet).font(.system(size: 11)).lineSpacing(3).foregroundStyle(Palette.muted).lineLimit(4)
                Text(hit.source + (hit.page.map { " · 第 \($0+1) 页" } ?? "")).font(.system(size: 9)).foregroundStyle(
                    Palette.green)
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(
            store.catalogPaperID == paper.id ? Palette.pale : .white.opacity(0.6),
            in: RoundedRectangle(cornerRadius: 10)
        ).overlay(
            RoundedRectangle(cornerRadius: 10).stroke(
                store.catalogPaperID == paper.id ? Palette.green.opacity(0.35) : Palette.line.opacity(0.6), lineWidth: 1
            )
        ).contentShape(Rectangle())
    }
}

struct ResearchProgress: View {
    @ObservedObject var store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                if store.researchBusy { ProgressView().controlSize(.small) }
                Text(store.researchMessage).font(.system(size: 11)).lineLimit(2)
                Spacer()
                if store.researchBusy {
                    Button("取消整理") { store.cancelResearch() }.buttonStyle(.bordered).font(.system(size: 10))
                } else {
                    Button {
                        store.researchError = nil
                        store.researchMessage = ""
                    } label: {
                        Image(systemName: "xmark")
                    }.buttonStyle(ReadingButtonStyle())
                }
            }
            if store.researchBusy {
                ProgressView(value: store.researchProgress).tint(Palette.green)
                Text("可继续阅读、关键词检索和写笔记；整理时暂缓翻译与 OmniVoice，系统语音仍可使用。").font(.system(size: 10)).foregroundStyle(
                    Palette.muted)
            }
            if let error = store.researchError {
                Text(error).font(.system(size: 11)).foregroundStyle(Palette.orange).textSelection(.enabled)
            }
        }.padding(12).background(Palette.pale.opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
    }
}

struct ResearchCompactStatus: View {
    @ObservedObject var store: AppStore
    @ObservedObject var audio: AudioService
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ProgressView().controlSize(.small)
                Text("本机论文整理").font(.system(size: 12, weight: .medium))
                Spacer()
                Button {
                    store.route = .library
                } label: {
                    Image(systemName: "books.vertical")
                }.buttonStyle(ReadingButtonStyle()).help("查看研究库与整理进度")
                Button {
                    store.cancelResearch()
                } label: {
                    Image(systemName: "xmark")
                }.buttonStyle(ReadingButtonStyle()).help("取消整理")
            }
            Text(store.researchMessage).font(.system(size: 10)).lineLimit(1)
            ProgressView(value: store.researchProgress).tint(Palette.green)
            if let error = audio.error {
                Text(error).font(.system(size: 10)).foregroundStyle(Palette.orange).lineLimit(2)
            }
        }.padding(14).frame(width: 300).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).overlay(
            RoundedRectangle(cornerRadius: 12).stroke(Palette.line, lineWidth: 1)
        ).shadow(color: .black.opacity(0.08), radius: 12)
    }
}

struct ResearchPaperDetail: View {
    @ObservedObject var store: AppStore
    let paper: Paper
    @State private var tab = 0
    @State private var noteToDelete: PaperNote?
    init(store: AppStore, paper: Paper) {
        self.store = store
        self.paper = paper
        let source = store.searchHits.first { $0.paperID == paper.id }?.source
        _tab = State(initialValue: source == "笔记" ? 2 : (["汇总","论文概览"].contains(source ?? "") ? 1 : (source == "实验记录" ? 3:0)))
    }
    private var notes: [PaperNote] {
        let values = store.researchNotes.filter { $0.paperID == paper.id }
        let query = TextTools.clean(store.libraryQuery)
        guard !query.isEmpty else { return values }
        func matches(_ note: PaperNote) -> Bool {
            [note.title, note.body, note.quote].joined(separator: " ").range(of: query, options: .caseInsensitive)
                != nil
        }
        return values.sorted { a, b in
            if matches(a) != matches(b) { return matches(a) }
            return a.updated > b.updated
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text(paper.title).font(.system(size: 23, weight: .medium, design: .serif)).lineLimit(4).textSelection(
                    .enabled)
                ViewThatFits(in: .horizontal) {
                    HStack {
                        actions
                        Spacer()
                        statusPicker
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { actions }
                        statusPicker
                    }
                }
                Picker("论文详情", selection: $tab) {
                    Text("档案").tag(0)
                    Text("实验与证据").tag(3)
                    Text("AI 概览").tag(1)
                    Text("笔记 \(notes.count)").tag(2)
                }.pickerStyle(.segmented)
            }.padding(22)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let hit = store.searchHits.first(where: { $0.paperID == paper.id }), !store.libraryQuery.isEmpty
                    {
                        searchMatch(hit)
                    }
                    switch tab {
                    case 0: archive
                    case 1: digest
                    case 3: experimentalRecords
                    default: personalNotes
                    }
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.onChange(of: store.digests[paper.id]?.id) { tab = 1 }
            .onChange(of: store.searchHits.first { $0.paperID == paper.id }?.source) {
                if let source = store.searchHits.first(where: { $0.paperID == paper.id })?.source {
                    if source == "笔记" { tab = 2 } else if source == "汇总" { tab = 1 } else if source == "实验记录" {tab=3}
                }
            }
            .confirmationDialog(
                "删除这条个人笔记？", isPresented: Binding(get: { noteToDelete != nil }, set: { if !$0 { noteToDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("删除笔记", role: .destructive) {
                    if let note = noteToDelete { store.removeNote(note) }
                    noteToDelete = nil
                }
                Button("取消", role: .cancel) { noteToDelete = nil }
            } message: {
                Text("删除后无法在 app 内撤销，可先导出论文档案。")
            }
    }
    @ViewBuilder private var actions: some View {
        Button {
            store.open(paper)
        } label: {
            Label("读原文", systemImage: "doc.text")
        }.buttonStyle(PrimaryButton())
        Button {
            store.newNote(paper)
        } label: {
            Image(systemName: "square.and.pencil")
        }.buttonStyle(ReadingButtonStyle()).help("新建笔记")
        Button {
            store.toggleFavorite(paper)
        } label: {
            Image(systemName: store.record(for: paper).favorite ? "star.fill" : "star")
        }.buttonStyle(ReadingButtonStyle()).help("收藏论文")
        Menu {
            Button("编辑文献信息与分类…") { store.metadataEditor = paper }
            Button("导出档案与笔记 Markdown…") { store.exportArchive(paper) }
            Divider()
            Button("重新提取正文并整理") { store.startResearch([paper], refreshText: true) }.disabled(
                store.researchBusy || store.searching)
            Button("建立 / 更新检索索引") { store.startResearch([paper], summarize: false) }.disabled(
                store.researchBusy || store.searching)
            Button("移除论文…", role: .destructive) { store.pendingPaperDeletion = paper }
        } label: {
            Image(systemName: "ellipsis")
        }.menuStyle(.borderlessButton).frame(width: 28)
    }
    private var statusPicker: some View {
        Picker(
            "阅读状态",
            selection: Binding(get: { store.record(for: paper).status }, set: { store.setStatus($0, for: paper) })
        ) { ForEach(ReadingStatus.allCases, id: \.rawValue) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(
            width: 115)
    }
    private var archive: some View {
        let r = store.record(for: paper)
        return VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("文献资料").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("编辑资料") { store.metadataEditor = paper }.buttonStyle(.bordered).font(.system(size: 11))
            }
            VStack(alignment: .leading, spacing: 12) {
                meta("作者", r.authors)
                meta("年份 / 出处", [r.year, r.venue].filter { !$0.isEmpty }.joined(separator: " · "))
                meta("DOI", r.doi)
                meta("arXiv", r.arxiv)
                meta("来源", paper.source)
                meta("分类", r.category)
                meta("标签", r.tags.joined(separator: " · "))
                meta("导入时间", paper.added.formatted(date: .abbreviated, time: .omitted))
                meta("最后阅读", r.lastOpened?.formatted(date: .abbreviated, time: .shortened) ?? "")
                if let date = r.completed { meta("完成阅读", date.formatted(date: .abbreviated, time: .omitted)) }
            }
            Divider()
            Text("我为什么保留这篇论文").font(.system(size: 14, weight: .semibold))
            Text(r.purpose.isEmpty ? "写下与你的课题有什么关系，或什么时候可能用到它。可在「编辑资料」中补充。" : r.purpose).font(.system(size: 12))
                .lineSpacing(5).foregroundStyle(r.purpose.isEmpty ? Palette.muted : Palette.ink).textSelection(.enabled)
            if let status = store.textStatuses[paper.id] {
                Label(
                    status.chunkCount == 0
                        ? "未提取到文字；扫描件需先 OCR" : "\(status.totalPages) 页原文已保存 · 每篇一个概览索引",
                    systemImage: status.chunkCount == 0 ? "doc.viewfinder" : "doc.text.magnifyingglass"
                ).font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            Divider()
            if let ledger=store.ledgers[paper.id] {
                Button("查看实验记录与原文证据（\(ledger.experiments.filter{$0.kind == .experiment}.count)）"){tab=3}.buttonStyle(.bordered)
            }
            if let digest = store.digests[paper.id] {
                Text(digest.isPartial == true ? "阶段概览 · 全文尚未完成" : "一句话回顾").font(.system(size: 14, weight: .semibold))
                Text(digest.oneLine).font(.system(size: 13)).lineSpacing(5).textSelection(.enabled)
                Button(digest.isPartial == true ? "查看阶段概览与证据" : "查看 AI 概览与证据") { tab = 1 }.buttonStyle(.bordered)
            } else {
                Text("还没有 AI 汇总").font(.system(size: 14, weight: .semibold))
                Text("整理会提取研究问题、方法、贡献和局限，并保留可回到原文的证据。个人笔记与手工资料会单独保留。").font(.system(size: 12)).foregroundStyle(
                    Palette.muted
                ).lineSpacing(5)
                analyzeButton
            }
        }
    }
    private func meta(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title).font(.system(size: 11)).foregroundStyle(Palette.muted).frame(width: 76, alignment: .leading)
            Text(value.isEmpty ? "未记录" : value).font(.system(size: 12)).foregroundStyle(
                value.isEmpty ? Palette.muted : Palette.ink
            ).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var analyzeButton: some View {
        Button {
            store.startResearch([paper])
        } label: {
            Label(
                store.digests[paper.id] == nil
                    ? "用本地模型整理论文" : (store.digests[paper.id]?.isPartial == true ? "继续全文整理" : "更新 AI 汇总"),
                systemImage: "sparkles")
        }.buttonStyle(PrimaryButton()).disabled(store.researchBusy || store.searching)
    }
    @ViewBuilder private var digest: some View {
        if let digest = store.digests[paper.id] {
            if digest.isPartial == true {
                Label("阶段预览：仅基于 \(digest.processedPages) 个有文字页面，全文尚未完成。可先阅读；如已取消，可继续整理。", systemImage: "clock").font(
                    .system(size: 12, weight: .medium)
                ).foregroundStyle(Palette.orange).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
            }
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(digest.oneLine).font(.system(size: 17, weight: .medium, design: .serif)).lineSpacing(6)
                        .textSelection(.enabled)
                    Text("AI 生成 · \(digest.created.formatted(date:.abbreviated,time:.shortened))").font(
                        .system(size: 10)
                    ).foregroundStyle(Palette.muted)
                }
                Spacer()
            }
            Text(digest.pipeline == ResearchModels.structuredVersion ? "基于已保存的实验记录和 \(digest.processedPages) 页重点证据生成；原文件共 \(digest.totalPages) 页。全部文字另存供检索，未逐段交给大模型，未解读图片。指标直接取自实验记录，请核对表头、条件及解释。" : "旧版分层汇总：已处理含文字的 \(digest.processedPages) 页 / 原文件共 \(digest.totalPages) 页；仅分析文字层，未解读图片或图表。可重新整理生成结构化记录。"
            ).font(
                .system(size: 10)
            ).foregroundStyle(Palette.muted).lineSpacing(4)
            if store.textStatuses[paper.id]?.sourceHash != digest.sourceHash {
                Label("原文已变化，建议更新汇总", systemImage: "arrow.clockwise").font(.system(size: 11)).foregroundStyle(
                    Palette.orange)
            }
            if digest.rejectedEvidence > 0 {
                Text("本次丢弃了 \(digest.rejectedEvidence) 条无法与原文匹配的引用。缺少证据的要点未显示。").font(.system(size: 10))
                    .foregroundStyle(Palette.orange)
            }
            if let rejected=digest.rejectedFields,rejected>0 {
                Text("\(rejected) 个字段或定位需要进一步核对，已保留可匹配部分与完整原文；详见实验记录。").font(.system(size:10)).foregroundStyle(Palette.orange)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("建议分类：\(digest.suggestedCategory.isEmpty ? "未明确" : digest.suggestedCategory)").font(
                    .system(size: 12, weight: .medium))
                Text(digest.suggestedTags.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(
                    Palette.muted)
                DisclosureGroup("核对文献资料建议") {
                    VStack(alignment: .leading, spacing: 10) {
                        meta("标题", digest.suggestedTitle)
                        meta("作者", digest.suggestedAuthors.joined(separator: ", "))
                        meta("年份", digest.suggestedYear)
                        meta("出处", digest.suggestedVenue)
                        meta("DOI", digest.suggestedDOI)
                        meta("arXiv", digest.suggestedArxiv)
                    }.padding(.vertical, 8)
                }.font(.system(size: 11))
                Button("采用分类与空缺资料建议") { store.applySuggestions(digest, to: paper) }.buttonStyle(.bordered).font(
                    .system(size: 11))
                Text("仅补全空缺资料、未分类项并合并标签；已有手工内容保留。作者和年份等建议仍需对照首页核对。").font(.system(size: 10)).foregroundStyle(
                    Palette.muted)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(
                Palette.pale, in: RoundedRectangle(cornerRadius: 10))
            ForEach(DigestTopic.allCases, id: \.rawValue) { topic in
                VStack(alignment: .leading, spacing: 12) {
                    Text(topic.title).font(.system(size: 15, weight: .semibold))
                    let points = digest.points.filter { $0.topic == topic }
                    if points.isEmpty { Text("本次未提取到有证据的要点。").font(.system(size: 11)).foregroundStyle(Palette.muted) }
                    ForEach(points) { point in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(point.text).font(.system(size: 13)).lineSpacing(5).textSelection(.enabled)
                            DisclosureGroup {
                                Text(point.quote).font(.system(size: 12, design: .serif)).foregroundStyle(Palette.muted)
                                    .lineSpacing(5).textSelection(.enabled).padding(.vertical, 5)
                                Button(paper.kind == "PDF" ? "打开第 \(point.page+1) 页核对" : "回到网页正文") {
                                    store.open(paper, page: point.page)
                                }.buttonStyle(.bordered).font(.system(size: 11))
                            } label: {
                                Label(
                                    paper.kind == "PDF" ? "原文证据 · 第 \(point.page+1) 页" : "原文证据 · 网页片段",
                                    systemImage: "quote.bubble"
                                ).font(.system(size: 10)).foregroundStyle(Palette.green)
                            }
                        }.padding(14).background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
                    }
                }
            }
            analyzeButton
            Text("模型：\(digest.model)").font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.muted)
                .textSelection(.enabled)
        } else {
            VStack(alignment: .leading, spacing: 16) {
                Text("把全文整理成下次读得懂的线索。").font(.system(size: 20, design: .serif))
                Text("先保存实验表、条件和原文证据，再提取结构化字段，最后生成概览。全文用于检索，重点证据交给本机模型；个人笔记独立保留，可取消后继续。").font(.system(size: 12)).lineSpacing(6)
                    .foregroundStyle(Palette.muted)
                analyzeButton
            }
        }
    }
    @ViewBuilder private var experimentalRecords:some View {
        if let ledger=store.ledgers[paper.id] {
            let experiments=ledger.experiments.filter{$0.kind == .experiment}
            VStack(alignment:.leading,spacing:16) {
                Text("先留证据，再写概览").font(.system(size:20,design:.serif))
                Text("全文保留 \(ledger.evidence.count) 份证据块；识别 \(experiments.count) 项实验、\(ledger.experiments.filter{$0.kind == .dataProfile}.count) 项数据资料。模型已提取 \(experiments.filter(\.extracted).count)/\(experiments.count) 项实验字段，实际提供 \(ledger.analyzedEvidenceIDs.count) 份重点证据。未提取项目仍可展开完整原文。").font(.system(size:11)).foregroundStyle(Palette.muted).lineSpacing(4)
                Text("数值按原文复制并匹配证据，尚未自动验证复杂表格的行列对应。请核对数据集、指标、方法和条件；空缺表示该证据未明确提供。").font(.system(size:11)).foregroundStyle(Palette.orange).lineSpacing(4)
                if ledger.experiments.isEmpty {Text("没有自动识别到实验表或明确的实验段落。原文仍可检索，也可选取关键结果保存个人笔记。").font(.system(size:12))}
                ForEach(ledger.experiments) { record in
                    VStack(alignment:.leading,spacing:12) {
                        HStack(alignment:.top) {
                            Text(record.title).font(.system(size:13,weight:.semibold)).textSelection(.enabled)
                            Spacer()
                            Toggle("已核对",isOn:Binding(get:{store.experimentReviews[record.id]?.reviewed ?? false},set:{ value in
                                var review=store.experimentReviews[record.id] ?? ExperimentReview(paperID:paper.id,experimentID:record.id)
                                review.reviewed=value;store.saveExperimentReview(review)
                            })).toggleStyle(.checkbox).font(.system(size:10)).fixedSize()
                        }
                        if record.kind == .dataProfile {
                            Label("数据资料 · 不作为实验效果",systemImage:"tray.full").font(.system(size:11)).foregroundStyle(Palette.muted)
                        } else {
                            if !record.extracted {Text("原文已保存，模型字段尚未完成；可继续整理。").font(.system(size:11)).foregroundStyle(Palette.orange)}
                            meta("数据集",record.dataset);meta("任务",record.task);meta("指标",record.metrics.joined(separator:", "))
                            meta("实验条件",record.conditions);meta("局限",record.limitations)
                            if !record.measurements.isEmpty {Text("以下为代表数值，完整表格和其他指标保留在原文证据中。").font(.system(size:10)).foregroundStyle(Palette.muted)}
                            ForEach(record.measurements) {row in
                                VStack(alignment:.leading,spacing:5) {
                                    Text("\(row.method) · \(row.metric) = \(row.value)").font(.system(size:12,weight:.medium,design:.monospaced)).textSelection(.enabled)
                                    if !row.condition.isEmpty {Text(row.condition).font(.system(size:11)).foregroundStyle(Palette.muted).textSelection(.enabled)}
                                    Text(row.quote).font(.system(size:11,design:.serif)).foregroundStyle(Palette.muted).textSelection(.enabled)
                                }.padding(10).frame(maxWidth:.infinity,alignment:.leading).background(Palette.pale,in:RoundedRectangle(cornerRadius:7))
                            }
                            if record.measurements.isEmpty && record.extracted {Text("未保存可核对的代表数值；完整表格保留在下方原文中。").font(.system(size:11)).foregroundStyle(Palette.muted)}
                            if record.rejectedFields>0 {Text("已留空或剔除 \(record.rejectedFields) 个无法按原文匹配的字段，请展开证据核对。").font(.system(size:10)).foregroundStyle(Palette.orange)}
                        }
                        ForEach(record.evidenceIDs,id:\.self) {id in
                            if let source=ledger.evidence.first(where:{$0.id == id}) {
                                DisclosureGroup("完整原文证据 · 第 \(source.page+1) 页") {
                                    Text(source.text).font(.system(size:11,design:.monospaced)).lineSpacing(3).textSelection(.enabled).padding(.vertical,8)
                                    HStack {
                                        Button("打开原文核对"){store.open(paper,page:source.page)}.buttonStyle(.bordered)
                                        Button("记录想法或疑问") {store.noteEditor=PaperNote(paperID:paper.id,title:record.title,quote:source.text,page:source.page)}.buttonStyle(.bordered)
                                    }.font(.system(size:11))
                                }.font(.system(size:11)).foregroundStyle(Palette.green)
                            }
                        }
                    }.padding(16).background(.white.opacity(0.8),in:RoundedRectangle(cornerRadius:10))
                }
                analyzeButton
            }
        } else {
            Text("点击整理后，会先提取并保存实验记录和原文证据。").font(.system(size:12)).foregroundStyle(Palette.muted)
            analyzeButton
        }
    }
    private var personalNotes: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("写给下一次读到这里的自己").font(.system(size: 15, weight: .medium, design: .serif))
                Spacer()
                Button {
                    store.newNote(paper)
                } label: {
                    Label("新笔记", systemImage: "plus")
                }.buttonStyle(.bordered)
            }
            Text("支持 Markdown。阅读页的记录按钮可将当前选区和页码附入笔记；AI 更新不会改写这里的内容。").font(.system(size: 11)).foregroundStyle(
                Palette.muted
            ).lineSpacing(5)
            ForEach(notes) { note in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(note.kind.rawValue).font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.green)
                        Spacer()
                        Button {
                            store.noteEditor = note
                        } label: {
                            Image(systemName: "pencil")
                        }.buttonStyle(ReadingButtonStyle())
                        Button {
                            noteToDelete = note
                        } label: {
                            Image(systemName: "trash")
                        }.buttonStyle(ReadingButtonStyle()).foregroundStyle(Palette.muted)
                    }
                    if !note.title.isEmpty { Text(note.title).font(.system(size: 15, weight: .semibold)) }
                    Text(LocalizedStringKey(note.body)).font(.system(size: 13)).lineSpacing(5).textSelection(.enabled)
                    if !note.quote.isEmpty {
                        Text(note.quote).font(.system(size: 12, design: .serif)).foregroundStyle(Palette.muted)
                            .lineSpacing(4).textSelection(.enabled)
                        Button(paper.kind == "PDF" ? "回到第 \((note.page ?? 0)+1) 页" : "回到原文") {
                            store.open(paper, page: note.page)
                        }.buttonStyle(.bordered).font(.system(size: 11))
                    }
                    Text(note.updated.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 9))
                        .foregroundStyle(Palette.muted)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(
                    .white.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
            }
            if notes.isEmpty {
                Text("还没有笔记。你可以记录一个疑问、一个可复用的方法，或一次复现实验的结果。").font(.system(size: 12)).foregroundStyle(Palette.muted)
                    .padding(.vertical, 20)
            }
        }
    }
    private func searchMatch(_ hit: ResearchSearchHit) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("本次检索匹配 · \(hit.source)", systemImage: "magnifyingglass").font(.system(size: 10)).foregroundStyle(
                Palette.green)
            Text(hit.snippet).font(.system(size: 12)).lineSpacing(4).textSelection(.enabled)
            if let page = hit.page {
                Button(paper.kind == "PDF" ? "查看第 \(page+1) 页" : "查看原文") { store.open(paper, page: page) }.buttonStyle(
                    .bordered
                ).font(.system(size: 11))
            }
            if hit.matches.count>1 {
                DisclosureGroup("另有 \(hit.matches.count-1) 处相关证据") {
                    ForEach(Array(hit.matches.dropFirst())) {match in
                        VStack(alignment:.leading,spacing:6) {
                            Text("\(match.source) · \(match.section)").font(.system(size:10)).foregroundStyle(Palette.muted)
                            Text(match.snippet).font(.system(size:11)).textSelection(.enabled)
                            if let page=match.page {Button("打开第 \(page+1) 页"){store.open(paper,page:page)}.buttonStyle(.bordered).font(.system(size:10))}
                        }.padding(.vertical,6)
                    }
                }.font(.system(size:11))
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(
            Palette.pale, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct ResearchNoteEditor: View {
    @ObservedObject var store: AppStore
    let original: PaperNote
    @State private var draft: PaperNote
    @State private var discard = false
    init(store: AppStore, note: PaperNote) {
        self.store = store
        self.original = note
        _draft = State(initialValue: note)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("个人笔记").font(.system(size: 24, weight: .medium, design: .serif))
                Spacer()
                Picker("类型", selection: $draft.kind) {
                    ForEach(NoteKind.allCases, id: \.rawValue) { Text($0.rawValue).tag($0) }
                }.labelsHidden().frame(width: 130)
            }
            Text(store.papers.first { $0.id == draft.paperID }?.title ?? "论文").font(.system(size: 11)).foregroundStyle(
                Palette.muted
            ).lineLimit(2)
            TextField("标题（可选）", text: $draft.title).textFieldStyle(.roundedBorder)
            if !draft.quote.isEmpty {
                ScrollView {
                    Text(draft.quote).font(.system(size: 12, design: .serif)).foregroundStyle(Palette.muted)
                        .lineSpacing(4).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 64).padding(12).background(Palette.pale, in: RoundedRectangle(cornerRadius: 9))
                Text(
                    store.papers.first(where: { $0.id == draft.paperID })?.kind == "PDF"
                        ? (draft.page.map { "来自原文第 \($0+1) 页" } ?? "原文摘录") : "网页正文摘录"
                ).font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
            Text("想法、疑问或实验记录 · 支持 Markdown").font(.system(size: 11)).foregroundStyle(Palette.muted)
            TextEditor(text: $draft.body).font(.system(size: 14)).scrollContentBackground(.hidden).padding(8).frame(
                minHeight: 110, maxHeight: .infinity
            ).background(.white, in: RoundedRectangle(cornerRadius: 9)).overlay(
                RoundedRectangle(cornerRadius: 9).stroke(Palette.line, lineWidth: 1))
            HStack {
                Button("取消") { if draft != original { discard = true } else { store.noteEditor = nil } }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Text("只保存在本机，AI 不会覆盖").font(.system(size: 10)).foregroundStyle(Palette.muted)
                Button("保存笔记") { store.saveNote(draft) }.buttonStyle(PrimaryButton()).keyboardShortcut(
                    "s", modifiers: .command
                ).disabled(draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.quote.isEmpty)
            }
        }.padding(24).frame(width: 620, height: 620).background(Palette.cream).interactiveDismissDisabled()
            .onAppear { store.hasUnsavedResearchEdits = draft != original }
            .onChange(of: draft) { store.hasUnsavedResearchEdits = $0 != original }
            .onDisappear { if store.noteEditor == nil { store.hasUnsavedResearchEdits = false } }
            .confirmationDialog("放弃未保存的笔记修改？", isPresented: $discard, titleVisibility: .visible) {
                Button("放弃修改", role: .destructive) { store.noteEditor = nil }
                Button("继续编辑", role: .cancel) {}
            }
    }
}

struct ResearchMetadataEditor: View {
    @ObservedObject var store: AppStore
    let paper: Paper
    @State private var draft: PaperRecord
    @State private var title: String
    @State private var tags: String
    @State private var discard = false
    let original: PaperRecord
    private var hasChanges: Bool {
        draft != original || title != paper.title || tags != original.tags.joined(separator: ", ")
    }
    init(store: AppStore, paper: Paper) {
        self.store = store
        self.paper = paper
        let record = store.record(for: paper)
        original = record
        _draft = State(initialValue: record)
        _title = State(initialValue: paper.title)
        _tags = State(initialValue: record.tags.joined(separator: ", "))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("论文档案").font(.system(size: 24, weight: .medium, design: .serif))
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    field("标题", text: $title)
                    field("作者", text: $draft.authors)
                    HStack {
                        field("年份", text: $draft.year)
                        field("会议 / 期刊", text: $draft.venue)
                    }
                    field("DOI", text: $draft.doi)
                    field("arXiv ID", text: $draft.arxiv)
                    field("分类（可自建）", text: $draft.category)
                    field("标签（逗号分隔）", text: $tags)
                    Text("我为什么保留这篇论文 / 与课题的关系").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    TextEditor(text: $draft.purpose).font(.system(size: 13)).frame(height: 95).padding(6).background(
                        .white, in: RoundedRectangle(cornerRadius: 8))
                    HStack {
                        Picker("阅读状态", selection: $draft.status) {
                            ForEach(ReadingStatus.allCases, id: \.rawValue) { Text($0.rawValue).tag($0) }
                        }
                        Toggle("收藏", isOn: $draft.favorite)
                    }
                }
            }
            HStack {
                Button("取消") {
                    if draft != original || title != paper.title || tags != original.tags.joined(separator: ", ") {
                        discard = true
                    } else {
                        store.metadataEditor = nil
                    }
                }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存档案") {
                    draft.tags = ResearchText.tags(tags)
                    if store.saveRecord(draft, title: title) { store.metadataEditor = nil }
                }.buttonStyle(PrimaryButton()).keyboardShortcut("s", modifiers: .command).disabled(
                    title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 600, height: 600).background(Palette.cream).interactiveDismissDisabled()
            .onAppear { store.hasUnsavedResearchEdits = hasChanges }
            .onChange(of: hasChanges) { store.hasUnsavedResearchEdits = $0 }
            .onDisappear { if store.metadataEditor == nil { store.hasUnsavedResearchEdits = false } }
            .confirmationDialog("放弃未保存的档案修改？", isPresented: $discard, titleVisibility: .visible) {
                Button("放弃修改", role: .destructive) { store.metadataEditor = nil }
                Button("继续编辑", role: .cancel) {}
            }
    }
    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 11)).foregroundStyle(Palette.muted)
            TextField(label, text: text).textFieldStyle(.roundedBorder)
        }
    }
}

struct ResearchModelSettings: View {
    @ObservedObject var engines: EngineManager
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Label("实验记录与检索 · v0.2.1", systemImage: "books.vertical").font(.system(size: 14, weight: .semibold))
            row("整理 · Qwen3.6 27B Q4", status: engines.analysisStatus, ready: engines.analysisReady)
            row("检索 · Qwen3 Embedding 0.6B", status: engines.embeddingStatus, ready: engines.embeddingReady)
            row("相关性复核 · Qwen3 Reranker 0.6B",status:engines.rerankerReady ? "已就绪 · 本机重排":"尚未就绪；需安装模型并重启本地引擎",ready:engines.rerankerReady)
            Text("针对 M2 Pro / 32 GB：研究与重排模型共约 19.3 GB。大模型整理时暂停本应用的语音与重排服务，完成或取消后恢复；可继续阅读、写笔记和关键词检索。").font(.system(size: 11))
                .foregroundStyle(Palette.muted).lineSpacing(5)
            HStack {
                if !engines.bundled {
                    Button("安装研究模型…") {
                        NSWorkspace.shared.open(
                            engines.runtime.deletingLastPathComponent().appendingPathComponent("安装研究模型.command"))
                    }.buttonStyle(.bordered)
                }
                Button("检查模型状态") { Task { await engines.check() } }.buttonStyle(.bordered).disabled(engines.checking)
            }
            if !engines.analysisReady || !engines.embeddingReady {
                TimelineView(.periodic(from: .now, by: 3)) { _ in
                    if let progress = progress {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(progress.model).font(.system(size: 10, design: .monospaced))
                            ProgressView(value: progress.ratio).tint(Palette.green)
                            Text("下载进度 \(Int(progress.ratio*100))% · 中断后可继续安装").font(.system(size: 10)).foregroundStyle(
                                Palette.muted)
                        }
                    }
                }
            }
            Text("Qwen 模型为 Apache-2.0；OmniVoice 与 TranslateGemma 继续使用各自的许可。研究内容仅发给本机回环服务。").font(.system(size: 10))
                .foregroundStyle(Palette.muted)
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading).background(
            .white.opacity(0.7), in: RoundedRectangle(cornerRadius: 13)
        ).overlay(RoundedRectangle(cornerRadius: 13).stroke(Palette.line, lineWidth: 1))
    }
    private var progress: (model: String, ratio: Double)? {
        guard let data = try? Data(contentsOf: engines.runtime.appendingPathComponent("logs/research-progress.json")),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let model = object["model"] as? String, let total = object["total"] as? Double, total > 0
        else { return nil }
        return (model, min(1, (object["completed"] as? Double ?? 0) / total))
    }
    private func row(_ title: String, status: String, ready: Bool) -> some View {
        HStack {
            Text(title).font(.system(size: 12))
            Spacer()
            Circle().fill(ready ? Palette.green : Palette.orange).frame(width: 6, height: 6)
            Text(status).font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
    }
}
