import Foundation
import AppKit
import Combine
import AVFoundation

final class OverlayViewModel: ObservableObject {
    enum SubmitAction: String, CaseIterable {
        case translate
        case searchQuick
        case searchDetailed
        case summarize
        case subtitles
    }

    @Published var selectedText: String = ""
    @Published var resultText: String = ""
    @Published var providers: [ProviderConfig] = []
    @Published var selectedProviderId: String = ""
    @Published var apiKeyInput: String = ""
    @Published var hotkeyString: String = "Cmd+Option+Z"
    @Published var isHotkeyRecorderPresented: Bool = false
    @Published var isSettingsPresented: Bool = false
    @Published var apiKeySavedMessage: String = ""
    @Published var modelSavedMessage: String = ""
    @Published var modelSelection: String = ""
    @Published var lastAction: String = ""
    @Published var translationText: String = ""
    @Published var ipaText: String = ""
    @Published var partOfSpeechText: String = ""
    @Published var supadataAPIKeyInput: String = ""
    @Published var supadataAPIKeySavedMessage: String = ""
    @Published var translationSaveMessage: String = ""
    @Published var selectedSubmitAction: SubmitAction = .translate

    private let selectionManager = SelectionManager()
    private let llmClient = LLMClient()
    private let transcriptClient = YouTubeTranscriptClient()
    private let configLoader = ConfigLoader()
    let historyStore = HistoryStore()
    let userSettings = UserSettings()
    private let speechSynthesizer = AVSpeechSynthesizer()
    private var latencyTimer: DispatchSourceTimer?
    private var latencyStartDate: Date?
    private var activeLatencyToken = UUID()
    private var providerLabelState = "ProviderID: -"
    private var latencyLabelState = "Latency: -"
    private var settingsCancellable: AnyCancellable?
    weak var panelController: FloatingPanelController?
    weak var hotKeyManager: HotKeyManager?
    weak var historyWindowController: HistoryWindowController?

