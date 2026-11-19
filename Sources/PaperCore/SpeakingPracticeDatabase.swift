import Foundation

extension Database {
    func migrateSpeakingPracticeSchema() throws {
        try exec("""
            CREATE TABLE IF NOT EXISTS speaking_expressions(
                id TEXT PRIMARY KEY,
                created REAL NOT NULL,
                payload TEXT NOT NULL
            );
            """)
    }

    public func saveSpeakingExpression(_ expression: SpeakingPracticeExpression) throws {
        var entry = expression
        entry.original = entry.original.trimmingCharacters(in: .whitespacesAndNewlines)
        entry.improved = entry.improved.trimmingCharacters(in: .whitespacesAndNewlines)
        entry.reason = entry.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entry.original.isEmpty || !entry.improved.isEmpty else {
            throw StorageError.sqlite("请填写想保存的原话或改进表达。")
        }
        guard !entry.id.isEmpty else { throw StorageError.sqlite("这条表达缺少标识。") }
        try write("""
            INSERT INTO speaking_expressions(id,created,payload) VALUES(?,?,?)
            ON CONFLICT(id) DO UPDATE SET created=excluded.created,payload=excluded.payload
            """, [entry.id, entry.created.timeIntervalSince1970, try encoded(entry)])
    }

    public func speakingExpressions() throws -> [SpeakingPracticeExpression] {
        let payloads = try rows("SELECT payload FROM speaking_expressions ORDER BY created DESC, rowid DESC") { text($0, 0) }
        return try payloads.map { try decoded(SpeakingPracticeExpression.self, $0) }
    }

    public func deleteSpeakingExpression(_ id: String) throws {
        try write("DELETE FROM speaking_expressions WHERE id=?", [id])
    }

    public func reviewSpeakingWord(id: String, grade: Grade, now: Date = Date()) throws {
        try review(wordID: id, grade: grade, mode: "speaking", now: now)
    }
}
