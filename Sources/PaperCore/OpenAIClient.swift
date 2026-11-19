import Foundation

public struct OpenAIJSONSchema {
    public let name: String
    public let schema: [String: Any]

    public init(name: String, schema: [String: Any]) {
        self.name = name
        self.schema = schema
    }
}

/// Model requests can contain private text or credentials. The caller selects
/// the initial endpoint and its timeouts; redirects must never forward a request.
public enum ModelHTTPSession {
    public static func make(configuration: URLSessionConfiguration) -> URLSession {
        URLSession(configuration: configuration, delegate: NoModelRedirects(), delegateQueue: nil)
    }
}

private final class NoModelRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public struct OpenAIClient: Sendable {
    public static let textModel = "gpt-6-luna"
    public static let summaryModel = "gpt-6.2-sol"
    public static let speechModel = "gpt-realtime-2.1-mini"
    public static let defaultVoice = "marin"
    public static let voices = ["marin", "cedar", "alloy", "ash", "ballad", "coral", "echo",
                                "sage", "shimmer", "verse"]

    private static let responsesURL = URL(string: "https://api.openai.com/v1/responses")!
    private static let sharedSession = makeSession()
    private static let practiceTransport = makeSession(resourceTimeout: 3_660)
    private let session: URLSession
    private let apiKey: String
    private let realtimeSocket: (@Sendable (URLRequest) -> any RealtimeSpeechSocket)?
    private let practiceSocket: (@Sendable (URLRequest) -> any RealtimeSpeechSocket)?
    private let realtimeTimeout: Duration

    public init(apiKey: String) {
        self.apiKey = apiKey
        session = Self.sharedSession
        realtimeSocket = { OpenAIWebSocket($0, session: Self.sharedSession) }
        practiceSocket = { OpenAIWebSocket($0, session: Self.practiceTransport) }
        realtimeTimeout = .seconds(90)
    }

    // Used by the offline transport checks, with the same configuration and redirect policy.
    @_spi(Testing) public init(apiKey: String, protocolClass: URLProtocol.Type,
                               realtimeTimeout: Duration = .seconds(90),
                               realtimeSocket: (@Sendable (URLRequest) -> any RealtimeSpeechSocket)? = nil) {
        self.apiKey = apiKey
        session = Self.makeSession(protocolClass: protocolClass)
        self.realtimeSocket = realtimeSocket
        practiceSocket = realtimeSocket
        self.realtimeTimeout = realtimeTimeout
    }