    init() {
        reloadConfig()
        hotkeyString = HotKeyManager.hotkeyString()
        supadataAPIKeyInput = userSettings.supadataAPIKey
        settingsCancellable = userSettings.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    func loadSelectionAndShow(panelController: FloatingPanelController?) {
        self.panelController = panelController
        // Hotkey entry should always open the query panel, not force-open settings.
        isSettingsPresented = false

        // Fall back to clipboard copy when AX cannot read the current selection.
        let latestSelection = selectionManager.selectedText()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasNewSelection = !latestSelection.isEmpty
        let shouldRestorePreviousConversation =
            !hasNewSelection && hasConversationStateToRestore()

        if hasNewSelection {
            selectedText = latestSelection
            resultText = ""
            translationText = ""
            ipaText = ""
            partOfSpeechText = ""
            translationSaveMessage = ""
            lastAction = ""
            resetLatencyDisplay()
        } else if !shouldRestorePreviousConversation {
            selectedText = ""
        }

        if let panelController {
            let location = NSEvent.mouseLocation
            let adjusted = NSPoint(x: location.x + 12, y: location.y - 12)
            panelController.show(at: adjusted)
        }

        if hasNewSelection && userSettings.autoTranslateOnOpen {
            translate()
        }
    }

    func translate() {
        let input = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        let providerId = currentProviderId(for: .translate)
        let latencyToken = beginLatency(providerId: providerId)
        resultText = annotateStreamingResult("", providerId: providerId)
        translationText = ""
        ipaText = ""
        partOfSpeechText = ""
        translationSaveMessage = ""

        Task {
            let result = await llmClient.translate(text: input) { partial in
                Task { @MainActor in
                    self.resultText = self.annotateStreamingResult(partial, providerId: providerId)
                }
            }
            await MainActor.run {
                let parsed = self.parseTranslationResponse(result.text)
                self.translationText = parsed.translation
                self.ipaText = parsed.ipa
                self.partOfSpeechText = parsed.partOfSpeech
                var lines = ["Translation: \(parsed.translation)"]
                if !parsed.partOfSpeech.isEmpty {
                    lines.append("Part of Speech: \(parsed.partOfSpeech)")
                }
                if !parsed.ipa.isEmpty {
                    lines.append("IPA: \(parsed.ipa)")
                }
                self.resultText = self.annotateResult(lines.joined(separator: "\n"), providerId: providerId, elapsedMs: result.elapsedMs)
                self.endLatency(token: latencyToken, elapsedMs: result.elapsedMs)
                self.lastAction = "translate"
                self.historyStore.add(action: "translate", input: input, output: result.text)
            }
        }
    }

    func saveCurrentTranslation() {
        let source = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let translation = translationText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSaveCurrentTranslation else {
            translationSaveMessage = "Cannot save"
            return
        }

        do {
            try persistTranslation(source: source, translation: translation)
            translationSaveMessage = "Saved"
        } catch {
            translationSaveMessage = translationSaveFailureMessage(for: error)
            NSLog("shadowTunnel failed to persist translation: %@", error.localizedDescription)
        }
    }

    func search() {
        let input = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        let providerId = currentProviderId(for: .search)
        let latencyToken = beginLatency(providerId: providerId)
        resultText = annotateStreamingResult("", providerId: providerId)

        Task {
            let result = await llmClient.searchQuick(text: input) { partial in
                Task { @MainActor in
                    self.resultText = self.annotateStreamingResult(partial, providerId: providerId)
                }
            }
            await MainActor.run {
                self.resultText = self.annotateResult(result.text, providerId: providerId, elapsedMs: result.elapsedMs)
                self.endLatency(token: latencyToken, elapsedMs: result.elapsedMs)
                self.translationText = ""
                self.ipaText = ""
                self.partOfSpeechText = ""
                self.translationSaveMessage = ""
                self.lastAction = "search"
                self.historyStore.add(action: "search", input: input, output: result.text)
            }
        }
    }

    func searchDetailed() {
        let input = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        let providerId = currentProviderId(for: .search)
        let latencyToken = beginLatency(providerId: providerId)
        resultText = annotateStreamingResult("", providerId: providerId)

        Task {
            let result = await llmClient.searchDetailed(text: input) { partial in
                Task { @MainActor in
                    self.resultText = self.annotateStreamingResult(partial, providerId: providerId)
                }
            }
            await MainActor.run {
                self.resultText = self.annotateResult(result.text, providerId: providerId, elapsedMs: result.elapsedMs)
                self.endLatency(token: latencyToken, elapsedMs: result.elapsedMs)
                self.translationText = ""
                self.ipaText = ""
                self.partOfSpeechText = ""
                self.translationSaveMessage = ""
                self.lastAction = "search_detailed"
                self.historyStore.add(action: "search_detailed", input: input, output: result.text)
            }
        }
    }

    func summarizeWebPage() {
        let input = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }

        let providerId = currentProviderId(for: .search)
        let latencyToken = beginLatency(providerId: providerId)
        resultText = annotateStreamingResult("", providerId: providerId)
        translationText = ""
        ipaText = ""
        partOfSpeechText = ""
        translationSaveMessage = ""

        Task {
            do {
                if let url = extractFirstWebURL(from: input) {
                    if transcriptClient.containsYouTubeURL(url.absoluteString) {
                        await MainActor.run {
                            self.resultText = self.annotateStreamingResult("正在获取 YouTube 字幕...", providerId: providerId)
                        }

                        let transcript = try await transcriptClient.fetchTranscript(
                            from: url.absoluteString,
                            supadataAPIKey: userSettings.supadataAPIKey
                        )
                        let transcriptInput = summarizedTranscriptInput(transcript)

                        await MainActor.run {
                            self.resultText = self.annotateStreamingResult(
                                self.webSummaryDisplayBody(summary: nil),
                                providerId: providerId
                            )
                        }

                        let result = await llmClient.summarizeText(transcriptInput) { partial in
                            Task { @MainActor in
                                self.resultText = self.annotateStreamingResult(
                                    self.webSummaryDisplayBody(summary: partial),
                                    providerId: providerId
                                )
                            }
                        }

                        await MainActor.run {
                            self.resultText = self.annotateResult(
                                self.webSummaryDisplayBody(summary: result.text),
                                providerId: providerId,
                                elapsedMs: result.elapsedMs
                            )
                            self.endLatency(token: latencyToken, elapsedMs: result.elapsedMs)
                            self.lastAction = "summarize"
                            self.historyStore.add(action: "summarize", input: input, output: result.text)
                        }
                    } else {
                        let pageText = try await fetchReadablePageText(from: url)
                        await MainActor.run {
                            self.resultText = self.annotateStreamingResult(
                                self.webSummaryDisplayBody(summary: nil),
                                providerId: providerId
                            )
                        }

                        let result = await llmClient.summarizeWebPage(
                            url: url.absoluteString,
                            content: pageText
                        ) { partial in
                            Task { @MainActor in
                                self.resultText = self.annotateStreamingResult(
                                    self.webSummaryDisplayBody(summary: partial),
                                    providerId: providerId
                                )
                            }
                        }

                        await MainActor.run {
                            self.resultText = self.annotateResult(
                                self.webSummaryDisplayBody(summary: result.text),
                                providerId: providerId,
                                elapsedMs: result.elapsedMs
                            )
                            self.endLatency(token: latencyToken, elapsedMs: result.elapsedMs)
                            self.lastAction = "summarize"
                            self.historyStore.add(action: "summarize", input: input, output: result.text)
                        }
                    }
                } else {
                    let result = await llmClient.summarizeText(input) { partial in
                        Task { @MainActor in
                            self.resultText = self.annotateStreamingResult(partial, providerId: providerId)
                        }
                    }

                    await MainActor.run {
                        self.resultText = self.annotateResult(result.text, providerId: providerId, elapsedMs: result.elapsedMs)
                        self.endLatency(token: latencyToken, elapsedMs: result.elapsedMs)
                        self.lastAction = "summarize"
                        self.historyStore.add(action: "summarize", input: input, output: result.text)
                    }
                }
            } catch {
                await MainActor.run {
                    self.resultText = self.annotateResult("Summary error: \(error.localizedDescription)", providerId: providerId, elapsedMs: 0)
                    self.endLatency(token: latencyToken, elapsedMs: 0)
                    self.lastAction = "summarize"
                    self.historyStore.add(action: "summarize", input: input, output: "Summary error: \(error.localizedDescription)")
                }
            }
        }
    }


