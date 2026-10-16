import Foundation
import PaperCore

@main struct PaperRetrievalBenchmark {
    struct Input: Decodable { var id: String; var title: String; var digest: String? }
    static func main() async {
        let args = CommandLine.arguments
        func arg(_ key: String) -> String? { guard let i = args.firstIndex(of: key), args.indices.contains(i + 1) else { return nil }; return args[i + 1] }
        guard let input = arg("--input") else { print("--input corpus JSON required"); exit(2) }
        let work = URL(fileURLWithPath: arg("--work") ?? ".test-output/v022-retrieval")
        let client = ResearchClient(port: Int(arg("--port") ?? "11434") ?? 11434)
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let db = try Database(url: work.appendingPathComponent("retrieval.sqlite"))
            let inputs = try JSONDecoder().decode([Input].self, from: Data(contentsOf: URL(fileURLWithPath: input)))
            for source in inputs {
                if !(try db.papers()).contains(where: { $0.id == source.id }) { try db.addPaper(Paper(id: source.id, title: source.title, filename: "source.pdf", kind: "PDF")) }
                if let path = source.digest {
                    var digest = try JSONDecoder().decode(PaperDigest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
                    guard PaperSummary.isCurrent(digest) else { throw ResearchError.message("Diagnostic requires a current first-three-page summary") }
                    digest.paperID = source.id; digest.id = UUID().uuidString
                    try db.saveDigest(digest)
                }
            }
            let signature = ResearchModels.embedding + "|" + PaperSummary.indexVersion
            var units = try db.passages()
            let vectors = try await client.embeddings(units.map(\.embeddingInput))
            for i in units.indices { units[i].vector = vectors[i] }
            try db.savePassageVectors(units, model: signature); units = try db.passages()
            let expectedID = inputs.first { $0.digest != nil }?.id ?? ""
            let cases: [(String, String)] = [("扩散语言模型支持多语言零样本语音合成", expectedID), ("diffusion language model for zero-shot multilingual speech synthesis", expectedID), ("量子纠错表面码需要多少物理量子比特？", ""), ("CRISPR 基因编辑如何作用于干细胞？", "")]
            var results: [[String: Any]] = []
            for (query, expected) in cases {
                let vector = try await client.embeddings([query], query: true)[0]
                let candidates = ResearchRetrieval.candidates(query: vector, units: units, model: signature, lexical: try db.lexicalPassages(query))
                let scores = try await client.rerank(query: query, documents: candidates.map(\.passage.embeddingInput), port: Int(arg("--rerank-port") ?? "8766") ?? 8766)
                let hits = ResearchRetrieval.hits(candidates: candidates, relevance: scores, query: query)
                let correct = expected.isEmpty ? hits.isEmpty : hits.first?.paperID == expected
                results.append(["query": query, "expected": expected, "actual": hits.first?.paperID ?? "", "correct": correct, "relevance": scores])
                print("\(correct ? "PASS" : "FAIL") \(query)"); fflush(stdout)
            }
            let report: [String: Any] = ["passed": results.allSatisfy { $0["correct"] as? Bool == true } && units.count == inputs.filter { $0.digest != nil }.count,
                "scope": "Small diagnostic using a real first-three-page Chinese summary; papers without summaries have no vectors; no PDF text is loaded by this index benchmark",
                "paper_indexes": units.count, "papers_without_summary": inputs.filter { $0.digest == nil }.count, "cases": results]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: work.appendingPathComponent("verification.json")); print(String(decoding: data, as: UTF8.self))
        } catch { print("FAILED: \(error.localizedDescription)"); exit(1) }
        await client.unload(ResearchModels.embedding)
    }
}
