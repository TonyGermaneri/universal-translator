import Foundation

/// Minimal client for OpenAI-compatible chat servers such as LM Studio (`http://localhost:1234`).
public struct OpenAICompatibleClient: Sendable {
    public struct Message: Codable, Sendable {
        public var role: String
        public var content: String

        public init(role: String, content: String) {
            self.role = role
            self.content = content
        }
    }

    public enum ClientError: LocalizedError {
        case badURL(String)
        case http(Int, String)
        case emptyResponse

        public var errorDescription: String? {
            switch self {
            case .badURL(let s): return "Invalid server URL: \(s)"
            case .http(let code, let body): return "Server returned HTTP \(code): \(body.prefix(200))"
            case .emptyResponse: return "The model returned an empty response."
            }
        }
    }

    public var baseURL: String
    public var apiKey: String
    public var timeout: TimeInterval

    public init(baseURL: String, apiKey: String = "", timeout: TimeInterval = 20) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.timeout = timeout
    }

    func endpoint(_ path: String) throws -> URL {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        if !base.hasSuffix("/v1") { base += "/v1" }
        guard let url = URL(string: base + path), url.scheme != nil else { throw ClientError.badURL(baseURL) }
        return url
    }

    private func request(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        return req
    }

    /// Model identifiers the server can serve, excluding embedding models.
    public func listModels() async throws -> [String] {
        let (data, response) = try await URLSession.shared.data(for: request(try endpoint("/models")))
        try check(response, data)
        struct Models: Decodable { struct Model: Decodable { let id: String }; let data: [Model] }
        return try JSONDecoder().decode(Models.self, from: data).data.map(\.id)
            .filter { !$0.lowercased().contains("embed") }
    }

    public func complete(model: String, messages: [Message], temperature: Double, maxTokens: Int) async throws -> String {
        struct Body: Encodable {
            let model: String
            let messages: [Message]
            let temperature: Double
            let max_tokens: Int
            let stream = false
        }
        var req = request(try endpoint("/chat/completions"))
        req.httpMethod = "POST"
        req.httpBody = try JSONEncoder().encode(Body(model: model, messages: messages, temperature: temperature, max_tokens: maxTokens))
        let (data, response) = try await URLSession.shared.data(for: req)
        try check(response, data)
        struct Reply: Decodable {
            struct Choice: Decodable { struct Msg: Decodable { let content: String? }; let message: Msg }
            let choices: [Choice]
        }
        let text = try JSONDecoder().decode(Reply.self, from: data).choices.first?.message.content ?? ""
        let cleaned = Prompts.stripReasoning(text)
        if cleaned.isEmpty { throw ClientError.emptyResponse }
        return cleaned
    }

    /// Raw text completion (`/v1/completions`): the prompt is sent as is (chat template applied by the caller),
    /// and the continuation is returned untrimmed so it can extend a prefilled reply.
    public func completeText(model: String, prompt: String, maxTokens: Int, temperature: Double,
                             stop: [String]) async throws -> String {
        struct Body: Encodable {
            let model: String
            let prompt: String
            let max_tokens: Int
            let temperature: Double
            let stop: [String]
            let stream = false
            let cache_prompt = true
        }
        var req = request(try endpoint("/completions"))
        req.httpMethod = "POST"
        req.httpBody = try JSONEncoder().encode(Body(model: model, prompt: prompt, max_tokens: maxTokens,
                                                     temperature: temperature, stop: stop))
        let (data, response) = try await URLSession.shared.data(for: req)
        try check(response, data)
        struct Reply: Decodable {
            struct Choice: Decodable { let text: String? }
            let choices: [Choice]
        }
        return try JSONDecoder().decode(Reply.self, from: data).choices.first?.text ?? ""
    }

    private func check(_ response: URLResponse, _ data: Data) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ClientError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
    }
}