    func fetchYouTubeTranscript() {
        let input = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        guard transcriptClient.containsYouTubeURL(input) else {
            resultText = "Please provide a valid YouTube link."
            translationText = ""
            ipaText = ""
            partOfSpeechText = ""
            translationSaveMessage = ""
            lastAction = "youtube_transcript"
            return
        }

        let latencyToken = beginLatency(providerId: "youtube")
        resultText = "Loading transcript..."
        translationText = ""
        ipaText = ""
        partOfSpeechText = ""
        translationSaveMessage = ""

        Task {
            do {
                let result = try await transcriptClient.fetchTranscript(
                    from: input,
                    supadataAPIKey: userSettings.supadataAPIKey
                )
                await MainActor.run {
                    let display = self.formattedYouTubeTranscriptResult(result)
                    self.resultText = display
                    self.endLatency(token: latencyToken, elapsedMs: nil)
                    self.lastAction = "youtube_transcript"
                    self.historyStore.add(action: "youtube_transcript", input: input, output: display)
                }
            } catch {
                await MainActor.run {
                    let display = self.formattedYouTubeTranscriptError(error)
                    self.resultText = display
                    self.endLatency(token: latencyToken, elapsedMs: nil)
                    self.lastAction = "youtube_transcript"
                    self.historyStore.add(action: "youtube_transcript", input: input, output: display)
                }
            }
        }
    }

    func showHistory() {
        historyWindowController?.show()
    }

    func selectSubmitAction(_ action: SubmitAction) {
        selectedSubmitAction = action
    }

    func triggerSubmitAction(_ action: SubmitAction) {
        selectedSubmitAction = action
        performPrimarySubmitAction()
    }

    func performPrimarySubmitAction() {
        switch selectedSubmitAction {
        case .translate:
            translate()
        case .searchQuick:
            search()
        case .searchDetailed:
            searchDetailed()
        case .summarize:
            summarizeWebPage()
        case .subtitles:
            fetchYouTubeTranscript()
        }
    }

    func closePanel() {
        panelController?.close()
    }

    func reloadConfig() {
        let config = configLoader.loadConfig()
        providers = config.providers
        selectedProviderId = config.defaults.translateProviderId.isEmpty ? (providers.first?.id ?? "") : config.defaults.translateProviderId
        apiKeyInput = providers.first(where: { $0.id == selectedProviderId })?.apiKey ?? ""
        modelSelection = providers.first(where: { $0.id == selectedProviderId })?.model ?? ""
    }

    func saveApiKey() {
        var config = configLoader.loadConfig()
        guard let index = config.providers.firstIndex(where: { $0.id == selectedProviderId }) else { return }
        config.providers[index].apiKey = apiKeyInput
        configLoader.saveOverride(config: config)
        providers = config.providers
        apiKeySavedMessage = "Saved"
    }

