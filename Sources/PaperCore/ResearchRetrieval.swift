import Foundation
import CSQLite

public struct ResearchPassage: Codable,Equatable,Identifiable,Sendable {
    public var id:String
    public var paperID:String
    public var source:String
    public var sourceID:String
    public var title:String
    public var section:String
    public var page:Int?
    public var text:String
    public var vector:[Float]=[]
    public var vectorModel:String=""
    public var semanticEligible:Bool
    public var embeddingInput:String {"Title: \(title)\nSection: \(section)\n\(text)"}
    public init(paperID:String,source:String,sourceID:String,title:String,section:String,page:Int?,text:String,semanticEligible:Bool=true) {
        self.paperID=paperID;self.source=source;self.sourceID=sourceID;self.title=title;self.section=section;self.page=page;self.text=text;self.semanticEligible=semanticEligible
        id=ResearchText.hash(ResearchStructure.indexVersion+paperID+source+sourceID+title+section+text)
    }
}

public struct ResearchMatch: Identifiable,Sendable {
    public var id:String
    public var snippet:String
    public var page:Int?
    public var source:String
    public var section:String
}

public struct RetrievalCandidate:Sendable {
    public var passage:ResearchPassage
    public var score:Double
    public var similarity:Double
}

public enum ResearchRetrieval {
    public static func candidates(query:[Float],units:[ResearchPassage],model:String,lexical:[String],limit:Int=24)->[RetrievalCandidate] {
        let semantic=units.filter{$0.semanticEligible && $0.vectorModel == model}.compactMap {unit -> RetrievalCandidate? in
            guard let similarity=ResearchText.cosine(query,unit.vector),similarity >= 0.30 else{return nil}
            return RetrievalCandidate(passage:unit,score:0,similarity:similarity)
        }.sorted{$0.similarity > $1.similarity}.prefix(80)
        var scores:[String:RetrievalCandidate]=[:]
        for (rank,var item) in semantic.enumerated() {item.score=1/Double(30+rank);scores[item.passage.id]=item}
        let lookup=Dictionary(uniqueKeysWithValues:units.map{($0.id,$0)})
        for (rank,id) in lexical.prefix(50).enumerated() {
            guard lookup[id]?.semanticEligible == true else{continue}
            if var item=scores[id] {item.score+=1/Double(30+rank);scores[id]=item}
            else if let unit=lookup[id] {scores[id]=RetrievalCandidate(passage:unit,score:1/Double(30+rank),similarity:0)}
        }
        // One summary card and one vector per paper, independent of page count.
        var perPaper:[String:Int]=[:]
        return scores.values.sorted{$0.score > $1.score}.filter {item in
            let count=perPaper[item.passage.paperID,default:0]
            guard count < 1 else{return false}
            perPaper[item.passage.paperID]=count+1;return true
        }.prefix(max(0,limit)).map{$0}
    }
    public static func hits(candidates:[RetrievalCandidate],relevance:[Double]?,query:String,threshold:Double=0.50,limit:Int=30)->[ResearchSearchHit] {
        guard relevance == nil || relevance?.count == candidates.count else{return []}
        let best=relevance?.filter(\.isFinite).max() ?? 0
        let cutoff=relevance == nil ? 0.48:max(threshold,best-0.15)
        let numericPattern="(?<![A-Za-z0-9.])[+-]?[0-9]+\\.[0-9]+(?:%|[eE][+-]?[0-9]+)?"
        let numbers=(try? NSRegularExpression(pattern:numericPattern))?.matches(in:query,range:NSRange(query.startIndex...,in:query)).compactMap{Range($0.range,in:query).map{String(query[$0])}} ?? []
        var grouped:[String:[(ResearchPassage,Double)]]=[:]
        for (i,item) in candidates.enumerated() {
            let score=relevance?[i] ?? item.similarity
            guard score.isFinite,score >= cutoff,numbers.allSatisfy({ResearchNumbers.cell(for:$0,in:item.passage.embeddingInput) != nil}) else{continue}
            grouped[item.passage.paperID,default:[]].append((item.passage,score))
        }
        return grouped.map {id,values in
            let ranked=values.sorted{$0.1 > $1.1};let best=ranked[0]
            var hit=ResearchSearchHit(paperID:id,score:best.1+min(0.03,Double(ranked.count-1)*0.01),snippet:excerpt(best.0.text,query:query),page:best.0.page,source:best.0.source)
            hit.matches=ranked.prefix(3).map{ResearchMatch(id:$0.0.id,snippet:excerpt($0.0.text,query:query),page:$0.0.page,source:$0.0.source,section:$0.0.section)}
            return hit
        }.sorted{$0.score > $1.score}.prefix(max(0,limit)).map{$0}
    }
    public static func excerpt(_ text:String,query:String)->String {
        let clean=TextTools.clean(text)
        let tokens=query.split(whereSeparator:{$0.isWhitespace}).map(String.init).filter{$0.count>2}
        let match=clean.range(of:query,options:.caseInsensitive) ?? tokens.compactMap{clean.range(of:$0,options:.caseInsensitive)}.first
        guard let match else{return String(clean.prefix(420))}
        let start=clean.index(match.lowerBound,offsetBy:-100,limitedBy:clean.startIndex) ?? clean.startIndex
        let end=clean.index(start,offsetBy:420,limitedBy:clean.endIndex) ?? clean.endIndex
        return (start>clean.startIndex ? "…":"")+String(clean[start..<end])+(end<clean.endIndex ? "…":"")
    }
}

