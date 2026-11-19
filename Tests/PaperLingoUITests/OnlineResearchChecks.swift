import Foundation
@_spi(Testing) import PaperCore

// Runs through scripts/check-review-ui.sh with PAPERLINGO_UI_CHECK_SOURCE set to this file.
// Only synthetic documents and a process-local URLProtocol participate in these requests.
private final class OnlineResearchProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var inputs: [String] = []
    private static var malformed = false
    private static var suspended = false
    static var sent: [String] { lock.withLock { inputs } }
    static func failResponses(_ fail: Bool) { lock.withLock { malformed = fail } }
    static func suspendResponses(_ value: Bool) { lock.withLock { suspended = value } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 2048)
                while true {
                    let count = stream.read(&bytes, maxLength: bytes.count)
                    if count <= 0 { break }
                    data.append(contentsOf: bytes.prefix(count))
                }
            }
            let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let input = body?["input"] as? String,
                  let url = request.url, ["https://api.openai.com/v1/responses", "https://api.openai.com/v1/audio/speech"].contains(url.absoluteString) else {
                throw AppError.message("Unexpected test request")
            }
            let (invalid, suspended) = Self.lock.withLock {
                Self.inputs.append(input)
                return (Self.malformed, Self.suspended)
            }
            if suspended { return }
            let format = (body?["text"] as? [String: Any])?["format"] as? [String: Any]
            let answer: String
            switch format?["name"] as? String {
            case "word_explanation":
                answer = invalid ? "{}" : #"{"meaning":"形容词；稳健的","inContext":"指估计值在变化下仍然稳定。","usage":"robust to noise 指对噪声有抵抗力。"}"#
            case "paper_summary":
                answer = invalid ? "{}" : #"{"oneLine":"合成示例摘要。","motivation":"检验稳健性。","method":"比较估计值。","results":"开头未报告结果。","category":"测试","tags":["估计"]}"#
            default:
                answer = "稳健的"
            }
            let result: [String: Any] = ["status": "completed", "output": [
                ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": answer]]]]]
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: result))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main @MainActor private struct OnlineResearchChecks {
    static func check(_ value: Bool, _ label: String) throws {
        guard value else { throw AppError.message("FAIL " + label) }
        print("PASS " + label)
    }

    static func waitForRequest(after count: Int) async throws {
        for _ in 0..<150 {
            if OnlineResearchProtocol.sent.count > count { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw AppError.message("No request received by isolated test transport")
    }

    static func main() async throws {
        let mock = OpenAIClient(apiKey: "fixture-only", protocolClass: OnlineResearchProtocol.self)
        let store = AppStore(onlineClient: { mock })
        guard let db = store.db else { throw AppError.message("Missing isolated database") }
        try check(!store.translationOnline && !store.analysisOnline, "Fresh installation uses local text services")

        let paper = Paper(title: "PRIVATE TITLE", filename: "synthetic.txt", kind: "WEB", source: "https://example.org/private-source")
        let opening = "A robust estimate remains stable. " + String(repeating: "Synthetic introduction. ", count: 800)
        try (opening + "PRIVATE TAIL").write(to: store.fileURL(paper), atomically: true, encoding: .utf8)
        try db.addPaper(paper)
        try db.saveNote(PaperNote(paperID: paper.id, body: "PRIVATE NOTE"))
        try store.reload()
        store.analysisOnline = true
        store.startResearch([paper])
        await store.researchTask?.value
        guard let digest = store.digests[paper.id] else {
            throw AppError.message("Cloud summary missing: " + (store.researchError ?? "unknown"))
        }
        try check(PaperSummary.isCurrent(digest) && digest.model == OpenAIClient.analysisSignature, "Online summary saved with provenance without a local model")
        let requests = OnlineResearchProtocol.sent
        try check(requests.count == 1, "One request for one summary")
        let pages = try JSONDecoder().decode([[String: String]].self, from: Data(requests[0].utf8))
        try check(pages == [["page": "1", "text": String(opening.prefix(PaperSummarySource.webCharacterLimit))]],
                  "Summary sends only the bounded opening, without title, URL, notes, local IDs or paths")
        try check(try db.keywordSearch("合成示例摘要").first?.paperID == paper.id, "Online summary is immediately searchable locally")
        try check((try db.passages()).first?.embeddingInput == PaperSummary.indexText(digest), "Semantic indexing continues to use only the Chinese summary")
        OnlineResearchProtocol.failResponses(true)
        store.startResearch([paper])
        await store.researchTask?.value
        try check(store.researchError != nil && store.digests[paper.id]?.id == digest.id, "Invalid online output preserves the previous summary")
        OnlineResearchProtocol.failResponses(false)
        OnlineResearchProtocol.suspendResponses(true)
        let beforeSwitch = OnlineResearchProtocol.sent.count
        store.startResearch([paper])
        try await waitForRequest(after: beforeSwitch)
        try check(!store.translationBlocked && !store.translationOnline, "Local translation is available during a cloud summary")
        UserDefaults.standard.set("openai", forKey: "speechProvider")
        store.audio.speak("A held online utterance.")
        try await waitForRequest(after: beforeSwitch + 1)
        store.stopLocalEngines()
        try check(store.researchTask?.isCancelled == false && store.audio.generating,
                  "Stopping local engines preserves both an in-flight cloud summary and online speech")
        store.audio.stop()
        store.analysisOnline = false
        await store.researchTask?.value
        try check(!store.researchBusy && !store.researchIsCloudText && store.digests[paper.id]?.id == digest.id && OnlineResearchProtocol.sent.count == beforeSwitch + 2,
                  "Switching summary service cancels the in-flight request and preserves the saved digest")
        OnlineResearchProtocol.suspendResponses(false)
        store.analysisOnline = true

        store.translationOnline = true
        store.open(paper)
        let original = "A robust estimate remains stable."
        store.updateSelection("robust", context: original, page: 0)
        await store.translate()
        guard let word = store.words.first(where: { $0.text == "robust" }) else { throw AppError.message("Translation did not save the word") }
        try check(store.translation == "稳健的" && OnlineResearchProtocol.sent.last == "robust", "Reading translation sends only the selection and saves the result with its original local context")

        store.route = .vocabulary
        let baseline = OnlineResearchProtocol.sent.count
        store.focusVocabulary([word])
        store.resumeWordExplanationIfNeeded()
        await store.wordExplanationTask?.value
        try check(OnlineResearchProtocol.sent.count == baseline, "Browsing and idle callbacks never start a paid explanation")
        store.showWordDetails(word, force: true)
        await store.wordExplanationTask?.value
        let value = store.explanation(for: word)
        try check(value?.model == OpenAIClient.analysisSignature && value?.content.meaning.contains("稳健") == true, "Explicit generation stores a validated contextual explanation")
        let input = try JSONDecoder().decode(WordExplanationInput.self, from: Data(OnlineResearchProtocol.sent.last!.utf8))
        try check(input.expression == word.text && input.context == original, "Word request uses the selected expression and its source sentence")
        OnlineResearchProtocol.suspendResponses(true)
        let beforeWordSwitch = OnlineResearchProtocol.sent.count
        store.showWordDetails(word, force: true)
        try await waitForRequest(after: beforeWordSwitch)
        store.analysisOnline = false
        await store.wordExplanationTask?.value
        try check(store.explanation(for: word)?.content == value?.content, "Switching to local preserves the online cache")
        try check(store.wordExplanationTask == nil && OnlineResearchProtocol.sent.count == beforeWordSwitch + 1,
                  "A service switch cancels the in-flight word request without resubmitting it")
        OnlineResearchProtocol.suspendResponses(false)
        store.analysisOnline = true
        try db.record(text: "sparse", translation: "稀疏", context: "A sparse estimate.", paper: nil, page: 0)
        try db.record(text: "adaptive", translation: "自适应", context: "An adaptive estimate.", paper: nil, page: 0)
        try store.reload()
        OnlineResearchProtocol.suspendResponses(true)
        let beforeBatch = OnlineResearchProtocol.sent.count
        store.startWordExplanationBatch()
        try await waitForRequest(after: beforeBatch)
        store.stopLocalEngines()
        try check(store.batchingWordExplanations && store.wordExplanationTask?.isCancelled == false,
                  "Stopping local engines preserves an active online vocabulary batch")
        store.pauseWordExplanation()
        await store.wordExplanationTask?.value
        OnlineResearchProtocol.suspendResponses(false)
        OnlineResearchProtocol.failResponses(true)
        let beforeFailure = OnlineResearchProtocol.sent.count
        store.startWordExplanationBatch()
        await store.wordExplanationTask?.value
        try check(OnlineResearchProtocol.sent.count == beforeFailure + 1 && store.unexplainedWords.count == 2,
                  "An online batch stops after the first failure and preserves unprocessed words")
        OnlineResearchProtocol.failResponses(false)
        store.startWordExplanationBatch()
        await store.wordExplanationTask?.value
        try check(store.unexplainedWords.isEmpty && OnlineResearchProtocol.sent.count == beforeFailure + 3, "An explicit retry processes only the two missing explanations")
        store.openReview()
        store.resumeWordExplanationIfNeeded()
        try check(OnlineResearchProtocol.sent.count == beforeFailure + 3, "Practice reads locally saved explanations without an online request")
    }
}
