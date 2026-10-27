import Foundation
import NaturalLanguage

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
    public static func context(in text: String, selection: String, matching previousContext: String = "") -> String {
        let normalized = clean(text)
        let source = normalized as NSString
        let selected = clean(selection), previous = clean(previousContext)
        guard !selected.isEmpty else { return "" }
        // Old cards may contain only a middle fragment. Use that fragment to
        // locate the correct occurrence before recovering the whole sentence.
        if !previous.isEmpty {
            let saved = source.range(of: previous, options: [.caseInsensitive])
            if saved.location != NSNotFound {
                let range = source.range(of: selected, options: [.caseInsensitive], range: saved)
                if range.location != NSNotFound { return context(in: normalized, range: range) }
            }
        }
        let range = source.range(of: selected, options: [.caseInsensitive])
        guard range.location != NSNotFound else { return previous.isEmpty ? selected : previous }
        if !previous.isEmpty {
            let rest = NSRange(location: NSMaxRange(range), length: source.length - NSMaxRange(range))
            if source.range(of: selected, options: [.caseInsensitive], range: rest).location != NSNotFound {
                return previous // An ambiguous old source is safer than a different occurrence.
            }
        }
        return context(in: normalized, range: range)
    }
    /// Start locally, then expand only when a sentence touches a cut boundary.
    /// Short sentences in large articles stay cheap; long ones are never clipped.
    public static func context(in text: String, range: NSRange) -> String {
        let source = text as NSString
        guard range.location != NSNotFound, range.length > 0,
              range.location <= source.length, range.length <= source.length - range.location else { return "" }
        var radius = 400
        while true {
            let lower = max(0, range.location - radius)
            let upper = NSMaxRange(range) + min(radius, source.length - NSMaxRange(range))
            let window = source.rangeOfComposedCharacterSequences(for: NSRange(location: lower, length: upper-lower))
            let excerpt = source.substring(with: window)
            let local = NSRange(location: range.location-window.location, length: range.length)
            guard let selected = Range(local, in: excerpt) else { return clean(source.substring(with: range)) }
            // NSLinguisticTagger.sentenceRange can silently cap long sentences
            // at an internal buffer boundary. NLTokenizer preserves them.
            let tokenizer = NLTokenizer(unit: .sentence); tokenizer.string = excerpt
            let first = tokenizer.tokenRange(at: selected.lowerBound)
            let last = tokenizer.tokenRange(at: excerpt.index(before: selected.upperBound))
            let sentence = NSRange(first.lowerBound..<last.upperBound, in: excerpt)
            guard sentence.location != NSNotFound, sentence.location <= local.location,
                  NSMaxRange(sentence) >= NSMaxRange(local), NSMaxRange(sentence) <= window.length else {
                return clean(source.substring(with: range))
            }
            let clippedStart = window.location > 0 && sentence.location == 0
            let clippedEnd = NSMaxRange(window) < source.length && NSMaxRange(sentence) == window.length
            if !clippedStart && !clippedEnd { return clean((excerpt as NSString).substring(with: sentence)) }
            radius = min(source.length, radius > source.length / 2 ? source.length : radius * 2)
        }
    }
}

public struct Paper: Identifiable, Codable, Equatable, Sendable {
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
    public static func practiceQueue(_ words:[Vocabulary],at now:Date=Date(),limit:Int=20,avoiding previous:[String]=[]) -> [Vocabulary] {
        var generator=SystemRandomNumberGenerator()
        return practiceQueue(words,at:now,limit:limit,avoiding:previous,using:&generator)
    }
    public static func practiceQueue<R:RandomNumberGenerator>(_ words:[Vocabulary],at now:Date=Date(),limit:Int=20,avoiding previous:[String]=[],using generator:inout R) -> [Vocabulary] {
        guard limit > 0 else {return []}
        // An exponential race samples without replacement from all due cards.
        // Difficult cards are more likely to appear; no fixed top-20 cutoff.
        var ranked:[(word:Vocabulary,key:Double)]=[]
        for word in words where word.due <= now {
            let stage=min(3,max(0,word.stage))
            let learning=Double(3-stage)
            let weight:Double=1+word.priority(at:now)+learning
            let draw=Double.random(in:0..<1,using:&generator)
            ranked.append((word,-log(1-draw)/weight))
        }
        ranked.sort {a,b in
            if a.key == b.key {return a.word.id < b.word.id}
            return a.key < b.key
        }
        var selected=ranked.prefix(limit).map{$0.word}
        // Small eligible pools can otherwise repeat the exact previous order.
        if selected.count > 1,selected.map(\.id) == previous {
            selected.swapAt(0,Int.random(in:1..<selected.count,using:&generator))
        }
        return selected
    }
}
