import Foundation
import PaperCore
import CSQLite

final class SummaryTests {
    func source() throws -> PaperSummarySource {
        try PaperSummarySource.firstPages(paperID: "p", totalPages: 22) { "Page \($0 + 1): motivation and proposed method. No evaluation outcomes reported." }
    }
    func digest() throws -> PaperDigest {
        let json: [String: Any] = ["oneLine": "一种降低语音合成延迟的方法。", "motivation": "现有方法的等待时间较长。",
            "method": "使用分段生成改善首次返回速度。", "results": "所提供的开头内容未明确报告实验结果", "category": "语音合成", "tags": ["分段生成", "语音"]]
        return try JSONDecoder().decode(PaperSummaryDraft.self, from: JSONSerialization.data(withJSONObject: json)).digest(source: source(), model: "test")
    }
    func testFirstThreePagesOnly() throws {
        var read: [Int] = []
        let opening = try PaperSummarySource.firstPages(paperID: "p", totalPages: 200) { page in
            read.append(page)
            return page == 0 ? "" : "Introduction page \(page)."
        }
        XCTAssertEqual(read, [0, 1, 2]); XCTAssertEqual(opening.status.totalPages, 200)
        XCTAssertEqual(opening.chunks.map(\.page), [1, 2])
        read = []
        _ = try PaperSummarySource.firstPages(paperID: "p", totalPages: 1) { page in read.append(page); return "Short paper." }
        XCTAssertEqual(read, [0])
        let empty = try PaperSummarySource.firstPages(paperID: "p", totalPages: 30) { _ in "" }
        XCTAssertTrue(empty.chunks.isEmpty)
        let summary = try digest()
        XCTAssertEqual(summary.points.map(\.topic), [.problem, .method, .results])
        XCTAssertTrue(summary.points.last!.text.contains("未明确报告"))
        XCTAssertEqual(summary.processedPages, 3); XCTAssertEqual(summary.totalPages, 22)
    }
    func testSummaryOnlyIndex() throws {
        let (db, dir) = try PaperCoreTests().database(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = Paper(id: "p", title: "English title secret", filename: "p.pdf", kind: "PDF")
        try db.addPaper(p); XCTAssertTrue(try db.passages().isEmpty)
        let summary = try digest(); try db.saveDigest(summary)
        var unit = try db.passages()[0]
        XCTAssertEqual(try db.passages().count, 1)
        XCTAssertEqual(unit.embeddingInput, PaperSummary.indexText(summary))
        XCTAssertTrue(!unit.embeddingInput.contains(p.title))
        unit.vector = [1, 0]; try db.savePassageVectors([unit], model: "test")
        let note = PaperNote(paperID: "p", body: "Personal secret not in vector")
        try db.saveNote(note)
        var record = PaperRecord(paperID: "p"); record.category = "Manual category"
        try db.savePaperRecord(record, title: "Renamed English title")
        let updated = try db.passages()[0]
        XCTAssertEqual(updated.id, unit.id); XCTAssertEqual(updated.vector, [1, 0])
        XCTAssertTrue(!updated.embeddingInput.contains("secret"))
        XCTAssertEqual(try db.keywordSearch("Personal secret").first?.paperID, "p")
        var revised = summary; revised.id = UUID().uuidString; revised.created = Date().addingTimeInterval(1)
        revised.oneLine += "新的结果。"; try db.saveDigest(revised)
        XCTAssertTrue(try db.passages()[0].vector.isEmpty)
        XCTAssertTrue(try db.passages()[0].id != unit.id)
        XCTAssertTrue(!(try db.exportPaperMarkdown(p)).contains("结构化实验记录"))
    }
    func testMigrationRemovesRetiredCaches() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("library.sqlite")
        do {
            let db = try Database(url: url)
            try db.addPaper(Paper(id: "p", title: "Original", filename: "p.pdf", kind: "PDF", page: 4))
            try db.saveNote(PaperNote(paperID: "p", body: "Keep this thought"))
            try db.record(text: "latent", translation: "潜在的", context: "", paper: nil, page: 0)
            try db.saveLedger(EvidenceTests().fixture())
            try db.replaceChunks(paperID: "p", chunks: ResearchText.chunks(paperID: "p", pages: Array(repeating: "Old full text", count: 20)))
        }
        var old: OpaquePointer?; sqlite3_open(url.path, &old)
        sqlite3_exec(old, "PRAGMA user_version=3; UPDATE research_index_meta SET value='old-index';", nil, nil, nil); sqlite3_close(old)
        let migrated = try Database(url: url)
        XCTAssertTrue(migrated.migrationBackupURL != nil)
        XCTAssertTrue(try migrated.ledgers().isEmpty); XCTAssertTrue(try migrated.experimentReviews().isEmpty)
        XCTAssertTrue(try migrated.chunks().isEmpty); XCTAssertTrue(try migrated.passages().isEmpty)
        XCTAssertEqual(try migrated.papers().first?.page, 4)
        XCTAssertEqual(try migrated.allNotes().first?.body, "Keep this thought")
        XCTAssertEqual(try migrated.vocabulary().count, 1)
        var backup: OpaquePointer?; sqlite3_open(migrated.migrationBackupURL!.path, &backup); defer { sqlite3_close(backup) }
        var statement: OpaquePointer?
        sqlite3_prepare_v2(backup, "SELECT COUNT(*) FROM paper_ledgers", -1, &statement, nil); defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW); XCTAssertEqual(sqlite3_column_int(statement, 0), 1)
    }
}
