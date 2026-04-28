import Foundation
import AppKit

final class UserSettings: ObservableObject {
    @Published var fontSize: Double {
        didSet {
            UserDefaults.standard.set(fontSize, forKey: Self.fontSizeKey)
        }
    }
    @Published var supadataAPIKey: String {
        didSet {
            UserDefaults.standard.set(supadataAPIKey, forKey: Self.supadataAPIKeyKey)
        }
    }
    @Published var translationSaveFilePath: String {
        didSet {
            UserDefaults.standard.set(translationSaveFilePath, forKey: Self.translationSaveFilePathKey)
        }
    }
    @Published var autoTranslateOnOpen: Bool {
        didSet {
            UserDefaults.standard.set(autoTranslateOnOpen, forKey: Self.autoTranslateOnOpenKey)
        }
    }

    private static let fontSizeKey = "shadowTunnel.fontSize"
    private static let supadataAPIKeyKey = "shadowTunnel.supadataAPIKey"
    private static let translationSaveFilePathKey = "shadowTunnel.translationSaveFilePath"
    private static let autoTranslateOnOpenKey = "shadowTunnel.autoTranslateOnOpen"

    init() {
        let value = UserDefaults.standard.double(forKey: Self.fontSizeKey)
        fontSize = value > 0 ? value : 13
        supadataAPIKey =
            UserDefaults.standard.string(forKey: Self.supadataAPIKeyKey)
            ?? UserDefaults.standard.string(forKey: "shadowTunnel.youtubeAPIKey")
            ?? ""
        translationSaveFilePath = UserDefaults.standard.string(forKey: Self.translationSaveFilePathKey) ?? ""
        if UserDefaults.standard.object(forKey: Self.autoTranslateOnOpenKey) == nil {
            autoTranslateOnOpen = false
        } else {
            autoTranslateOnOpen = UserDefaults.standard.bool(forKey: Self.autoTranslateOnOpenKey)
        }
    }
}