extension Database {
    func migrateEvidenceSchema() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS paper_ledgers(paper_id TEXT PRIMARY KEY REFERENCES papers(id) ON DELETE CASCADE,payload TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS experiment_reviews(paper_id TEXT NOT NULL REFERENCES papers(id) ON DELETE CASCADE,experiment_id TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(paper_id,experiment_id));
        CREATE TABLE IF NOT EXISTS research_cache(cache_key TEXT PRIMARY KEY,paper_id TEXT NOT NULL REFERENCES papers(id) ON DELETE CASCADE,payload TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS research_passages(id TEXT PRIMARY KEY,paper_id TEXT NOT NULL REFERENCES papers(id) ON DELETE CASCADE,payload TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS research_passages_paper ON research_passages(paper_id);
        CREATE VIRTUAL TABLE IF NOT EXISTS passage_search USING fts5(id UNINDEXED,paper_id UNINDEXED,title,section,body,tokenize='unicode61 remove_diacritics 2');
        CREATE TABLE IF NOT EXISTS research_index_meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);
        """)
    }
    public func ledgers() throws->[String:ResearchLedger] {
        try Dictionary(uniqueKeysWithValues:rows("SELECT paper_id,payload FROM paper_ledgers"){(text($0,0),text($0,1))}.map{($0.0,try decoded(ResearchLedger.self,$0.1))})
    }
    public func saveLedger(_ ledger:ResearchLedger) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try write("INSERT INTO paper_ledgers VALUES(?,?) ON CONFLICT(paper_id) DO UPDATE SET payload=excluded.payload",[ledger.paperID,try encoded(ledger)])
            try refreshPaperSearch(ledger.paperID);try exec("COMMIT")
        }catch{try? exec("ROLLBACK");throw error}
    }
    public func experimentReviews() throws->[String:ExperimentReview] {
        try Dictionary(uniqueKeysWithValues:rows("SELECT payload FROM experiment_reviews"){text($0,0)}.map{try decoded(ExperimentReview.self,$0)}.map{($0.experimentID,$0)})
    }
    public func saveExperimentReview(_ review:ExperimentReview) throws {
        try write("INSERT INTO experiment_reviews VALUES(?,?,?) ON CONFLICT(paper_id,experiment_id) DO UPDATE SET payload=excluded.payload",[review.paperID,review.experimentID,try encoded(review)])
    }
    public func cachedStructured(_ key:String) throws->StructuredDraft? {
        try rows("SELECT payload FROM research_cache WHERE cache_key=?",[key]){text($0,0)}.first.map{try decoded(StructuredDraft.self,$0)}
    }
    public func cacheStructured(_ draft:StructuredDraft,key:String,paperID:String) throws {
        try write("INSERT INTO research_cache VALUES(?,?,?) ON CONFLICT(cache_key) DO UPDATE SET payload=excluded.payload",[key,paperID,try encoded(draft)])
    }
    public func passages(paperID:String?=nil) throws->[ResearchPassage] {
        try rows("SELECT payload FROM research_passages"+(paperID == nil ? "":" WHERE paper_id=?"),paperID.map{[$0]} ?? []){text($0,0)}.map{try decoded(ResearchPassage.self,$0)}
    }
    func syncPassages(_ paper:Paper,record:PaperRecord,notes:[PaperNote],digest:PaperDigest?) throws {
        let previous=Dictionary(try passages(paperID:paper.id).map{($0.id,$0)},uniquingKeysWith:{$1})
        var sections:[String]=[]
        if let digest {
            sections += ["AI 概览："+String(digest.oneLine.prefix(250)),"分类与标签："+digest.suggestedCategory+" "+digest.suggestedTags.joined(separator:" ")]
            // Retain every research topic within a bounded paper-level card.
            for topic in DigestTopic.allCases {
                let points=digest.points.filter{$0.topic == topic}.map{String($0.text.prefix(220))}.joined(separator:" ")
                if !points.isEmpty {sections.append(topic.title+": "+String(points.prefix(topic == .results ? 700:300)))}
            }
        } else {
            sections.append("尚未生成 AI 概览，当前按标题与手工资料检索。")
        }
        sections.append("文献资料："+String(record.searchable.prefix(350)))
        // Personal prose supplements the overview. Long original quotes and tables
        // remain in the evidence ledger and are never embedded separately.
        let noteText=notes.map{[$0.title,$0.body].joined(separator:" ")}.joined(separator:"\n")
        if !noteText.isEmpty {sections.append("个人笔记："+String(noteText.prefix(650)))}
        var unit=ResearchPassage(paperID:paper.id,source:digest == nil ? "档案（待概览）":"论文概览",sourceID:paper.id,title:paper.title,section:"Paper overview and personal notes",page:nil,text:String(sections.joined(separator:"\n").prefix(3600)))
        if let old=previous[unit.id] {
            unit.vector=old.vector;unit.vectorModel=old.vectorModel
        }
        try write("DELETE FROM research_passages WHERE paper_id=?",[paper.id]);try write("DELETE FROM passage_search WHERE paper_id=?",[paper.id])
        try write("INSERT INTO research_passages VALUES(?,?,?)",[unit.id,paper.id,try encoded(unit)])
        try write("INSERT INTO passage_search VALUES(?,?,?,?,?)",[unit.id,paper.id,unit.title,unit.section,unit.text])
    }
    public func savePassageVectors(_ units:[ResearchPassage],model:String) throws {
        guard units.allSatisfy({!$0.vector.isEmpty && $0.vector.allSatisfy(\.isFinite)}) else{throw StorageError.sqlite("检索向量无效")}
        try exec("BEGIN IMMEDIATE")
        do {
            for var unit in units {unit.vectorModel=model;try write("UPDATE research_passages SET payload=? WHERE id=? AND paper_id=?",[try encoded(unit),unit.id,unit.paperID])}
            try exec("COMMIT")
        }catch{try? exec("ROLLBACK");throw error}
    }
    public func lexicalPassages(_ query:String,limit:Int=60) throws->[String] {
        let cleaned=TextTools.clean(query);guard !cleaned.isEmpty else{return []}
        let terms=cleaned.components(separatedBy:CharacterSet.alphanumerics.inverted).filter{!$0.isEmpty}.prefix(16)
        guard !terms.isEmpty else{return []}
        let expression=terms.map{"\""+$0.replacingOccurrences(of:"\"",with:"\"\"")+"\""}.joined(separator:" OR ")
        return try rows("SELECT id FROM passage_search WHERE passage_search MATCH ? ORDER BY bm25(passage_search,0,0,3,2,1) LIMIT ?",[expression,limit]){text($0,0)}
    }
}
