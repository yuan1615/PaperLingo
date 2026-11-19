import Foundation
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
        var contentType = "application/json"
        var data: Data
        switch payload["input"] as? String {
        case "wait": return // Remains in flight until the caller cancels.
        case "audio":
            contentType = "audio/wav"
            data = Data("RIFF0000WAVE".utf8) + Data(repeating: 0, count: 34)
        case "bad audio":
            data = Data("html error page".utf8)
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
        XCTAssertEqual(Set(body.keys), ["input", "instructions", "model", "store", "max_output_tokens", "text"])
        XCTAssertEqual(body["model"] as? String, OpenAIClient.textModel)
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["max_output_tokens"] as? Int, 256)
        XCTAssertEqual(body["input"] as? String, "public test")
        let format = (body["text"] as? [String: Any])?["format"] as? [String: Any]
        XCTAssertEqual(format?["type"] as? String, "json_schema")
        XCTAssertEqual(format?["strict"] as? Bool, true)
        XCTAssertEqual(format?["name"] as? String, "example")
    }

    func testSpeechDataBoundaryAndInputGuards() async throws {
        StubOpenAIProtocol.reset()
        let audio = try await client.speech(input: "audio")
        XCTAssertTrue(audio.starts(with: "RIFF".utf8))
        let call = StubOpenAIProtocol.calls.first
        XCTAssertEqual(call?.url?.absoluteString, "https://api.openai.com/v1/audio/speech")
        XCTAssertEqual(Set((call?.payload ?? [:]).keys), ["model", "input", "voice", "response_format"])
        XCTAssertEqual(call?.payload["voice"] as? String, OpenAIClient.defaultVoice)
        XCTAssertEqual(call?.payload["response_format"] as? String, "wav")
        do { _ = try await client.speech(input: "audio", voice: "private-reference"); fail("unrecognized voice accepted") } catch {}
        do { _ = try await client.speech(input: String(repeating: "a", count: 4097)); fail("oversized TTS accepted") } catch {}
        let invalid = OpenAIClient(apiKey: "fixture\r\nheader", protocolClass: StubOpenAIProtocol.self)
        do { _ = try await invalid.speech(input: "audio"); fail("invalid key accepted") } catch {}
        XCTAssertEqual(StubOpenAIProtocol.calls.count, 1)
        do { _ = try await client.speech(input: "bad audio"); fail("invalid WAV accepted") } catch {}
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
