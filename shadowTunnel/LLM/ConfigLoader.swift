import Foundation

final class ConfigLoader {
    private let cacheKey = "shadowTunnel.config.override"

    func loadConfig() -> AppConfig {
        let bundled = bundledConfig()

        if let override = UserDefaults.standard.string(forKey: cacheKey),
           let data = override.data(using: .utf8),
           let config = try? JSONDecoder().decode(AppConfig.self, from: data) {
            return normalized(mergedWithBundled(override: config, bundled: bundled))
        }

        return normalized(bundled)
    }

    func saveOverride(json: String) {
        UserDefaults.standard.setValue(json, forKey: cacheKey)
    }

    func saveOverride(config: AppConfig) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(config),
           let json = String(data: data, encoding: .utf8) {
            saveOverride(json: json)
        }
    }

    private func bundledConfig() -> AppConfig {
        guard let url = Bundle.main.url(forResource: "Providers.example", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data)
        else {
            return AppConfig(
                providers: [],
                defaults: DefaultConfig(translateProviderId: "", searchProviderId: "", translationTargetLanguage: "en")
            )
        }
        return config
    }

    private func mergedWithBundled(override: AppConfig, bundled: AppConfig) -> AppConfig {
        var merged = override
        let existingIds = Set(override.providers.map { $0.id })
        let missingBundledProviders = bundled.providers.filter { !existingIds.contains($0.id) }
        merged.providers.append(contentsOf: missingBundledProviders)
        return merged
    }

    private func normalized(_ config: AppConfig) -> AppConfig {
        var updated = config
        updated.providers = config.providers.map { normalizeProvider($0) }
        return updated
    }

    private func normalizeProvider(_ provider: ProviderConfig) -> ProviderConfig {
        var normalized = provider
        let host = URLComponents(string: provider.baseURL)?.host?.lowercased() ?? ""
        let looksLikeQwen = provider.id.lowercased() == "qwen" || host.contains("dashscope.aliyuncs.com")
        let looksLikeDoubao = provider.id.lowercased() == "doubao" || host.contains("volces.com")

        if looksLikeQwen {
            if normalized.type == .openAICompatible {
                normalized.type = .qwen
            }
            normalized.baseURL = normalizeQwenBaseURL(normalized.baseURL)
        }
        if looksLikeDoubao {
            if normalized.type == .openAICompatible {
                normalized.type = .doubao
            }
            normalized.baseURL = normalizeDoubaoBaseURL(normalized.baseURL)
        }
        return normalized
    }

    private func normalizeQwenBaseURL(_ baseURL: String) -> String {
        let trimmed = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        if trimmed.hasSuffix("/compatible-mode/v1") {
            return String(trimmed.dropLast("/v1".count))
        }
        if trimmed.hasSuffix("/v1") {
            return String(trimmed.dropLast("/v1".count))
        }
        return trimmed
    }

    private func normalizeDoubaoBaseURL(_ baseURL: String) -> String {
        let trimmed = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        if trimmed.hasSuffix("/api/v3/chat/completions") {
            return String(trimmed.dropLast("/chat/completions".count))
        }
        if trimmed.hasSuffix("/api/v3") {
            return trimmed
        }
        return trimmed
    }
}
