import Foundation
import CSQLite

public enum StorageError: LocalizedError {
    case sqlite(String)
    public var errorDescription: String? { if case .sqlite(let message) = self { return "本地数据库：\(message)" }; return nil }
}

public final class Database {
    private var handle: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    public init(url: URL) throws {
        guard sqlite3_open(url.path, &handle) == SQLITE_OK else { throw StorageError.sqlite("无法打开数据库") }
        try exec("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;")
        try exec("""
        CREATE TABLE IF NOT EXISTS papers(id TEXT PRIMARY KEY,title TEXT NOT NULL,filename TEXT NOT NULL,kind TEXT NOT NULL,source TEXT NOT NULL,added REAL NOT NULL,page INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS vocabulary(id TEXT PRIMARY KEY,normalized TEXT UNIQUE NOT NULL,text TEXT NOT NULL,translation TEXT NOT NULL,kind TEXT NOT NULL,context TEXT NOT NULL,paper_id TEXT NOT NULL,paper_title TEXT NOT NULL,page INTEGER NOT NULL,lookups INTEGER NOT NULL,lapses INTEGER NOT NULL,stage INTEGER NOT NULL,due REAL NOT NULL,created REAL NOT NULL,last_seen REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS lookups(id INTEGER PRIMARY KEY,word_id TEXT,paper_id TEXT,text TEXT,context TEXT,page INTEGER,created REAL);
        CREATE TABLE IF NOT EXISTS reviews(id INTEGER PRIMARY KEY,word_id TEXT,grade TEXT,mode TEXT,created REAL,next_due REAL);
        CREATE INDEX IF NOT EXISTS vocabulary_due ON vocabulary(due);
        PRAGMA user_version=1;
        """)
    }
    deinit { sqlite3_close(handle) }
    private func exec(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func failure() -> StorageError { .sqlite(String(cString: sqlite3_errmsg(handle))) }
    private func statement(_ sql: String, _ values: [Any] = []) throws -> OpaquePointer {
        var result: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &result, nil) == SQLITE_OK, let result else { throw failure() }
        for (i, value) in values.enumerated() {
            let index = Int32(i+1)
            if let value = value as? String { sqlite3_bind_text(result, index, value, -1, transient) }
            else if let value = value as? Int { sqlite3_bind_int64(result, index, sqlite3_int64(value)) }
            else if let value = value as? Double { sqlite3_bind_double(result, index, value) }
            else { sqlite3_bind_null(result, index) }
        }
        return result
    }
    private func write(_ sql: String, _ values: [Any] = []) throws {
        let s = try statement(sql, values); defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_DONE else { throw failure() }
    }
    private func rows<T>(_ sql: String, _ values: [Any] = [], map: (OpaquePointer) -> T) throws -> [T] {
        let s = try statement(sql, values); defer { sqlite3_finalize(s) }
        var result: [T] = []
        while true {
            let status = sqlite3_step(s)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw failure() }
            result.append(map(s))
        }
    }
    private func text(_ s: OpaquePointer, _ index: Int32) -> String { sqlite3_column_text(s,index).map { String(cString: $0) } ?? "" }
    private func date(_ s: OpaquePointer, _ index: Int32) -> Date { Date(timeIntervalSince1970: sqlite3_column_double(s,index)) }
    public func papers() throws -> [Paper] {
        try rows("SELECT id,title,filename,kind,source,added,page FROM papers ORDER BY added DESC") { s in
            Paper(id: text(s,0), title: text(s,1), filename: text(s,2), kind: text(s,3), source: text(s,4), added: date(s,5), page: Int(sqlite3_column_int(s,6)))
        }
    }
    public func addPaper(_ p: Paper) throws {
        try write("INSERT INTO papers VALUES(?,?,?,?,?,?,?)", [p.id,p.title,p.filename,p.kind,p.source,p.added.timeIntervalSince1970,p.page])
    }
    public func updatePage(_ id: String, page: Int) throws { try write("UPDATE papers SET page=? WHERE id=?", [page,id]) }
    public func deletePaper(_ id: String) throws { try write("DELETE FROM papers WHERE id=?", [id]) }
    public func vocabulary() throws -> [Vocabulary] {
        try rows("SELECT id,text,translation,kind,context,paper_id,paper_title,page,lookups,lapses,stage,due,created,last_seen FROM vocabulary ORDER BY last_seen DESC") { s in
            Vocabulary(id: text(s,0), text: text(s,1), translation: text(s,2), kind: text(s,3), context: text(s,4), paperID: text(s,5), paperTitle: text(s,6), page: Int(sqlite3_column_int(s,7)), lookups: Int(sqlite3_column_int(s,8)), lapses: Int(sqlite3_column_int(s,9)), stage: Int(sqlite3_column_int(s,10)), due: date(s,11), created: date(s,12), lastSeen: date(s,13))
        }
    }
    @discardableResult public func record(text: String, translation: String, context: String, paper: Paper?, page: Int, save: Bool = true, now: Date = Date()) throws -> String? {
        let cleaned = TextTools.clean(text), key = TextTools.key(text)
        guard !key.isEmpty, !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        try exec("BEGIN IMMEDIATE")
        do {
            var id = try rows("SELECT id FROM vocabulary WHERE normalized=?", [key]) { self.text($0,0) }.first
            if save || id != nil {
                if let id {
                    try write("UPDATE vocabulary SET lookups=lookups+1,last_seen=?,due=MIN(due,?),translation=?,context=?,paper_id=?,paper_title=?,page=? WHERE id=?", [now.timeIntervalSince1970,now.timeIntervalSince1970,translation,context,paper?.id ?? "",paper?.title ?? "手动查阅",page,id])
                } else {
                    id = UUID().uuidString
                    try write("INSERT INTO vocabulary VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", [id!,key,cleaned,translation,TextTools.kind(cleaned),context,paper?.id ?? "",paper?.title ?? "手动查阅",page,1,0,0,now.timeIntervalSince1970,now.timeIntervalSince1970,now.timeIntervalSince1970])
                }
            }
            try write("INSERT INTO lookups(word_id,paper_id,text,context,page,created) VALUES(?,?,?,?,?,?)", [id ?? "",paper?.id ?? "",cleaned,context,page,now.timeIntervalSince1970])
            try exec("COMMIT")
            return id
        } catch { try? exec("ROLLBACK"); throw error }
    }
    public func review(_ word: Vocabulary, grade: Grade, mode: String, now: Date = Date()) throws {
        let next = Scheduler.next(stage: word.stage, grade: grade, now: now)
        try exec("BEGIN IMMEDIATE")
        do {
            try write("UPDATE vocabulary SET stage=?,due=?,lapses=lapses+? WHERE id=?", [next.stage,next.due.timeIntervalSince1970,grade == .again ? 1 : 0,word.id])
            try write("INSERT INTO reviews(word_id,grade,mode,created,next_due) VALUES(?,?,?,?,?)", [word.id,grade.rawValue,mode,now.timeIntervalSince1970,next.due.timeIntervalSince1970])
            try exec("COMMIT")
        } catch { try? exec("ROLLBACK"); throw error }
    }
    public func deleteWord(_ id: String) throws { try write("DELETE FROM vocabulary WHERE id=?", [id]) }
    public func reviewsToday(now: Date = Date()) throws -> Int {
        try rows("SELECT COUNT(*) FROM reviews WHERE created>=?", [Calendar.current.startOfDay(for: now).timeIntervalSince1970]) { Int(sqlite3_column_int($0,0)) }.first ?? 0
    }
    public func promote(text: String, translation: String, context: String, paper: Paper?, page: Int) throws {
        // Promotion is a new explicit save, not another lookup of the same sentence.
        let key = TextTools.key(text)
        guard !(try vocabulary()).contains(where: { TextTools.key($0.text) == key }) else { return }
        try write("INSERT INTO vocabulary VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", [UUID().uuidString,key,TextTools.clean(text),translation,TextTools.kind(text),context,paper?.id ?? "",paper?.title ?? "手动查阅",page,1,0,0,Date().timeIntervalSince1970,Date().timeIntervalSince1970,Date().timeIntervalSince1970])
    }
}
