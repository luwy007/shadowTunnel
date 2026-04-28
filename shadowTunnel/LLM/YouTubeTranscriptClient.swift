import Foundation

final class YouTubeTranscriptClient {
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = true
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    private let apiBaseURL = URL(string: "https://api.supadata.ai/v1/transcript")!

    struct TranscriptResult {
        let source: String
        let videoID: String
        let languageCode: String
        let text: String
        let debugText: String
    }

    struct TranscriptDebugFailure: LocalizedError {
        let message: String
        let debugText: String

        var errorDescription: String? { message }
    }

    private final class DebugTrace {
        private(set) var lines: [String] = []

        func add(_ line: String) {
            lines.append(line)
        }

        var text: String {
            lines.joined(separator: "\n")
        }
    }

    func fetchTranscript(from input: String, supadataAPIKey: String) async throws -> TranscriptResult {
        let debug = DebugTrace()
        debug.add("Provider: Supadata transcript API")
        debug.add("Input length: \(input.count)")

        do {
            guard let videoID = extractVideoID(from: input) else {
                debug.add("Video ID extraction failed.")
                throw TranscriptError.invalidYouTubeURL
            }
            debug.add("Resolved video ID: \(videoID)")

            let key = supadataAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                debug.add("Supadata API key is missing.")
                throw TranscriptError.missingSupadataAPIKey
            }
            debug.add("Supadata API key: \(maskedAPIKey(key))")

            let videoURL = "https://www.youtube.com/watch?v=\(videoID)"
            debug.add("Supadata request video URL: \(videoURL)")

            let response = try await requestTranscript(urlString: videoURL, apiKey: key, debug: debug)
            let transcript = try await resolveTranscript(from: response, apiKey: key, debug: debug)
            let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw TranscriptError.emptyTranscript
            }

