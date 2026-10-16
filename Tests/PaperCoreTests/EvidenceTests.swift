import Foundation
import PaperCore
import CSQLite

final class EvidenceTests {
    func fixture()->ResearchLedger {
        let context=ResearchEvidence(paperID:"p",page:1,section:"Experimental setup",kind:.narrative,text:"We evaluate on Benchmark-X with an H20 GPU and batch size 1. All baselines use the same evaluation protocol.")
        var table=ResearchEvidence(paperID:"p",page:2,section:"Results",label:"Table 1: Evaluation on Benchmark-X",kind:.experiment,text:"Table 1: Evaluation on Benchmark-X\nMethod WER RTF\nBaseline 2.50 0.0557\nProposed 1.30 0.0319")
        table.contextIDs=[context.id]
        return ResearchLedger(paperID:"p",sourceHash:"h",totalPages:3,evidence:[context,table],model:"test")
    }
    func draft(value:String="1.30",condition:String="H20 GPU") throws->StructuredDraft {
        let json:[String:Any]=["bibliography":["title":"","authors":[],"year":"","venue":"","doi":"","arxiv":""],"facts":[],"experiments":[["source":"E1","dataset":"Benchmark-X","task":"","metrics":["WER"],"conditions":"H20 GPU","limitations":"unknown invented limitation","rows":[["method":"Proposed","metric":"WER","value":value,"condition":condition,"source":"E1","quote":"Proposed 1.30 0.0319"]]]]]
        return try JSONDecoder().decode(StructuredDraft.self,from:JSONSerialization.data(withJSONObject:json))
    }
    func testSourceInventoryAndReferenceExclusion() {
        let pages=["1 Introduction\nWe propose a local system.\nTable 4. We observe that this is a reference to a result, not a caption.\n3 Experimental Setup\nWe use an H20 GPU and batch size 1.\nTable 1: Evaluation results on Benchmark-X.\nMethod WER\nBaseline 2.50\nProposed 1.30\nTable 2: Supported languages and training data.\nEnglish en 206061.1\nReferences\nSomeone. A cited paper about evaluation.\nA Limitations\nThe evaluation covers only a small dataset, so broader conclusions require further tests."]
        let sources=ResearchStructure.sources(paperID:"p",pages:pages)
        XCTAssertEqual(sources.filter{$0.kind == .experiment}.count,1)
        XCTAssertEqual(sources.filter{$0.kind == .dataProfile}.count,1)
        XCTAssertTrue(sources.contains{$0.kind == .references})
        XCTAssertTrue(sources.contains{$0.kind == .narrative && $0.section == "A Limitations"})
        let ledger=ResearchLedger(paperID:"p",sourceHash:"x",totalPages:1,evidence:sources,model:"m")
        let planned=ResearchStructure.plan(ledger).flatMap{$0}
        XCTAssertTrue(!planned.contains{$0.kind == .references || $0.kind == .dataProfile})
        XCTAssertTrue(planned.contains{$0.text.contains("H20 GPU")})
        let bare=ResearchStructure.sources(paperID:"bare",pages:["Table 11."])
        XCTAssertEqual(bare.count,1)
        XCTAssertEqual(bare[0].kind,.narrative)
        XCTAssertEqual(bare[0].text,"Table 11.")
    }
    func testFieldGroundingRejectsInventedNumbersAndConditions() throws {
        let ledger=fixture()
        let valid=try draft().applying(to:ledger,sources:ledger.evidence)
        XCTAssertEqual(valid.experiments.first?.measurements.first?.value,"1.30")
        XCTAssertEqual(valid.experiments.first?.conditions,"H20 GPU")
        XCTAssertEqual(valid.experiments.first?.limitations,"")
        XCTAssertTrue(valid.experiments[0].rejectedFields>0)
        let forged=try draft(value:"0.13").applying(to:ledger,sources:ledger.evidence)
        XCTAssertTrue(forged.experiments[0].measurements.isEmpty)
        let wrongContext=try draft(condition:"A100 GPU").applying(to:ledger,sources:ledger.evidence)
        XCTAssertEqual(wrongContext.experiments[0].measurements.first?.value,"1.30")
        XCTAssertEqual(wrongContext.experiments[0].measurements.first?.condition,"")
        XCTAssertEqual(forged.evidence,ledger.evidence)
    }
    func testLedgerPersistenceReviewAndCache() throws {
        let (db,dir)=try PaperCoreTests().database();defer{try? FileManager.default.removeItem(at:dir)}
        let paper=Paper(id:"p",title:"Paper",filename:"paper.pdf",kind:"PDF");try db.addPaper(paper)
        let ledger=fixture();try db.saveLedger(ledger)
        let review=ExperimentReview(paperID:"p",experimentID:ledger.experiments[0].id,reviewed:true,annotation:"Check the denominator")
        try db.saveExperimentReview(review)
        let note=PaperNote(paperID:"p",body:"My independent thought");try db.saveNote(note)
        let extracted=try draft().applying(to:ledger,sources:ledger.evidence);try db.saveLedger(extracted)
        try db.cacheStructured(draft(),key:"key",paperID:"p")
        XCTAssertEqual(try db.ledgers()["p"]?.experiments[0].measurements[0].value,"1.30")
        XCTAssertEqual(try db.experimentReviews()[review.experimentID],review)
        XCTAssertEqual(try db.notes(paperID:"p").first?.body,note.body)
        XCTAssertTrue(try db.cachedStructured("key") != nil)
        let markdown=try db.exportPaperMarkdown(paper)
        XCTAssertTrue(markdown.contains("1.30"));XCTAssertTrue(markdown.contains("结构化实验记录"));XCTAssertTrue(markdown.contains("已核对"))
        try db.deletePaper("p")
        XCTAssertTrue(try db.ledgers().isEmpty);XCTAssertTrue(try db.passages().isEmpty);XCTAssertTrue(try db.experimentReviews().isEmpty)
    }
    func testPassageVectorsInvalidateOnlyChangedInputs() throws {
        let (db,dir)=try PaperCoreTests().database();defer{try? FileManager.default.removeItem(at:dir)}
        let p=Paper(id:"p",title:"Speech methods",filename:"p.pdf",kind:"PDF");try db.addPaper(p)
        let chunks=ResearchStructure.chunks(paperID:"p",pages:["1 Methods\nWe synthesize English speech incrementally to reduce first audio latency while preserving pronunciation."])
        try db.replaceChunks(paperID:"p",chunks:chunks)
        var note=PaperNote(paperID:"p",body:"first thought");try db.saveNote(note)
        var units=try db.passages();for i in units.indices{units[i].vector=[1,0]};try db.savePassageVectors(units,model:"v3")
        XCTAssertEqual(try db.passages().count,1)
        XCTAssertTrue(try db.passages()[0].page == nil)
        XCTAssertTrue(try !db.passages()[0].text.contains("preserving pronunciation"))
        let oldID=try db.passages()[0].id
        try db.saveLedger(fixture())
        XCTAssertEqual(try db.passages()[0].id,oldID)
        XCTAssertEqual(try db.passages()[0].vector,[1,0])
        note.body="second independent thought";try db.saveNote(note)
        XCTAssertEqual(try db.passages().count,1)
        XCTAssertTrue(try db.passages()[0].vector.isEmpty)
        XCTAssertTrue(try db.passages()[0].id != oldID)
        XCTAssertTrue(try db.passages()[0].text.contains(note.body))
        try db.savePaperRecord(PaperRecord(paperID:"p"),title:"Renamed paper")
        XCTAssertTrue(try db.passages().allSatisfy{$0.vector.isEmpty})
    }
    func testHybridRetrievalThresholdsAndEvidenceGrouping() {
        var units=(0..<3).map{i in ResearchPassage(paperID:i<2 ? "a":"b",source:"正文",sourceID:"\(i)",title:"Paper",section:"Results",page:i,text:"WER and streaming latency evidence \(i)")}
        for i in units.indices{units[i].vector=i<2 ? [1,0]:[0,1];units[i].vectorModel="v3"}
        var reference=ResearchPassage(paperID:"ref",source:"正文",sourceID:"ref",title:"Cited title",section:"References",page:0,text:"Streaming speech",semanticEligible:false);reference.vector=[1,0];reference.vectorModel="v3";units.append(reference)
        let candidates=ResearchRetrieval.candidates(query:[1,0],units:units,model:"v3",lexical:[reference.id])
        XCTAssertEqual(candidates.count,1)
        let hits=ResearchRetrieval.hits(candidates:candidates,relevance:[0.9],query:"latency")
        XCTAssertEqual(hits.count,1);XCTAssertEqual(hits[0].matches.count,1)
        XCTAssertTrue(ResearchRetrieval.hits(candidates:candidates,relevance:[0.02],query:"unrelated").isEmpty)
        XCTAssertTrue(ResearchRetrieval.hits(candidates:candidates,relevance:[0.99],query:"WER 1.30").isEmpty)
        XCTAssertTrue(ResearchRetrieval.candidates(query:[1,0],units:units,model:"old",lexical:[]).isEmpty)
        XCTAssertTrue(ResearchRetrieval.excerpt(String(repeating:"Intro. ",count:200)+"Important latency evidence.",query:"latency").contains("Important latency"))
    }
    func testV2UpgradeKeepsNotesAndCreatesConsistentBackup() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);let url=root.appendingPathComponent("library.sqlite")
        do {let db=try Database(url:url);try db.addPaper(Paper(id:"p",title:"Old",filename:"p.pdf",kind:"PDF"));try db.saveNote(PaperNote(paperID:"p",body:"Existing note"))}
        var pointer:OpaquePointer?;sqlite3_open(url.path,&pointer)
        sqlite3_exec(pointer,"PRAGMA user_version=2; UPDATE research_index_meta SET value='legacy-page-index' WHERE key='version';",nil,nil,nil);sqlite3_close(pointer)
        let upgraded=try Database(url:url)
        XCTAssertTrue(upgraded.migrationBackupURL != nil);XCTAssertEqual(try upgraded.notes(paperID:"p").first?.body,"Existing note")
        XCTAssertTrue(try upgraded.ledgers().isEmpty)
        XCTAssertEqual(try upgraded.passages().count,1)
    }
    func testTruncatedRecordsRecoverAndLineNumbersUseOriginalText() throws {
        let experiment:[String:Any]=["source":"E1","dataset":"Benchmark-X","task":"","metrics":["WER"],"conditions":"H20 GPU","limitations":"","rows":[["method":"Proposed","metric":"WER","value":"1.30","condition":"H20 GPU","line":3]]]
        let text=String(decoding:try JSONSerialization.data(withJSONObject:experiment),as:UTF8.self)
        let broken="{\"facts\":[],\"experiments\":["+text+",{\"source\":\"E1\",\"dataset\":\"unfinished"
        guard let recovered=StructuredDraft.recover(broken) else{fail("Completed experiment was discarded after truncation");return}
        XCTAssertTrue(recovered.truncated == true);XCTAssertEqual(recovered.experiments.count,1)
        let ledger=fixture();let applied=recovered.applying(to:ledger,sources:ledger.evidence)
        XCTAssertEqual(applied.experiments[0].measurements.first?.quote,"Proposed 1.30 0.0319")
        XCTAssertEqual(applied.experiments[0].measurements.first?.value,"1.30")
        XCTAssertTrue(ResearchNumbers.cell(for:"0.30",in:"Method -0.30±0.16") == nil)
        XCTAssertTrue(ResearchNumbers.cell(for:"1.30",in:"Method 11.30") == nil)
        XCTAssertEqual(ResearchNumbers.cell(for:"-0.30",in:"Method -0.30±0.16"),"-0.30±0.16")
        XCTAssertEqual(ResearchNumbers.condition("Batch Size 1",in:"We use a batch size of 1.",row:"16 0.0319"),"batch size of 1")
    }
    func testLongEvidencePlansBoundEveryBatchAndKeepEveryExperiment() {
        let contexts=(0..<5).map{ResearchEvidence(paperID:"long",page:$0,section:"Experimental setup",kind:.narrative,text:"Setup \($0). "+String(repeating:"source context ",count:100))}
        let tables=(0..<20).map{i -> ResearchEvidence in
            var e=ResearchEvidence(paperID:"long",page:i+5,section:"Results",label:"Table \(i+1): Results",kind:.experiment,text:"Table \(i+1): Results\n"+String(repeating:"method 1.30 0.0319 ",count:250))
            e.contextIDs=contexts.map(\.id);return e
        }
        let ledger=ResearchLedger(paperID:"long",sourceHash:"x",totalPages:25,evidence:contexts+tables,model:"m")
        let plan=ResearchStructure.plan(ledger)
        XCTAssertTrue(plan.allSatisfy{$0.reduce(0){$0+$1.text.count}<=24000})
        XCTAssertEqual(Set(plan.flatMap{$0}.filter{$0.kind == .experiment}.map(\.id)),Set(tables.map(\.id)))
    }
}
