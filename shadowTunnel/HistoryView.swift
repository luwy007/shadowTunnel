import SwiftUI

struct HistoryView: View {
    @ObservedObject var store: HistoryStore
    @State private var query: String = ""

    private var filtered: [HistoryEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return store.entries }
        return store.entries.filter { entry in
            entry.input.localizedCaseInsensitiveContains(q) ||
            entry.output.localizedCaseInsensitiveContains(q) ||
            entry.action.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Search history", text: $query)
                Button("Clear") { store.clear() }
            }
            List(filtered) { entry in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(entry.action.capitalized)
                            .font(.footnote.weight(.semibold))
                        Spacer()
                        Text(formatDate(entry.date))
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    Text(entry.input)
                        .font(.callout)
                    Text(entry.output)
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func formatDate(_ date: Date) -> String {
        Self.historyDateFormatter.string(from: date)
    }

    private static let historyDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
