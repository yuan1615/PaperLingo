import AppKit
import Foundation
import PDFKit
import PaperCore
import UniformTypeIdentifiers

extension AppStore {
    var catalogPaper: Paper? { papers.first { $0.id == catalogPaperID } }
    var currentNotePaper: Paper? { route == .library ? catalogPaper : selectedPaper }
    func noteCurrentLocation() {
        if let paper = currentNotePaper {
            newNote(paper, fromSelection: route == .reading && !selection.isEmpty)
        }
    }
    var categories: [String] { Array(Set(papers.map { record(for: $0).category }.filter { !$0.isEmpty })).sorted() }
    var allPaperTags: [String] { Array(Set(records.values.flatMap(\.tags))).sorted() }
    var embeddingSignature: String {
        ResearchModels.embedding + "@" + (engines.modelDigests[ResearchModels.embedding] ?? "unavailable") + "|" + PaperSummary.indexVersion
    }
    func record(for paper: Paper) -> PaperRecord { records[paper.id] ?? PaperRecord(paperID: paper.id) }
    func showArchive(_ paper: Paper) {
        catalogPaperID = paper.id
        route = .library
    }
    func newNote(_ paper: Paper, fromSelection: Bool = false) {
        noteEditor = PaperNote(
            paperID: paper.id, quote: fromSelection ? selection : "", page: fromSelection ? selectedPage : nil)
    }
    func saveNote(_ value: PaperNote) {
        var note = value
        note.updated = Date()
        do {
            try db?.saveNote(note)
            try reload()
            noteEditor = nil
            refreshLibrarySearch()
            toast = "笔记已保存在本机"
        } catch { self.error = error.localizedDescription }
    }
    func removeNote(_ note: PaperNote) {
        do {
            try db?.deleteNote(note)
            try reload()
            refreshLibrarySearch()
        } catch { self.error = error.localizedDescription }
    }
    @discardableResult func saveRecord(_ record: PaperRecord, title: String? = nil) -> Bool {
        var record = record
        record.tags = ResearchText.tags(record.tags.joined(separator: ","))
        if record.category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { record.category = "未分类" }
        if record.status == .read && record.completed == nil { record.completed = Date() }
        do {
            try db?.savePaperRecord(record, title: title)
            try reload()
            refreshLibrarySearch()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
    func toggleFavorite(_ paper: Paper) {
        var r = record(for: paper)
        r.favorite.toggle()
        saveRecord(r)
    }
    func setStatus(_ status: ReadingStatus, for paper: Paper) {
        var r = record(for: paper)
        r.status = status
        saveRecord(r)
    }
    func applySuggestions(_ digest: PaperDigest, to paper: Paper) {
        var r = record(for: paper)
        if r.authors.isEmpty { r.authors = digest.suggestedAuthors.joined(separator: ", ") }
        if r.year.isEmpty { r.year = digest.suggestedYear }
        if r.venue.isEmpty { r.venue = digest.suggestedVenue }
        if r.doi.isEmpty { r.doi = digest.suggestedDOI }
        if r.arxiv.isEmpty { r.arxiv = digest.suggestedArxiv }
        if r.category == "未分类" && !digest.suggestedCategory.isEmpty { r.category = digest.suggestedCategory }
        r.tags = ResearchText.tags((r.tags + digest.suggestedTags).joined(separator: ","))
        if saveRecord(r) { toast = "已补全空缺资料并合并标签，已有手工内容保留；请核对 AI 建议" }
    }
    func exportArchive(_ paper: Paper) {
        do {
            guard let text = try db?.exportPaperMarkdown(paper) else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
            let name = String(paper.title.prefix(80)).components(
                separatedBy: CharacterSet(charactersIn: "/:").union(.controlCharacters)
            ).joined(separator: "-")
            panel.nameFieldStringValue = (name.isEmpty ? "论文档案" : name) + ".md"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try text.write(to: url, atomically: true, encoding: .utf8)
            toast = "论文档案与个人笔记已导出"
        } catch { self.error = error.localizedDescription }
    }
    func refreshLibrarySearch() {
        if semanticSearchQuery == TextTools.clean(libraryQuery), !libraryQuery.isEmpty, !researchBusy {
            searchSemantically()
        } else {
            searchKeywords(resetSemantic: false)
        }
    }
    func searchKeywords(resetSemantic: Bool = true) {
        if resetSemantic { semanticSearchQuery = nil }
        searchTask?.cancel()
        searching = false
        do {
            searchHits = try db?.keywordSearch(libraryQuery) ?? []
            searchMessage = ""
        } catch { searchMessage = error.localizedDescription }
    }
    func searchSemantically() {
        let query = TextTools.clean(libraryQuery)
        guard !query.isEmpty else {
            searchHits = []
            searchMessage = ""
            return
        }
        guard !researchBusy else {
            searchKeywords(resetSemantic: false)
            searchMessage = "整理期间仍可关键词检索，语义检索请稍后再试"
            return
        }
        searchTask?.cancel()
        semanticSearchQuery = query
        searching = true
        searchMessage = "正在本机理解检索意图…"
        searchTask = Task {
            do {
                await yieldWordExplanation()
                try Task.checkCancellation()
                await engines.check()
                guard engines.embeddingReady else { throw AppError.message("检索模型尚未安装；可先使用关键词，或到设置安装研究模型。") }
                let signature = embeddingSignature
                var units = try db?.passages() ?? []
                let updates=Array(units.filter{$0.source != "正文" && $0.semanticEligible && ($0.vectorModel != signature || $0.vector.isEmpty)}.prefix(32))
                if !updates.isEmpty {
                    searchMessage="正在更新中文摘要索引…"
                    for offset in stride(from:0,to:updates.count,by:8) {
                        var batch=Array(updates[offset..<min(offset+8,updates.count)])
                        let vectors=try await researchClient.embeddings(batch.map(\.embeddingInput))
                        try Task.checkCancellation()
                        for i in batch.indices {batch[i].vector=vectors[i]}
                        try db?.savePassageVectors(batch,model:signature)
                    }
                    units=try db?.passages() ?? []
                }
                guard units.contains(where: { $0.vectorModel == signature && !$0.vector.isEmpty }) else {
                    throw AppError.message("请先生成前三页摘要，再建立中文摘要索引。标题、资料和笔记仍可用关键词检索。")
                }
                let vector = try await researchClient.embeddings([query], query: true)[0]
                try Task.checkCancellation()
                let lexical = try db?.lexicalPassages(query) ?? []
                let candidates = await Task.detached(priority:.userInitiated) {ResearchRetrieval.candidates(query:vector,units:units,model:signature,lexical:lexical)}.value
                try Task.checkCancellation()
                searchMessage="正在本机复核候选论文的相关性…"
                var scores:[Double]?
                do {scores=try await researchClient.rerank(query:query,documents:candidates.map(\.passage.embeddingInput))}
                catch is CancellationError {throw CancellationError()}
                catch {scores=nil}
                try Task.checkCancellation()
                guard TextTools.clean(libraryQuery) == query else {
                    if !Task.isCancelled { searching = false }
                    return
                }
                searchHits=ResearchRetrieval.hits(candidates:candidates,relevance:scores,query:query)
                let indexed=Set(units.filter{$0.vectorModel == signature && !$0.vector.isEmpty}.map(\.paperID)).count
                let pending=units.filter{$0.semanticEligible && ($0.vectorModel != signature || $0.vector.isEmpty)}.count
                searchMessage = scores == nil ? "重排服务未就绪，当前显示通过阈值的论文候选；可检查本地引擎。\(indexed)/\(papers.count) 篇有当前语义索引。" : "\(indexed)/\(papers.count) 篇参与语义检索，每篇一个概览索引。\(searchHits.isEmpty ? "没有找到足够相关的论文。":"候选已由本机重排模型复核，可查看概览了解关联。")"
                if pending>0 {searchMessage += " 仍有 \(pending) 篇待更新，可点击建立 / 更新检索索引。"}
                let missing=papers.filter{!PaperSummary.isCurrent(digests[$0.id])}.count
                if missing>0 {searchMessage += " \(missing) 篇待生成前三页摘要，暂只参与关键词检索。"}
            } catch is CancellationError {} catch {
                if !Task.isCancelled {
                    searchMessage = error.localizedDescription
                    searchHits = (try? db?.keywordSearch(query)) ?? []
                }
            }
            if !Task.isCancelled { searching = false }
        }
    }
    func openingSource(_ paper: Paper, force: Bool = false) async throws -> PaperSummarySource {
        if !force, let status = textStatuses[paper.id], status.extractionVersion == PaperSummary.version {
            return PaperSummarySource(chunks: try db?.chunks(paperID: paper.id) ?? [], status: status)
        }
        let url = fileURL(paper)
        let worker = Task.detached(priority: .utility) {
            try paper.kind == "PDF" ? PaperSummarySource.pdf(paperID: paper.id, url: url) : PaperSummarySource.web(paperID: paper.id, url: url)
        }
        let source = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        try Task.checkCancellation()
        guard papers.contains(where: { $0.id == paper.id }) else { throw CancellationError() }
        try db?.replaceChunks(paperID: paper.id, chunks: source.chunks, status: source.status)
        textStatuses[paper.id] = source.status
        return source
    }
    func cancelResearch() {
        researchTask?.cancel()
        researchMessage = "正在停止整理并释放模型…"
    }
    func stopLocalEngines() {
        allowEngineRestore = false
        researchTask?.cancel()
        pauseWordExplanation()
        audio.stop()
        engines.stop()
    }
    func startResearch(_ targets: [Paper], summarize: Bool = true, refreshText: Bool = false) {
        guard !researchBusy, !searching, !targets.isEmpty else { return }
        let eligible = summarize ? targets : targets.filter { PaperSummary.isCurrent(digests[$0.id]) }
        guard !eligible.isEmpty else {
            researchMessage = "请先生成前三页摘要，再建立摘要索引。"
            return
        }
        guard !translating else {
            toast = "当前翻译完成后即可整理论文，避免同时加载多个模型。"
            return
        }
        researchBusy = true
        researchError = nil
        researchProgress = 0
        researchMessage = "准备本地模型…"
        allowEngineRestore = true
        researchTask = Task { await runResearch(eligible, summarize: summarize, refreshText: refreshText) }
    }
    private func runResearch(_ targets: [Paper], summarize: Bool, refreshText: Bool) async {
        var pausedSpeech = false
        var didPauseAudio = false
        do {
            await yieldWordExplanation()
            try Task.checkCancellation()
            await engines.check()
            let ready = summarize ? engines.analysisReady : engines.embeddingReady
            guard ready else { throw AppError.message("所需研究模型尚未安装，请到设置安装。手工归档、笔记和关键词检索不受影响。") }
            audio.stop()
            audio.error = nil
            audio.researchBusy = true
            didPauseAudio = true
            if summarize { pausedSpeech = await engines.pauseSpeechForResearch() }
            let modelSignature =
                ResearchModels.analysis + "@" + (engines.modelDigests[ResearchModels.analysis] ?? "unknown")
            for (number, paper) in targets.enumerated() {
                try Task.checkCancellation()
                researchPaperID = paper.id
                if summarize {
                    researchMessage = "\(number+1)/\(targets.count) · 读取开头内容：\(paper.title)"
                    let source = try await openingSource(paper, force: refreshText)
                    guard !source.chunks.isEmpty else { throw AppError.message("\(paper.title) 前三页没有可提取的文字，请先 OCR。") }
                    researchMessage = "\(number+1)/\(targets.count) · 生成研究动机、核心方法与实验结果"
                    let digest = try await researchClient.summarizeOpening(source, signature: modelSignature)
                    try Task.checkCancellation()
                    try db?.saveDigest(digest)
                    digests[paper.id] = digest
                    researchProgress = Double(number + 1) / Double(targets.count) * 0.8
                }
            }
            await researchClient.unload(ResearchModels.analysis)
            if engines.embeddingReady {
                let signature = embeddingSignature
                for (number, paper) in targets.enumerated() {
                    try Task.checkCancellation()
                    researchPaperID = paper.id
                    let units = try db?.passages(paperID: paper.id) ?? []
                    let pending = units.filter { $0.semanticEligible && ($0.vectorModel != signature || $0.vector.isEmpty) }
                    for offset in stride(from: 0, to: pending.count, by: 8) {
                        try Task.checkCancellation()
                        let batch = Array(pending[offset..<min(offset + 8, pending.count)])
                        researchMessage = "\(number+1)/\(targets.count) · 建立中文摘要向量（每篇一个）"
                        let vectors = try await researchClient.embeddings(batch.map(\.embeddingInput))
                        var updates: [ResearchPassage] = []
                        for (chunk, vector) in zip(batch, vectors) {
                            var item = chunk
                            item.vector = vector
                            updates.append(item)
                        }
                        try db?.savePassageVectors(updates, model: signature)
                        let fraction = Double(min(offset + 8, pending.count)) / Double(max(1, pending.count))
                        let overall = (Double(number) + fraction) / Double(targets.count)
                        let indexScale: Double = summarize ? 0.2 : 1
                        let indexBase: Double = summarize ? 0.8 : 0
                        researchProgress = indexBase + overall * indexScale
                    }
                }
            }
            try reload()
            researchProgress = 1
            researchMessage = "已完成 \(targets.count) 篇\(summarize ? "论文整理" : "检索索引")"
        } catch is CancellationError { researchMessage = "已取消；已完成的摘要保留，未完成项沿用原摘要" } catch {
            if Task.isCancelled {
                researchMessage = "已取消；已完成内容保留"
            } else {
                researchError = error.localizedDescription
                researchMessage = "本次任务未完成，可重试"
            }
        }
        let client = researchClient
        await Task.detached {
            await client.unload(ResearchModels.analysis)
            await client.unload(ResearchModels.embedding)
        }.value
        if didPauseAudio {
            audio.researchBusy = false
            audio.error = nil
        }
        researchBusy = false
        researchPaperID = nil
        researchTask = nil
        if !shuttingDown && allowEngineRestore { refreshLibrarySearch() }
        if route != .library {
            toast = researchError == nil ? researchMessage : "论文整理未完成，返回研究库查看原因"
        }
        if pausedSpeech && !shuttingDown && allowEngineRestore { Task { await self.engines.start() } }
    }
}
