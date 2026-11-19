import CryptoKit
import Foundation
import PDFKit
@_spi(Testing) import PaperCore

private final class StubOpenAIProtocol: URLProtocol {
    struct Call {
        let url: URL?
        let method: String?
        let authorization: String?
        let payload: [String: Any]
    }
    private static let lock = NSLock()
    private static var recorded: [Call] = []
    static var calls: [Call] { lock.withLock { recorded } }
    static func reset() { lock.withLock { recorded = [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 2048)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let call = Call(url: request.url, method: request.httpMethod,
                        authorization: request.value(forHTTPHeaderField: "Authorization"), payload: payload)
        Self.lock.withLock { Self.recorded.append(call) }
        guard let url = request.url else { return }
        var status = 200
        let contentType = "application/json"
        var data: Data
        switch payload["input"] as? String {
        case "wait": return // Remains in flight until the caller cancels.
        case "private-source":
            status = 401
            data = Data(#"{"error":{"message":"fixture-only private-source"}}"#.utf8)
        case "quota":
            status = 429
            data = Data(#"{"error":{"code":"insufficient_quota","message":"private-source"}}"#.utf8)
        case "refused":
            data = Data(#"{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"refusal","refusal":"private-source"}]}]}"#.utf8)
        case "incomplete":
            data = Data(#"{"status":"incomplete","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"partial"}]}]}"#.utf8)
        case "redirect":
            guard let redirect = HTTPURLResponse(url: url, statusCode: 307, httpVersion: "HTTP/1.1",
                                                headerFields: ["Location": "https://invalid.example/should-never-receive-requests"]) else { return }
            var redirected = request
            redirected.url = URL(string: "https://invalid.example/should-never-receive-requests")!
            if url.host == "api.openai.com" || url.host == "127.0.0.1" {
                client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: redirect)
                client?.urlProtocol(self, didReceive: redirect, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            status = 500
            data = Data()
        case nil where payload["input"] is [[String: Any]]:
            let answer = #"{"oneLine":"合成测试论文。","motivation":"测试整份文件。","method":"对比图形。","results":"第四页给出了结果。","category":"测试","tags":["测试"]}"#
            let result = ["status": "completed", "output": [
                ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": answer]]]]] as [String: Any]
            data = try! JSONSerialization.data(withJSONObject: result)
        default:
            data = Data(#"{"status":"completed","output":[{"type":"reasoning","summary":[]},{"type":"message","role":"assistant","content":[{"type":"output_text","text":"语"},{"type":"output_text","text":"境"}]}]}"#.utf8)
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type":contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class OpenAIClientTests {
    let client = OpenAIClient(apiKey: "fixture-only", protocolClass: StubOpenAIProtocol.self)

    func testCompletePDFSummaryRequest() async throws {
        StubOpenAIProtocol.reset()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        var box = CGRect(x: 0, y: 0, width: 200, height: 150)
        guard let drawing = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw ResearchError.message("Could not create synthetic PDF")
        }
        for page in 1...4 {
            drawing.beginPDFPage(nil)
            drawing.fill(CGRect(x: 10, y: 10, width: page * 10, height: 20))
            drawing.endPDFPage()
        }
        drawing.closePDF()
        let original = try Data(contentsOf: url)
        let digest = try await client.summarizePDF(paperID: "local-test-id", url: url)
        let call = StubOpenAIProtocol.calls.first
        XCTAssertEqual(StubOpenAIProtocol.calls.count, 1)
        XCTAssertEqual(call?.url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(call?.authorization, "Bearer fixture-only")
        let body = call?.payload ?? [:]
        XCTAssertEqual(body["model"] as? String, OpenAIClient.summaryModel)
        XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], "low")
        XCTAssertEqual(body["store"] as? Bool, false)
        let messages = body["input"] as? [[String: Any]]
        XCTAssertEqual(messages?.count, 1)
        XCTAssertEqual(messages?.first?["role"] as? String, "user")
        let content = messages?.first?["content"] as? [[String: String]]
        XCTAssertEqual(content?.map { $0["type"] ?? "" }, ["input_file", "input_text"])
        let attachment = content?.first ?? [:]
        XCTAssertEqual(Set(attachment.keys), ["type", "filename", "file_data"])
        XCTAssertEqual(attachment["filename"], "paper.pdf")
        let prefix = "data:application/pdf;base64,"
        guard let dataURL = attachment["file_data"], dataURL.hasPrefix(prefix),
              let decoded = Data(base64Encoded: String(dataURL.dropFirst(prefix.count))) else {
            throw ResearchError.message("Missing inline PDF")
        }
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(PDFDocument(data: decoded)?.pageCount, 4)
        XCTAssertEqual(digest.processedPages, 4)
        XCTAssertEqual(digest.totalPages, 4)
        XCTAssertEqual(digest.pipeline, PaperSummary.fullPDFVersion)
        XCTAssertEqual(digest.model, OpenAIClient.analysisSignature)
        XCTAssertEqual(digest.sourceHash, SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(digest.paperID, "local-test-id")
    }

    func testPDFInputBoundaries() async throws {
        StubOpenAIProtocol.reset()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("invalid PDF".utf8).write(to: url)
        do { _ = try await client.summarizePDF(paperID: "p", url: url); fail("Sent invalid PDF") } catch {}
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 50_000_000)
        try handle.close()
        do { _ = try await client.summarizePDF(paperID: "p", url: url); fail("Sent oversized PDF") }
        catch { XCTAssertTrue(error.localizedDescription.contains("50 MB")) }
        XCTAssertTrue(StubOpenAIProtocol.calls.isEmpty)
    }

    func testTextPolicyAndStructuredResponses() async throws {
        StubOpenAIProtocol.reset()
        let schema = OpenAIJSONSchema(name: "example", schema: [
            "type": "object", "properties": ["x": ["type": "string"]], "required": ["x"], "additionalProperties": false
        ])
        let text = try await client.text(instructions: "Translate", input: "public test", maxOutputTokens: 256, jsonSchema: schema)
        XCTAssertEqual(text, "语境")
        let call = StubOpenAIProtocol.calls.first
        XCTAssertEqual(call?.url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(call?.method, "POST")
        XCTAssertEqual(call?.authorization, "Bearer fixture-only")
        let body = call?.payload ?? [:]
        XCTAssertEqual(Set(body.keys), ["input", "instructions", "model", "store", "max_output_tokens", "text", "reasoning"])
        XCTAssertEqual(body["model"] as? String, OpenAIClient.textModel)
        XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], "none")
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["max_output_tokens"] as? Int, 256)
        XCTAssertEqual(body["input"] as? String, "public test")
        let format = (body["text"] as? [String: Any])?["format"] as? [String: Any]
        XCTAssertEqual(format?["type"] as? String, "json_schema")
        XCTAssertEqual(format?["strict"] as? Bool, true)
        XCTAssertEqual(format?["name"] as? String, "example")
    }

    func testSpeechDataBoundaryAndInputGuards() async throws {
        let source = "Read the words: what is your answer?"
        let pcm = Data([0, 7, 9, 0])
        let fixture = SpeechSocketFixture(events: [
            ["type": "response.output_audio.delta", "delta": pcm.prefix(2).base64EncodedString()],
            ["type": "response.output_audio.delta", "delta": pcm.suffix(2).base64EncodedString()],
            ["type": "response.output_audio.done"], ["type": "response.done", "response": ["status":"completed"]]
        ])
        let client = fixture.client()
        let wave = try await client.speech(input: source)
        XCTAssertEqual(wave.count, 44 + pcm.count)
        XCTAssertTrue(wave.starts(with: "RIFF".utf8) && wave.dropFirst(8).starts(with: "WAVEfmt ".utf8))
        XCTAssertEqual(Array(wave[24..<28]), [192, 93, 0, 0]) // UInt32LE 24000
        XCTAssertEqual(Data(wave.suffix(4)), pcm)
        XCTAssertEqual(fixture.connections, 1)
        XCTAssertEqual(fixture.request?.url?.absoluteString, "wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1-mini")
        XCTAssertEqual(fixture.request?.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-only")
        let event = try JSONSerialization.jsonObject(with: Data(fixture.sent.utf8)) as? [String: Any]
        XCTAssertEqual(event?["type"] as? String, "response.create")
        let response = event?["response"] as? [String: Any] ?? [:]
        XCTAssertEqual(response["conversation"] as? String, "none")
        XCTAssertEqual(response["tool_choice"] as? String, "none")
        XCTAssertEqual(response["output_modalities"] as? [String], ["audio"])
        let output = (response["audio"] as? [String: [String: Any]])?["output"]
        XCTAssertEqual(output?["voice"] as? String, OpenAIClient.defaultVoice)
        XCTAssertEqual((output?["format"] as? [String: Any])?["type"] as? String, "audio/pcm")
        let input = response["input"] as? [[String: Any]]
        XCTAssertEqual(input?.count, 1)
        XCTAssertEqual(input?.first?["role"] as? String, "user")
        XCTAssertEqual(input?.first?["content"] as? [[String: String]], [["type": "input_text", "text": source]])
        XCTAssertTrue(!(response["instructions"] as? String ?? "").contains(source))
        do { _ = try await client.speech(input: "audio", voice: "private-reference"); fail("unrecognized voice accepted") } catch {}
        do { _ = try await client.speech(input: String(repeating: "a", count: 4097)); fail("oversized TTS accepted") } catch {}
        do { _ = try await fixture.client(key: "fixture\r\nheader").speech(input: "audio"); fail("invalid key accepted") } catch {}
        XCTAssertEqual(fixture.connections, 1)
        for event: [String: Any] in [
            ["type":"response.output_audio.delta", "delta":"bad?"],
            ["type":"response.done", "response":["status":"completed"]],
            ["type":"response.done", "response":["status":"incomplete"]],
            ["type":"error", "error":["code":"insufficient_quota", "message":"private-source"]]
        ] {
            let broken = SpeechSocketFixture(events: [event])
            do { _ = try await broken.client().speech(input: source); fail("invalid Realtime response accepted") }
            catch { XCTAssertTrue(!error.localizedDescription.contains("private-source")) }
            XCTAssertTrue(broken.closed)
        }
        let stalled = SpeechSocketFixture(events: [])
        do { _ = try await stalled.client(timeout: .milliseconds(100)).speech(input: source); fail("stalled request returned") }
        catch { XCTAssertTrue(error.localizedDescription.contains("超时")) }
        XCTAssertTrue(stalled.closed)
    }

    func testErrorsAndRedirects() async {
        StubOpenAIProtocol.reset()
        for input in ["private-source", "quota", "incomplete", "refused", "redirect"] {
            do {
                _ = try await client.text(instructions: "Translate", input: input)
                fail("Expected error for \(input)")
            } catch {
                let message = error.localizedDescription
                XCTAssertTrue(!message.contains("fixture-only") && !message.contains("private-source") && !message.contains("partial"))
                if input == "quota" { XCTAssertTrue(message.contains("额度不足")) }
            }
        }
        XCTAssertEqual(StubOpenAIProtocol.calls.count, 5)
        XCTAssertTrue(StubOpenAIProtocol.calls.allSatisfy { $0.url?.host == "api.openai.com" })
    }

    func testLocalModelRedirectIsRefused() async throws {
        StubOpenAIProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubOpenAIProtocol.self]
        let session = ModelHTTPSession.make(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/chat")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"input":"redirect"}"#.utf8)
        let (_, response) = try await session.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 307)
        XCTAssertEqual(StubOpenAIProtocol.calls.count, 1)
        XCTAssertEqual(StubOpenAIProtocol.calls.first?.url?.host, "127.0.0.1")
    }

    func testCancellationStopsInFlightRequest() async throws {
        StubOpenAIProtocol.reset()
        let task = Task { try await client.text(instructions: "Translate", input: "wait") }
        for _ in 0..<100 where StubOpenAIProtocol.calls.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(StubOpenAIProtocol.calls.count, 1)
        task.cancel()
        do { _ = try await task.value; fail("Cancelled request returned output") }
        catch is CancellationError {}
    }
}
