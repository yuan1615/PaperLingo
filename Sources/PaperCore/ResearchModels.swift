import CryptoKit
import Foundation

public enum ReadingStatus: String, CaseIterable, Codable, Sendable {
    case inbox = "待阅读"
    case reading = "阅读中"
    case read = "已读"
    case archived = "已归档"
}

public struct PaperRecord: Codable, Equatable, Sendable {
    public var paperID: String
    public var authors = ""
    public var year = ""
    public var venue = ""
    public var doi = ""
    public var arxiv = ""
    public var category = "未分类"
    public var tags: [String] = []
    public var status: ReadingStatus = .inbox
    public var favorite = false
    public var purpose = ""
    public var lastOpened: Date?
    public var completed: Date?
    public init(paperID: String) { self.paperID = paperID }
    public var searchable: String {
        [authors, year, venue, doi, arxiv, category, tags.joined(separator: " "), status.rawValue, purpose].joined(
            separator: " ")
    }
}

public enum NoteKind: String, CaseIterable, Codable, Sendable {
    case thought = "想法"
    case question = "疑问"
    case todo = "待办"
    case reproduction = "复现记录"
}

public struct PaperNote: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var paperID: String
    public var title: String
    public var body: String
    public var kind: NoteKind
    public var quote: String
    public var page: Int?
    public var created: Date
    public var updated: Date
    public init(
        id: String = UUID().uuidString, paperID: String, title: String = "", body: String = "",
        kind: NoteKind = .thought, quote: String = "", page: Int? = nil, created: Date = Date(), updated: Date = Date()
    ) {
        self.id = id
        self.paperID = paperID
        self.title = title
        self.body = body
        self.kind = kind
        self.quote = quote
        self.page = page
        self.created = created
        self.updated = updated
    }
}

public struct PaperTextChunk: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var paperID: String
    public var page: Int
    public var ordinal: Int
    public var text: String
    public var vector: [Float]
    public var vectorModel: String
    public init(paperID: String, page: Int, ordinal: Int, text: String, vector: [Float] = [], vectorModel: String = "")
    {
        self.paperID = paperID
        self.page = page
        self.ordinal = ordinal
        self.text = text
        self.vector = vector
        self.vectorModel = vectorModel
        self.id = ResearchText.hash("\(paperID):\(page):\(ordinal):\(text)")
    }
}

public enum DigestTopic: String, CaseIterable, Codable, Sendable {
    case problem, method, contribution, results, limitations, reuse
    public var title: String {
        switch self {
        case .problem: return "研究问题"
        case .method: return "核心方法"
        case .contribution: return "主要贡献"
        case .results: return "实验与结论"
        case .limitations: return "局限与未解决问题"
        case .reuse: return "可借鉴之处 · AI 提示"
        }
    }
}

public struct DigestPoint: Identifiable, Codable, Equatable, Sendable {
    public var id: String { ResearchText.hash(topic.rawValue + text + chunkID) }
    public var topic: DigestTopic
    public var text: String
    public var chunkID: String
    public var quote: String
    public var page: Int
}

public struct PaperDigest: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID().uuidString
    public var paperID: String
    public var model: String
    public var created = Date()
    public var sourceHash: String
    public var processedPages: Int
    public var totalPages: Int
    public var oneLine: String
    public var suggestedTitle: String
    public var suggestedAuthors: [String]
    public var suggestedYear: String
    public var suggestedVenue: String
    public var suggestedDOI: String
    public var suggestedArxiv: String
    public var suggestedCategory: String
    public var suggestedTags: [String]
    public var points: [DigestPoint]
    public var rejectedEvidence: Int
    public var isPartial: Bool? = nil
}

