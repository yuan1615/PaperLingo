import CSQLite
import Foundation
import PaperCore

final class WordExplanationTests {
    let draft=WordExplanationDraft(meaning:"形容词；稳健的",inContext:"指模型在干扰下仍能保持稳定表现。",usage:"robust to noise：对噪声有抵抗力。")
    func testBoundedContextKeepsLateTermAndUnicode() throws {
        let source=String(repeating:"Earlier context 🧠. ",count:200)+"A ROBUST estimate remains stable. "+String(repeating:"Later context. ",count:200)
        let input=try WordExplanationInput(expression:"robust",context:source)
        XCTAssertTrue(input.context.contains("ROBUST"));XCTAssertTrue(input.contextIsExcerpt)
        XCTAssertTrue(input.context.utf16.count<=1202)
        XCTAssertEqual(try WordExplanationInput(expression:"in contrast to",context:"In contrast to the baseline, this method uses less data.").expression,"in contrast to")
        do {_=try WordExplanationInput(expression:"missing",context:source);fail("Unrelated prefix was accepted")}catch{}
        do {_=try WordExplanationInput(expression:"This is a saved sentence.",context:source);fail("Sentence generated a word gloss")}catch{}
    }
    func testOutputLimitsRejectIncompleteAndLongResults() throws {
        XCTAssertEqual(try draft.validated(),draft)
        for value in [WordExplanationDraft(meaning:"",inContext:"语境",usage:"用法"),WordExplanationDraft(meaning:"释义",inContext:String(repeating:"长",count:121),usage:"用法")] {
            do {_=try value.validated();fail("Invalid output was silently cached")}catch{}
        }
    }
    func testContextCachePreservesLearningAndRejectsStaleWrites() throws {
        let (db,dir)=try PaperCoreTests().database();defer{try? FileManager.default.removeItem(at:dir)}
        try db.record(text:"robust",translation:"稳健的",context:"A robust estimate.",paper:nil,page:0)
        let word=try db.vocabulary()[0]
        let value=try WordExplanation(word:word,context:word.context,model:ResearchModels.analysis,content:draft)
        try db.saveWordExplanation(value)
        XCTAssertEqual(try db.vocabulary()[0],word)
        XCTAssertEqual(try db.wordExplanations()[word.id],value)
        try db.record(text:"robust",translation:"强健的",context:"A robust physical structure.",paper:nil,page:0)
        let changed=try db.vocabulary()[0]
        XCTAssertTrue(!value.isCurrent(for:changed))
        do {try db.saveWordExplanation(value);fail("Stale response overwrote a new context")}catch{}
        try db.deleteWord(word.id);XCTAssertTrue(try db.wordExplanations().isEmpty)
    }
    func testV4MigrationBacksUpWALAndKeepsOriginalRecords() throws {
        let (db,dir)=try PaperCoreTests().database();defer{try? FileManager.default.removeItem(at:dir)}
        try db.record(text:"robust",translation:"稳健的",context:"A robust estimate.",paper:nil,page:4)
        let original=try db.vocabulary()[0]
        var old:OpaquePointer?;sqlite3_open(dir.appendingPathComponent("test.sqlite").path,&old)
        sqlite3_exec(old,"DROP TABLE word_explanations; PRAGMA user_version=4;",nil,nil,nil);sqlite3_close(old)
        let upgraded=try Database(url:dir.appendingPathComponent("test.sqlite"))
        XCTAssertTrue(upgraded.migrationBackupURL != nil)
        XCTAssertEqual(try upgraded.vocabulary()[0],original)
        var backup:OpaquePointer?;sqlite3_open(upgraded.migrationBackupURL!.path,&backup);defer{sqlite3_close(backup)}
        var statement:OpaquePointer?;sqlite3_prepare_v2(backup,"SELECT count(*) FROM vocabulary",-1,&statement,nil);defer{sqlite3_finalize(statement)}
        XCTAssertEqual(sqlite3_step(statement),SQLITE_ROW);XCTAssertEqual(sqlite3_column_int(statement,0),1)
        XCTAssertTrue(try upgraded.wordExplanations().isEmpty)
    }
}