            return TranscriptResult(
                source: transcript.source,
                videoID: videoID,
                languageCode: transcript.languageCode,
                text: text,
                debugText: debug.text
            )
        } catch {
            throw TranscriptDebugFailure(message: describe(error), debugText: debug.text)
        }
    }

    func containsYouTubeURL(_ input: String) -> Bool {
        extractVideoID(from: input) != nil
    }

    private func requestTranscript(urlString: String, apiKey: String, debug: DebugTrace) async throws -> SupadataTranscriptEnvelope {
        var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "url", value: urlString),
            URLQueryItem(name: "text", value: "true"),
            URLQueryItem(name: "mode", value: "auto")
        ]
        guard let url = components?.url else {
            throw TranscriptError.invalidSupadataRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        debug.add("Supadata request URL: \(redactAPIURL(url))")
        let (data, response) = try await session.data(for: request)
        return try parseSupadataEnvelope(data: data, response: response, debug: debug, label: "Supadata transcript")
    }

    private func resolveTranscript(
        from envelope: SupadataTranscriptEnvelope,
        apiKey: String,
        debug: DebugTrace
    ) async throws -> ResolvedTranscript {
        if let text = envelope.transcriptText {
            debug.add("Supadata returned transcript directly.")
            debug.add("Supadata transcript length: \(text.count)")
            return ResolvedTranscript(
                source: "Supadata API",
                languageCode: envelope.resolvedLanguage ?? "unknown",
                text: text
            )
        }

        guard let jobID = envelope.jobId, !jobID.isEmpty else {
            debug.add("Supadata response did not contain transcript text or jobId.")
            throw TranscriptError.invalidSupadataResponse
        }

        debug.add("Supadata async job id: \(jobID)")
        return try await pollTranscriptJob(jobID: jobID, apiKey: apiKey, debug: debug)
    }

    private func pollTranscriptJob(jobID: String, apiKey: String, debug: DebugTrace) async throws -> ResolvedTranscript {
        let maxAttempts = 45

        for attempt in 1...maxAttempts {
            let url = apiBaseURL.appendingPathComponent(jobID)
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            debug.add("Polling Supadata job attempt \(attempt)/\(maxAttempts): \(url.absoluteString)")
            let (data, response) = try await session.data(for: request)
            let envelope = try parseSupadataEnvelope(data: data, response: response, debug: debug, label: "Supadata job")
            let status = envelope.status?.lowercased() ?? "completed"
            debug.add("Supadata job status: \(status)")

            if let text = envelope.transcriptText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                debug.add("Supadata job transcript length: \(text.count)")
                return ResolvedTranscript(
                    source: "Supadata API (async)",
                    languageCode: envelope.resolvedLanguage ?? "unknown",
                    text: text
                )
            }

            if ["completed", "done", "success", "succeeded"].contains(status) {
                throw TranscriptError.emptyTranscript
            }

            if ["failed", "error", "cancelled"].contains(status) {
                let reason = envelope.errorSummary ?? "Unknown async job failure."
                throw TranscriptError.supadataRequestFailed(reason)
            }

            try await Task.sleep(nanoseconds: 1_000_000_000)
        }

        throw TranscriptError.transcriptJobTimedOut
    }

    private func parseSupadataEnvelope(
        data: Data,
        response: URLResponse,
        debug: DebugTrace,
        label: String
    ) throws -> SupadataTranscriptEnvelope {
        guard let http = response as? HTTPURLResponse else {
            throw TranscriptError.supadataRequestFailed("Unknown response.")
        }

        debug.add("\(label) HTTP status: \(http.statusCode)")
        debug.add("\(label) content-type: \(http.value(forHTTPHeaderField: "Content-Type") ?? "unknown")")

        let previewText = String(data: data, encoding: .utf8) ?? ""
        if !previewText.isEmpty {
            debug.add("\(label) response preview: \(preview(previewText))")
        }

        let envelope = try decodeSupadataEnvelope(from: data)
        if (200...299).contains(http.statusCode) {
            return envelope
        }

        let message = envelope.errorSummary ?? "status \(http.statusCode)"
        throw TranscriptError.supadataRequestFailed(message)
    }

    private func decodeSupadataEnvelope(from data: Data) throws -> SupadataTranscriptEnvelope {
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(SupadataTranscriptEnvelope.self, from: data)
        } catch {
            if let text = String(data: data, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return SupadataTranscriptEnvelope(
                    content: .text(text),
                    text: nil,
                    transcript: nil,
                    lang: nil,
                    language: nil,
                    jobId: nil,
                    status: "completed",
                    error: nil,
                    message: nil,
                    detail: nil
                )
            }
            throw TranscriptError.invalidSupadataResponse
        }
    }

    private func extractVideoID(from input: String) -> String? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let nsInput = input as NSString
        let matches = detector?.matches(in: input, options: [], range: NSRange(location: 0, length: nsInput.length)) ?? []

        for match in matches {
            guard let url = match.url, let id = extractVideoID(from: url) else { continue }
            return id
        }

        if let url = URL(string: input.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return extractVideoID(from: url)
        }

        if let id = extractVideoIDWithRegex(from: input) {
            return id
        }

        return nil
    }

    private func extractVideoID(from url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }

        if host == "youtu.be" {
            let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return normalizeVideoID(id)
        }

        if host.contains("youtube.com") || host.contains("youtube-nocookie.com") {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let queryID = components.queryItems?.first(where: { $0.name == "v" })?.value,
               let normalized = normalizeVideoID(queryID) {
                return normalized
            }

            let parts = url.path.split(separator: "/").map(String.init)
            if let idx = parts.firstIndex(of: "shorts"), parts.indices.contains(idx + 1) {
                return normalizeVideoID(parts[idx + 1])
            }
            if let idx = parts.firstIndex(of: "embed"), parts.indices.contains(idx + 1) {
                return normalizeVideoID(parts[idx + 1])
            }
        }

        return nil
    }

    private func extractVideoIDWithRegex(from input: String) -> String? {
        let patterns = [
            #"(?i)(?:youtube\.com/watch\?[^ ]*v=)([A-Za-z0-9_-]{11})"#,
            #"(?i)(?:youtu\.be/)([A-Za-z0-9_-]{11})"#,
            #"(?i)(?:youtube\.com/shorts/)([A-Za-z0-9_-]{11})"#,
            #"(?i)(?:youtube\.com/embed/)([A-Za-z0-9_-]{11})"#,
            #"(?i)(?:youtube-nocookie\.com/embed/)([A-Za-z0-9_-]{11})"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsInput = input as NSString
            let range = NSRange(location: 0, length: nsInput.length)
            guard let match = regex.firstMatch(in: input, range: range), match.numberOfRanges > 1 else { continue }
            let id = nsInput.substring(with: match.range(at: 1))
            if let normalized = normalizeVideoID(id) {
                return normalized
            }
        }
        return nil
    }

    private func normalizeVideoID(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"[A-Za-z0-9_-]{11}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = trimmed as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: trimmed, options: [], range: range), match.range.location != NSNotFound else {
            return nil
        }
        return ns.substring(with: match.range)
    }

    private func redactAPIURL(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.queryItems = components.queryItems?.map { item in
            if item.name == "url" {
                return URLQueryItem(name: item.name, value: item.value)
            }
            return item
        }
        return components.url?.absoluteString ?? url.absoluteString
    }

    private func maskedAPIKey(_ key: String) -> String {
        guard key.count > 8 else { return String(repeating: "*", count: key.count) }
        return "\(key.prefix(4))...\(key.suffix(4)) (len=\(key.count))"
    }

    private func preview(_ text: String, limit: Int = 220) -> String {
        let compact = text.replacingOccurrences(of: "\n", with: " ")
        if compact.count > limit {
            return String(compact.prefix(limit)) + "..."
        }
        return compact
    }

    private func describe(_ error: Error) -> String {
        if let debugFailure = error as? TranscriptDebugFailure {
            return debugFailure.message
        }
        if let localized = error as? LocalizedError, let message = localized.errorDescription {
            return message
        }
        return error.localizedDescription
    }
}

