import CSQLite
import Foundation

extension Database {
    public func backup(to url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { throw StorageError.sqlite("备份目标已存在") }
        var target: OpaquePointer?
        guard sqlite3_open(url.path, &target) == SQLITE_OK else {
            sqlite3_close(target)
            throw StorageError.sqlite("无法创建升级备份")
        }
        defer { sqlite3_close(target) }
        guard let copy = sqlite3_backup_init(target, "main", handle, "main") else {
            throw StorageError.sqlite("无法开始一致性备份")
        }
        let status = sqlite3_backup_step(copy, -1)
        let finish = sqlite3_backup_finish(copy)
        guard status == SQLITE_DONE, finish == SQLITE_OK else { throw StorageError.sqlite("备份未完成，已停止升级以保留原始数据") }
    }
    func migrateResearchSchema() throws {
        try exec(
            """
            CREATE TABLE IF NOT EXISTS paper_records(paper_id TEXT PRIMARY KEY REFERENCES papers(id) ON DELETE CASCADE,payload TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS paper_notes(id TEXT PRIMARY KEY,paper_id TEXT NOT NULL REFERENCES papers(id) ON DELETE CASCADE,payload TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS paper_notes_paper ON paper_notes(paper_id);
            CREATE TABLE IF NOT EXISTS paper_chunks(id TEXT PRIMARY KEY,paper_id TEXT NOT NULL REFERENCES papers(id) ON DELETE CASCADE,page INTEGER NOT NULL,ordinal INTEGER NOT NULL,text TEXT NOT NULL,vector TEXT NOT NULL DEFAULT '',vector_model TEXT NOT NULL DEFAULT '');
            CREATE INDEX IF NOT EXISTS paper_chunks_paper ON paper_chunks(paper_id);
            CREATE TABLE IF NOT EXISTS paper_text_status(paper_id TEXT PRIMARY KEY REFERENCES papers(id) ON DELETE CASCADE,payload TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS paper_digests(id TEXT PRIMARY KEY,paper_id TEXT NOT NULL REFERENCES papers(id) ON DELETE CASCADE,created REAL NOT NULL,payload TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS paper_digests_paper ON paper_digests(paper_id,created DESC);
            CREATE TABLE IF NOT EXISTS paper_analysis_cache(cache_key TEXT PRIMARY KEY,paper_id TEXT NOT NULL REFERENCES papers(id) ON DELETE CASCADE,payload TEXT NOT NULL);
            CREATE VIRTUAL TABLE IF NOT EXISTS paper_search USING fts5(paper_id UNINDEXED,title,metadata,summary,notes,body,tokenize='unicode61 remove_diacritics 2');
            """)
        let indexed = Set(try rows("SELECT paper_id FROM paper_search") { text($0, 0) })
        for paper in try papers() where !indexed.contains(paper.id) { try refreshPaperSearch(paper.id) }
    }
    func encoded<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
    func decoded<T: Decodable>(_ type: T.Type, _ source: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(source.utf8))
    }
    public func paperRecords() throws -> [String: PaperRecord] {
        let payloads = try rows("SELECT paper_id,payload FROM paper_records") { (text($0, 0), text($0, 1)) }
        return try Dictionary(uniqueKeysWithValues: payloads.map { ($0.0, try decoded(PaperRecord.self, $0.1)) })
    }
    public func textStatuses() throws -> [String: PaperTextStatus] {
        try Dictionary(
            uniqueKeysWithValues: rows("SELECT paper_id,payload FROM paper_text_status") { (text($0, 0), text($0, 1)) }
                .map { ($0.0, try decoded(PaperTextStatus.self, $0.1)) })
    }
    public func saveTextStatus(_ status: PaperTextStatus) throws {
        try write(
            "INSERT INTO paper_text_status VALUES(?,?) ON CONFLICT(paper_id) DO UPDATE SET payload=excluded.payload",
            [status.paperID, try encoded(status)])
    }
    public func paperRecord(_ id: String) throws -> PaperRecord {
        guard
            let payload = try rows("SELECT payload FROM paper_records WHERE paper_id=?", [id], map: { text($0, 0) })
                .first
        else { return PaperRecord(paperID: id) }
        return try decoded(PaperRecord.self, payload)
    }
    public func savePaperRecord(_ record: PaperRecord, title: String? = nil) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try write(
                "INSERT INTO paper_records VALUES(?,?) ON CONFLICT(paper_id) DO UPDATE SET payload=excluded.payload",
                [record.paperID, try encoded(record)])
            if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try write("UPDATE papers SET title=? WHERE id=?", [title, record.paperID])
            }
            try refreshPaperSearch(record.paperID)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
    public func markPaperOpened(_ id: String, now: Date = Date()) throws {
        var record = try paperRecord(id)
        record.lastOpened = now
        if record.status == .inbox { record.status = .reading }
        try savePaperRecord(record)
    }
    public func notes(paperID: String) throws -> [PaperNote] {
        try rows("SELECT payload FROM paper_notes WHERE paper_id=? ORDER BY rowid DESC", [paperID]) { text($0, 0) }.map
        { try decoded(PaperNote.self, $0) }.sorted { $0.updated > $1.updated }
    }
    public func allNotes() throws -> [PaperNote] {
        try rows("SELECT payload FROM paper_notes") { text($0, 0) }.map { try decoded(PaperNote.self, $0) }
    }
    public func saveNote(_ note: PaperNote) throws {
        guard !note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !note.quote.isEmpty else {
            throw StorageError.sqlite("请写一点记录或保存一段原文")
        }
        if let owner = try rows("SELECT paper_id FROM paper_notes WHERE id=?", [note.id], map: { text($0, 0) }).first,
            owner != note.paperID
        {
            throw StorageError.sqlite("笔记不能被写入另一篇论文")
        }
        try exec("BEGIN IMMEDIATE")
        do {
            try write(
                "INSERT INTO paper_notes VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",
                [note.id, note.paperID, try encoded(note)])
            try refreshPaperSearch(note.paperID)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
    public func deleteNote(_ note: PaperNote) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try write("DELETE FROM paper_notes WHERE id=? AND paper_id=?", [note.id, note.paperID])
            try refreshPaperSearch(note.paperID)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
    public func chunks(paperID: String? = nil) throws -> [PaperTextChunk] {
        let clause = paperID == nil ? "" : " WHERE paper_id=?"
        return try rows(
            "SELECT paper_id,page,ordinal,text,vector,vector_model FROM paper_chunks" + clause
                + " ORDER BY page,ordinal", paperID.map { [$0] } ?? []
        ) { s in
            PaperTextChunk(
                paperID: text(s, 0), page: Int(sqlite3_column_int(s, 1)), ordinal: Int(sqlite3_column_int(s, 2)),
                text: text(s, 3), vector: (try? decoded([Float].self, text(s, 4))) ?? [], vectorModel: text(s, 5))
        }
    }
    public func replaceChunks(paperID: String, chunks: [PaperTextChunk], status: PaperTextStatus? = nil) throws {
        guard chunks.allSatisfy({ $0.paperID == paperID }) else { throw StorageError.sqlite("正文片段与论文不匹配") }
        guard status == nil || status?.paperID == paperID else { throw StorageError.sqlite("正文状态与论文不匹配") }
        let existing = Dictionary(try self.chunks(paperID: paperID).map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        try exec("BEGIN IMMEDIATE")
        do {
            try write("DELETE FROM paper_chunks WHERE paper_id=?", [paperID])
            for chunk in chunks {
                let vector = chunk.vector.isEmpty ? (existing[chunk.id]?.vector ?? []) : chunk.vector
                let model = chunk.vector.isEmpty ? (existing[chunk.id]?.vectorModel ?? "") : chunk.vectorModel
                try write(
                    "INSERT INTO paper_chunks VALUES(?,?,?,?,?,?,?)",
                    [chunk.id, paperID, chunk.page, chunk.ordinal, chunk.text, try encoded(vector), model])
            }
            if let status { try saveTextStatus(status) }
            try refreshPaperSearch(paperID)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
    public func saveVectors(_ updates: [PaperTextChunk], model: String) throws {
        guard updates.allSatisfy({ !$0.vector.isEmpty && $0.vector.allSatisfy(\.isFinite) }) else {
            throw StorageError.sqlite("检索模型返回了无效向量")
        }
        try exec("BEGIN IMMEDIATE")
        do {
            for chunk in updates {
                try write(
                    "UPDATE paper_chunks SET vector=?,vector_model=? WHERE id=? AND paper_id=? AND text=?",
                    [try encoded(chunk.vector), model, chunk.id, chunk.paperID, chunk.text])
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
    public func digests(paperID: String) throws -> [PaperDigest] {
        try rows("SELECT payload FROM paper_digests WHERE paper_id=? ORDER BY created DESC", [paperID]) { text($0, 0) }
            .map { try decoded(PaperDigest.self, $0) }
    }
    public func latestDigests() throws -> [String: PaperDigest] {
        let all = try rows("SELECT payload FROM paper_digests ORDER BY created DESC") { text($0, 0) }.map {
            try decoded(PaperDigest.self, $0)
        }
        var result: [String: PaperDigest] = [:]
        for digest in all where result[digest.paperID] == nil { result[digest.paperID] = digest }
        return result
    }
    public func saveDigest(_ digest: PaperDigest) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try write(
                "INSERT INTO paper_digests VALUES(?,?,?,?)",
                [digest.id, digest.paperID, digest.created.timeIntervalSince1970, try encoded(digest)])
            try refreshPaperSearch(digest.paperID)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
    public func cachedAnalysis(key: String) throws -> DigestDraft? {
        try rows("SELECT payload FROM paper_analysis_cache WHERE cache_key=?", [key]) { text($0, 0) }.first.map {
            try decoded(DigestDraft.self, $0)
        }
    }
    public func cacheAnalysis(_ draft: DigestDraft, key: String, paperID: String) throws {
        try write(
            "INSERT INTO paper_analysis_cache VALUES(?,?,?) ON CONFLICT(cache_key) DO UPDATE SET payload=excluded.payload",
            [key, paperID, try encoded(draft)])
    }
    func refreshPaperSearch(_ id: String) throws {
        guard let paper = try papers().first(where: { $0.id == id }) else { return }
        let record = try paperRecord(id)
        let notes = try notes(paperID: id)
        let digest = try digests(paperID: id).first
        let summary = ([digest?.oneLine ?? ""] + (digest?.points.map(\.text) ?? [])).joined(separator: " ")
        let noteText = notes.map { [$0.title, $0.body, $0.quote, $0.kind.rawValue].joined(separator: " ") }.joined(
            separator: "\n")
        let body = try rows("SELECT text FROM paper_chunks WHERE paper_id=? ORDER BY page,ordinal", [id]) {
            text($0, 0)
        }.joined(separator: "\n")
        try write("DELETE FROM paper_search WHERE paper_id=?", [id])
        try write(
            "INSERT INTO paper_search VALUES(?,?,?,?,?,?)",
            [id, paper.title, record.searchable, summary, noteText, body])
    }
    public func keywordSearch(_ query: String, limit: Int = 100) throws -> [ResearchSearchHit] {
        let cleaned = TextTools.clean(query)
        guard !cleaned.isEmpty else { return [] }
        let literal = cleaned.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let term = "%" + literal + "%"
        let sql = """
            SELECT paper_id,
            CASE WHEN title LIKE ? ESCAPE '\\' THEN title WHEN metadata LIKE ? ESCAPE '\\' THEN metadata WHEN notes LIKE ? ESCAPE '\\' THEN notes WHEN summary LIKE ? ESCAPE '\\' THEN summary ELSE body END,
            CASE WHEN title LIKE ? ESCAPE '\\' THEN '标题' WHEN metadata LIKE ? ESCAPE '\\' THEN '档案' WHEN notes LIKE ? ESCAPE '\\' THEN '笔记' WHEN summary LIKE ? ESCAPE '\\' THEN '汇总' ELSE '正文' END
            FROM paper_search WHERE title LIKE ? ESCAPE '\\' OR metadata LIKE ? ESCAPE '\\' OR summary LIKE ? ESCAPE '\\' OR notes LIKE ? ESCAPE '\\' OR body LIKE ? ESCAPE '\\' LIMIT ?
            """
        var values: [Any] = Array(repeating: term, count: 13)
        values.append(limit)
        var result = try rows(sql, values) { s in
            ResearchSearchHit(
                paperID: text(s, 0), score: 1, snippet: searchExcerpt(text(s, 1), query: cleaned), source: text(s, 2))
        }
        let tokens = cleaned.split(whereSeparator: { $0.isWhitespace }).prefix(12).map {
            "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*"
        }.joined(separator: " AND ")
        if !tokens.isEmpty {
            let fulltext = try rows(
                "SELECT paper_id,snippet(paper_search,-1,'','',' … ',40),bm25(paper_search,0,6,4,3,3,1) FROM paper_search WHERE paper_search MATCH ? ORDER BY bm25(paper_search,0,6,4,3,3,1) LIMIT ?",
                [tokens, limit]
            ) { s in
                ResearchSearchHit(
                    paperID: text(s, 0), score: 0.5 - sqlite3_column_double(s, 2), snippet: text(s, 1), source: "全文")
            }
            let existing = Set(result.map(\.paperID))
            result += fulltext.filter { !existing.contains($0.paperID) }
        }
        for index in result.indices {
            if ["正文", "全文"].contains(result[index].source),
                let source = try chunks(paperID: result[index].paperID).first(where: {
                    $0.text.range(of: cleaned, options: .caseInsensitive) != nil
                })
            {
                result[index].page = source.page
                if result[index].snippet.count > 600 || result[index].snippet.isEmpty {
                    result[index].snippet = searchExcerpt(source.text, query: cleaned)
                }
            }
        }
        return Array(result.prefix(max(0, limit)))
    }
    private func searchExcerpt(_ text: String, query: String) -> String {
        guard let range = text.range(of: query, options: .caseInsensitive) else { return String(text.prefix(360)) }
        let start = text.index(range.lowerBound, offsetBy: -90, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 230, limitedBy: text.endIndex) ?? text.endIndex
        return (start > text.startIndex ? "…" : "") + String(text[start..<end]) + (end < text.endIndex ? "…" : "")
    }
    public func exportPaperMarkdown(_ paper: Paper) throws -> String {
        let r = try paperRecord(paper.id)
        let notes = try notes(paperID: paper.id)
        let digest = try digests(paperID: paper.id).first
        var lines = [
            "# \(paper.title)", "", "- 作者：\(r.authors)", "- 年份 / 出处：\(r.year) · \(r.venue)", "- DOI：\(r.doi)",
            "- arXiv：\(r.arxiv)", "- 来源：\(paper.source)", "- 状态：\(r.status.rawValue)", "- 分类：\(r.category)",
            "- 标签：\(r.tags.joined(separator:", "))", "", "## 我的用途", "", r.purpose,
        ]
        if let digest {
            lines += [
                "", digest.isPartial == true ? "## AI 阶段预览（全文尚未完成）" : "## AI 汇总", "", digest.oneLine, "",
                "模型：\(digest.model) · \(digest.created.formatted()) · 已处理有文字的 \(digest.processedPages)/\(digest.totalPages) 页。内容仍需对照论文核实。",
            ]
            for topic in DigestTopic.allCases {
                lines += ["", "### \(topic.title)", ""]
                let points = digest.points.filter { $0.topic == topic }
                if points.isEmpty { lines.append("未从本次材料中提取到有证据的要点。") }
                for point in points {
                    lines += [
                        "- \(point.text)", "", "> \(point.quote.replacingOccurrences(of:"\n",with:"\n> "))", "",
                        "来源：第 \(point.page+1) 页。", "",
                    ]
                }
            }
        }
        lines += ["", "## 个人笔记", ""]
        for note in notes {
            lines += [
                "### \(note.title.isEmpty ? note.kind.rawValue : note.title)", "",
                "\(note.kind.rawValue) · 更新于 \(note.updated.formatted())", "", note.body,
            ]
            if !note.quote.isEmpty {
                lines += [
                    "", "> \(note.quote.replacingOccurrences(of:"\n",with:"\n> "))", "",
                    note.page.map { "第 \($0+1) 页" } ?? "网页正文",
                ]
            }
            lines.append("")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