    func syncApiKeyInput() {
        apiKeyInput = providers.first(where: { $0.id == selectedProviderId })?.apiKey ?? ""
        apiKeySavedMessage = ""
        modelSelection = providers.first(where: { $0.id == selectedProviderId })?.model ?? ""
        modelSavedMessage = ""
    }

    func saveSelectedProviderAsDefault() {
        guard providers.contains(where: { $0.id == selectedProviderId }) else { return }
        var config = configLoader.loadConfig()
        config.defaults.translateProviderId = selectedProviderId
        config.defaults.searchProviderId = selectedProviderId
        configLoader.saveOverride(config: config)
    }

    func hasProviderSelected() -> Bool {
        providers.contains(where: { $0.id == selectedProviderId })
    }

    func saveModelSelection() {
        let model = modelSelection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return }
        var config = configLoader.loadConfig()
        guard let index = config.providers.firstIndex(where: { $0.id == selectedProviderId }) else { return }
        config.providers[index].model = model
        configLoader.saveOverride(config: config)
        providers = config.providers
        modelSelection = config.providers[index].model
        modelSavedMessage = "Saved"
    }

    func syncSupadataAPIKeyInput() {
        supadataAPIKeyInput = userSettings.supadataAPIKey
        supadataAPIKeySavedMessage = ""
    }

    func saveSupadataAPIKey() {
        userSettings.supadataAPIKey = supadataAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        supadataAPIKeySavedMessage = "Saved"
    }

    var modelOptions: [String] {
        guard let provider = providers.first(where: { $0.id == selectedProviderId }) else { return [] }
        let suggestions: [String]
        switch provider.type {
        case .openAICompatible:
            suggestions = ["gpt-4o-mini", "gpt-4o", "gpt-4.1-mini", "gpt-4.1", "gpt-4.1-nano", "o4-mini", "o3-mini"]
        case .qwen:
            suggestions = ["qwen-turbo", "qwen-plus", "qwen-max"]
        case .doubao:
            suggestions = ["doubao-seed-2-0-pro-260215", "doubao-seed-1-6-flash-250715", "doubao-1-5-pro-32k-250115"]
        case .gemini:
            suggestions = ["gemini-2.0-flash", "gemini-2.0-flash-lite", "gemini-1.5-flash", "gemini-1.5-pro"]
        }

        if suggestions.contains(provider.model) {
            return suggestions
        }
        return [provider.model] + suggestions
    }

    var selectedProviderType: ProviderType? {
        providers.first(where: { $0.id == selectedProviderId })?.type
    }

    var modelInputPlaceholder: String {
        guard let providerType = selectedProviderType else { return "Custom model" }
        switch providerType {
        case .doubao:
            return "Doubao endpoint ID (e.g. ep-xxxxxx)"
        default:
            return "Custom model"
        }
    }

    func applyHotkey(_ config: HotKeyConfig) {
        hotKeyManager?.updateHotKey(config: config)
        hotkeyString = HotKeyManager.hotkeyString()
    }

    func speakTranslation() {
        let text = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if speechSynthesizer.isSpeaking { speechSynthesizer.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.voice = AVSpeechSynthesisVoice(language: speechVoiceLanguage())
        DispatchQueue.main.async { [weak self] in
            self?.speechSynthesizer.speak(utterance)
        }
    }

    private func extractTranslationText(from result: String) -> String {
        let lines = result.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        if let first = lines.first(where: { $0.lowercased().hasPrefix("translation:") }) {
            return first.replacingOccurrences(of: "Translation:", with: "", options: [.caseInsensitive]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return lines.first ?? result
    }

    private func parseTranslationResponse(_ response: String) -> (translation: String, ipa: String, partOfSpeech: String) {
        if let data = response.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let translation = (json["translation"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let ipa = (json["ipa"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let partOfSpeech = (json["partOfSpeech"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return (translation.isEmpty ? response : translation, ipa, partOfSpeech)
        }
        return (extractTranslationText(from: response), "", extractPartOfSpeech(from: response))
    }

    private func extractPartOfSpeech(from result: String) -> String {
        let lines = result.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        if let first = lines.first(where: { $0.lowercased().hasPrefix("part of speech:") }) {
            return first.replacingOccurrences(of: "Part of Speech:", with: "", options: [.caseInsensitive]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    private func persistTranslationIfNeeded(source: String, translation: String) {
        do {
            try persistTranslation(source: source, translation: translation)
        } catch {
            NSLog("shadowTunnel failed to persist translation: %@", error.localizedDescription)
        }
    }

    var canSaveCurrentTranslation: Bool {
        let source = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let translation = translationText.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = userSettings.translationSaveFilePath.trimmingCharacters(in: .whitespacesAndNewlines)
        return !path.isEmpty && !translation.isEmpty && isWordOrPhraseQuery(source)
    }

    private func persistTranslation(source: String, translation: String) throws {
        let path = userSettings.translationSaveFilePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { throw TranslationSaveError.missingFilePath }
        guard isWordOrPhraseQuery(source) else { throw TranslationSaveError.unsupportedInput }

        let normalizedSource = normalizeTranslationRecordField(source)
        let normalizedTranslation = normalizeTranslationRecordField(translation)
        guard !normalizedSource.isEmpty, !normalizedTranslation.isEmpty else {
            throw TranslationSaveError.emptyContent
        }

        let fileURL = try resolvedTranslationFileURL(from: path)
        let directoryURL = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try Data().write(to: fileURL, options: .atomic)
        }

        let existingData = try Data(contentsOf: fileURL)
        let needsLeadingNewline = !existingData.isEmpty && existingData.last != 0x0A
        let linePrefix = needsLeadingNewline ? "\n" : ""
        let line = "\(linePrefix)\(normalizedSource)=\(normalizedTranslation)\n"
        guard let data = line.data(using: .utf8) else {
            throw TranslationSaveError.encodingFailed
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func isWordOrPhraseQuery(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !trimmed.contains("\n") else { return false }
        let words = trimmed.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty, words.count <= 6 else { return false }
        return !trimmed.contains { ".!?;:，。！？；：".contains($0) }
    }

    private func normalizeTranslationRecordField(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resolvedTranslationFileURL(from rawPath: String) throws -> URL {
        let expandedPath = NSString(string: rawPath).expandingTildeInPath
        guard expandedPath.hasPrefix("/") else {
            throw TranslationSaveError.pathMustBeAbsolute
        }

        let fileURL = URL(fileURLWithPath: expandedPath).standardizedFileURL
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw TranslationSaveError.invalidFilePath
        }
        return fileURL
    }

    private func translationSaveFailureMessage(for error: Error) -> String {
        guard let translationError = error as? TranslationSaveError else {
            return "Save failed"
        }

        switch translationError {
        case .missingFilePath:
            return "Set file path"
        case .unsupportedInput:
            return "Only words or phrases"
        case .emptyContent:
            return "Nothing to save"
        case .encodingFailed:
            return "Encoding failed"
        case .pathMustBeAbsolute:
            return "Use /... or ~/..."
        case .invalidFilePath:
            return "Path points to folder"
        }
    }

    private enum TranslationSaveError: Error {
        case missingFilePath
        case unsupportedInput
        case emptyContent
        case encodingFailed
        case pathMustBeAbsolute
        case invalidFilePath
    }

    private func speechVoiceLanguage() -> String {
        containsChineseCharacters(selectedText) ? "zh-CN" : "en-US"
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

    private func extractFirstWebURL(from input: String) -> URL? {
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let nsInput = trimmedInput as NSString
        let matches = detector?.matches(in: trimmedInput, options: [], range: NSRange(location: 0, length: nsInput.length)) ?? []

        for match in matches {
            guard let url = match.url else { continue }
            if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                return url
            }
        }

        if let url = URL(string: trimmedInput), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            return url
        }

        // Support links without scheme, e.g. mp.weixin.qq.com/s/xxxx
        let candidate = trimmedInput
            .split(whereSeparator: { $0.isWhitespace || $0 == "\"" || $0 == "'" })
            .map(String.init)
            .first ?? trimmedInput
        if let normalized = normalizedURLString(candidate),
           let url = URL(string: normalized),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return url
        }

        return nil
    }

    private func fetchReadablePageText(from url: URL) async throws -> String {
        let html: String
        do {
            html = try await fetchHTML(from: url)
        } catch let urlError as URLError where urlError.code == .appTransportSecurityRequiresSecureConnection {
            // Fallback for sites blocked by ATS/redirect policies.
            html = try await fetchHTMLViaReaderProxy(for: url)
        } catch {
            // Some sites fail direct load for anti-bot/TLS quirks; try reader proxy once.
            html = try await fetchHTMLViaReaderProxy(for: url)
        }

        let text = extractReadableText(fromHTML: html)
        let normalized = text.replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        guard !normalized.isEmpty else {
            throw WebSummaryError.emptyPageContent
        }

        return String(normalized.prefix(12000))
    }

    private func fetchHTML(from url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw WebSummaryError.requestFailed
        }
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .unicode) else {
            throw WebSummaryError.invalidPageContent
        }
        return html
    }

    private func fetchHTMLViaReaderProxy(for url: URL) async throws -> String {
        let absolute = url.absoluteString
        let noScheme = absolute.replacingOccurrences(of: #"^https?://"#, with: "", options: .regularExpression)
        let candidates = [
            "https://r.jina.ai/http://\(noScheme)",
            "https://r.jina.ai/http://\(absolute)"
        ]

        for target in candidates {
            guard let proxyURL = URL(string: target) else { continue }
            do {
                var request = URLRequest(url: proxyURL)
                request.timeoutInterval = 20
                request.setValue("text/plain", forHTTPHeaderField: "Accept")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    continue
                }
                if let body = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .unicode),
                   !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return body
                }
            } catch {
                continue
            }
        }
        throw WebSummaryError.requestFailed
    }

    private func normalizedURLString(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.lowercased().hasPrefix("http://") || value.lowercased().hasPrefix("https://") {
            return value
        }
        if value.range(of: #"^[A-Za-z0-9.-]+\.[A-Za-z]{2,}([/:?].*)?$"#, options: .regularExpression) != nil {
            return "https://\(value)"
        }
        return nil
    }

    private func extractReadableText(fromHTML html: String) -> String {
        var cleaned = html
        let patterns = [
            "(?is)<script[^>]*>.*?</script>",
            "(?is)<style[^>]*>.*?</style>",
            "(?is)<noscript[^>]*>.*?</noscript>",
            "(?is)<!--.*?-->"
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let range = NSRange(location: 0, length: (cleaned as NSString).length)
                cleaned = regex.stringByReplacingMatches(in: cleaned, options: [], range: range, withTemplate: " ")
            }
        }

        cleaned = cleaned.replacingOccurrences(of: "(?i)</p>|</div>|</li>|</h[1-6]>", with: "\n", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "(?is)<[^>]+>", with: " ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "&nbsp;", with: " ")
        cleaned = cleaned.replacingOccurrences(of: "&amp;", with: "&")
        cleaned = cleaned.replacingOccurrences(of: "&lt;", with: "<")
        cleaned = cleaned.replacingOccurrences(of: "&gt;", with: ">")
        cleaned = cleaned.replacingOccurrences(of: "&quot;", with: "\"")
        cleaned = cleaned.replacingOccurrences(of: "&#39;", with: "'")
        return cleaned
    }

    private enum QueryType {
        case translate
        case search
    }

    private func currentProviderId(for queryType: QueryType) -> String {
        let config = configLoader.loadConfig()
        switch queryType {
        case .translate:
            return config.defaults.translateProviderId
        case .search:
            return config.defaults.searchProviderId
        }
    }

    private func annotateResult(_ text: String, providerId: String, elapsedMs: Int) -> String {
        "ProviderID: \(providerId)\nLatency: \(elapsedMs) ms\n\(text)"
    }

    private func annotateStreamingResult(_ text: String, providerId: String) -> String {
        if text.isEmpty {
            return "ProviderID: \(providerId)\nLatency: streaming...\n"
        }
        return "ProviderID: \(providerId)\nLatency: streaming...\n\(text)"
    }

    private func formattedYouTubeTranscriptResult(_ result: YouTubeTranscriptClient.TranscriptResult) -> String {
        """
        Source: \(result.source)
        VideoID: \(result.videoID)
        Language: \(result.languageCode)

        Debug:
        \(result.debugText)

        Transcript:
        \(result.text)
        """
    }

    private func formattedYouTubeTranscriptError(_ error: Error) -> String {
        if let debugFailure = error as? YouTubeTranscriptClient.TranscriptDebugFailure {
            return """
            Transcript error: \(debugFailure.message)

            Debug:
            \(debugFailure.debugText)
            """
        }
        return "Transcript error: \(error.localizedDescription)"
    }

    private func summarizedTranscriptInput(_ result: YouTubeTranscriptClient.TranscriptResult) -> String {
        """
        YouTube transcript metadata:
        - VideoID: \(result.videoID)
        - Language: \(result.languageCode)
        - Source: \(result.source)

        Transcript:
        \(result.text)
        """
    }

    private func webSummaryDisplayBody(summary: String?) -> String {
        let normalizedSummary = summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalizedSummary.isEmpty ? "正在生成摘要..." : normalizedSummary
    }

    var resultProviderLabel: String {
        if providerLabelState != "ProviderID: -" {
            return providerLabelState
        }
        let lines = resultText.components(separatedBy: .newlines)
        guard let first = lines.first, first.hasPrefix("ProviderID: ") else { return "ProviderID: -" }
        return first
    }

    var resultLatencyLabel: String {
        if latencyLabelState != "Latency: -" {
            return latencyLabelState
        }
        let lines = resultText.components(separatedBy: .newlines)
        guard lines.count >= 2, lines[1].hasPrefix("Latency: ") else { return "Latency: -" }
        return lines[1]
    }

    var formattedResultBody: String {
        let lines = resultText.components(separatedBy: .newlines)
        var bodyLines = lines
        if lines.count >= 2, lines[0].hasPrefix("ProviderID: "), lines[1].hasPrefix("Latency: ") {
            bodyLines = Array(lines.dropFirst(2))
        }
        let body = bodyLines.joined(separator: "\n")
        return beautifyResultBody(body)
    }

    func copyFormattedResultToPasteboard() {
        let text = formattedResultBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func beautifyResultBody(_ input: String) -> String {
        var text = input.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if text.hasPrefix("```"), text.hasSuffix("```") {
            var lines = text.components(separatedBy: .newlines)
            if !lines.isEmpty { lines.removeFirst() }
            if !lines.isEmpty { lines.removeLast() }
            text = lines.joined(separator: "\n")
        }

        var normalizedLines: [String] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if normalizedLines.last != "" {
                    normalizedLines.append("")
                }
                continue
            }

            let isHeading = line.hasPrefix("#")
            let isBullet = line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ")
            let isOrdered = line.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil
            if (isHeading || isBullet || isOrdered), !normalizedLines.isEmpty, normalizedLines.last != "" {
                normalizedLines.append("")
            }
            normalizedLines.append(line)
        }

        while normalizedLines.last == "" {
            normalizedLines.removeLast()
        }
        return normalizedLines.joined(separator: "\n")
    }

    private func hasConversationStateToRestore() -> Bool {
        !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !resultText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !translationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !ipaText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !partOfSpeechText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func beginLatency(providerId: String) -> UUID {
        endLatency(token: activeLatencyToken, elapsedMs: nil)
        let token = UUID()
        activeLatencyToken = token
        providerLabelState = "ProviderID: \(providerId)"
        latencyStartDate = Date()
        latencyLabelState = "Latency: 0.0 s"

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.activeLatencyToken == token else { return }
            guard let start = self.latencyStartDate else { return }
            let elapsed = Date().timeIntervalSince(start)
            self.latencyLabelState = String(format: "Latency: %.1f s", elapsed)
        }
        timer.resume()
        latencyTimer = timer
        return token
    }

    private func endLatency(token: UUID, elapsedMs: Int?) {
        guard activeLatencyToken == token else { return }
        latencyTimer?.cancel()
        latencyTimer = nil

        let finalMs: Int
        if let elapsedMs {
            finalMs = max(0, elapsedMs)
        } else if let start = latencyStartDate {
            finalMs = max(0, Int(Date().timeIntervalSince(start) * 1000))
        } else {
            finalMs = 0
        }
        latencyLabelState = "Latency: \(finalMs) ms"
        latencyStartDate = nil
    }

    private func resetLatencyDisplay() {
        latencyTimer?.cancel()
        latencyTimer = nil
        latencyStartDate = nil
        activeLatencyToken = UUID()
        providerLabelState = "ProviderID: -"
        latencyLabelState = "Latency: -"
    }

    private enum WebSummaryError: LocalizedError {
        case requestFailed
        case invalidPageContent
        case emptyPageContent

        var errorDescription: String? {
            switch self {
            case .requestFailed:
                return "Failed to fetch webpage."
            case .invalidPageContent:
                return "Webpage content is invalid."
            case .emptyPageContent:
                return "Webpage text is empty."
            }
        }
    }
}
