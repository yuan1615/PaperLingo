import AppKit
import Foundation
import PDFKit
import PaperCore
import UniformTypeIdentifiers

enum ResearchDocumentLoader {
    static func extract(paper: Paper, url: URL) async throws -> (chunks: [PaperTextChunk], status: PaperTextStatus) {
        let worker = Task.detached(priority: .utility) {
            () throws -> (chunks: [PaperTextChunk], status: PaperTextStatus) in
            try Task.checkCancellation()
            var pages: [String] = []
            if paper.kind == "PDF" {
                guard let document = PDFDocument(url: url), document.pageCount > 0 else {
                    throw AppError.message("无法读取原论文文件，请检查文件是否存在或已损坏。")
                }
                for page in 0..<document.pageCount {
                    try Task.checkCancellation()
                    pages.append(document.page(at: page)?.string ?? "")
                }
            } else {
                pages = [try String(contentsOf: url, encoding: .utf8)]
            }
            let chunks = ResearchText.chunks(paperID: paper.id, pages: pages)
            let status = PaperTextStatus(
                paperID: paper.id, sourceHash: ResearchText.hash(pages.joined(separator: "\u{001E}")),
                totalPages: pages.count, textPages: pages.filter { !TextTools.clean($0).isEmpty }.count,
                chunkCount: chunks.count)
            return (chunks, status)
        }
        return try await withTaskCancellationHandler(
            operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
}

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
        ResearchModels.embedding + "@" + (engines.modelDigests[ResearchModels.embedding] ?? "unavailable")
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
                await engines.check()
                guard engines.embeddingReady else { throw AppError.message("检索模型尚未安装；可先使用关键词，或到设置安装研究模型。") }
                let signature = embeddingSignature
                let chunks = try db?.chunks() ?? []
                guard chunks.contains(where: { $0.vectorModel == signature && !$0.vector.isEmpty }) else {
                    throw AppError.message("尚未建立当前模型的语义索引，请点击「建立检索索引」。关键词检索已经可用。")
                }
                let vector = try await researchClient.embeddings([query], query: true)[0]
                try Task.checkCancellation()
                let semantic = await Task.detached(priority: .userInitiated) {
                    ResearchText.semanticHits(query: vector, chunks: chunks, model: signature)
                }.value
                try Task.checkCancellation()
                let lexical = try db?.keywordSearch(query) ?? []
                var combined: [String: ResearchSearchHit] = [:]
                for (rank, hit) in semantic.enumerated() {
                    var hit = hit
                    hit.score = 1.0 / Double(40 + rank)
                    combined[hit.paperID] = hit
                }
                for (rank, hit) in lexical.enumerated() {
                    if var existing = combined[hit.paperID] {
                        existing.score += 1.0 / Double(40 + rank)
                        existing.source = "语义 + 关键词"
                        combined[hit.paperID] = existing
                    } else {
                        var hit = hit
                        hit.score = 1.0 / Double(40 + rank)
                        combined[hit.paperID] = hit
                    }
                }
                guard TextTools.clean(libraryQuery) == query else {
                    if !Task.isCancelled { searching = false }
                    return
                }
                searchHits = combined.values.sorted { $0.score > $1.score }
                searchMessage = "\(semantic.count) 篇有语义索引的论文参与检索；其余内容仍可用关键词查找。相似度不代表结论正确。"
            } catch is CancellationError {} catch {
                if !Task.isCancelled {
                    searchMessage = error.localizedDescription
                    searchHits = (try? db?.keywordSearch(query)) ?? []
                }
            }
            if !Task.isCancelled { searching = false }
        }
    }
    func ensureText(_ paper: Paper, force: Bool = false) async throws -> [PaperTextChunk] {
        if !force, textStatuses[paper.id] != nil { return try db?.chunks(paperID: paper.id) ?? [] }
        let extracted = try await ResearchDocumentLoader.extract(paper: paper, url: fileURL(paper))
        try Task.checkCancellation()
        guard papers.contains(where: { $0.id == paper.id }) else { throw CancellationError() }
        try db?.replaceChunks(paperID: paper.id, chunks: extracted.chunks, status: extracted.status)
        textStatuses[paper.id] = extracted.status
        return try db?.chunks(paperID: paper.id) ?? []
    }
    func indexLibraryText() {
        guard !extractingLibrary, !researchBusy else { return }
        guard papers.contains(where: { textStatuses[$0.id] == nil }) else { return }
        extractingLibrary = true
        textIndexTask = Task {
            for paper in papers where textStatuses[paper.id] == nil {
                if Task.isCancelled || researchBusy { break }
                do { _ = try await ensureText(paper) } catch {
                    if !Task.isCancelled { researchError = "正文索引：\(paper.title) · \(error.localizedDescription)" }
                }
            }
            extractingLibrary = false
            if !Task.isCancelled { refreshLibrarySearch() }
        }
    }
    func cancelResearch() {
        researchTask?.cancel()
        researchMessage = "正在停止整理并释放模型…"
    }
    func stopLocalEngines() {
        allowEngineRestore = false
        researchTask?.cancel()
        audio.stop()
        engines.stop()
    }
    func startResearch(_ targets: [Paper], summarize: Bool = true, refreshText: Bool = false) {
        guard !researchBusy, !searching, !targets.isEmpty else { return }
        guard !translating else {
            toast = "当前翻译完成后即可整理论文，避免同时加载多个模型。"
            return
        }
        textIndexTask?.cancel()
        researchBusy = true
        researchError = nil
        researchProgress = 0
        researchMessage = "准备本地模型…"
        allowEngineRestore = true
        researchTask = Task { await runResearch(targets, summarize: summarize, refreshText: refreshText) }
    }
    private func runResearch(_ targets: [Paper], summarize: Bool, refreshText: Bool) async {
        var pausedSpeech = false
        var didPauseAudio = false
        do {
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
                researchMessage = "\(number+1)/\(targets.count) · 提取 \(paper.title)"
                let chunks = try await ensureText(paper, force: refreshText)
                guard !chunks.isEmpty else { throw AppError.message("\(paper.title) 没有可提取的文字，需要先 OCR；未生成汇总。") }
                if summarize {
                    let digest = try await analyzePaper(
                        paper, chunks: chunks, signature: modelSignature,
                        base: Double(number) / Double(targets.count) * 0.8, scale: 0.8 / Double(targets.count),
                        useCache: !refreshText)
                    try Task.checkCancellation()
                    try db?.saveDigest(digest)
                    digests[paper.id] = digest
                }
            }
            await researchClient.unload(ResearchModels.analysis)
            if engines.embeddingReady {
                let signature = embeddingSignature
                for (number, paper) in targets.enumerated() {
                    try Task.checkCancellation()
                    researchPaperID = paper.id
                    let chunks = try db?.chunks(paperID: paper.id) ?? []
                    let pending = chunks.filter { $0.vectorModel != signature || $0.vector.isEmpty }
                    for offset in stride(from: 0, to: pending.count, by: 4) {
                        try Task.checkCancellation()
                        let batch = Array(pending[offset..<min(offset + 4, pending.count)])
                        researchMessage = "\(number+1)/\(targets.count) · 检索索引 \(offset)/\(pending.count) 段"
                        let vectors = try await researchClient.embeddings(batch.map(\.text))
                        var updates: [PaperTextChunk] = []
                        for (chunk, vector) in zip(batch, vectors) {
                            var item = chunk
                            item.vector = vector
                            updates.append(item)
                        }
                        try db?.saveVectors(updates, model: signature)
                        let fraction = Double(min(offset + 4, pending.count)) / Double(max(1, pending.count))
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
        } catch is CancellationError { researchMessage = "已取消；完成的汇总和分段缓存已保留" } catch {
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
    private func analyzePaper(
        _ paper: Paper, chunks: [PaperTextChunk], signature: String, base: Double, scale: Double,
        useCache: Bool
    )
        async throws -> PaperDigest
    {
        var partials: [DigestDraft] = []
        let groups = stride(from: 0, to: chunks.count, by: 3).map { Array(chunks[$0..<min($0 + 3, chunks.count)]) }
        for (index, group) in groups.enumerated() {
            try Task.checkCancellation()
            researchMessage = "整理 \(paper.title) · 第 \(index+1)/\(groups.count) 组原文"
            let key = ResearchText.hash(
                ResearchModels.promptVersion + signature + "final=\(groups.count == 1)"
                    + group.map { $0.id + $0.text }.joined())
            let draft: DigestDraft
            if useCache, let cached = try db?.cachedAnalysis(key: key) {
                draft = cached
            } else {
                draft = try await researchClient.draft(chunks: group, categories: categories, final: groups.count == 1)
                try db?.cacheAnalysis(draft, key: key, paperID: paper.id)
            }
            partials.append(draft)
            researchProgress = base + scale * 0.75 * Double(index + 1) / Double(groups.count)
        }
        // Bibliographic suggestions come from the opening source group, so
        // reference sections processed later cannot replace the paper's identity.
        let bibliography = partials.first
        var level = 0
        while partials.count > 1 {
            var merged: [DigestDraft] = []
            level += 1
            for offset in stride(from: 0, to: partials.count, by: 3) {
                try Task.checkCancellation()
                researchMessage = "合并 \(paper.title) · 第 \(level) 层"
                let batch = Array(partials[offset..<min(offset + 3, partials.count)])
                if batch.count == 1 {
                    merged.append(batch[0])
                } else {
                    merged.append(
                        try await researchClient.draft(
                            chunks: [], previous: batch, categories: categories, final: partials.count <= 3))
                }
            }
            partials = merged
        }
        guard var draft = partials.first, let status = textStatuses[paper.id] else {
            throw AppError.message("没有可整理的原文内容。")
        }
        if let bibliography {
            draft.title = bibliography.title
            draft.authors = bibliography.authors
            draft.year = bibliography.year
            draft.venue = bibliography.venue
            draft.doi = bibliography.doi
            draft.arxiv = bibliography.arxiv
        }
        let digest = draft.grounded(
            in: chunks, paperID: paper.id, model: signature, sourceHash: status.sourceHash,
            totalPages: status.totalPages)
        guard !digest.points.isEmpty else { throw AppError.message("模型返回的要点无法与原文摘录核对，本次未覆盖已有汇总。可以重试。") }
        return digest
    }
}
