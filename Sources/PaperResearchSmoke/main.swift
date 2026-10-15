import Foundation
import PDFKit
import PaperCore

/// Optional real-model diagnostic, never part of the no-model core checks.
@main struct PaperResearchSmoke {
    static func main() async {
        let args = CommandLine.arguments
        func argument(_ name: String) -> String? {
            guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else { return nil }
            return args[index + 1]
        }
        let port = Int(argument("--port") ?? "11434") ?? 11434
        let work = URL(fileURLWithPath: argument("--work") ?? ".test-output/v02-research-smoke")
        let client = ResearchClient(port: port)
        var report: [String: Any] = [
            "passed": false, "analysis_model": ResearchModels.analysis, "embedding_model": ResearchModels.embedding,
        ]
        report["mode"] = args.contains("--embedding-only") ? "embedding-only" : "analysis-and-embedding"
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            if !args.contains("--embedding-only") {
                var pages: [String]
                if let source = argument("--source") {
                    let url = URL(fileURLWithPath: source)
                    if url.pathExtension.lowercased() == "pdf" {
                        guard let document = PDFDocument(url: url) else {
                            throw ResearchError.message("Cannot read source PDF")
                        }
                        pages = (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
                    } else {
                        pages = [try String(contentsOf: url, encoding: .utf8)]
                    }
                    report["source"] = "user-specified local document; first 3 chunks only"
                } else {
                    pages = [
                        """
                        Synthetic diagnostic fixture, not a published paper.
                        Efficient Retrieval for Research Notes. Authors: Alice Example and Bob Example. Year: 2026.
                        Research question: How can readers find previously read English papers using a Chinese description?
                        We combine keyword retrieval with a multilingual embedding model. Each document is split into page-linked chunks and stored locally.
                        The proposed method preserves a quote and page number for each summary point. Personal notes are stored separately and are never overwritten by regenerated summaries.
                        In this synthetic test, the hybrid system retrieves the target paper at rank one in 18 of 20 queries, compared with 12 of 20 for keyword search alone.
                        The test uses only twenty hand-written queries, so it does not establish general retrieval quality. Scanned documents without text are not supported.
                        """
                    ]
                    report["source"] = "explicitly synthetic diagnostic fixture"
                }
                let chunks = Array(ResearchText.chunks(paperID: "smoke", pages: pages).prefix(3))
                let started = Date()
                let draft = try await client.draft(chunks: chunks, final: true)
                let digest = draft.grounded(
                    in: chunks, paperID: "smoke", model: ResearchModels.analysis,
                    sourceHash: ResearchText.hash(chunks.map(\.text).joined()), totalPages: pages.count)
                guard !digest.points.isEmpty else {
                    throw ResearchError.message("No generated evidence matched the source")
                }
                report["analysis_seconds"] = Date().timeIntervalSince(started)
                report["grounded_points"] = digest.points.count
                report["rejected_evidence"] = digest.rejectedEvidence
                report["one_line"] = digest.oneLine
                try JSONEncoder().encode(digest).write(to: work.appendingPathComponent("digest.json"))
                await client.unload(ResearchModels.analysis)
            }
            let documents = [
                "Streaming text-to-speech reduces the waiting time before the first audio segment. The system synthesizes English sentences one clause at a time and plays each chunk immediately.",
                "A convolutional image classifier predicts the category of a photograph from pixel features.",
                "A relational database joins customer tables using a hash index and transactions.",
            ]
            let vectors = try await client.embeddings(documents)
            let query = try await client.embeddings(["如何缩短英文长句语音合成的等待时间？"], query: true)[0]
            let scores = vectors.map { ResearchText.cosine(query, $0) ?? -1 }
            guard scores.enumerated().max(by: { $0.element < $1.element })?.offset == 0 else {
                throw ResearchError.message("Cross-language retrieval did not rank the speech passage first")
            }
            report["embedding_dimensions"] = query.count
            report["cross_language_scores"] = scores
            report["passed"] = true
        } catch { report["error"] = error.localizedDescription }
        await client.unload(ResearchModels.analysis)
        await client.unload(ResearchModels.embedding)
        let data =
            (try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        try? data.write(to: work.appendingPathComponent("verification.json"))
        print(String(decoding: data, as: UTF8.self))
        if report["passed"] as? Bool != true { exit(1) }
    }
}
