import Foundation

struct AppConfig: Codable {
    var providers: [ProviderConfig]
    var defaults: DefaultConfig

    func provider(by id: String) -> ProviderConfig? {
        providers.first { $0.id == id }
    }
}

struct DefaultConfig: Codable {
    var translateProviderId: String
    var searchProviderId: String
    var translationTargetLanguage: String
}

struct ProviderConfig: Codable {
    var id: String
    var type: ProviderType
    var baseURL: String
    var apiKey: String
    var model: String
    var headers: [String: String]?
}

enum ProviderType: String, Codable {
    case openAICompatible = "openai-compatible"
    case qwen
    case doubao
    case gemini
}

enum LLMRequestBuilder {
    static func build(provider: ProviderConfig, prompt: String, input: String, stream: Bool = false) throws -> URLRequest {
        switch provider.type {
        case .openAICompatible:
            return try openAICompatibleRequest(provider: provider, prompt: prompt, input: input, stream: stream)
        case .qwen:
            return try qwenRequest(provider: provider, prompt: prompt, input: input, stream: stream)
        case .doubao:
            return try doubaoRequest(provider: provider, prompt: prompt, input: input, stream: stream)
        case .gemini:
            return try geminiRequest(provider: provider, prompt: prompt, input: input)
        }
    }

    private static func openAICompatibleRequest(provider: ProviderConfig, prompt: String, input: String, stream: Bool) throws -> URLRequest {
        let path = hasPathSuffix(provider.baseURL, suffix: "/v1") ? "/chat/completions" : "/v1/chat/completions"
        let url = try makeURL(baseURL: provider.baseURL, path: path)
        return try chatCompletionsRequest(url: url, provider: provider, prompt: prompt, input: input, stream: stream)
    }

    private static func qwenRequest(provider: ProviderConfig, prompt: String, input: String, stream: Bool) throws -> URLRequest {
        let path = hasPathSuffix(provider.baseURL, suffix: "/compatible-mode") ? "/v1/chat/completions" : "/compatible-mode/v1/chat/completions"
        let url = try makeURL(baseURL: provider.baseURL, path: path)
        return try chatCompletionsRequest(url: url, provider: provider, prompt: prompt, input: input, stream: stream)
    }

    private static func doubaoRequest(provider: ProviderConfig, prompt: String, input: String, stream: Bool) throws -> URLRequest {
        let path = hasPathSuffix(provider.baseURL, suffix: "/api/v3") ? "/chat/completions" : "/api/v3/chat/completions"
        let url = try makeURL(baseURL: provider.baseURL, path: path)
        return try chatCompletionsRequest(url: url, provider: provider, prompt: prompt, input: input, stream: stream)
    }

    private static func chatCompletionsRequest(url: URL, provider: ProviderConfig, prompt: String, input: String, stream: Bool) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let headers = provider.headers ?? [:]
        for (key, value) in headers {
            request.setValue(resolvePlaceholders(value, apiKey: provider.apiKey), forHTTPHeaderField: key)
        }
        var messages: [[String: Any]] = []
        if !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append(["role": "system", "content": prompt])
        }
        messages.append(["role": "user", "content": input])
        let body: [String: Any] = [
            "model": provider.model,
            "messages": messages,
            "temperature": 0.2,
            "stream": stream
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        return request
    }

    private static func geminiRequest(provider: ProviderConfig, prompt: String, input: String) throws -> URLRequest {
        let modelPath = provider.model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? provider.model
        let keyValue = provider.apiKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? provider.apiKey
        let url = try makeURL(baseURL: provider.baseURL, path: "/v1beta/models/\(modelPath):generateContent?key=\(keyValue)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let combinedText: String
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            combinedText = input
        } else {
            combinedText = "\(prompt)\n\n\(input)"
        }
        let body: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": combinedText]
                    ]
                ]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        return request
    }

    private static func resolvePlaceholders(_ value: String, apiKey: String) -> String {
        value.replacingOccurrences(of: "${API_KEY}", with: apiKey)
    }

    private static func makeURL(baseURL: String, path: String) throws -> URL {
        let normalizedBase = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: "\(normalizedBase)\(path)") else {
            throw URLError(.badURL)
        }
        return url
    }

    private static func hasPathSuffix(_ baseURL: String, suffix: String) -> Bool {
        guard let components = URLComponents(string: baseURL) else {
            return baseURL.lowercased().hasSuffix(suffix.lowercased())
        }
        return components.path.lowercased().hasSuffix(suffix.lowercased())
    }
}

enum LLMResponseParser {
    static func parse(provider: ProviderConfig, data: Data) -> String? {
        switch provider.type {
        case .openAICompatible:
            return parseOpenAI(data: data)
        case .qwen:
            return parseOpenAI(data: data)
        case .doubao:
            return parseOpenAI(data: data)
        case .gemini:
            return parseGemini(data: data)
        }
    }

    private static func parseOpenAI(data: Data) -> String? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String
        else { return nil }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseGemini(data: Data) -> String? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let candidates = json["candidates"] as? [[String: Any]],
            let content = candidates.first?["content"] as? [String: Any],
            let parts = content["parts"] as? [[String: Any]],
            let text = parts.first?["text"] as? String
        else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
