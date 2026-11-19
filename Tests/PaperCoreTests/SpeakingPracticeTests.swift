import CSQLite
import Foundation
import PaperCore

final class SpeakingPracticeTests {
    func testSourcesAndModes() throws {
        let paper = Paper(id: "p", title: "Synthetic benchmark", filename: "private-file.pdf", kind: "PDF")
        let digest = try SummaryTests().digest()
        let summary = SpeakingPracticeSource.paper(paper, digest: digest)
        XCTAssertTrue(summary.coverage.contains("前 3 页"))
        XCTAssertTrue(summary.text.contains(digest.oneLine))
        XCTAssertTrue(summary.page == nil)
        var full = digest
        full.pipeline = PaperSummary.fullPDFVersion
        full.processedPages = full.totalPages
        XCTAssertTrue(SpeakingPracticeSource.paper(paper, digest: full).coverage.contains("全文摘要"))
        full.paperID = "other"
        XCTAssertTrue(SpeakingPracticeSource.paper(paper, digest: full).text.isEmpty)
        var old = digest
        old.pipeline = nil
        XCTAssertTrue(SpeakingPracticeSource.paper(paper, digest: old).text.isEmpty)

        let quote = SpeakingPracticeSource.excerpt(paper: paper, text: "Quoted data from a sample.", page: 4)
        let web = Paper(title: "Web article", filename: "article.txt", kind: "WEB")
        XCTAssertTrue(SpeakingPracticeSource.excerpt(paper: web, text: quote.text, page: 0).page == nil)
        var word = PracticeQueueTests().word("test-term")
        XCTAssertTrue(SpeakingPracticeSource.vocabulary(word, paper: paper).paperID == nil)
        word.context = String(repeating: "Earlier material. ", count: 120) + "A test-term near the end."
        let context = SpeakingPracticeSource.vocabulary(word)
        XCTAssertTrue(context.text.contains("语境片段") && context.text.contains("test-term"))
        XCTAssertTrue(context.text.count < word.context.count)
        XCTAssertTrue(SpeakingPracticeCoach.material(sources: []) == nil)
        let instructions = SpeakingPracticeMode.allCases.map {
            SpeakingPracticeCoach.instructions(mode: $0, sources: [quote])
        }
        XCTAssertEqual(Set(instructions).count, 3)
        XCTAssertTrue(instructions.allSatisfy { !$0.contains(quote.text) && !$0.contains(paper.title) })
        let materials = SpeakingPracticeCoach.material(sources: [summary, quote]) ?? ""
        let json = String(materials.split(separator: "\n", maxSplits: 1).last ?? "")
        let references = try JSONDecoder().decode([[String: String]].self, from: Data(json.utf8))
        XCTAssertEqual(references[0]["coverage"], summary.coverage)
        XCTAssertTrue(references[0]["pdfPage"] == nil)
        XCTAssertEqual(references[1]["pdfPage"], "5")
        XCTAssertEqual(references[1]["text"], quote.text)
        XCTAssertTrue(!materials.contains(paper.filename))
    }

