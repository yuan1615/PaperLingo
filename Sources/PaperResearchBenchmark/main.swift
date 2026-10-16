import Foundation
import PaperCore

@main struct PaperResearchBenchmark {
    static func main() async {
        let args = CommandLine.arguments
        func arg(_ key: String) -> String? { guard let i = args.firstIndex(of: key), args.indices.contains(i + 1) else { return nil }; return args[i + 1] }
        guard let sourcePath = arg("--source") else { print("--source PDF required"); exit(2) }
        let work = URL(fileURLWithPath: arg("--work") ?? ".test-output/v022-summary")
        let client = ResearchClient(port: Int(arg("--port") ?? "11434") ?? 11434)
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let started = Date()
            let source = try PaperSummarySource.pdf(paperID: "benchmark", url: URL(fileURLWithPath: sourcePath))
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(source.status).write(to: work.appendingPathComponent("source-status.json"))
            print("Read pages: \(source.chunks.map { $0.page + 1 }); total PDF pages: \(source.status.totalPages); input characters: \(source.chunks.reduce(0) { $0 + $1.text.count })"); fflush(stdout)
            if args.contains("--plan-only") { return }
            let digest = try await client.summarizeOpening(source)
            let summarySeconds = Date().timeIntervalSince(started)
            try encoder.encode(digest).write(to: work.appendingPathComponent("digest.json"))
            await client.unload(ResearchModels.analysis)
            let db = try Database(url: work.appendingPathComponent("benchmark.sqlite"))
            if try db.papers().isEmpty { try db.addPaper(Paper(id: "benchmark", title: "Local verification paper", filename: "source.pdf", kind: "PDF")) }
            try db.saveDigest(digest)
            var unit = try db.passages()[0]
            let indexStarted = Date()
            unit.vector = try await client.embeddings([unit.embeddingInput])[0]
            try db.savePassageVectors([unit], model: PaperSummary.indexVersion)
            let report: [String: Any] = ["passed": PaperSummary.isCurrent(digest) && unit.vector.count == 1024 && source.chunks.allSatisfy { $0.page < 3 },
                "pipeline": PaperSummary.version, "pdf_pages": source.status.totalPages, "read_pages": source.chunks.map { $0.page + 1 },
                "actual_summary_calls": 1, "summary_seconds": summarySeconds, "index_seconds": Date().timeIntervalSince(indexStarted),
                "vector_count": try db.passages().count, "vector_dimensions": unit.vector.count, "embedding_input": unit.embeddingInput,
                "experiment_records": try db.ledgers().count, "scope": "One real local paper; no full-text model input or experiment extraction"]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: work.appendingPathComponent("verification.json")); print(String(decoding: data, as: UTF8.self))
        } catch { await client.unload(ResearchModels.analysis); print("FAILED: \(error.localizedDescription)"); exit(1) }
        await client.unload(ResearchModels.embedding)
    }
}
