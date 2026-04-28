import Foundation

struct HistoryEntry: Codable, Identifiable {
    let id: UUID
    let date: Date
    let action: String
    let input: String
    let output: String
}

final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []
    private let fileURL: URL

    init() {
        fileURL = Self.resolveHistoryFileURL(fileManager: .default)
        load()
    }

    private static func resolveHistoryFileURL(fileManager: FileManager) -> URL {
        let preferredDirectory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("shadowTunnel", isDirectory: true)

        if ensureDirectoryExists(preferredDirectory, fileManager: fileManager) {
            return preferredDirectory.appendingPathComponent("history.json")
        }

        let fallbackDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("shadowTunnel", isDirectory: true)
        _ = ensureDirectoryExists(fallbackDirectory, fileManager: fileManager)
        return fallbackDirectory.appendingPathComponent("history.json")
    }

    private static func ensureDirectoryExists(_ directoryURL: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory) {
            return isDirectory.boolValue
        }

        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            return true
        } catch {
            NSLog("shadowTunnel failed to create directory at %@: %@", directoryURL.path, error.localizedDescription)
            return false
        }
    }

    func add(action: String, input: String, output: String) {
        let entry = HistoryEntry(id: UUID(), date: Date(), action: action, input: input, output: output)
        entries.insert(entry, at: 0)
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = decoded
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(entries) {
            try? data.write(to: fileURL, options: [.atomic])
        }
    }
}
