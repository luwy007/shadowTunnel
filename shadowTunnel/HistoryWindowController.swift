import Cocoa
import SwiftUI

final class HistoryWindowController {
    private let window: NSWindow

    init(store: HistoryStore) {
        let view = HistoryView(store: store)
        let hosting = NSHostingView(rootView: view)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "History"
        window.contentView = hosting
        window.isReleasedWhenClosed = false
    }

    func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
