import Foundation
import PaperCore

@main struct WordExplanationSmoke {
    static func main() async {
        do {try await run()} catch {fputs("Word explanation smoke failed: \(error.localizedDescription)\n",stderr);exit(1)}
    }
    static func run() async throws {
        let args=CommandLine.arguments
        func argument(_ name:String)->String? {
            guard let index=args.firstIndex(of:name),index+1<args.count else {return nil}
            return args[index+1]
        }
        let port=argument("--port").flatMap(Int.init) ?? 11436
        guard (1...65535).contains(port) else {throw ResearchError.message("Invalid loopback port")}
        let directory=argument("--work").map{URL(fileURLWithPath:$0)} ?? URL(fileURLWithPath:".test-output/word-explanation-smoke")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let client=ResearchClient(port:port)
        let batchMode=args.contains("--batch")
        if batchMode {await client.unload(ResearchModels.analysis)}
        var examples=[
            ("novel","We propose a novel method for estimating uncertainty with fewer labeled examples."),
            ("novel","Participants read a novel and then answered questions about its main character."),
            ("in contrast to","In contrast to the baseline, our method does not require labeled examples.")]
        if let index=args.firstIndex(of:"--case"),index+1<args.count,let selected=Int(args[index+1]),examples.indices.contains(selected) {examples=[examples[selected]]}
        if args.contains("--cancel-only") {examples=[]}
        var results:[[String:Any]]=[]
        for (term,context) in examples {
            if !batchMode {await client.unload(ResearchModels.analysis)}
            let start=Date()
            do {
                let result=try await client.explainWord(WordExplanationInput(expression:term,context:context),keepAliveSeconds:batchMode ? 60:0)
                let seconds=Date().timeIntervalSince(start)
                let row:[String:Any]=["expression":term,"context":context,"seconds":seconds,"content":try JSONSerialization.jsonObject(with:JSONEncoder().encode(result)),"characters":result.meaning.count+result.inContext.count+result.usage.count]
                results.append(row);print(String(decoding:try JSONSerialization.data(withJSONObject:row,options:.sortedKeys),as:UTF8.self));fflush(stdout)
            } catch {
                await client.unload(ResearchModels.analysis)
                throw error
            }
        }
        var batch:[String:Any]=[:]
        if batchMode {
            let (data,_)=try await URLSession.shared.data(from:URL(string:"http://127.0.0.1:\(port)/api/ps")!)
            let object=try JSONSerialization.jsonObject(with:data) as? [String:Any]
            batch["residentModelsBeforeCleanup"]=(object?["models"] as? [Any])?.count ?? -1
        }
        await client.unload(ResearchModels.analysis)
        if batchMode {
            let (data,_)=try await URLSession.shared.data(from:URL(string:"http://127.0.0.1:\(port)/api/ps")!)
            let object=try JSONSerialization.jsonObject(with:data) as? [String:Any]
            batch["residentModelsAfterCleanup"]=(object?["models"] as? [Any])?.count ?? -1
            guard batch["residentModelsBeforeCleanup"] as? Int == 1,batch["residentModelsAfterCleanup"] as? Int == 0 else {throw ResearchError.message("Batch model residence or cleanup check failed")}
        }
        var cancellation:[String:Any]=[:]
        if args.contains("--cancel-only") {
            let input=try WordExplanationInput(expression:"robust",context:"A robust estimate remains stable under perturbations.")
            let pending=Task {try await client.explainWord(input)}
            let cancelAfter=args.firstIndex(of:"--cancel-after").flatMap{index in index+1<args.count ? Double(args[index+1]) : nil} ?? 2
            try await Task.sleep(for:.seconds(max(0.1,cancelAfter)))
            let start=Date();pending.cancel()
            do {_=try await pending.value;cancellation["completedBeforeCancellation"]=true}
            catch {cancellation["completedBeforeCancellation"]=false}
            await client.unload(ResearchModels.analysis)
            cancellation["cancelAndUnloadSeconds"]=Date().timeIntervalSince(start)
            let (ps,_)=try await URLSession.shared.data(from:URL(string:"http://127.0.0.1:\(port)/api/ps")!)
            let object=try JSONSerialization.jsonObject(with:ps) as? [String:Any]
            cancellation["residentModelsAfterCleanup"]=(object?["models"] as? [Any])?.count ?? -1
            print(String(decoding:try JSONSerialization.data(withJSONObject:cancellation,options:.sortedKeys),as:UTF8.self));fflush(stdout)
        }
        let report:[String:Any]=["model":ResearchModels.analysis,"promptVersion":WordExplanationPolicy.version,"maxRequestSeconds":WordExplanationPolicy.timeout,"scope":batchMode ? "Synthetic language examples, one model load reused within a batch, explicit final unload; no user database" : "Synthetic language examples, unloaded model before each request; OS file cache may remain warm; no user database","results":results,"cancellation":cancellation,"batch":batch]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("verification.json"))
    }
}