private struct ResolvedTranscript {
    let source: String
    let languageCode: String
    let text: String
}

private struct SupadataTranscriptEnvelope: Decodable {
    let content: SupadataTranscriptContent?
    let text: String?
    let transcript: String?
    let lang: String?
    let language: String?
    let jobId: String?
    let status: String?
    let error: String?
    let message: String?
    let detail: String?

    var transcriptText: String? {
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let transcript, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return content?.joinedText
    }

    var resolvedLanguage: String? {
        [lang, language]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    var errorSummary: String? {
        [error, message, detail]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }
}

private enum SupadataTranscriptContent: Decodable {
    case text(String)
    case chunks([SupadataTranscriptChunk])

    var joinedText: String? {
        switch self {
        case let .text(value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let .chunks(items):
            let text = items
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            return text.isEmpty ? nil : text
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .text(value)
            return
        }
        if let items = try? container.decode([SupadataTranscriptChunk].self) {
            self = .chunks(items)
            return
        }
        throw DecodingError.typeMismatch(
            SupadataTranscriptContent.self,
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unsupported content shape.")
        )
    }
}

private struct SupadataTranscriptChunk: Decodable {
    let text: String
}

enum TranscriptError: LocalizedError {
    case invalidYouTubeURL
    case missingSupadataAPIKey
    case invalidSupadataRequest
    case invalidSupadataResponse
    case supadataRequestFailed(String)
    case transcriptJobTimedOut
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .invalidYouTubeURL:
            return "Input is not a valid YouTube link."
        case .missingSupadataAPIKey:
            return "Missing Supadata API key. Add it in Settings > Supadata."
        case .invalidSupadataRequest:
            return "Invalid Supadata transcript request."
        case .invalidSupadataResponse:
            return "Supadata returned an unexpected transcript response."
        case let .supadataRequestFailed(message):
            return "Supadata transcript request failed: \(message)"
        case .transcriptJobTimedOut:
            return "Supadata transcript job timed out."
        case .emptyTranscript:
            return "Transcript is empty."
        }
    }
}
