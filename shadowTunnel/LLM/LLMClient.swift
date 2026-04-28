import Foundation

struct LLMCallResult {
    let text: String
    let elapsedMs: Int
}

final class LLMClient {
    private let configLoader = ConfigLoader()

    func translate(text: String, onChunk: @escaping (String) -> Void) async -> LLMCallResult {
        let config = configLoader.loadConfig()
        guard let provider = config.provider(by: config.defaults.translateProviderId) else {
            return LLMCallResult(text: "No translate provider configured.", elapsedMs: 0)
        }
        let target = translationTargetLanguage(for: text)
        let prompt: String
        if shouldReturnIPA(for: text, targetLanguage: target) {
            prompt = """
Translate the following text to \(target).
Rules:
- If the input contains Chinese characters, translate to English.
- Otherwise, translate to Simplified Chinese.
- Return JSON only: {"translation":"...","ipa":"/.../","partOfSpeech":"..."}.
- IPA should be for the original text.
- If the input is a single word or lexical term, fill partOfSpeech with concise labels like "noun", "verb", "adjective", or "noun, verb".
- If partOfSpeech is not applicable, return an empty string.
"""
        } else {
            prompt = """
Translate the following text to \(target).
Rules:
- If the input contains Chinese characters, translate to English.
- Otherwise, translate to Simplified Chinese.
- Return JSON only: {"translation":"...","partOfSpeech":"..."}.
- If the input is a single word or lexical term, fill partOfSpeech with concise labels like "noun", "verb", "adjective", or "noun, verb".
- If partOfSpeech is not applicable, return an empty string.
"""
        }
        return await send(provider: provider, prompt: prompt, input: text, onChunk: onChunk)
    }

    func searchQuick(text: String, onChunk: @escaping (String) -> Void) async -> LLMCallResult {
        let config = configLoader.loadConfig()
        guard let provider = config.provider(by: config.defaults.searchProviderId) else {
            return LLMCallResult(text: "No search provider configured.", elapsedMs: 0)
        }
        let prompt = "You are a research assistant. Return the most concise answer possible. Use bullet points only if needed."
        return await send(provider: provider, prompt: prompt, input: text, onChunk: onChunk)
    }

    func searchDetailed(text: String, onChunk: @escaping (String) -> Void) async -> LLMCallResult {
        let config = configLoader.loadConfig()
        guard let provider = config.provider(by: config.defaults.searchProviderId) else {
            return LLMCallResult(text: "No search provider configured.", elapsedMs: 0)
        }
        let prompt = """
You are a research assistant. Provide a comprehensive answer with:
- key facts and definitions
- context and background
- steps or frameworks (if relevant)
- pros/cons or tradeoffs (if relevant)
- follow-up questions or next research directions
"""
        return await send(provider: provider, prompt: prompt, input: text, onChunk: onChunk)
    }

    func summarizeWebPage(url _: String, content: String, onChunk: @escaping (String) -> Void) async -> LLMCallResult {
        let config = configLoader.loadConfig()
        guard let provider = config.provider(by: config.defaults.searchProviderId) else {
            return LLMCallResult(text: "No search provider configured.", elapsedMs: 0)
        }
        let prompt = """
You summarize webpage content strictly from extracted webpage text.
Requirements:
- Return a concise summary in Chinese.
- Use only the provided extracted webpage text as evidence.
- Do not use the URL, domain name, prior knowledge, or external facts.
- Do not infer missing details unless they are directly supported by the extracted text.
- Include only: 1) Core topic 2) Key points explicitly stated in the text.
- If the extracted content is incomplete, noisy, or insufficient, state that uncertainty explicitly.
"""
        let input = "Extracted web page content:\n\(content)"
        return await send(provider: provider, prompt: prompt, input: input, onChunk: onChunk)
    }

    func summarizeText(_ text: String, onChunk: @escaping (String) -> Void) async -> LLMCallResult {
        let config = configLoader.loadConfig()
        guard let provider = config.provider(by: config.defaults.searchProviderId) else {
            return LLMCallResult(text: "No search provider configured.", elapsedMs: 0)
        }
        let prompt = """
You summarize user-provided text.
Requirements:
- Return a concise summary in Chinese.
- Include only: 1) Core topic 2) Key points.
- Keep it grounded in the given text only.
"""
        return await send(provider: provider, prompt: prompt, input: text, onChunk: onChunk)
    }

