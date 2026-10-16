import Foundation
import PDFKit
import PaperCore

@main struct PaperResearchBenchmark {
    static func main() async {
        let args=CommandLine.arguments
        func arg(_ name:String)->String? {guard let i=args.firstIndex(of:name),args.indices.contains(i+1) else{return nil};return args[i+1]}
        guard let source=arg("--source") else {print("--source PDF required");exit(2)}
        let work=URL(fileURLWithPath:arg("--work") ?? ".test-output/v021-benchmark")
        let client=ResearchClient(port:Int(arg("--port") ?? "11434") ?? 11434)
        do {
            try FileManager.default.createDirectory(at:work,withIntermediateDirectories:true)
            let started=Date()
            guard let document=PDFDocument(url:URL(fileURLWithPath:source)) else{throw ResearchError.message("Cannot read PDF")}
            let pages=(0..<document.pageCount).map{document.page(at:$0)?.string ?? ""}
            let evidence=ResearchStructure.sources(paperID:"benchmark",pages:pages)
            let sourceHash=ResearchText.hash(pages.joined(separator:"\u{001E}"))
            var ledger=ResearchLedger(paperID:"benchmark",sourceHash:sourceHash,totalPages:pages.count,evidence:evidence,model:ResearchModels.analysis)
            let batches=ResearchStructure.plan(ledger)
            let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
            try encoder.encode(ledger).write(to:work.appendingPathComponent("sources.json"))
            print("Pages \(pages.count); sources \(evidence.count); experimental \(ledger.experiments.filter{$0.kind == .experiment}.count); data profiles \(ledger.experiments.filter{$0.kind == .dataProfile}.count); extraction calls \(batches.count)")
            for (i,batch) in batches.enumerated(){print("Batch \(i+1): \(batch.reduce(0){$0+$1.text.count}) chars; \(batch.filter{$0.kind == .experiment}.map(\.label))")}
            fflush(stdout)
            if args.contains("--plan-only"){return}
            let db=try Database(url:work.appendingPathComponent("benchmark.sqlite"))
            if try db.papers().isEmpty {try db.addPaper(Paper(id:"benchmark",title:"OmniVoice diagnostic source",filename:"source.pdf",kind:"PDF"))}
            try db.saveLedger(ledger)
            var batchTimes:[Double]=[];var cacheHits=0;var actualCalls=0
            for (i,batch) in batches.enumerated() {
                let before=Date();let key=ResearchText.hash(ResearchModels.structuredVersion+ResearchModels.analysis+batch.map(\.id).joined())
                let draft:StructuredDraft
                if !args.contains("--no-cache"),let cached=try db.cachedStructured(key){draft=cached;cacheHits+=1}
                else {draft=try await client.extract(sources:batch);actualCalls+=1;try db.cacheStructured(draft,key:key,paperID:"benchmark")}
                ledger=draft.applying(to:ledger,sources:batch);try db.saveLedger(ledger)
                batchTimes.append(Date().timeIntervalSince(before));print("Saved structured batch \(i+1): \(batchTimes.last!)s");fflush(stdout)
            }
            for attempt in 0..<2 {
                let pending=ledger.experiments.filter{$0.kind == .experiment && !$0.extracted}
                guard !pending.isEmpty else{break}
                let ids=Set(pending.flatMap(\.evidenceIDs));var retryLedger=ledger
                retryLedger.evidence=ledger.evidence.filter{ids.contains($0.id)}
                let before=Date();print("Recover remaining \(pending.count) experiments, pass \(attempt+1)");fflush(stdout)
                for sources in ResearchStructure.plan(retryLedger) {
                    let draft=try await client.extract(sources:sources);actualCalls+=1
                    ledger=draft.applying(to:ledger,sources:sources);try db.saveLedger(ledger)
                }
                batchTimes.append(Date().timeIntervalSince(before))
                if ledger.experiments.filter({$0.kind == .experiment && !$0.extracted}).count>=pending.count{break}
            }
            ledger.completed=true;try db.saveLedger(ledger)
            let summaryStarted=Date();let digest=try await client.summarize(ledger:ledger,categories:[])
            try db.saveDigest(digest)
            ledger.elapsedSeconds=Date().timeIntervalSince(started);ledger.modelCalls=actualCalls+1;try db.saveLedger(ledger)
            try encoder.encode(ledger).write(to:work.appendingPathComponent("ledger.json"))
            try encoder.encode(digest).write(to:work.appendingPathComponent("digest.json"))
            let report:[String:Any]=["passed":true,"source":"OmniVoice arXiv:2604.00688v3","pipeline":ResearchModels.structuredVersion,"pages":pages.count,"sources":evidence.count,"experiments":ledger.experiments.filter{$0.kind == .experiment}.count,"extracted_experiments":ledger.experiments.filter{$0.kind == .experiment && $0.extracted}.count,"measurement_rows":ledger.experiments.reduce(0){$0+$1.measurements.count},"rejected_fields":ledger.experiments.reduce(0){$0+$1.rejectedFields},"extraction_batches":batches.count,"actual_model_calls":ledger.modelCalls,"cache_hits":cacheHits,"batch_seconds":batchTimes,"summary_seconds":Date().timeIntervalSince(summaryStarted),"total_seconds":ledger.elapsedSeconds,"submitted_evidence":ledger.analyzedEvidenceIDs.count,"total_evidence":ledger.evidence.count]
            let data=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]);try data.write(to:work.appendingPathComponent("verification.json"));print(String(decoding:data,as:UTF8.self))
        } catch {print("FAILED: \(error.localizedDescription)");exit(1)}
        await client.unload(ResearchModels.analysis)
    }
}
