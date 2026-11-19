import Foundation

extension OpenAIClient {
    public static var analysisSignature: String { "OpenAI/" + summaryModel }
    public static var wordSignature: String { "OpenAI/" + textModel }

    public func summarizeOpening(_ source: PaperSummarySource) async throws -> PaperDigest {
        let result = try await text(instructions: PaperSummary.prompt, input: source.modelInput(), model: Self.summaryModel,
                                    maxOutputTokens: 2000, jsonSchema: Self.summarySchema)
        let draft = try Self.summaryDraft(result)
        return try draft.digest(source: source, model: Self.analysisSignature)
    }

    public func summarizePDF(paperID: String, url: URL) async throws -> PaperDigest {
        let pdf = try FullPaperPDF(url: url)
        try Task.checkCancellation()
        let content: [[String: String]] = [
            ["type": "input_file", "filename": "paper.pdf",
             "file_data": "data:application/pdf;base64," + pdf.data.base64EncodedString()],
            ["type": "input_text", "text": "请阅读整份 PDF 并生成中文摘要。"]
        ]
        let result = try await responseText(instructions: PaperSummary.fullPDFPrompt,
                                            input: [["role": "user", "content": content]], model: Self.summaryModel,
                                            maxOutputTokens: 4000, jsonSchema: Self.summarySchema)
        return try Self.summaryDraft(result).digest(paperID: paperID, model: Self.analysisSignature,
            sourceHash: pdf.sourceHash, processedPages: pdf.pageCount, totalPages: pdf.pageCount,
            pipeline: PaperSummary.fullPDFVersion)
    }

    private static var summarySchema: OpenAIJSONSchema {
        OpenAIJSONSchema(name: "paper_summary", schema: PaperSummary.schema)
    }

    private static func summaryDraft(_ result: String) throws -> PaperSummaryDraft {
        guard let draft = try? JSONDecoder().decode(PaperSummaryDraft.self, from: Data(result.utf8)) else {
            throw ResearchError.message("摘要格式不完整，本次未覆盖原有摘要。")
        }
        return draft
    }

    public func explainWord(_ input: WordExplanationInput) async throws -> WordExplanationDraft {
        let context = String(decoding: try JSONEncoder().encode(input), as: UTF8.self)
        let result = try await text(instructions: WordExplanationPolicy.prompt, input: context,
            maxOutputTokens: 512, jsonSchema: OpenAIJSONSchema(name: "word_explanation", schema: WordExplanationPolicy.schema))
        return try WordExplanationDraft.decode(result, input: input)
    }
}
