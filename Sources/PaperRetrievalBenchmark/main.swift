import Foundation
import PDFKit
import PaperCore

@main struct PaperRetrievalBenchmark {
    struct Input:Decodable {var id:String;var title:String;var path:String;var kind:String;var digest:String?}
    static func main() async {
        let args=CommandLine.arguments
        func arg(_ key:String)->String? {guard let i=args.firstIndex(of:key),args.indices.contains(i+1) else{return nil};return args[i+1]}
        guard let input=arg("--input") else{print("--input corpus JSON required");exit(2)}
        let work=URL(fileURLWithPath:arg("--work") ?? ".test-output/v021-retrieval")
        let client=ResearchClient(port:Int(arg("--port") ?? "11434") ?? 11434)
        do {
            try FileManager.default.createDirectory(at:work,withIntermediateDirectories:true)
            let db=try Database(url:work.appendingPathComponent("retrieval.sqlite"))
            let inputs=try JSONDecoder().decode([Input].self,from:Data(contentsOf:URL(fileURLWithPath:input)))
            var oldChunks:[PaperTextChunk]=[];var omni="";var fire=""
            for source in inputs {
                let pages:[String]
                if source.kind == "PDF",let doc=PDFDocument(url:URL(fileURLWithPath:source.path)){pages=(0..<doc.pageCount).map{doc.page(at:$0)?.string ?? ""}}
                else {pages=[try String(contentsOfFile:source.path,encoding:.utf8)]}
                if source.title.contains("OmniVoice"){omni=source.id}
                if source.title.contains("FireRedTTS3"){fire=source.id}
                if !(try db.papers()).contains(where:{$0.id == source.id}){try db.addPaper(Paper(id:source.id,title:source.title,filename:"source",kind:source.kind))}
                try db.replaceChunks(paperID:source.id,chunks:ResearchStructure.chunks(paperID:source.id,pages:pages))
                if let path=source.digest {
                    var digest=try JSONDecoder().decode(PaperDigest.self,from:Data(contentsOf:URL(fileURLWithPath:path)))
                    digest.paperID=source.id;digest.id=UUID().uuidString
                    try db.saveDigest(digest)
                }
                oldChunks+=legacy(paperID:source.id,pages:pages)
            }
            let controls=[("control-db","Synthetic diagnostic: Database retrieval","A relational database joins tables using indexes. Transactions maintain consistent writes and rollback changes after failure. This is a synthetic diagnostic passage, not a published paper."),
                          ("control-image","Synthetic diagnostic: Image classification","A convolutional neural network predicts image categories from photographs and pixel features. Its visual filters detect edges and textures. This is a synthetic diagnostic passage, not a published paper.")]
            for (id,title,text) in controls {
                if !(try db.papers()).contains(where:{$0.id == id}){try db.addPaper(Paper(id:id,title:title,filename:"control.txt",kind:"WEB"))}
                var record=PaperRecord(paperID:id);record.purpose=text;try db.savePaperRecord(record)
                try db.replaceChunks(paperID:id,chunks:ResearchStructure.chunks(paperID:id,pages:[text]));oldChunks+=legacy(paperID:id,pages:[text])
            }
            if !omni.isEmpty {try db.saveNote(PaperNote(id:"diagnostic-note",paperID:omni,title:"验收笔记：下一步实验",body:"这是合成验收笔记，不是用户真实记录。我计划比较16步和32步语音合成的首段等待，并记录长句音色一致性。"))}
            let oldModel="legacy-raw";let model=ResearchModels.embedding+"|"+ResearchStructure.indexVersion
            let indexStarted=Date();let pending=try db.passages().filter{$0.semanticEligible && ($0.vectorModel != model || $0.vector.isEmpty)}
            for offset in stride(from:0,to:pending.count,by:8) {
                var batch=Array(pending[offset..<min(offset+8,pending.count)])
                let vectors=try await client.embeddings(batch.map(\.embeddingInput))
                for i in batch.indices{batch[i].vector=vectors[i]}
                try db.savePassageVectors(batch,model:model)
            }
            let indexSeconds=Date().timeIntervalSince(indexStarted)
            for offset in stride(from:0,to:oldChunks.count,by:4) {
                let end=min(offset+4,oldChunks.count);let vectors=try await client.embeddings(Array(oldChunks[offset..<end]).map(\.text))
                for (i,vector) in vectors.enumerated(){oldChunks[offset+i].vector=vector;oldChunks[offset+i].vectorModel=oldModel}
            }
            var cases:[(String,String)]=[("如何对数据库表做索引连接并保持事务一致性？","control-db"),("image classification with convolutional networks","control-image"),("量子纠错表面码需要多少物理量子比特？",""),("CRISPR基因编辑如何作用于干细胞？","")]
            if !omni.isEmpty {cases += [("扩散语言模型支持多语言零样本语音合成",omni),("LibriSpeech WER 1.30 语音合成",omni),("我计划比较16步和32步发音的首段等待",omni)]}
            if !fire.isEmpty {cases.append(("统一的语音生成与语音编辑模型",fire))}
            let units=try db.passages();var results:[[String:Any]]=[]
            for (query,expected) in cases {
                let started=Date();let vector=try await client.embeddings([query],query:true)[0]
                let old=ResearchText.semanticHits(query:vector,chunks:oldChunks,model:oldModel)
                let lexical=try db.lexicalPassages(query)
                let candidates=ResearchRetrieval.candidates(query:vector,units:units,model:model,lexical:lexical)
                let scores=try await client.rerank(query:query,documents:candidates.map(\.passage.embeddingInput),port:Int(arg("--rerank-port") ?? "8766") ?? 8766)
                let hits=ResearchRetrieval.hits(candidates:candidates,relevance:scores,query:query)
                let correct=expected.isEmpty ? hits.isEmpty:hits.first?.paperID == expected
                let row:[String:Any]=["query":query,"expected":expected.isEmpty ? "no relevant result":expected,"baseline_top":old.first?.paperID ?? "none","baseline_results":old.count,"new_top":hits.first?.paperID ?? "none","new_results":hits.count,"new_page":hits.first?.page.map{$0+1} ?? 0,"new_source":hits.first?.source ?? "none","matching_passages":hits.first?.matches.count ?? 0,"correct":correct,"seconds":Date().timeIntervalSince(started),"candidate_scores":scores]
                results.append(row);print("\(correct ? "PASS":"FAIL") \(query) -> \(hits.first?.paperID ?? "none")");fflush(stdout)
            }
            let vectorBytes=try JSONEncoder().encode(units.map(\.vector)).count
            let oldVectorBytes=try JSONEncoder().encode(oldChunks.map(\.vector)).count
            let report:[String:Any]=["passed":results.allSatisfy{$0["correct"] as? Bool == true} && units.count == inputs.count+controls.count,"scope":"Small hand-selected diagnostic: two real local papers (one saved AI overview, one title-only fallback), two synthetic metadata controls, one synthetic note; not a statistical benchmark","real_documents":inputs.count,"saved_real_overviews":inputs.filter{$0.digest != nil}.count,"control_documents":controls.count,"paper_indexes":units.count,"newly_embedded_papers":pending.count,"legacy_page_chunks":oldChunks.count,"vector_json_bytes":vectorBytes,"legacy_vector_json_bytes":oldVectorBytes,"index_seconds":indexSeconds,"cases":results]
            let data=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]);try data.write(to:work.appendingPathComponent("verification.json"));print(String(decoding:data,as:UTF8.self))
        }catch{print("FAILED: \(error.localizedDescription)");exit(1)}
        await client.unload(ResearchModels.embedding)
    }
    static func legacy(paperID:String,pages:[String])->[PaperTextChunk] {
        var result:[PaperTextChunk]=[]
        for (page,text) in pages.enumerated() {
            let chars=Array(TextTools.clean(text));var offset=0;var ordinal=0
            while offset<chars.count {
                let end=min(offset+3200,chars.count)
                result.append(PaperTextChunk(paperID:paperID,page:page,ordinal:ordinal,text:String(chars[offset..<end])))
                if end == chars.count {break};offset+=3040;ordinal+=1
            }
        }
        return result
    }
}