public struct DigestDraft: Codable, Sendable {
    public struct Point: Codable, Sendable {
        public var topic: DigestTopic
        public var text: String
        public var chunkID: String
        public var quote: String
    }
    public var title: String
    public var authors: [String]
    public var year: String
    public var venue: String
    public var doi: String
    public var arxiv: String
    public var category: String
    public var tags: [String]
    public var oneLine: String
    public var points: [Point]
    public func grounded(
        in chunks: [PaperTextChunk], paperID: String, model: String, sourceHash: String, totalPages: Int
    ) -> PaperDigest {
        let lookup = Dictionary(chunks.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        var rejected = 0
        let accepted = points.prefix(24).compactMap { point -> DigestPoint? in
            let quote = TextTools.clean(point.quote)
            guard let chunk = lookup[point.chunkID], quote.count >= 18, quote.count <= 800,
                TextTools.clean(chunk.text).range(of: quote, options: [.caseInsensitive, .diacriticInsensitive]) != nil,
                !point.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                rejected += 1
                return nil
            }
            return DigestPoint(
                topic: point.topic, text: String(point.text.prefix(1200)), chunkID: chunk.id, quote: quote,
                page: chunk.page)
        }
        return PaperDigest(
            paperID: paperID, model: model, sourceHash: sourceHash, processedPages: Set(chunks.map(\.page)).count,
            totalPages: totalPages, oneLine: String(oneLine.prefix(500)), suggestedTitle: String(title.prefix(500)),
            suggestedAuthors: Array(authors.prefix(30)), suggestedYear: String(year.prefix(8)),
            suggestedVenue: String(venue.prefix(200)), suggestedDOI: String(doi.prefix(200)),
            suggestedArxiv: String(arxiv.prefix(100)), suggestedCategory: String(category.prefix(80)),
            suggestedTags: Array(tags.prefix(12)), points: accepted, rejectedEvidence: rejected)
    }
}

public struct ResearchSearchHit: Identifiable, Sendable {
    public var id: String { paperID }
    public var paperID: String
    public var score: Double
    public var snippet: String
    public var page: Int?
    public var source: String
    public init(paperID: String, score: Double = 0, snippet: String = "", page: Int? = nil, source: String = "关键词") {
        self.paperID = paperID
        self.score = score
        self.snippet = snippet
        self.page = page
        self.source = source
    }
}

public struct PaperTextStatus: Codable, Equatable, Sendable {
    public var paperID: String
    public var sourceHash: String
    public var totalPages: Int
    public var textPages: Int
    public var chunkCount: Int
    public var created: Date
    public init(
        paperID: String, sourceHash: String, totalPages: Int, textPages: Int, chunkCount: Int, created: Date = Date()
    ) {
        self.paperID = paperID
        self.sourceHash = sourceHash
        self.totalPages = totalPages
        self.textPages = textPages
        self.chunkCount = chunkCount
        self.created = created
    }
}

public enum ResearchText {
    public static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public static func chunks(paperID: String, pages: [String], size: Int = 3200, overlap: Int = 160)
        -> [PaperTextChunk]
    {
        let width = max(100, size)
        let stride = max(1, max(100, size) - max(0, overlap))
        var result: [PaperTextChunk] = []
        for (page, text) in pages.enumerated() {
            let chars = Array(TextTools.clean(text))
            var offset = 0
            var ordinal = 0
            while offset < chars.count {
                let end = min(chars.count, offset + width)
                let content = String(chars[offset..<end])
                if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append(PaperTextChunk(paperID: paperID, page: page, ordinal: ordinal, text: content))
                }
                if end == chars.count { break }
                offset += stride
                ordinal += 1
            }
        }
        return result
    }
    public static func cosine(_ a: [Float], _ b: [Float]) -> Double? {
        guard !a.isEmpty, a.count == b.count else { return nil }
        var dot = 0.0
        var aa = 0.0
        var bb = 0.0
        for (x, y) in zip(a, b) {
            guard x.isFinite, y.isFinite else { return nil }
            dot += Double(x) * Double(y)
            aa += Double(x) * Double(x)
            bb += Double(y) * Double(y)
        }
        guard aa > 0, bb > 0 else { return nil }
        return dot / sqrt(aa * bb)
    }
    public static func semanticHits(query: [Float], chunks: [PaperTextChunk], model: String, limit: Int = 30)
        -> [ResearchSearchHit]
    {
        var best: [String: ResearchSearchHit] = [:]
        for chunk in chunks where chunk.vectorModel == model {
            guard let score = cosine(query, chunk.vector) else { continue }
            if best[chunk.paperID].map({ $0.score >= score }) == true { continue }
            best[chunk.paperID] = ResearchSearchHit(
                paperID: chunk.paperID, score: score, snippet: String(chunk.text.prefix(360)), page: chunk.page,
                source: "语义 · 原文")
        }
        return Array(best.values.sorted { $0.score > $1.score }.prefix(max(0, limit)))
    }
    public static func tags(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.components(separatedBy: CharacterSet(charactersIn: ",，;；\n")).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }.map { String($0.prefix(80)) }
    }
}
