import Foundation

extension OpenAIClient {
    public static var analysisSignature: String { "OpenAI/" + textModel }

    public func summarizeOpening(_ source: PaperSummarySource) async throws -> PaperDigest {
        let result = try await text(instructions: PaperSummary.prompt, input: source.modelInput(),
            maxOutputTokens: 2000, jsonSchema: OpenAIJSONSchema(name: "paper_summary", schema: PaperSummary.schema))
        guard let draft = try? JSONDecoder().decode(PaperSummaryDraft.self, from: Data(result.utf8)) else {
            throw ResearchError.message("摘要格式不完整，本次未覆盖原有摘要。")
        }
        return try draft.digest(source: source, model: Self.analysisSignature)
    }

    public func explainWord(_ input: WordExplanationInput) async throws -> WordExplanationDraft {
        let context = String(decoding: try JSONEncoder().encode(input), as: UTF8.self)
        let result = try await text(instructions: WordExplanationPolicy.prompt, input: context,
            maxOutputTokens: 512, jsonSchema: OpenAIJSONSchema(name: "word_explanation", schema: WordExplanationPolicy.schema))
        return try WordExplanationDraft.decode(result, input: input)
    }
}
