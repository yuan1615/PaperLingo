import Foundation

public enum TextTools {
    public static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "-\\s*\\n\\s*", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public static func key(_ text: String) -> String {
        clean(text).lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
    }
    public static func kind(_ text: String) -> String {
        let words = clean(text).split(separator: " ")
        if words.count == 1 { return "单词" }
        if words.count <= 6 && !text.contains(where: { ".!?。！？".contains($0) }) { return "短语" }
        return "句子"
    }
    public static func context(in text: String, selection: String) -> String {
        let normalized = clean(text)
        let source = normalized as NSString
        let range = source.range(of: clean(selection), options: [.caseInsensitive])
        guard range.location != NSNotFound else { return clean(selection) }
        let tagger = NSLinguisticTagger(tagSchemes: [.tokenType], options: 0)
        tagger.string = normalized
        let sentence = tagger.sentenceRange(for: range)
        let lower = max(sentence.location, range.location - 350)
        let upper = min(NSMaxRange(sentence), NSMaxRange(range) + 350)
        return clean(source.substring(with: NSRange(location: lower, length: upper-lower)))
    }
    /// Read around the actual selection instead of tagging an entire article or
    /// finding the first occurrence of a word that may appear many times.
    public static func context(in text: String, range: NSRange) -> String {
        let source = text as NSString
        guard range.location != NSNotFound, range.length > 0,
              range.location <= source.length, range.length <= source.length - range.location else { return "" }
        if range.length > 2000 { return clean(source.substring(with: range)) }
        let lower = max(0, range.location - 400)
        let upper = min(source.length, NSMaxRange(range) + 400)
        let window = source.rangeOfComposedCharacterSequences(for: NSRange(location: lower, length: upper-lower))
        let excerpt = source.substring(with: window)
        let local = NSRange(location: range.location-window.location, length: range.length)
        let tagger = NSLinguisticTagger(tagSchemes: [.tokenType], options: 0)
        tagger.string = excerpt
        let sentence = tagger.sentenceRange(for: local)
        guard sentence.location != NSNotFound else { return clean(source.substring(with: range)) }
        return clean((excerpt as NSString).substring(with: sentence))
    }
}

public struct Paper: Identifiable, Codable, Equatable {
    public var id: String
    public var title: String
    public var filename: String
    public var kind: String
    public var source: String
    public var added: Date
    public var page: Int
    public init(id: String = UUID().uuidString, title: String, filename: String, kind: String, source: String = "", added: Date = Date(), page: Int = 0) {
        self.id=id; self.title=title; self.filename=filename; self.kind=kind; self.source=source; self.added=added; self.page=page
    }
}

public struct Vocabulary: Identifiable, Codable, Equatable {
    public var id: String
    public var text: String
    public var translation: String
    public var kind: String
    public var context: String
    public var paperID: String
    public var paperTitle: String
    public var page: Int
    public var lookups: Int
    public var lapses: Int
    public var stage: Int
    public var due: Date
    public var created: Date
    public var lastSeen: Date
    public var priority: Double { priority(at: Date()) }
    public func priority(at date: Date) -> Double {
        Double(lapses)*4 + log2(Double(lookups)+1)*2 + min(30, max(0, date.timeIntervalSince(due)/86400))
    }
}

public enum Grade: String, CaseIterable {
    case again, hard, good, easy
    public var title: String {
        switch self { case .again: return "忘记"; case .hard: return "模糊"; case .good: return "记住"; case .easy: return "轻松" }
    }
}

public enum Scheduler {
    public static let days = [1, 3, 7, 14, 30, 60]
    public static func next(stage: Int, grade: Grade, now: Date) -> (stage: Int, due: Date) {
        switch grade {
        case .again: return (0, now.addingTimeInterval(600))
        case .hard: return (max(0, stage-1), now.addingTimeInterval(86400))
        case .good:
            let index = min(max(0, stage), days.count-1)
            return (min(index+1, days.count-1), now.addingTimeInterval(Double(days[index])*86400))
        case .easy:
            let index = min(max(0, stage)+1, days.count-1)
            return (min(index+1, days.count-1), now.addingTimeInterval(Double(days[index])*86400))
        }
    }
    public static func queue(_ words: [Vocabulary], at now: Date = Date(), limit: Int = 20) -> [Vocabulary] {
        Array(words.filter { $0.due <= now }.sorted {
            if $0.priority(at: now) == $1.priority(at: now) { return $0.created < $1.created }
            return $0.priority(at: now) > $1.priority(at: now)
        }.prefix(max(0, limit)))
    }
}