    private static func makeSession(protocolClass: URLProtocol.Type? = nil, resourceTimeout: TimeInterval = 180) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = resourceTimeout
        if let protocolClass { config.protocolClasses = [protocolClass] }
        return ModelHTTPSession.make(configuration: config)
    }

    public func text(instructions: String, input: String, model: String = Self.textModel,
                     maxOutputTokens: Int = 1024, jsonSchema: OpenAIJSONSchema? = nil) async throws -> String {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              input.utf8.count <= 64_000, (16...8192).contains(maxOutputTokens) else {
            throw Failure("在线文本请求为空或超出长度上限，请缩短选区后重试。")
        }
        return try await responseText(instructions: instructions, input: input, model: model,
                                      maxOutputTokens: maxOutputTokens, jsonSchema: jsonSchema)
    }

    func responseText(instructions: String, input: Any, model: String, maxOutputTokens: Int,
                      jsonSchema: OpenAIJSONSchema?) async throws -> String {
        var payload: [String: Any] = [
            "model": model, "instructions": instructions, "input": input,
            "store": false, "max_output_tokens": maxOutputTokens
        ]
        if model == Self.summaryModel { payload["reasoning"] = ["effort": "low"] }
        if model == Self.textModel { payload["reasoning"] = ["effort": "none"] }
        if let jsonSchema {
            payload["text"] = ["format": ["type": "json_schema", "strict": true,
                                          "name": jsonSchema.name, "schema": jsonSchema.schema]]
        }
        let data = try await post(Self.responsesURL, payload: payload)
        guard let response = try? JSONDecoder().decode(TextResponse.self, from: data) else {
            throw Failure("OpenAI 返回了无法识别的文本响应。")
        }
        guard response.status == "completed" else {
            throw Failure("OpenAI 未完成此次生成，请稍后重试。")
        }
        let content = response.output.filter { $0.type == "message" && $0.role == "assistant" }
            .flatMap { $0.content ?? [] }
        guard !content.contains(where: { $0.type == "refusal" }) else {
            throw Failure("OpenAI 拒绝了此次请求。")
        }
        let result = content.filter { $0.type == "output_text" }.compactMap(\.text)
            .joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw Failure("OpenAI 未返回可用的正文。") }
        return result
    }

    public func speech(input: String, voice: String = Self.defaultVoice) async throws -> Data {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              input.count <= 4096, Self.voices.contains(voice) else {
            throw Failure("在线朗读的文本长度或发音人无效。")
        }
        guard let realtimeSocket else { throw Failure("语音连接未配置。") }
        return try await RealtimeSpeech.synthesize(input: input, voice: voice, key: apiKey,
                                                   timeout: realtimeTimeout, connect: realtimeSocket)
    }

    public func voicePracticeSession(instructions: String, material: String? = nil, voice: String = Self.defaultVoice,
                                     keyboardOnly: Bool = false,
                                     onEvent: @escaping @Sendable (VoicePracticeEvent) async -> Void,
                                     interruptPlayback: @escaping @Sendable (String) async -> Int?) throws -> VoicePracticeSession {
        guard !apiKey.isEmpty, apiKey.utf8.count <= 1024, apiKey.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw Failure("请在设置中保存有效的 OpenAI API Key。")
        }
        guard Self.voices.contains(voice) else { throw Failure("请选择有效的 OpenAI 发音人。") }
        try VoicePracticeSession.validate(instructions: instructions, material: material)
        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?model=" + Self.speechModel)!,
                                 timeoutInterval: 30)
        request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        let connectionRequest = request
        guard let connect = practiceSocket else { throw Failure("语音连接未配置。") }
        return VoicePracticeSession(instructions: instructions, material: material, voice: voice, keyboardOnly: keyboardOnly, timeout: realtimeTimeout,
                                    connect: { connect(connectionRequest) }, onEvent: onEvent, interruptPlayback: interruptPlayback)
    }

    private func post(_ url: URL, payload: [String: Any]) async throws -> Data {
        try Task.checkCancellation()
        guard !apiKey.isEmpty, apiKey.utf8.count <= 1024, apiKey.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw Failure("请在设置中保存有效的 OpenAI API Key。")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: .withoutEscapingSlashes)
        try Task.checkCancellation()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw Failure("无法连接 OpenAI，请检查网络后重试。")
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.url == url else {
            throw Failure("OpenAI 的响应地址无效。")
        }
        switch http.statusCode {
        case 200..<300:
            return data
        case 300..<400:
            throw Failure("出于密钥安全考虑，已拒绝 OpenAI 接口的重定向。")
        case 400:
            let reason = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            if reason?.error.code == "context_length_exceeded" {
                throw Failure("输入超出模型的上下文上限，本次未完成。")
            }
            throw Failure("OpenAI 无法处理此次输入（HTTP 400）。")
        case 401:
            throw Failure("OpenAI 密钥无效或已撤销，请在设置中更新。")
        case 403, 404:
            throw Failure("此 OpenAI 项目没有所选模型的使用权限或该模型不可用。")
        case 413:
            throw Failure("文件超出 OpenAI 的请求大小上限。")
        case 429:
            let reason = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            if reason?.error.code == "insufficient_quota" || reason?.error.code == "billing_hard_limit_reached" {
                throw Failure("此 OpenAI 项目额度不足，请检查 API 组织及账单。")
            }
            throw Failure("OpenAI 已限制请求频率，请稍后再试或检查项目额度。")
        default:
            // Error bodies can echo the API key, the user's text, or their project ID.
            throw Failure("OpenAI 请求失败（HTTP \(http.statusCode)）。")
        }
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
    private struct ErrorResponse: Decodable {
        struct Detail: Decodable { let code: String? }
        let error: Detail
    }
    private struct TextResponse: Decodable {
        struct Output: Decodable {
            struct Content: Decodable { let type: String; let text: String? }
            let type: String
            let role: String?
            let content: [Content]?
        }
        let status: String
        let output: [Output]
    }
}
