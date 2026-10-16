import AppKit
import PaperCore
import SwiftUI

struct ResearchLibraryScreen: View {
    @ObservedObject var store: AppStore
    @State private var showingFilters = false
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
            header.padding(.horizontal, 16).frame(height: 60)
            if store.researchBusy || store.researchError != nil || !store.researchMessage.isEmpty {
                ResearchProgress(store: store).padding(.horizontal, 16).padding(.bottom, 8)
            }
            Rectangle().fill(Palette.line).frame(height: 1)
            GeometryReader { geometry in
                let compact = geometry.size.width < 850
                HStack(spacing: 0) {
                    if !compact || store.catalogPaper == nil {
                        paperList.frame(width: compact ? nil : 270).frame(maxWidth: compact ? .infinity : nil)
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
                }.onAppear { if !compact { selectFirstIfNeeded() } }
                    .onChange(of: filtered.map(\.id)) { if !compact && !store.searching { selectFirstIfNeeded() } }
                    .onChange(of: store.searching) { if !compact && !store.searching { selectFirstIfNeeded() } }
                    .onChange(of: store.libraryQuery) { if compact { store.catalogPaperID = nil } }
            }
        }
    }
    private func selectFirstIfNeeded() {
        if !filtered.contains(where: { $0.id == store.catalogPaperID }) { store.catalogPaperID = filtered.first?.id }
    }
    private var activeFilterCount: Int {
        [status != "全部状态", category != "全部分类", tag != "全部标签", favorites].filter { $0 }.count
    }
    private var header: some View {
        HStack(spacing: 12) {
            Button { store.layout.sidebarVisible.toggle() } label: { Image(systemName: "sidebar.left") }
                .buttonStyle(ReadingButtonStyle()).help("显示或收起导航")
            Text("研究库").font(.system(size: 20, weight: .medium, design: .serif)).fixedSize()
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
                TextField("搜索摘要、标题或笔记", text: $store.libraryQuery).textFieldStyle(.plain)
                    .onSubmit { store.searchSemantically() }
                    .onChange(of: store.libraryQuery) { store.searchKeywords() }
                if !store.libraryQuery.isEmpty {
                    Button { store.libraryQuery = ""; store.searchKeywords() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(Palette.muted).help("清除搜索")
                }
                if store.searching { ProgressView().controlSize(.small) }
                Button { store.searchSemantically() } label: { Image(systemName: "sparkle.magnifyingglass") }
                    .buttonStyle(ReadingButtonStyle()).help("按意思查找 · 输入后回车")
                    .accessibilityLabel("按意思查找")
                    .disabled(store.libraryQuery.isEmpty || store.searching || store.researchBusy)
            }.font(.system(size: 12)).padding(.leading, 10).padding(.trailing, 3).frame(height: 34)
                .frame(minWidth: 130, maxWidth: 500).background(.white, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line, lineWidth: 1))
            Button { showingFilters.toggle() } label: {
                Image(systemName: activeFilterCount > 0 ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }.buttonStyle(ReadingButtonStyle()).help("筛选与排序").accessibilityLabel("筛选与排序")
                .popover(isPresented: $showingFilters, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 15) {
                        HStack {
                            Text("筛选与排序").font(.system(size: 14, weight: .semibold))
                            Spacer()
                            Button("重置") {
                                store.libraryStatusFilter = "全部状态"; store.libraryCategoryFilter = "全部分类"
                                store.libraryTagFilter = "全部标签"; store.libraryFavoritesOnly = false; store.librarySort = "最近加入"
                            }.buttonStyle(.link)
                        }
                        filterForm
                        Text("\(filtered.count) / \(store.papers.count) 篇论文").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }.padding(18).frame(width: 290)
                }
            Menu {
                Button("导入 PDF…") { store.choosePDF() }
                Button("导入链接…") { store.showLink = true }
                Divider()
                Button("生成缺失的前三页摘要") { store.startResearch(store.papers.filter { !PaperSummary.isCurrent(store.digests[$0.id]) }) }
                    .disabled(store.researchBusy || store.searching)
                Button("更新摘要检索索引") { store.startResearch(store.papers, summarize: false) }.disabled(store.researchBusy || store.searching)
            } label: { Image(systemName: "plus").frame(width: 28, height: 32).contentShape(Rectangle()) }
                .menuStyle(.borderlessButton).fixedSize().help("导入与批量整理").accessibilityLabel("导入与整理")
        }
    }
    private var filterForm: some View {
        Form {
            Picker("阅读状态", selection: $store.libraryStatusFilter) {
                Text("全部状态").tag("全部状态")
                ForEach(ReadingStatus.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
            }
            Picker("分类", selection: $store.libraryCategoryFilter) {
                Text("全部分类").tag("全部分类")
                ForEach(store.categories, id: \.self) { Text($0).tag($0) }
            }
            Picker("标签", selection: $store.libraryTagFilter) {
                Text("全部标签").tag("全部标签")
                ForEach(store.allPaperTags, id: \.self) { Text($0).tag($0) }
            }
            Picker("排序", selection: $store.librarySort) {
                ForEach(["最近加入", "最近阅读", "发表年份", "标题"], id: \.self) { Text($0).tag($0) }
            }
            Toggle("只看收藏", isOn: $store.libraryFavoritesOnly)
        }
    }
    private var paperList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(filtered.count) / \(store.papers.count) 篇 · \(store.researchNotes.count) 条个人记录").font(
                .system(size: 10)
            ).foregroundStyle(Palette.muted).padding(15)
            if !store.libraryQuery.isEmpty && !store.searchMessage.isEmpty {
                Text(store.searchMessage).font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(3)
                    .textSelection(.enabled).padding(.horizontal, 15).padding(.bottom, 10)
            }
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
    @State private var tab = 1
    @State private var noteToDelete: PaperNote?
    init(store: AppStore, paper: Paper) {
        self.store = store
        self.paper = paper
        let source = store.searchHits.first { $0.paperID == paper.id }?.source
        _tab = State(initialValue: source == "笔记" ? 2 : 1)
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
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Text(paper.title).font(.system(size: 18, weight: .medium, design: .serif)).lineLimit(2)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    actions
                }
                Picker("论文详情", selection: $tab) {
                    Text("摘要").tag(1)
                    Text("笔记 \(notes.count)").tag(2)
                    Text("资料").tag(0)
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 320)
            }.padding(.horizontal, 20).padding(.vertical, 12)
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
                    default: personalNotes
                    }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.onChange(of: store.digests[paper.id]?.id) { tab = 1 }
            .onChange(of: store.searchHits.first { $0.paperID == paper.id }?.source) {
                if let source = store.searchHits.first(where: { $0.paperID == paper.id })?.source {
                    if source == "笔记" { tab = 2 } else if ["汇总", "论文摘要", "论文概览"].contains(source) { tab = 1 }
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
        }.buttonStyle(.bordered).controlSize(.small)
        Menu {
            Button("新建笔记") { store.newNote(paper) }
            Button(store.record(for: paper).favorite ? "取消收藏" : "收藏论文") { store.toggleFavorite(paper) }
            Picker("阅读状态", selection: Binding(get: { store.record(for: paper).status }, set: { store.setStatus($0, for: paper) })) {
                ForEach(ReadingStatus.allCases, id: \.rawValue) { Text($0.rawValue).tag($0) }
            }
            Divider()
            Button("编辑文献信息与分类…") { store.metadataEditor = paper }
            Button("导出档案与笔记 Markdown…") { store.exportArchive(paper) }
            Divider()
            Button("重新读取前三页并生成摘要") { store.startResearch([paper], refreshText: true) }.disabled(
                store.researchBusy || store.searching)
            Button("建立 / 更新检索索引") { store.startResearch([paper], summarize: false) }.disabled(
                store.researchBusy || store.searching)
            Button("移除论文…", role: .destructive) { store.pendingPaperDeletion = paper }
        } label: {
            Image(systemName: "ellipsis").frame(width: 28, height: 32).contentShape(Rectangle())
        }.menuStyle(.borderlessButton).frame(width: 28)
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
                        ? "开头未提取到文字；扫描件需先 OCR" : (paper.kind == "PDF" ? "只读取前 \(min(3, status.totalPages)) 页 · 原文件共 \(status.totalPages) 页" : "只读取网页开头最多 15,000 字符"),
                    systemImage: status.chunkCount == 0 ? "doc.viewfinder" : "doc.text.magnifyingglass"
                ).font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            Divider()
            if let digest = store.digests[paper.id] {
                Text("一句话回顾").font(.system(size: 14, weight: .semibold))
                Text(digest.oneLine).font(.system(size: 13)).lineSpacing(5).textSelection(.enabled)
                Button("查看中文摘要") { tab = 1 }.buttonStyle(.bordered)
            } else {
                Text("还没有 AI 汇总").font(.system(size: 14, weight: .semibold))
                Text("只根据前三页的摘要和引言整理研究动机、核心方法与实验结果；未报告的内容会明确标注。").font(.system(size: 12)).foregroundStyle(
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
                    ? "生成前三页摘要" : "更新前三页摘要",
                systemImage: "sparkles")
        }.buttonStyle(PrimaryButton()).disabled(store.researchBusy || store.searching)
    }
    @ViewBuilder private var digest: some View {
        if let digest = store.digests[paper.id] {
            Text(digest.oneLine).font(.system(size: 17, weight: .medium, design: .serif)).lineSpacing(6).textSelection(.enabled)
            Text(PaperSummary.isCurrent(digest) ? (paper.kind == "PDF" ? "前三页摘要 · \(min(3, digest.totalPages)) / \(digest.totalPages) 页" : "网页开头摘要") : "历史摘要 · 可在更多菜单更新")
                .font(.system(size: 10)).foregroundStyle(Palette.muted)
                .help("仅依据开头文字，实验结果为作者的报告，未核验后文实验。")
            ForEach(PaperSummary.topics, id: \.rawValue) { topic in
                VStack(alignment: .leading, spacing: 10) {
                    Text(PaperSummary.title(topic)).font(.system(size: 15, weight: .semibold))
                    let points = digest.points.filter { $0.topic == topic }
                    if points.isEmpty { Text("开头内容未明确报告。").foregroundStyle(Palette.muted) }
                    ForEach(points) { point in
                        Text(point.text).font(.system(size: 13)).lineSpacing(6).textSelection(.enabled)
                    }
                }.padding(15).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
            }
            DisclosureGroup("摘要信息与分类建议") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("生成于 \(digest.created.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 10)).foregroundStyle(Palette.muted)
                    if !digest.suggestedCategory.isEmpty {
                        Text(digest.suggestedCategory + " / " + digest.suggestedTags.joined(separator: " / "))
                        Button("采用分类与标签") { store.applySuggestions(digest, to: paper) }.buttonStyle(.bordered)
                    }
                    Text(digest.model).font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.muted)
                }.font(.system(size: 11)).padding(.top, 8)
            }.font(.system(size: 11)).foregroundStyle(Palette.muted)
        } else {
            Text("用三页，留住论文的主要思路。").font(.system(size: 20, design: .serif))
            Text("本地模型只阅读 PDF 前三页，按研究动机、核心方法、实验结果生成中文摘要，再用摘要建立每篇唯一的语义索引。网页使用开头的有限正文。没有报告的结果会明确写出。").font(.system(size: 12)).lineSpacing(6).foregroundStyle(Palette.muted)
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
        DisclosureGroup("查看检索关联 · " + hit.source) {
            Text(hit.snippet).font(.system(size: 12)).lineSpacing(4).textSelection(.enabled).padding(.top, 8)
        }.font(.system(size: 10)).foregroundStyle(Palette.green)
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
            Text("想法、疑问或待办 · 支持 Markdown").font(.system(size: 11)).foregroundStyle(Palette.muted)
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
            .onChange(of: draft) { _, value in store.hasUnsavedResearchEdits = value != original }
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
            .onChange(of: hasChanges) { _, value in store.hasUnsavedResearchEdits = value }
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
            Label("前三页摘要与检索 · v0.2.3", systemImage: "books.vertical").font(.system(size: 14, weight: .semibold))
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