    func testSaveEditAndReview() throws {
        let (db, dir) = try PaperCoreTests().database()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let paper = Paper(title: "Sample paper", filename: "sample.pdf", kind: "PDF")
        try db.addPaper(paper)
        try db.record(text: "estimate", translation: "估计", context: "An estimate depends on the sample.",
                      paper: paper, page: 2, now: now)
        let card = try db.vocabulary()[0]
        let wordSource = SpeakingPracticeSource.vocabulary(card, paper: paper)
        XCTAssertEqual(wordSource.page, 2)
        XCTAssertEqual(wordSource.wordID, card.id)
        var expression = SpeakingPracticeExpression(original: "I estimate it.", improved: "I estimated it.",
                                                    mode: .vocabulary, source: wordSource, created: now)
        try db.saveSpeakingExpression(expression)
        expression.reason = "Use the past tense for the completed experiment."
        try db.saveSpeakingExpression(expression)
        let free = SpeakingPracticeExpression(original: "I went for a walk.", improved: "", mode: .free,
                                              created: now.addingTimeInterval(1))
        try db.saveSpeakingExpression(free)
        do {
            try db.saveSpeakingExpression(.init(original: "  ", improved: "", reason: "Reason only", mode: .free))
            fail("Accepted an empty expression")
        } catch {}
        let fresh = try Database(url: dir.appendingPathComponent("test.sqlite"))
        XCTAssertEqual(try fresh.speakingExpressions(), [free, expression])
        XCTAssertEqual(try fresh.vocabulary(), [card])
        XCTAssertEqual(try fresh.reviewsToday(now: now), 0)
        try fresh.reviewSpeakingWord(id: card.id, grade: .good, now: now)
        XCTAssertEqual(try fresh.vocabulary()[0].stage, 1)
        // A Today card opened before the speaking grade must use the live stage.
        try db.review(card, grade: .good, mode: "recognition", now: now)
        XCTAssertEqual(try db.vocabulary()[0].stage, 2)
        XCTAssertEqual(try db.vocabulary()[0].due, Scheduler.next(stage: 1, grade: .good, now: now).due)
        XCTAssertEqual(try db.vocabulary()[0].lookups, card.lookups)
        try db.deletePaper(paper.id)
        try db.deleteWord(card.id)
        do { try db.reviewSpeakingWord(id: card.id, grade: .again, now: now); fail("Graded removed word") } catch {}
        XCTAssertEqual(try db.reviewsToday(now: now), 2)
        XCTAssertEqual(try db.speakingExpressions(), [free, expression])
        try db.deleteSpeakingExpression(expression.id)
        XCTAssertEqual(try db.speakingExpressions(), [free])
    }

    func testSchemaFiveUpgrade() throws {
        let (old, dir) = try PaperCoreTests().database()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("test.sqlite")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let paper = Paper(title: "WAL fixture", filename: "paper.pdf", kind: "PDF",
                          added: now, page: 4)
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &writer), SQLITE_OK)
        defer { sqlite3_close(writer) }
        XCTAssertEqual(sqlite3_exec(writer, "DROP TABLE speaking_expressions; PRAGMA user_version=5", nil, nil, nil), SQLITE_OK)
        try old.addPaper(paper)
        let note = PaperNote(paperID: paper.id, body: "Local note", quote: "Evidence", page: 4)
        try old.saveNote(note)
        try old.record(text: "candidate", translation: "候选", context: "A candidate method.", paper: paper, page: 4, now: now)
        let card = try old.vocabulary()[0]
        try old.review(card, grade: .hard, mode: "listening", now: now)
        let vocabulary = try old.vocabulary()

        let migrated = try Database(url: url)
        XCTAssertEqual(try migrated.papers(), [paper])
        XCTAssertEqual(try migrated.notes(paperID: paper.id), [note])
        XCTAssertEqual(try migrated.vocabulary(), vocabulary)
        XCTAssertEqual(try migrated.reviewsToday(now: now), 1)
        XCTAssertTrue(try migrated.speakingExpressions().isEmpty)
        XCTAssertTrue(try Database(url: url).migrationBackupURL == nil)
        guard let backupURL = migrated.migrationBackupURL else { fail("Missing v5 backup"); return }
        var backup: OpaquePointer?
        let snapshotURI = backupURL.absoluteString + "?immutable=1"
        XCTAssertEqual(sqlite3_open_v2(snapshotURI, &backup, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil), SQLITE_OK)
        defer { sqlite3_close(backup) }
        var snapshot: OpaquePointer?
        let sql = """
            SELECT user_version,(SELECT count(*) FROM reviews),(SELECT count(*) FROM lookups),
                   (SELECT count(*) FROM sqlite_master WHERE name='speaking_expressions') FROM pragma_user_version
            """
        guard sqlite3_prepare_v2(backup, sql, -1, &snapshot, nil) == SQLITE_OK else {
            fail("Unreadable v5 backup: " + String(cString: sqlite3_errmsg(backup)))
            return
        }
        defer { sqlite3_finalize(snapshot) }
        XCTAssertEqual(sqlite3_step(snapshot), SQLITE_ROW)
        XCTAssertEqual((0..<4).map { sqlite3_column_int(snapshot, Int32($0)) }, [5, 1, 1, 0])
    }
}