    private func send(provider: ProviderConfig, prompt: String, input: String, onChunk: @escaping (String) -> Void) async -> LLMCallResult {
        let start = Date()
        do {
            if #available(macOS 12.0, *), supportsStreaming(provider) {
                let streamRequest = try LLMRequestBuilder.build(provider: provider, prompt: prompt, input: input, stream: true)
                let (bytes, response) = try await URLSession.shared.bytes(for: streamRequest)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                    let body = try await readStreamPreview(bytes: bytes)
                    let err = requestFailureMessage(status: status, body: body)
                    return LLMCallResult(text: err, elapsedMs: elapsedMs(since: start))
                }

                var accumulated = ""
                for try await line in bytes.lines {
                    guard line.hasPrefix("data:") else { continue }
                    let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                    if payload == "[DONE]" { break }
                    guard let data = payload.data(using: .utf8) else { continue }
                    if let delta = parseStreamDelta(data: data) {
                        accumulated += delta
                        onChunk(accumulated)
                    }
                }
                if accumulated.isEmpty {
                    accumulated = "Empty response."
                }
                return LLMCallResult(text: accumulated, elapsedMs: elapsedMs(since: start))
            }

            let request = try LLMRequestBuilder.build(provider: provider, prompt: prompt, input: input, stream: false)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                let body = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let err = requestFailureMessage(status: status, body: body)
                return LLMCallResult(text: err, elapsedMs: elapsedMs(since: start))
            }
            let text = LLMResponseParser.parse(provider: provider, data: data) ?? "Empty response."
            return LLMCallResult(text: text, elapsedMs: elapsedMs(since: start))
        } catch {
            return LLMCallResult(text: "Error: \(error.localizedDescription)", elapsedMs: elapsedMs(since: start))
        }
    }

    private func shouldReturnIPA(for text: String, targetLanguage: String) -> Bool {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return false }
        guard targetLanguage.lowercased().contains("chinese") else { return false }
        guard !cleaned.contains(where: { $0.isWhitespace }) else { return false }
        let isAsciiWord = cleaned.allSatisfy { $0.isLetter && $0.isASCII }
        return isAsciiWord
    }

    private func translationTargetLanguage(for text: String) -> String {
        containsChineseCharacters(text) ? "English" : "Simplified Chinese"
    }

    private func containsChineseCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) ||
            (0x3400...0x4DBF).contains(scalar.value) ||
            (0x20000...0x2A6DF).contains(scalar.value) ||
            (0x2A700...0x2B73F).contains(scalar.value) ||
            (0x2B740...0x2B81F).contains(scalar.value) ||
            (0x2B820...0x2CEAF).contains(scalar.value) ||
            (0xF900...0xFAFF).contains(scalar.value)
        }
    }

    private func supportsStreaming(_ provider: ProviderConfig) -> Bool {
        switch provider.type {
        case .openAICompatible, .qwen, .doubao:
            return true
        case .gemini:
            return false
        }
    }

    private func parseStreamDelta(data: Data) -> String? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let delta = choices.first?["delta"] as? [String: Any],
            let content = delta["content"] as? String
        else { return nil }
        return content
    }

    private func elapsedMs(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    private func requestFailureMessage(status: Int, body: String) -> String {
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let snippet = trimmedBody.isEmpty ? "" : " body: \(String(trimmedBody.prefix(400)))"
        if status == 429 {
            return "Request failed with status 429 (rate limit/quota).\(snippet)"
        }
        if status == 404 {
            return "Request failed with status 404 (endpoint not found). Check provider baseURL/type.\(snippet)"
        }
        return "Request failed with status \(status).\(snippet)"
    }

    @available(macOS 12.0, *)
    private func readStreamPreview(bytes: URLSession.AsyncBytes) async throws -> String {
        var lines: [String] = []
        for try await line in bytes.lines {
            if !line.isEmpty {
                lines.append(line)
            }
            if lines.joined(separator: "\n").count > 400 || lines.count >= 6 {
                break
            }
        }
        return lines.joined(separator: "\n")
    }
}
